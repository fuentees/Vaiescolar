// firebase-admin v14+ usa API modular (nao ha mais admin.credential/admin.messaging
// no objeto default de require('firebase-admin') -- precisa importar dos submodulos).
const { initializeApp, applicationDefault } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');
const db = require('./db');

let firebaseApp = null;
let warnedMissingCredentials = false;

// So inicializa o Firebase Admin se GOOGLE_APPLICATION_CREDENTIALS estiver
// configurado. Sem isso, push vira no-op (util em dev sem projeto Firebase).
function getFirebaseApp() {
  if (firebaseApp) return firebaseApp;
  if (!process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    if (!warnedMissingCredentials) {
      console.warn('[push] GOOGLE_APPLICATION_CREDENTIALS nao configurado - notificacoes desativadas');
      warnedMissingCredentials = true;
    }
    return null;
  }
  firebaseApp = initializeApp({ credential: applicationDefault() });
  return firebaseApp;
}

// Envia uma notificacao para uma lista de userIds (busca o fcm_token de cada
// um). Tokens invalidos/desinstalados sao limpos do banco automaticamente.
async function sendToUsers(userIds, title, body, data = {}) {
  const uniqueIds = [...new Set(userIds)].filter(Boolean);
  if (uniqueIds.length === 0) return;

  const app = getFirebaseApp();
  if (!app) return;

  const r = await db.query(
    'SELECT id, fcm_token FROM users WHERE id = ANY($1::uuid[]) AND fcm_token IS NOT NULL',
    [uniqueIds]
  );
  if (r.rows.length === 0) return;

  const stringData = Object.fromEntries(
    Object.entries(data).map(([k, v]) => [k, String(v)])
  );

  const res = await getMessaging(app).sendEachForMulticast({
    tokens: r.rows.map((u) => u.fcm_token),
    notification: { title, body },
    data: stringData,
  });

  const invalidUserIds = [];
  res.responses.forEach((resp, i) => {
    if (resp.success) return;
    const code = resp.error && resp.error.code;
    if (
      code === 'messaging/invalid-registration-token' ||
      code === 'messaging/registration-token-not-registered'
    ) {
      invalidUserIds.push(r.rows[i].id);
    }
  });
  if (invalidUserIds.length > 0) {
    await db.query('UPDATE users SET fcm_token = NULL WHERE id = ANY($1::uuid[])', [invalidUserIds]);
  }
}

module.exports = { sendToUsers };
