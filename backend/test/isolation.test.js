// Testes de integracao contra o mesmo Postgres de dev do projeto (nao ha
// camada de mock em lugar nenhum do backend). Cada rodada cria seu proprio
// tenant isolado (nomes/e-mails com sufixo unico) e apaga tudo no final --
// apagar o tenant e o suficiente, todo o resto tem ON DELETE CASCADE nele.
//
// Cobre exatamente a logica que uma revisao de seguranca encontrou fragil:
// isolamento multi-tenant em /students, /trips/:id/events, /trips/:id/finish,
// /trips/:id/locations e /trips/:id/location, alem de login sem ambiguidade
// de e-mail e invalidacao de token na troca de senha.
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');

const suffix = Date.now();
let app, server, db, baseUrl;
let tenantId;
let adminToken, driverToken, driver2Token, parentToken, unrelatedParentToken;
let studentId, routeId;

async function post(path, body, token) {
  return fetch(`${baseUrl}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
}
async function get(path, token) {
  return fetch(`${baseUrl}${path}`, { headers: token ? { authorization: `Bearer ${token}` } : {} });
}
async function put(path, body, token) {
  return fetch(`${baseUrl}${path}`, {
    method: 'PUT',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
}

before(async () => {
  ({ app, server } = require('../src/server'));
  db = require('../src/db');
  await new Promise((resolve) => server.listen(0, resolve));
  baseUrl = `http://localhost:${server.address().port}`;

  const reg = await post('/api/auth/register-tenant', {
    tenantName: `Tenant Teste ${suffix}`,
    name: 'Admin Teste',
    email: `admin-${suffix}@test.local`,
    password: 'senha123',
  }).then((r) => r.json());
  adminToken = reg.token;
  tenantId = reg.tenantId;

  async function createUser(role, name, email) {
    await post('/api/users', { role, name, email, password: 'senha123' }, adminToken);
    const r = await post('/api/auth/login', { email, password: 'senha123' }).then((x) => x.json());
    return r.token;
  }
  driverToken = await createUser('driver', 'Motorista Teste', `driver-${suffix}@test.local`);
  driver2Token = await createUser('driver', 'Motorista Intruso Teste', `driver2-${suffix}@test.local`);
  parentToken = await createUser('parent', 'Responsavel Teste', `parent-${suffix}@test.local`);
  unrelatedParentToken = await createUser('parent', 'Responsavel Nao Vinculado', `parent2-${suffix}@test.local`);

  const student = await post('/api/students', { name: 'Aluno Teste' }, adminToken).then((r) => r.json());
  studentId = student.id;
  const route = await post('/api/routes', { name: 'Rota Teste' }, adminToken).then((r) => r.json());
  routeId = route.id;
  await post(`/api/routes/${routeId}/students`, { student_id: studentId }, adminToken);

  const parentUserId = (await db.query('SELECT id FROM users WHERE email=$1', [`parent-${suffix}@test.local`])).rows[0].id;
  await db.query('INSERT INTO student_guardians(tenant_id, student_id, guardian_user_id) VALUES($1,$2,$3)', [
    tenantId, studentId, parentUserId,
  ]);
});

after(async () => {
  await db.query('DELETE FROM tenants WHERE id=$1', [tenantId]);
  await new Promise((resolve) => server.close(resolve));
  await db.pool.end();
});

test('GET /api/students exige admin (responsavel nao pode listar todos os alunos)', async () => {
  const asParent = await get('/api/students', parentToken);
  assert.equal(asParent.status, 403);
  const asAdmin = await get('/api/students', adminToken);
  assert.equal(asAdmin.status, 200);
});

test('POST /api/trips/:id/events rejeita aluno que nao esta na rota da viagem', async () => {
  const trip = await post('/api/trips/start', { route_id: routeId, direction: 'to_school' }, driverToken).then((r) => r.json());
  const outroAluno = await post('/api/students', { name: 'Aluno Fora Da Rota' }, adminToken).then((r) => r.json());
  const res = await post(`/api/trips/${trip.tripId}/events`, { student_id: outroAluno.id, type: 'boarded' }, driverToken);
  assert.equal(res.status, 404);
  await post(`/api/trips/${trip.tripId}/finish`, {}, driverToken);
});

test('motorista nao consegue iniciar duas viagens ativas', async () => {
  const first = await post('/api/trips/start', { route_id: routeId, direction: 'to_school' }, driverToken);
  assert.equal(first.status, 200);
  const { tripId } = await first.json();

  const duplicate = await post('/api/trips/start', { route_id: routeId, direction: 'to_home' }, driverToken);
  assert.equal(duplicate.status, 409);
  const body = await duplicate.json();
  assert.equal(body.tripId, tripId);

  await post(`/api/trips/${tripId}/finish`, {}, driverToken);
});

test('aviso de chegada em 5 minutos e persistido e nao duplica', async () => {
  const started = await post('/api/trips/start', { route_id: routeId, direction: 'to_home' }, driverToken);
  const { tripId } = await started.json();

  const first = await post(`/api/trips/${tripId}/students/${studentId}/approaching`, {}, driverToken);
  assert.equal(first.status, 200);
  assert.equal((await first.json()).alreadySent, false);

  const duplicate = await post(`/api/trips/${tripId}/students/${studentId}/approaching`, {}, driverToken);
  assert.equal(duplicate.status, 200);
  assert.equal((await duplicate.json()).alreadySent, true);

  const students = await get(`/api/trips/${tripId}/students`, driverToken).then((r) => r.json());
  assert.equal(students.find((s) => s.id === studentId).approaching_alert_sent, true);

  const notifications = await get('/api/notifications', parentToken).then((r) => r.json());
  const alerts = notifications.filter((n) => n.type === 'approaching' && n.entity_id === tripId);
  assert.equal(alerts.length, 1);

  await post(`/api/trips/${tripId}/finish`, {}, driverToken);
});

test('WebSocket autoriza somente responsavel vinculado e transmite localizacao', async () => {
  const started = await post('/api/trips/start', { route_id: routeId, direction: 'to_school' }, driverToken);
  const { tripId } = await started.json();
  const wsBase = baseUrl.replace('http://', 'ws://');

  const deniedStatus = await new Promise((resolve, reject) => {
    const denied = new WebSocket(`${wsBase}/?tripId=${tripId}`, {
      headers: { authorization: `Bearer ${unrelatedParentToken}` },
    });
    denied.once('unexpected-response', (_request, response) => resolve(response.statusCode));
    denied.once('open', () => reject(new Error('responsavel sem vinculo conectou')));
    denied.once('error', () => {});
  });
  assert.equal(deniedStatus, 403);

  const socket = new WebSocket(`${wsBase}/?tripId=${tripId}`, {
    headers: { authorization: `Bearer ${parentToken}` },
  });
  const subscribed = await new Promise((resolve, reject) => {
    socket.once('message', (data) => resolve(JSON.parse(data.toString())));
    socket.once('error', reject);
  });
  assert.equal(subscribed.type, 'subscribed');
  assert.equal(subscribed.tripId, tripId);

  const locationMessage = new Promise((resolve, reject) => {
    socket.once('message', (data) => resolve(JSON.parse(data.toString())));
    socket.once('error', reject);
  });
  const location = await post(`/api/trips/${tripId}/locations`, { lat: -23.55, lng: -46.63 }, driverToken);
  assert.equal(location.status, 200);
  const received = await locationMessage;
  assert.equal(received.type, 'location');
  assert.equal(received.tripId, tripId);
  assert.equal(received.lat, -23.55);

  socket.close();
  await post(`/api/trips/${tripId}/finish`, {}, driverToken);
});

test('POST /api/trips/:id/finish e /locations exigem ser o motorista dono da viagem', async () => {
  const trip = await post('/api/trips/start', { route_id: routeId, direction: 'to_school' }, driverToken).then((r) => r.json());

  const finishByIntruder = await post(`/api/trips/${trip.tripId}/finish`, {}, driver2Token);
  assert.equal(finishByIntruder.status, 404);

  const pingByIntruder = await post(`/api/trips/${trip.tripId}/locations`, { lat: -1, lng: -1 }, driver2Token);
  assert.equal(pingByIntruder.status, 404);

  const finishByOwner = await post(`/api/trips/${trip.tripId}/finish`, {}, driverToken);
  assert.equal(finishByOwner.status, 200);
});

test('GET /api/trips/:id/location exige o responsavel ter filho vinculado aquela viagem', async () => {
  const trip = await post('/api/trips/start', { route_id: routeId, direction: 'to_school' }, driverToken).then((r) => r.json());

  const unrelated = await get(`/api/trips/${trip.tripId}/location`, unrelatedParentToken);
  assert.equal(unrelated.status, 403);

  const related = await get(`/api/trips/${trip.tripId}/location`, parentToken);
  assert.equal(related.status, 200);

  await post(`/api/trips/${trip.tripId}/finish`, {}, driverToken);
});

test('responsavel perde acesso ao GPS assim que o proprio filho desembarca', async () => {
  const trip = await post('/api/trips/start', { route_id: routeId, direction: 'to_school' }, driverToken).then((r) => r.json());
  await post(`/api/trips/${trip.tripId}/events`, { student_id: studentId, type: 'boarded' }, driverToken);
  await post(`/api/trips/${trip.tripId}/events`, { student_id: studentId, type: 'dropped' }, driverToken);

  const location = await get(`/api/trips/${trip.tripId}/location`, parentToken);
  assert.equal(location.status, 403);

  const wsBase = baseUrl.replace('http://', 'ws://');
  const deniedStatus = await new Promise((resolve, reject) => {
    const denied = new WebSocket(`${wsBase}/?tripId=${trip.tripId}`, {
      headers: { authorization: `Bearer ${parentToken}` },
    });
    denied.once('unexpected-response', (_request, response) => resolve(response.statusCode));
    denied.once('open', () => reject(new Error('responsavel continuou rastreando depois do desembarque')));
    denied.once('error', () => {});
  });
  assert.equal(deniedStatus, 403);
  await post(`/api/trips/${trip.tripId}/finish`, {}, driverToken);
});

test('timeline do responsavel contem somente eventos dos proprios filhos', async () => {
  const otherStudent = await post('/api/students', { name: 'Outro Aluno Da Rota' }, adminToken).then((r) => r.json());
  await post(`/api/routes/${routeId}/students`, { student_id: otherStudent.id }, adminToken);
  const otherParentId = (await db.query(
    'SELECT id FROM users WHERE email=$1', [`parent2-${suffix}@test.local`]
  )).rows[0].id;
  await db.query(
    'INSERT INTO student_guardians(tenant_id, student_id, guardian_user_id) VALUES($1,$2,$3)',
    [tenantId, otherStudent.id, otherParentId]
  );

  const trip = await post('/api/trips/start', { route_id: routeId, direction: 'to_school' }, driverToken).then((r) => r.json());
  await post(`/api/trips/${trip.tripId}/events`, { student_id: studentId, type: 'dropped' }, driverToken);
  await post(`/api/trips/${trip.tripId}/events`, { student_id: otherStudent.id, type: 'dropped' }, driverToken);
  const events = await get(`/api/trips/${trip.tripId}/events`, parentToken).then((r) => r.json());
  assert.ok(events.length > 0);
  assert.ok(events.every((event) => event.student_name === 'Aluno Teste'));
  await post(`/api/trips/${trip.tripId}/finish`, {}, driverToken);
});

test('motorista nao le alunos da viagem de outro motorista', async () => {
  const trip = await post('/api/trips/start', { route_id: routeId, direction: 'to_school' }, driverToken).then((r) => r.json());
  const students = await get(`/api/trips/${trip.tripId}/students`, driver2Token).then((r) => r.json());
  assert.deepEqual(students, []);
  await post(`/api/trips/${trip.tripId}/finish`, {}, driverToken);
});

test('cadastros rejeitam senha numerica trivial', async () => {
  const res = await post('/api/users', {
    role: 'parent', name: 'Senha Fraca', email: `weak-${suffix}@test.local`, password: '123456'
  }, adminToken);
  assert.equal(res.status, 400);
});

test('responsavel lista somente rotas que atendem seus filhos', async () => {
  const unrelated = await post('/api/routes', { name: 'Rota Sem Meu Filho' }, adminToken).then((r) => r.json());
  const routes = await get('/api/routes', parentToken).then((r) => r.json());
  assert.ok(routes.some((route) => route.id === routeId));
  assert.ok(!routes.some((route) => route.id === unrelated.id));
});

test('login resolve pelo e-mail sem precisar de tenantId (e-mail e unico globalmente)', async () => {
  const res = await post('/api/auth/login', { email: `ADMIN-${suffix}@TEST.LOCAL`, password: 'senha123' }).then((r) => r.json());
  assert.equal(res.tenantId, tenantId);
});

test('trocar a propria senha invalida o token antigo e devolve um novo valido', async () => {
  const changed = await put('/api/auth/password', { currentPassword: 'senha123', newPassword: 'senha456' }, driverToken)
    .then((r) => r.json());
  assert.ok(changed.token, 'deveria devolver um token novo');

  const oldTokenNow = await get('/api/auth/me', driverToken);
  assert.equal(oldTokenNow.status, 401);

  const newTokenNow = await get('/api/auth/me', changed.token);
  assert.equal(newTokenNow.status, 200);
});
