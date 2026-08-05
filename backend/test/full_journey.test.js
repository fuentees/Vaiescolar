// Fluxo operacional completo: cadastros, financeiro, ida, volta e acompanhamento
// do responsavel por REST + WebSocket. Todos os dados sao temporarios.
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');

const suffix = `${Date.now()}-${process.pid}`;
let server, db, baseUrl, wsBaseUrl;
let tenantId, adminToken, driverToken, parentToken, driverId;
let schoolId, vehicleId, studentId, routeId, paymentId;
const tripIds = [];

async function request(method, path, body, token) {
  return fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
}

async function json(method, path, body, token, expectedStatus = 200) {
  const response = await request(method, path, body, token);
  const value = await response.json();
  assert.equal(response.status, expectedStatus, `${method} ${path}: ${JSON.stringify(value)}`);
  return value;
}

function openTripSocket(tripId) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${wsBaseUrl}?tripId=${tripId}`, {
      headers: { authorization: `Bearer ${parentToken}` },
    });
    const timer = setTimeout(() => reject(new Error('timeout conectando WebSocket')), 3000);
    ws.once('error', reject);
    ws.once('message', (raw) => {
      clearTimeout(timer);
      const message = JSON.parse(raw.toString());
      assert.equal(message.type, 'subscribed');
      resolve(ws);
    });
  });
}

function nextSocketMessage(ws, expectedType) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timeout aguardando ${expectedType}`)), 3000);
    const onMessage = (raw) => {
      const message = JSON.parse(raw.toString());
      if (message.type !== expectedType) return;
      clearTimeout(timer);
      ws.off('message', onMessage);
      resolve(message);
    };
    ws.on('message', onMessage);
  });
}

before(async () => {
  ({ server } = require('../src/server'));
  db = require('../src/db');
  await new Promise((resolve) => server.listen(0, resolve));
  const port = server.address().port;
  baseUrl = `http://127.0.0.1:${port}`;
  wsBaseUrl = `ws://127.0.0.1:${port}`;

  const registration = await json('POST', '/api/auth/register-tenant', {
    tenantName: `Operacao completa ${suffix}`,
    name: 'Administrador Operacional',
    email: `admin-${suffix}@e2e.local`,
    password: 'senha123',
  });
  tenantId = registration.tenantId;
  adminToken = registration.token;
});

after(async () => {
  if (tenantId) await db.query('DELETE FROM tenants WHERE id=$1', [tenantId]);
  await new Promise((resolve) => server.close(resolve));
  await db.pool.end();
});

test('fluxo completo de cadastro, mensalidade, ida e volta', async () => {
  const driver = await json('POST', '/api/users', {
    role: 'driver', name: 'Motorista da Rota',
    email: `motorista-${suffix}@e2e.local`, password: 'senha123',
  }, adminToken);
  driverId = driver.id;
  driverToken = (await json('POST', '/api/auth/login', {
    email: `motorista-${suffix}@e2e.local`, password: 'senha123',
  })).token;

  const school = await json('POST', '/api/schools', {
    name: `Escola Horizonte ${suffix}`, phone: '1133334444', postal_code: '01310100',
    street: 'Avenida Paulista', number: '1000', neighborhood: 'Bela Vista',
    city: 'Sao Paulo', state: 'SP', address: 'Avenida Paulista, 1000 - Bela Vista, Sao Paulo - SP',
    lat: -23.5646, lng: -46.6524,
  }, adminToken);
  schoolId = school.id;
  assert.equal(school.postal_code, '01310100');

  const vehicle = await json('POST', '/api/vehicles', {
    plate: 'ABC1D23', model: 'Van Executiva', capacity: 30, year: 2025,
    color: 'Prata', status: 'available',
  }, adminToken);
  vehicleId = vehicle.id;

  const student = await json('POST', '/api/students', {
    name: 'Aluno Fluxo Completo', school_id: schoolId, monthly_fee: 650,
    home_postal_code: '01415000', home_street: 'Rua Haddock Lobo', home_number: '500',
    home_neighborhood: 'Cerqueira Cesar', home_city: 'Sao Paulo', home_state: 'SP',
    home_address: 'Rua Haddock Lobo, 500 - Cerqueira Cesar, Sao Paulo - SP',
    home_lat: -23.5588, home_lng: -46.6658,
    emergency_contact_name: 'Responsavel Fluxo', emergency_contact_phone: '11999999999',
  }, adminToken);
  studentId = student.id;

  const route = await json('POST', '/api/routes', {
    name: 'Rota Escolar Completa', vehicle_id: vehicleId, driver_user_id: driverId,
    days_of_week: '1,2,3,4,5', planned_time: '07:00', active: true,
  }, adminToken);
  routeId = route.id;
  await json('POST', `/api/routes/${routeId}/students`, { student_id: studentId }, adminToken);

  await json('POST', '/api/users', {
    role: 'driver', name: 'Motorista Nao Atribuido',
    email: `intruso-${suffix}@e2e.local`, password: 'senha123',
  }, adminToken);
  const otherDriverToken = (await json('POST', '/api/auth/login', {
    email: `intruso-${suffix}@e2e.local`, password: 'senha123',
  })).token;
  await json('POST', '/api/trips/start', {
    route_id: routeId, direction: 'to_school',
  }, otherDriverToken, 403);

  const invite = await json('POST', `/api/students/${studentId}/invite`, {}, adminToken);
  const parent = await json('POST', '/api/auth/register-parent', {
    code: invite.code, name: 'Responsavel Fluxo Completo',
    email: `responsavel-${suffix}@e2e.local`, password: 'senha123',
  });
  parentToken = parent.token;
  const children = await json('GET', '/api/students/mine', undefined, parentToken);
  assert.deepEqual(children.map((item) => item.id), [studentId]);

  const month = new Date().toISOString().slice(0, 7);
  const generated = await json('POST', '/api/payments/generate', { month }, adminToken);
  assert.equal(generated.created, 1);
  const payments = await json('GET', `/api/payments?month=${month}`, undefined, adminToken);
  paymentId = payments[0].id;
  const provider = await json('PUT', '/api/payment-provider', {
    provider: 'manual_pix', pix_key: 'teste@pix.local', merchant_name: 'Transporte Teste',
  }, adminToken);
  assert.equal(provider.provider, 'manual_pix');
  const checkout = await json('POST', `/api/payments/${paymentId}/checkout`, undefined, adminToken);
  assert.equal(checkout.pix_key, 'teste@pix.local');
  const parentPending = await json('GET', `/api/payments/mine?month=${month}`, undefined, parentToken);
  assert.equal(parentPending[0].pix_key, 'teste@pix.local');
  const paid = await json('PUT', `/api/payments/${paymentId}`, {
    status: 'paid', payment_method: 'pix', notes: 'Pagamento simulado no teste E2E',
  }, adminToken);
  assert.equal(paid.status, 'paid');
  const parentPayments = await json('GET', `/api/payments/mine?month=${month}`, undefined, parentToken);
  assert.equal(parentPayments[0].status, 'paid');

  await executeTrip('to_school', {
    first: [-23.5588, -46.6658], last: [-23.5646, -46.6524],
  });
  await executeTrip('to_home', {
    first: [-23.5646, -46.6524], last: [-23.5588, -46.6658],
  });

  const history = await json('GET', `/api/trips/history?studentId=${studentId}`, undefined, parentToken);
  assert.equal(history.length, 2);
  assert.deepEqual(new Set(history.map((trip) => trip.direction)), new Set(['to_school', 'to_home']));
  assert.ok(history.every((trip) => trip.last_event_type === 'dropped'));

  const report = await json('GET', '/api/reports/trips?limit=10', undefined, adminToken);
  const testedTrips = report.filter((trip) => tripIds.includes(trip.id));
  assert.equal(testedTrips.length, 2);
  assert.deepEqual(testedTrips.map((trip) => Number(trip.event_count)).sort(), [2, 4]);

  const notifications = await json('GET', '/api/notifications?limit=30', undefined, parentToken);
  assert.equal(notifications.filter((item) => item.type === 'approaching').length, 2);
  assert.equal(notifications.filter((item) => item.type === 'trip_event').length, 6);
});

async function executeTrip(direction, points) {
  const started = await json('POST', '/api/trips/start', {
    route_id: routeId, direction,
  }, driverToken);
  const tripId = started.tripId;
  tripIds.push(tripId);

  const restored = await json('GET', '/api/trips/mine/active', undefined, driverToken);
  assert.equal(restored.trip_id, tripId);
  const activeForParent = await json('GET', '/api/trips/active', undefined, parentToken);
  assert.ok(activeForParent.some((trip) => trip.trip_id === tripId && trip.student_id === studentId));

  const ws = await openTripSocket(tripId);
  const locationPromise = nextSocketMessage(ws, 'location');
  await json('POST', `/api/trips/${tripId}/locations`, {
    lat: points.first[0], lng: points.first[1], speed: 8, heading: 90, accuracy: 6,
  }, driverToken);
  const locationMessage = await locationPromise;
  assert.equal(locationMessage.tripId, tripId);
  const parentLocation = await json('GET', `/api/trips/${tripId}/location`, undefined, parentToken);
  assert.equal(Number(parentLocation.lat), points.first[0]);

  const approachingPromise = nextSocketMessage(ws, 'approaching');
  const approaching = await json('POST', `/api/trips/${tripId}/students/${studentId}/approaching`, {}, driverToken);
  assert.equal(approaching.alreadySent, false);
  assert.equal((await approachingPromise).studentId, studentId);
  const duplicate = await json('POST', `/api/trips/${tripId}/students/${studentId}/approaching`, {}, driverToken);
  assert.equal(duplicate.alreadySent, true);

  const boardedPromise = nextSocketMessage(ws, 'event');
  await json('POST', `/api/trips/${tripId}/events`, {
    student_id: studentId, type: 'boarded', lat: points.first[0], lng: points.first[1],
  }, driverToken);
  assert.equal((await boardedPromise).event.type, 'boarded');
  const repeatedBoarding = await json('POST', `/api/trips/${tripId}/events`, {
    student_id: studentId, type: 'boarded', lat: points.first[0], lng: points.first[1],
  }, driverToken);
  assert.equal(repeatedBoarding.alreadyRecorded, true);

  const corrected = await json('DELETE',
    `/api/trips/${tripId}/students/${studentId}/last-event`, undefined, driverToken);
  assert.equal(corrected.ok, true);
  await json('POST', `/api/trips/${tripId}/events`, {
    student_id: studentId, type: 'boarded', lat: points.first[0], lng: points.first[1],
  }, driverToken);

  const droppedPromise = nextSocketMessage(ws, 'event');
  await json('POST', `/api/trips/${tripId}/locations`, {
    lat: points.last[0], lng: points.last[1], speed: 0, heading: 90, accuracy: 5,
  }, driverToken);
  await json('POST', `/api/trips/${tripId}/events`, {
    student_id: studentId, type: 'dropped', lat: points.last[0], lng: points.last[1],
    received_by: 'Maria Responsavel',
  }, driverToken);
  assert.equal((await droppedPromise).event.type, 'dropped');

  const events = await json('GET', `/api/trips/${tripId}/events`, undefined, parentToken);
  assert.deepEqual(events.map((event) => event.type), ['boarded', 'dropped']);
  assert.equal(events[1].received_by, 'Maria Responsavel');

  const activeAfterDrop = await json('GET', '/api/trips/active', undefined, parentToken);
  assert.equal(activeAfterDrop.some((trip) => trip.student_id === studentId), false);

  if (direction === 'to_school') {
    const emergency = await json('POST',
      `/api/trips/${tripId}/students/${studentId}/emergency-return`,
      { reason: 'Aluno passou mal' }, driverToken);
    assert.equal(emergency.ok, true);
    const activeEmergency = await json('GET', '/api/trips/active', undefined, parentToken);
    const emergencyTrip = activeEmergency.find((item) => item.student_id === studentId);
    assert.equal(emergencyTrip.emergency_return_active, true);
    assert.equal(emergencyTrip.target_lat, -23.5588);

    await json('POST', `/api/trips/${tripId}/events`, {
      student_id: studentId, type: 'dropped', lat: -23.5500, lng: -46.6300,
    }, driverToken);
    const inactiveAgain = await json('GET', '/api/trips/active', undefined, parentToken);
    assert.equal(inactiveAgain.some((trip) => trip.student_id === studentId), false);
  }

  const finishedPromise = nextSocketMessage(ws, 'trip_finished');
  await json('POST', `/api/trips/${tripId}/finish`, {}, driverToken);
  assert.equal((await finishedPromise).tripId, tripId);
  ws.close();
  const noActiveTrip = await json('GET', '/api/trips/mine/active', undefined, driverToken);
  assert.equal(noActiveTrip, null);
}
