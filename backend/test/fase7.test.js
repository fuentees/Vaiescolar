// Testes de integracao (P1 fase 7): historico de viagens do pai, central de
// notificacoes (pai e staff) e auditoria administrativa.
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

const suffix = Date.now();
let app, server, db, baseUrl;
let tenantId;
let adminToken, driverToken, parentToken;
let studentId, routeId, tripId;

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
async function del(path, token) {
  return fetch(`${baseUrl}${path}`, {
    method: 'DELETE',
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
}

before(async () => {
  ({ app, server } = require('../src/server'));
  db = require('../src/db');
  await new Promise((resolve) => server.listen(0, resolve));
  baseUrl = `http://localhost:${server.address().port}`;

  const reg = await post('/api/auth/register-tenant', {
    tenantName: `Tenant Fase7 ${suffix}`,
    name: 'Admin Fase7',
    email: `admin-f7-${suffix}@test.local`,
    password: 'senha123',
  }).then((r) => r.json());
  adminToken = reg.token;
  tenantId = reg.tenantId;
  await db.query(`UPDATE users SET is_platform_owner=true WHERE tenant_id=$1 AND role='admin'`, [tenantId]);

  await post('/api/users', { role: 'driver', name: 'Motorista Fase7', email: `driver-f7-${suffix}@test.local`, password: 'senha123' }, adminToken);
  driverToken = await post('/api/auth/login', { email: `driver-f7-${suffix}@test.local`, password: 'senha123' })
    .then((r) => r.json()).then((r) => r.token);

  const student = await post('/api/students', { name: 'Aluno Fase7' }, adminToken).then((r) => r.json());
  studentId = student.id;
  const route = await post('/api/routes', { name: 'Rota Fase7' }, adminToken).then((r) => r.json());
  routeId = route.id;
  await post(`/api/routes/${routeId}/students`, { student_id: studentId }, adminToken);

  const code = await post(`/api/students/${studentId}/invite`, {}, adminToken).then((r) => r.json()).then((r) => r.code);
  const parentReg = await post('/api/auth/register-parent', {
    code, name: 'Pai Fase7', email: `pai-f7-${suffix}@test.local`, password: 'senha123',
  }).then((r) => r.json());
  parentToken = parentReg.token;

  const trip = await post('/api/trips/start', { route_id: routeId, direction: 'to_school' }, driverToken).then((r) => r.json());
  tripId = trip.tripId;
  await post(`/api/trips/${tripId}/events`, { student_id: studentId, type: 'boarded' }, driverToken);
  const prematureFinish = await post(`/api/trips/${tripId}/finish`, {}, driverToken);
  assert.equal(prematureFinish.status, 409);
  await post(`/api/trips/${tripId}/events`, { student_id: studentId, type: 'dropped' }, driverToken);
  const finish = await post(`/api/trips/${tripId}/finish`, {}, driverToken);
  assert.equal(finish.status, 200);
});

after(async () => {
  await db.query('DELETE FROM tenants WHERE id=$1', [tenantId]);
  await new Promise((resolve) => server.close(resolve));
  await db.pool.end();
});

test('GET /api/trips/history exige studentId e retorna a viagem finalizada do aluno', async () => {
  const missing = await get('/api/trips/history', parentToken);
  assert.equal(missing.status, 400);

  const res = await get(`/api/trips/history?studentId=${studentId}`, parentToken).then((r) => r.json());
  assert.equal(res.length, 1);
  assert.equal(res[0].id, tripId);
  assert.equal(res[0].last_event_type, 'dropped');
});

test('GET /api/trips/history rejeita pai sem vinculo com o aluno (403)', async () => {
  await post('/api/users', { role: 'parent', name: 'Outro Pai', email: `outro-f7-${suffix}@test.local`, password: 'senha123' }, adminToken);
  const otherToken = await post('/api/auth/login', { email: `outro-f7-${suffix}@test.local`, password: 'senha123' })
    .then((r) => r.json()).then((r) => r.token);
  const res = await get(`/api/trips/history?studentId=${studentId}`, otherToken);
  assert.equal(res.status, 403);
});

test('GET /api/students/:id agora aceita o pai dono do aluno, mas rejeita outro pai', async () => {
  const own = await get(`/api/students/${studentId}`, parentToken);
  assert.equal(own.status, 200);
  const ownBody = await own.json();
  assert.equal(ownBody.id, studentId);
  assert.ok(Array.isArray(ownBody.guardians));

  const other = await post('/api/users', { role: 'parent', name: 'Pai Sem Vinculo', email: `semvinculo-f7-${suffix}@test.local`, password: 'senha123' }, adminToken)
    .then(() => post('/api/auth/login', { email: `semvinculo-f7-${suffix}@test.local`, password: 'senha123' }))
    .then((r) => r.json()).then((r) => r.token);
  const forbidden = await get(`/api/students/${studentId}`, other);
  assert.equal(forbidden.status, 403);
});

test('contrato individual registra assinatura e evidencias imutaveis', async () => {
  const issued = await post(`/api/students/${studentId}/contracts`, {}, adminToken);
  assert.equal(issued.status, 201);
  const contract = await issued.json();
  assert.equal(contract.status, 'pending');
  assert.equal(contract.contract_hash.length, 64);

  const duplicate = await post(`/api/students/${studentId}/contracts`, {}, adminToken);
  assert.equal(duplicate.status, 409);

  const invalidCpf = await post(`/api/contracts/${contract.id}/sign`, {
    accepted: true, signer_name: 'Pai Fase Sete', cpf: '11111111111', password: 'senha123',
  }, parentToken);
  assert.equal(invalidCpf.status, 400);
  const wrongPassword = await post(`/api/contracts/${contract.id}/sign`, {
    accepted: true, signer_name: 'Pai Fase Sete', cpf: '52998224725', password: 'errada', verification_code: '123456',
  }, parentToken);
  assert.equal(wrongPassword.status, 401);

  const challenge = await post(`/api/contracts/${contract.id}/challenge`, {}, parentToken).then((r) => r.json());
  assert.match(challenge.devCode, /^\d{6}$/);

  const signedResponse = await post(`/api/contracts/${contract.id}/sign`, {
    accepted: true, signer_name: 'Pai Fase Sete', cpf: '529.982.247-25', password: 'senha123', verification_code: challenge.devCode,
  }, parentToken);
  assert.equal(signedResponse.status, 200);
  const signed = await signedResponse.json();
  assert.equal(signed.status, 'signed');
  assert.equal(signed.evidence_hash.length, 64);
  assert.ok(signed.signer_ip);
  const rawCpf = await db.query('SELECT signer_cpf FROM student_contracts WHERE id=$1', [contract.id]);
  assert.ok(rawCpf.rows[0].signer_cpf.startsWith('enc:'));
  assert.ok(!rawCpf.rows[0].signer_cpf.includes('52998224725'));

  const signedAgain = await post(`/api/contracts/${contract.id}/sign`, {
    accepted: true, signer_name: 'Pai Fase Sete', cpf: '52998224725', password: 'senha123', verification_code: challenge.devCode,
  }, parentToken);
  assert.equal(signedAgain.status, 409);

  const list = await get(`/api/students/${studentId}/contracts`, parentToken).then((r) => r.json());
  assert.equal(list[0].id, contract.id);
  assert.equal(list[0].contract_hash, contract.contract_hash);
  assert.equal(list[0].student_name, 'Aluno Fase7');
  assert.equal(list[0].responsible_name, 'Pai Fase Sete');
  assert.equal(list[0].signer_cpf_display, '529.982.247-25');
  assert.match(list[0].contract_text, /CONTRATANTE\/RESPONSAVEL:/);
  assert.match(list[0].contract_text, /ALUNO: Aluno Fase7/);

  const verification = await get(`/api/contracts/${contract.id}/verify`, parentToken).then((r) => r.json());
  assert.equal(verification.contractValid, true);
  assert.equal(verification.evidenceValid, true);
  const pdf = await get(`/api/contracts/${contract.id}/pdf`, parentToken);
  assert.equal(pdf.status, 200);
  assert.equal(pdf.headers.get('content-type'), 'application/pdf');
  assert.ok((await pdf.arrayBuffer()).byteLength > 1000);
  const publicVerification = await get(`/contracts/verify/${contract.verification_token}`);
  assert.equal(publicVerification.status, 200);
  const publicHtml = await publicVerification.text();
  assert.match(publicHtml, /Documento autentico/);
  assert.ok(!publicHtml.includes('52998224725'));
  const adminList = await get('/api/contracts', adminToken).then((r) => r.json());
  assert.equal(adminList.find((item) => item.id === contract.id).download_count, 1);

  const cancellation = await post(`/api/contracts/${contract.id}/cancellation-request`, {
    reason: 'Mudanca de cidade da familia no proximo mes.',
  }, parentToken);
  assert.equal(cancellation.status, 201);
  const requests = await get('/api/contracts/cancellation-requests', adminToken).then((r) => r.json());
  const request = requests.find((item) => item.contract_id === contract.id);
  assert.equal(request.status, 'pending');
  const rejected = await post(`/api/contracts/cancellation-requests/${request.id}/resolve`, {
    decision: 'rejected',
  }, adminToken);
  assert.equal(rejected.status, 200);
});

test('conta de responsavel existente adiciona outro aluno usando a senha atual', async () => {
  const second = await post('/api/students', { name: 'Irma do Aluno Fase7' }, adminToken).then((r) => r.json());
  const invite = await post(`/api/students/${second.id}/invite`, { relationship: 'Pai' }, adminToken).then((r) => r.json());
  const response = await post('/api/auth/register-parent', {
    code: invite.code,
    name: 'Nome ignorado',
    email: `PAI-F7-${suffix}@TEST.LOCAL`,
    password: 'senha123',
  });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.existingAccount, true);
  assert.equal(body.studentName, 'Irma do Aluno Fase7');
  const children = await get('/api/students/mine', body.token).then((r) => r.json());
  assert.ok(children.some((child) => child.id === second.id));
});

test('admin lista e cancela convite pendente, que deixa de funcionar', async () => {
  const invited = await post('/api/students', { name: 'Aluno Convite Cancelado' }, adminToken).then((r) => r.json());
  const invite = await post(`/api/students/${invited.id}/invite`, {}, adminToken).then((r) => r.json());
  const list = await get(`/api/students/${invited.id}/invites`, adminToken).then((r) => r.json());
  assert.equal(list[0].status, 'pending');
  assert.equal(await del(`/api/students/${invited.id}/invites/${invite.id}`, adminToken).then((r) => r.status), 200);
  const registration = await post('/api/auth/register-parent', {
    code: invite.code, name: 'Nao cadastra', email: `cancelado-${suffix}@test.local`, password: 'senha123',
  });
  assert.equal(registration.status, 410);
  assert.equal((await registration.json()).error, 'codigo cancelado');
});

test('aluno pode usar uma rota na ida e outra rota na volta', async () => {
  const student = await post('/api/students', { name: 'Aluno Rotas Separadas' }, adminToken).then((r) => r.json());
  const outbound = await post('/api/routes', { name: 'Rota Somente Ida' }, adminToken).then((r) => r.json());
  const inbound = await post('/api/routes', { name: 'Rota Somente Volta' }, adminToken).then((r) => r.json());
  await post(`/api/routes/${outbound.id}/students`, {
    student_id: student.id, service_direction: 'to_school',
  }, adminToken);
  await post(`/api/routes/${inbound.id}/students`, {
    student_id: student.id, service_direction: 'to_home',
  }, adminToken);

  const outboundTrip = await post('/api/trips/start', {
    route_id: outbound.id, direction: 'to_school',
  }, adminToken).then((r) => r.json());
  const outboundStudents = await get(`/api/trips/${outboundTrip.tripId}/students`, adminToken).then((r) => r.json());
  assert.deepEqual(outboundStudents.map((item) => item.id), [student.id]);
  await post(`/api/trips/${outboundTrip.tripId}/cancel`, { reason: 'teste' }, adminToken);

  const wrongDirection = await post('/api/trips/start', {
    route_id: outbound.id, direction: 'to_home',
  }, adminToken);
  assert.equal(wrongDirection.status, 409);

  const inboundTrip = await post('/api/trips/start', {
    route_id: inbound.id, direction: 'to_home',
  }, adminToken).then((r) => r.json());
  const inboundStudents = await get(`/api/trips/${inboundTrip.tripId}/students`, adminToken).then((r) => r.json());
  assert.deepEqual(inboundStudents.map((item) => item.id), [student.id]);

  const duplicateRoute = await post('/api/routes', { name: 'Outra Rota de Ida' }, adminToken).then((r) => r.json());
  const duplicate = await post(`/api/routes/${duplicateRoute.id}/students`, {
    student_id: student.id, service_direction: 'to_school',
  }, adminToken);
  assert.equal(duplicate.status, 409);

  const secondActive = await post('/api/trips/start', {
    route_id: routeId, direction: 'to_school',
  }, driverToken).then((r) => r.json());
  const today = await get('/api/dashboard/today', adminToken).then((r) => r.json());
  assert.equal(today.activeTrips.length, 2);
  await post(`/api/trips/${secondActive.tripId}/cancel`, { reason: 'teste' }, driverToken);
  await post(`/api/trips/${inboundTrip.tripId}/cancel`, { reason: 'teste' }, adminToken);
});

test('GET /api/notifications devolve o embarque pro pai', async () => {
  const res = await get('/api/notifications', parentToken).then((r) => r.json());
  assert.ok(res.some((n) => n.type === 'trip_event' && n.message.includes('embarcou')));
});

test('GET /api/notifications devolve mensagem de chat pro staff', async () => {
  const me = await get('/api/auth/me', parentToken).then((r) => r.json());
  await post(`/api/chat/${me.id}`, { body: 'Oi, vai atrasar?' }, parentToken);
  const res = await get('/api/notifications', adminToken).then((r) => r.json());
  assert.ok(res.some((n) => n.type === 'chat' && n.message.includes('Oi, vai atrasar?')));
});

test('GET /api/audit-log registra reset de senha e exige admin', async () => {
  // Checa o 403 ANTES de resetar a senha: resetar incrementa token_version
  // do proprio driver, o que invalidaria driverToken e faria essa chamada
  // voltar 401 (token invalido) em vez de 403 (role errada) -- confundindo
  // os dois motivos de rejeicao.
  const forbidden = await get('/api/audit-log', driverToken);
  assert.equal(forbidden.status, 403);

  const users = await get('/api/users', adminToken).then((r) => r.json());
  const driver = users.find((u) => u.role === 'driver');
  await put(`/api/users/${driver.id}/password`, { newPassword: 'novaSenha123' }, adminToken);

  const log = await get('/api/audit-log?entityType=user', adminToken).then((r) => r.json());
  assert.ok(log.some((l) => l.action === 'resetar_senha' && l.entity_id === driver.id));
});

test('painel global isola acesso e gerencia plano, cobranca e auditoria', async () => {
  const forbidden = await get('/api/platform/dashboard', parentToken);
  assert.equal(forbidden.status, 403);

  const dashboard = await get('/api/platform/dashboard', adminToken);
  assert.equal(dashboard.status, 200);
  const dashboardBody = await dashboard.json();
  assert.ok(dashboardBody.tenants.total >= 1);
  assert.ok(Number(dashboardBody.finance.mrr) >= 0);

  const plans = await get('/api/platform/plans', adminToken).then((r) => r.json());
  assert.ok(plans.some((plan) => plan.code === 'basic'));
  const subscription = await put(`/api/platform/tenants/${tenantId}/subscription`, {
    plan_id: plans.find((plan) => plan.code === 'basic').id,
    billing_cycle: 'monthly', status: 'active', overrides: { max_students: 40 },
  }, adminToken);
  assert.equal(subscription.status, 200);

  await put(`/api/platform/tenants/${tenantId}/subscription`, {
    plan_id: plans.find((plan) => plan.code === 'basic').id,
    billing_cycle: 'monthly', status: 'active', overrides: { max_students: 1 },
  }, adminToken);
  const overLimit = await post('/api/students', { name: 'Aluno acima do plano' }, adminToken);
  assert.equal(overLimit.status, 409);
  assert.match((await overLimit.json()).error, /limite de alunos/);
  await put(`/api/platform/tenants/${tenantId}/subscription`, {
    plan_id: plans.find((plan) => plan.code === 'basic').id,
    billing_cycle: 'monthly', status: 'active', overrides: { max_students: 40 },
  }, adminToken);

  const invoice = await post('/api/platform/invoices', {
    tenant_id: tenantId, amount: 99.90, description: 'Plano de teste', due_at: new Date(Date.now() + 86400000).toISOString(),
  }, adminToken);
  assert.equal(invoice.status, 201);
  const invoiceBody = await invoice.json();
  assert.match(invoiceBody.payment_url, /\/pay\//);
  const paid = await post(`/api/platform/invoices/${invoiceBody.id}/status`, { status: 'paid' }, adminToken);
  assert.equal(paid.status, 200);

  const audit = await get('/api/platform/audit', adminToken).then((r) => r.json());
  assert.ok(audit.some((item) => item.action === 'gerar_fatura' && item.tenant_id === tenantId));
});
