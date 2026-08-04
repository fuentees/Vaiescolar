// Testes de integracao (mesmo Postgres de dev, tenant proprio isolado por
// sufixo unico) cobrindo o chat desta rodada: limite de tamanho de
// mensagem, e o calculo de nao lidas (chat_reads) -- abrir a thread zera o
// contador, mandar mensagem nova incrementa pro outro lado.
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

const suffix = Date.now();
let app, server, db, baseUrl;
let tenantId;
let adminToken, parentToken, parentUserId;

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
    tenantName: `Tenant Chat ${suffix}`,
    name: 'Admin Chat',
    email: `admin-chat-${suffix}@test.local`,
    password: 'senha123',
  }).then((r) => r.json());
  adminToken = reg.token;
  tenantId = reg.tenantId;

  await post('/api/users', { role: 'parent', name: 'Pai Chat', email: `parent-chat-${suffix}@test.local`, password: 'senha123' }, adminToken);
  const login = await post('/api/auth/login', { email: `parent-chat-${suffix}@test.local`, password: 'senha123' }).then((r) => r.json());
  parentToken = login.token;
  parentUserId = login.userId;
  const student = await post('/api/students', { name: 'Aluno da Familia Chat' }, adminToken).then((r) => r.json());
  await post(`/api/students/${student.id}/guardians`, { guardian_user_id: parentUserId }, adminToken);
});

after(async () => {
  await db.query('DELETE FROM tenants WHERE id=$1', [tenantId]);
  await new Promise((resolve) => server.close(resolve));
  await db.pool.end();
});

test('POST /api/chat/:parentUserId rejeita mensagem acima de 1000 caracteres', async () => {
  const tooLong = 'a'.repeat(1001);
  const res = await post(`/api/chat/${parentUserId}`, { body: tooLong }, adminToken);
  assert.equal(res.status, 400);

  const ok = await post(`/api/chat/${parentUserId}`, { body: 'oi' }, adminToken);
  assert.equal(ok.status, 200);
});

test('abrir a thread zera nao lidas; mensagem nova incrementa pro outro lado', async () => {
  // admin manda mensagem -- pai ainda nao abriu a thread, deve contar como nao lida
  await post(`/api/chat/${parentUserId}`, { body: 'primeira mensagem' }, adminToken);
  const unreadBefore = await get('/api/chat/unread-count', parentToken).then((r) => r.json());
  assert.ok(unreadBefore.unread >= 1);

  // pai abre a thread (GET historico) -- marca como lida
  await get(`/api/chat/${parentUserId}`, parentToken);
  const unreadAfter = await get('/api/chat/unread-count', parentToken).then((r) => r.json());
  assert.equal(unreadAfter.unread, 0);

  // admin manda outra -- volta a contar 1 nao lida pro pai
  await post(`/api/chat/${parentUserId}`, { body: 'segunda mensagem' }, adminToken);
  const unreadFinal = await get('/api/chat/unread-count', parentToken).then((r) => r.json());
  assert.equal(unreadFinal.unread, 1);
});

test('GET /api/chat/threads inclui unread_count pro admin', async () => {
  await post(`/api/chat/${parentUserId}`, { body: 'mensagem do pai' }, parentToken);
  const threads = await get('/api/chat/threads', adminToken).then((r) => r.json());
  const thread = threads.find((t) => t.parent_user_id === parentUserId);
  assert.ok(thread, 'thread do pai deveria aparecer');
  assert.ok(Number(thread.unread_count) >= 1);
  assert.equal(thread.student_names, 'Aluno da Familia Chat');
});
