// Testes de integracao (mesmo Postgres de dev, tenant proprio isolado por
// sufixo unico) cobrindo os endpoints novos da rodada de campos/cadastros:
// editar/excluir veiculo, editar/desativar usuario, e login rejeitando
// conta desativada.
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

const suffix = Date.now();
let app, server, db, baseUrl;
let tenantId;
let adminToken;
let driverUserId, driverEmail;

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
async function del(path, token) {
  return fetch(`${baseUrl}${path}`, { method: 'DELETE', headers: token ? { authorization: `Bearer ${token}` } : {} });
}

before(async () => {
  ({ app, server } = require('../src/server'));
  db = require('../src/db');
  await new Promise((resolve) => server.listen(0, resolve));
  baseUrl = `http://localhost:${server.address().port}`;

  const reg = await post('/api/auth/register-tenant', {
    tenantName: `Tenant Accounts ${suffix}`,
    name: 'Admin Accounts',
    email: `admin-acc-${suffix}@test.local`,
    password: 'senha123',
  }).then((r) => r.json());
  adminToken = reg.token;
  tenantId = reg.tenantId;

  driverEmail = `driver-acc-${suffix}@test.local`;
  const created = await post('/api/users', { role: 'driver', name: 'Motorista Accounts', email: driverEmail, password: 'senha123' }, adminToken)
    .then((r) => r.json());
  driverUserId = created.id;
});

after(async () => {
  await db.query('DELETE FROM tenants WHERE id=$1', [tenantId]);
  await new Promise((resolve) => server.close(resolve));
  await db.pool.end();
});

test('PUT /api/vehicles/:id edita e DELETE remove', async () => {
  const v = await post('/api/vehicles', { plate: 'ABC1234', capacity: 15 }, adminToken).then((r) => r.json());
  const updated = await put(`/api/vehicles/${v.id}`, { plate: 'ABC1234', capacity: 20, color: 'branco', year: 2020 }, adminToken)
    .then((r) => r.json());
  assert.equal(updated.capacity, 20);
  assert.equal(updated.color, 'branco');

  const delRes = await del(`/api/vehicles/${v.id}`, adminToken);
  assert.equal(delRes.status, 200);
  const delAgain = await del(`/api/vehicles/${v.id}`, adminToken);
  assert.equal(delAgain.status, 404);
});

test('PUT /api/users/:id edita nome/telefone', async () => {
  const updated = await put(`/api/users/${driverUserId}`, { name: 'Motorista Renomeado', phone: '11999999999' }, adminToken)
    .then((r) => r.json());
  assert.equal(updated.name, 'Motorista Renomeado');
  assert.equal(updated.phone, '11999999999');
});

test('PUT /api/users/:id/active desativa e login passa a rejeitar', async () => {
  const loginOk = await post('/api/auth/login', { email: driverEmail, password: 'senha123' });
  assert.equal(loginOk.status, 200);

  const deactivated = await put(`/api/users/${driverUserId}/active`, { active: false }, adminToken).then((r) => r.json());
  assert.equal(deactivated.active, false);

  const loginBlocked = await post('/api/auth/login', { email: driverEmail, password: 'senha123' });
  assert.equal(loginBlocked.status, 401);

  const reactivated = await put(`/api/users/${driverUserId}/active`, { active: true }, adminToken).then((r) => r.json());
  assert.equal(reactivated.active, true);
  const loginAgain = await post('/api/auth/login', { email: driverEmail, password: 'senha123' });
  assert.equal(loginAgain.status, 200);
});

test('admin nao consegue desativar a propria conta', async () => {
  const meRes = await fetch(`${baseUrl}/api/auth/me`, { headers: { authorization: `Bearer ${adminToken}` } }).then((r) => r.json());
  const res = await put(`/api/users/${meRes.id}/active`, { active: false }, adminToken);
  assert.equal(res.status, 400);
});

test('responsavel exclui a propria conta somente apos confirmar a senha', async () => {
  const email = `parent-delete-${suffix}@test.local`;
  await post('/api/users', {
    role: 'parent', name: 'Responsavel Delete', email, password: 'senha123'
  }, adminToken);
  const login = await post('/api/auth/login', { email, password: 'senha123' }).then((r) => r.json());

  const wrong = await fetch(`${baseUrl}/api/auth/account`, {
    method: 'DELETE',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${login.token}` },
    body: JSON.stringify({ password: 'errada' }),
  });
  assert.equal(wrong.status, 400);

  const removed = await fetch(`${baseUrl}/api/auth/account`, {
    method: 'DELETE',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${login.token}` },
    body: JSON.stringify({ password: 'senha123' }),
  });
  assert.equal(removed.status, 200);
  const loginAgain = await post('/api/auth/login', { email, password: 'senha123' });
  assert.equal(loginAgain.status, 401);
});
