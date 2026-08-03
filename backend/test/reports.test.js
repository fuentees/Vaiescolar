// Testes de integracao (mesmo Postgres de dev, tenant proprio isolado por
// sufixo unico) cobrindo os filtros/paginacao/campos novos de relatorios
// (P1 fase 6): duration_seconds, filtro por motorista/rota/veiculo, offset,
// e o parametro ?months= do historico financeiro.
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

const suffix = Date.now();
let app, server, db, baseUrl;
let tenantId;
let adminToken, driver1Token, driver2Token;
let routeId;

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

before(async () => {
  ({ app, server } = require('../src/server'));
  db = require('../src/db');
  await new Promise((resolve) => server.listen(0, resolve));
  baseUrl = `http://localhost:${server.address().port}`;

  const reg = await post('/api/auth/register-tenant', {
    tenantName: `Tenant Reports ${suffix}`,
    name: 'Admin Reports',
    email: `admin-rep-${suffix}@test.local`,
    password: 'senha123',
  }).then((r) => r.json());
  adminToken = reg.token;
  tenantId = reg.tenantId;

  async function createDriver(email) {
    await post('/api/users', { role: 'driver', name: 'Motorista', email, password: 'senha123' }, adminToken);
    return post('/api/auth/login', { email, password: 'senha123' }).then((r) => r.json()).then((r) => r.token);
  }
  driver1Token = await createDriver(`driver1-rep-${suffix}@test.local`);
  driver2Token = await createDriver(`driver2-rep-${suffix}@test.local`);

  const route = await post('/api/routes', { name: 'Rota Reports' }, adminToken).then((r) => r.json());
  routeId = route.id;
  const student = await post('/api/students', { name: 'Aluno Reports' }, adminToken).then((r) => r.json());
  await post(`/api/routes/${routeId}/students`, { student_id: student.id }, adminToken);

  // 2 viagens do driver1, 1 do driver2, todas finalizadas.
  for (const token of [driver1Token, driver1Token, driver2Token]) {
    const trip = await post('/api/trips/start', { route_id: routeId, direction: 'to_school' }, token).then((r) => r.json());
    await post(`/api/trips/${trip.tripId}/finish`, {}, token);
  }
});

after(async () => {
  await db.query('DELETE FROM tenants WHERE id=$1', [tenantId]);
  await new Promise((resolve) => server.close(resolve));
  await db.pool.end();
});

test('GET /api/reports/trips filtra por driverId e inclui duration_seconds', async () => {
  const meDriver1 = await fetch(`${baseUrl}/api/auth/me`, { headers: { authorization: `Bearer ${driver1Token}` } }).then((r) => r.json());
  const res = await get(`/api/reports/trips?driverId=${meDriver1.id}`, adminToken).then((r) => r.json());
  assert.equal(res.length, 2);
  for (const trip of res) {
    assert.ok(typeof trip.duration_seconds === 'number');
    assert.ok('distance_km' in trip);
    assert.ok('event_count' in trip);
  }
});

test('GET /api/reports/trips filtra por routeId e pagina com limit/offset', async () => {
  const all = await get(`/api/reports/trips?routeId=${routeId}&limit=100`, adminToken).then((r) => r.json());
  assert.equal(all.length, 3);

  const page1 = await get(`/api/reports/trips?routeId=${routeId}&limit=2&offset=0`, adminToken).then((r) => r.json());
  const page2 = await get(`/api/reports/trips?routeId=${routeId}&limit=2&offset=2`, adminToken).then((r) => r.json());
  assert.equal(page1.length, 2);
  assert.equal(page2.length, 1);
});

test('GET /api/reports/financial-history aceita ?months=', async () => {
  const res12 = await get('/api/reports/financial-history?months=12', adminToken);
  assert.equal(res12.status, 200);
  const res1 = await get('/api/reports/financial-history?months=1', adminToken).then((r) => r.json());
  assert.ok(res1.length <= 1);
});

test('GET /api/reports/trips/:id devolve detalhe com timeline de eventos', async () => {
  const trips = await get(`/api/reports/trips?routeId=${routeId}&limit=1`, adminToken).then((r) => r.json());
  const detail = await get(`/api/reports/trips/${trips[0].id}`, adminToken).then((r) => r.json());
  assert.equal(detail.id, trips[0].id);
  assert.ok(Array.isArray(detail.events));
});
