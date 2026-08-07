// Testes de integracao (mesmo Postgres de dev, tenant proprio isolado por
// sufixo unico) cobrindo a validacao de payload adicionada nesta rodada:
// lat/lng fora da faixa geografica valida, lote de GPS acima do limite, e
// valor de pagamento negativo -- tudo deve responder 400 com uma mensagem
// amigavel, em vez de deixar passar ou estourar um erro cru do Postgres.
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

const suffix = Date.now();
let app, server, db, baseUrl;
let tenantId;
let adminToken, driverToken;
let studentId, routeId, tripId, paymentId;

async function post(path, body, token) {
  return fetch(`${baseUrl}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
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
    tenantName: `Tenant Validacao ${suffix}`,
    name: 'Admin Validacao',
    email: `admin-valid-${suffix}@test.local`,
    password: 'senha123',
  }).then((r) => r.json());
  adminToken = reg.token;
  tenantId = reg.tenantId;

  await post('/api/users', { role: 'driver', name: 'Motorista Validacao', email: `driver-valid-${suffix}@test.local`, password: 'senha123' }, adminToken);
  driverToken = await post('/api/auth/login', { email: `driver-valid-${suffix}@test.local`, password: 'senha123' })
    .then((r) => r.json()).then((r) => r.token);

  const student = await post('/api/students', { name: 'Aluno Validacao', monthly_fee: 100 }, adminToken).then((r) => r.json());
  studentId = student.id;
  const route = await post('/api/routes', { name: 'Rota Validacao' }, adminToken).then((r) => r.json());
  routeId = route.id;
  await post(`/api/routes/${routeId}/students`, { student_id: studentId }, adminToken);

  const trip = await post('/api/trips/start', { route_id: routeId, direction: 'to_school' }, driverToken).then((r) => r.json());
  tripId = trip.tripId;

  await post('/api/payments/generate', { month: '2020-01' }, adminToken);
  const payments = await fetch(`${baseUrl}/api/payments?month=2020-01`, { headers: { authorization: `Bearer ${adminToken}` } }).then((r) => r.json());
  paymentId = payments[0].id;
});

after(async () => {
  await post(`/api/trips/${tripId}/finish`, {}, driverToken);
  await db.query('DELETE FROM tenants WHERE id=$1', [tenantId]);
  await new Promise((resolve) => server.close(resolve));
  await db.pool.end();
});

test('POST /api/trips/:id/locations rejeita latitude/longitude fora da faixa valida', async () => {
  const badLat = await post(`/api/trips/${tripId}/locations`, { lat: 200, lng: -46.6 }, driverToken);
  assert.equal(badLat.status, 400);
  const badLng = await post(`/api/trips/${tripId}/locations`, { lat: -23.5, lng: -300 }, driverToken);
  assert.equal(badLng.status, 400);
  const ok = await post(`/api/trips/${tripId}/locations`, { lat: -23.5, lng: -46.6 }, driverToken);
  assert.equal(ok.status, 200);
});

test('POST /api/trips/:id/locations rejeita lote de GPS acima do limite de 200 itens', async () => {
  const bigBatch = Array.from({ length: 201 }, () => ({ lat: -23.5, lng: -46.6 }));
  const res = await post(`/api/trips/${tripId}/locations`, bigBatch, driverToken);
  assert.equal(res.status, 400);

  const okBatch = Array.from({ length: 200 }, () => ({ lat: -23.5, lng: -46.6 }));
  const okRes = await post(`/api/trips/${tripId}/locations`, okBatch, driverToken);
  assert.equal(okRes.status, 200);
});

test('POST /api/trips/:id/locations rejeita lote vazio', async () => {
  const res = await post(`/api/trips/${tripId}/locations`, [], driverToken);
  assert.equal(res.status, 400);
});

test('PUT /api/payments/:id rejeita valor negativo', async () => {
  const res = await put(`/api/payments/${paymentId}`, { amount: -50 }, adminToken);
  assert.equal(res.status, 400);
  const ok = await put(`/api/payments/${paymentId}`, { amount: 100, status: 'paid' }, adminToken);
  assert.equal(ok.status, 200);
});

// Regressao: o app_motorista sempre manda os 4 campos opcionais no corpo
// (amount/notes/payment_method/paid_at), usando `null` explicito pros que
// nao mudaram -- e nao omitindo a chave. Um schema `.optional()` sem
// `.nullable()` rejeita `null` explicito (zod trata isso como "recebido
// null, esperado number"), then o "Estornar" do financeiro falhava com 400
// silenciosamente (a UI so recarregava a lista sem mostrar erro).
test('PUT /api/payments/:id aceita null explicito nos campos opcionais (estornar)', async () => {
  const res = await put(
    `/api/payments/${paymentId}`,
    { status: 'pending', amount: null, notes: null, payment_method: null, paid_at: null },
    adminToken
  );
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.status, 'pending');
});

test('veiculo rejeita placa fora dos formatos brasileiro e Mercosul', async () => {
  const invalid = await post('/api/vehicles', { plate: 'VAN-123', capacity: 15 }, adminToken);
  assert.equal(invalid.status, 400);
  const valid = await post('/api/vehicles', { plate: 'BRA2E19', capacity: 15 }, adminToken);
  assert.equal(valid.status, 200);
});

test('aluno persiste endereco estruturado e coordenadas validadas', async () => {
  const res = await post('/api/students', {
    name: 'Aluno Com Coordenadas',
    home_address: 'Praca da Se, 1 - Se - Sao Paulo - SP - 01001000',
    home_postal_code: '01001000', home_street: 'Praca da Se', home_number: '1',
    home_neighborhood: 'Se', home_city: 'Sao Paulo', home_state: 'SP',
    home_lat: -23.5505, home_lng: -46.6333,
  }, adminToken);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.home_postal_code, '01001000');
  assert.equal(body.home_lat, -23.5505);
});
