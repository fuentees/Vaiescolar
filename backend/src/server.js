require('express-async-errors'); // faz erro/rejeicao nao tratada numa rota async cair no error handler abaixo em vez de travar a request (Express 4 nao faz isso sozinho)
const express = require('express');
const cors = require('cors');
const http = require('http');
const path = require('path');
const { WebSocketServer } = require('ws');
const bcrypt = require('bcryptjs');
const crypto = require('crypto');
const PDFDocument = require('pdfkit');
const QRCode = require('qrcode');
const rateLimit = require('express-rate-limit');
require('dotenv').config();

const db = require('./db');
const { sign, authMiddleware, verifyToken, requireRole } = require('./auth');
const hub = require('./hub');
const push = require('./push');
const createPlatformRouter = require('./platform');
const { startMaintenance } = require('./maintenance');
const {
  locationsBody,
  tripEventBody,
  paymentUpdateBody,
  vehicleBody,
  studentBody,
  routeBody,
  schoolBody,
  chatMessageBody,
  userUpdateBody,
  validateBody,
} = require('./validation');

// Alfabeto sem 0/O/1/I para os codigos de convite (evita confusao ao digitar).
const INVITE_CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const brasiliaTimeFormatter = new Intl.DateTimeFormat('pt-BR', {
  timeZone: 'America/Sao_Paulo',
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
});
function generateInviteCode() {
  let code = '';
  for (let i = 0; i < 6; i++) {
    code += INVITE_CODE_ALPHABET[crypto.randomInt(INVITE_CODE_ALPHABET.length)];
  }
  return code;
}

// Auditoria administrativa: registra quem fez o que em cima de dado sensivel
// (reset de senha, status de pagamento, criar/editar/excluir aluno/rota/
// veiculo/usuario). So-insercao, nunca lido pelo app exceto pela tela de
// auditoria (admin); falha de log nunca deve derrubar a acao em si, entao
// nao precisa de try/catch aqui -- se `db.query` falhar, e um erro real de
// banco que o error handler global ja trata igual a qualquer outra rota.
async function logAudit(req, action, entityType, entityId, detail) {
  await db.query(
    `INSERT INTO audit_log(tenant_id, actor_user_id, action, entity_type, entity_id, detail)
     VALUES($1,$2,$3,$4,$5,$6)`,
    [req.auth.tenantId, req.auth.userId, action, entityType, entityId ? String(entityId) : null, detail ? JSON.stringify(detail) : null]
  );
}

const app = express();
app.set('trust proxy', 1);
// Apps mobile nao sao afetados por CORS (so navegadores aplicam essa
// politica) -- fica configuravel via env pra quando/se existir um painel
// web administrativo que precise ser restrito a uma origem especifica.
const configuredOrigins = String(process.env.CORS_ORIGIN || '')
  .split(',').map((value) => value.trim()).filter(Boolean);
const corsOrigin = configuredOrigins.includes('*')
  ? '*'
  : configuredOrigins.length
    ? configuredOrigins
    : (process.env.NODE_ENV === 'production' ? false : '*');
app.use(cors({ origin: corsOrigin }));
app.use(express.json());
app.use('/platform', (_req, res, next) => {
  res.set('Content-Security-Policy', "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'");
  res.set('X-Content-Type-Options', 'nosniff');
  res.set('Referrer-Policy', 'no-referrer');
  res.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  next();
}, express.static(path.resolve(__dirname, '..', 'platform')));
app.use('/api/platform', createPlatformRouter({ db, push, hub }));
app.get('/pay/:reference', async (req, res) => {
  const result = await db.query(`SELECT i.amount,i.status,i.due_at,i.description,i.payment_url,t.name tenant_name
    FROM platform_invoices i JOIN tenants t ON t.id=i.tenant_id WHERE i.external_reference=$1`, [req.params.reference]);
  if (!result.rows.length) return res.status(404).send('Cobranca nao encontrada.');
  const invoice = result.rows[0];
  const safe = (value) => String(value || '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  res.set('Cache-Control', 'no-store');
  res.type('html').send(`<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Cobranca TECO</title><style>body{font-family:system-ui;background:#f3f4f6;color:#1f2937;margin:0;padding:24px}.card{max-width:520px;margin:8vh auto;background:#fff;padding:32px;border-radius:24px;box-shadow:0 18px 55px #1232}h1{color:#0f4c5c}.value{font-size:34px;font-weight:800}.status{padding:8px 12px;border-radius:99px;background:#e7f6ee;display:inline-block}.hint{color:#66777b}</style></head><body><main class="card"><h1>TECO</h1><p>Assinatura da transportadora</p><h2>${safe(invoice.tenant_name)}</h2><p>${safe(invoice.description)}</p><p class="value">R$ ${Number(invoice.amount).toFixed(2).replace('.', ',')}</p><p class="status">${safe(invoice.status)}</p><p class="hint">Este link identifica a cobranca. Para PIX, boleto ou cartao, o administrador global deve conectar um provedor de pagamentos. A confirmacao final sempre ocorre no servidor.</p></main></body></html>`);
});
app.get('/health', async (_req, res) => {
  try {
    await db.query('SELECT 1');
    res.json({
      ok: true,
      database: 'connected',
      pushNotifications: push.isConfigured() ? 'configured' : 'not_configured',
      websocket: hub.stats(),
      databasePool: db.stats(),
      uptimeSeconds: Math.round(process.uptime()),
    });
  } catch (error) {
    console.error('[health] banco indisponivel', error.message);
    res.status(503).json({ ok: false, database: 'unavailable' });
  }
});
app.get('/app-version/:app', (req, res) => {
  res.set('Cache-Control', 'no-store, no-cache, must-revalidate');
  const versions = {
    motorista: {
      version: '1.0.38', buildNumber: 4044, releaseBuild: 44,
      url: 'https://vaiescolar.onrender.com/downloads/TECO.apk',
      notes: 'Logotipo oficial TECO agora permanece visivel em todas as areas depois do login.',
      mandatory: true,
    },
    responsavel: {
      version: '1.0.38', buildNumber: 4044, releaseBuild: 44,
      url: 'https://vaiescolar.onrender.com/downloads/TECO.apk',
      notes: 'Logotipo oficial TECO agora permanece visivel em todas as areas depois do login.',
      mandatory: true,
    },
  };
  const version = versions[req.params.app];
  if (!version) return res.status(404).json({ error: 'app nao encontrado' });
  res.json(version);
});

// Downloads publicos para instalacao de teste. `res.download` acrescenta
// Content-Disposition e o nome correto do arquivo, evitando navegadores
// Android que ficam presos ao baixar o blob pelo endereco raw do GitHub.
const apkDirectory = path.resolve(__dirname, '..', '..', 'downloads');
function sendApk(filename) {
  return (_req, res, next) => {
    res.set('Cache-Control', 'public, max-age=3600');
    res.download(path.join(apkDirectory, filename), filename, (error) => {
      if (error && !res.headersSent) next(error);
    });
  };
}
app.get('/downloads/VaiEscolar-Motorista.apk', sendApk('VaiEscolar-Motorista-arm64.apk'));
app.get('/downloads/VaiEscolar-Responsavel.apk', sendApk('VaiEscolar-Responsavel-arm64.apk'));
app.get('/downloads/VaiEscolar-Responsavel.zip', sendApk('VaiEscolar-Responsavel.zip'));
app.get('/downloads/VaiEscolar.apk', sendApk('VaiEscolar-arm64.apk'));
app.get('/downloads/TECO.apk', sendApk('VaiEscolar-arm64.apk'));
app.get('/downloads/VaiEscolar.zip', sendApk('VaiEscolar.zip'));

// Rate limit mais restrito nos endpoints publicos de auth (forca bruta de
// login/senha, spam de cadastro/convite); geral mais frouxo no resto da API.
const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 20, standardHeaders: true, legacyHeaders: false });
const apiLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 300, standardHeaders: true, legacyHeaders: false });
// Chat especifico: 30 msgs/min por IP, alem do limite geral de /api -- evita
// spam/flood de uma conversa sem travar o resto da API.
const chatLimiter = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: true, legacyHeaders: false });
const contractChallengeLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 5, standardHeaders: true, legacyHeaders: false });
app.use('/api/auth/login', authLimiter);
app.use('/api/auth/register-tenant', authLimiter);
app.use('/api/auth/register-parent', authLimiter);
app.use('/api/auth/link-child', authLimiter);
app.use('/api/contracts/:id/challenge', contractChallengeLimiter);
app.use('/api', apiLimiter);

function passwordProblem(password) {
  if (typeof password !== 'string' || password.length < 8) {
    return 'a senha precisa ter ao menos 8 caracteres';
  }
  if (!/[A-Za-z]/.test(password) || !/\d/.test(password)) {
    return 'a senha precisa conter letras e numeros';
  }
  const normalized = password.toLowerCase();
  if (/^(.)\1+$/.test(password) || ['12345678', 'password', 'qwerty123'].includes(normalized)) {
    return 'escolha uma senha menos previsivel';
  }
  return null;
}

/* =========================================================================
 * AUTENTICACAO / ONBOARDING
 * ========================================================================= */

// Cria um novo operador (tenant) + usuario admin. Onboarding do motorista dono.
app.post('/api/auth/register-tenant', async (req, res) => {
  const { tenantName, name, email, password } = req.body;
  if (!tenantName || !email || !password) {
    return res.status(400).json({ error: 'campos obrigatorios faltando' });
  }
  const passwordError = passwordProblem(password);
  if (passwordError) return res.status(400).json({ error: passwordError });
  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const t = await client.query(
      `INSERT INTO tenants(name,status,trial_ends_at) VALUES($1,'trial',now()+interval '14 days') RETURNING id`,
      [tenantName]
    );
    const tenantId = t.rows[0].id;
    await client.query(`INSERT INTO platform_subscriptions(tenant_id,plan_id,status,billing_cycle,current_period_start,current_period_end,trial_ends_at)
      SELECT $1,id,'trial','monthly',now(),now()+interval '14 days',now()+interval '14 days'
      FROM platform_plans WHERE code='basic'`, [tenantId]);
    const hash = await bcrypt.hash(password, 10);
    const u = await client.query(
      `INSERT INTO users(tenant_id, role, name, email, password_hash)
       VALUES($1,'admin',$2,$3,$4) RETURNING id, role`,
      [tenantId, name || 'Admin', email.trim().toLowerCase(), hash]
    );
    await client.query('COMMIT');
    const token = sign({ userId: u.rows[0].id, tenantId, role: 'admin', tokenVersion: 0 });
    res.json({ token, userId: u.rows[0].id, role: 'admin', name: name || 'Admin', tenantId });
  } catch (e) {
    await client.query('ROLLBACK');
    console.error('[register-tenant]', e);
    res.status(500).json({ error: 'falha no cadastro' });
  } finally {
    client.release();
  }
});

// Cria usuarios dentro de um tenant (motorista, pai ou outro admin -- um
// tenant pode ter mais de um administrador, ex.: socio/gerente). Requer admin.
app.post('/api/users', authMiddleware, requireRole('admin'), async (req, res) => {
  const { role, name, email, phone, password } = req.body;
  if (!['admin', 'driver', 'parent'].includes(role)) {
    return res.status(400).json({ error: 'role invalida' });
  }
  if (role === 'admin' || role === 'driver') {
    const limitError = await planLimitError(req.auth.tenantId, 'staff');
    if (limitError) return res.status(409).json({ error: limitError });
  }
  const passwordError = passwordProblem(password);
  if (passwordError) return res.status(400).json({ error: passwordError });
  const hash = await bcrypt.hash(password, 10);
  try {
    const r = await db.query(
      `INSERT INTO users(tenant_id, role, name, email, phone, password_hash)
       VALUES($1,$2,$3,$4,$5,$6) RETURNING id, role, name, email`,
      [req.auth.tenantId, role, name, email.trim().toLowerCase(), phone || null, hash]
    );
    res.json(r.rows[0]);
  } catch (e) {
    if (e.code === '23505') return res.status(409).json({ error: 'ja existe um usuario com este e-mail' });
    console.error('[criar usuario]', e);
    res.status(500).json({ error: 'falha ao criar usuario' });
  }
});

// Lista os usuarios do tenant (admins, motoristas e pais) -- usado na tela
// de "Motoristas e responsaveis" e para saber quem pode receber reset de senha.
app.get('/api/users', authMiddleware, requireRole('admin'), async (req, res) => {
  const r = await db.query(
    `SELECT id, role, name, email, phone, created_at, active, last_login_at
       FROM users WHERE tenant_id=$1 AND role IN ('admin','driver','parent')
      ORDER BY role, name`,
    [req.auth.tenantId]
  );
  res.json(r.rows);
});

// Edita nome/telefone de um usuario do tenant (nao muda role/email/senha --
// esses ja tem fluxos proprios).
app.put('/api/users/:id', authMiddleware, requireRole('admin'), validateBody(userUpdateBody), async (req, res) => {
  const { name, phone } = req.body;
  const current = await db.query(
    `SELECT name, phone FROM users WHERE id=$1 AND tenant_id=$2 AND role IN ('admin','driver','parent')`,
    [req.params.id, req.auth.tenantId]
  );
  if (current.rows.length === 0) return res.status(404).json({ error: 'usuario nao encontrado' });
  const r = await db.query(
    `UPDATE users SET name=$1, phone=$2 WHERE id=$3 AND tenant_id=$4 RETURNING id, role, name, email, phone, active`,
    [name ?? current.rows[0].name, phone ?? current.rows[0].phone, req.params.id, req.auth.tenantId]
  );
  res.json(r.rows[0]);
});

// Desativa/reativa uma conta em vez de excluir -- login passa a rejeitar
// contas inativas (ver POST /api/auth/login). Nao deixa o admin se
// autodesativar (ficaria sem acesso, e outros ninguem poderia reverter sem
// acesso direto ao banco).
app.put('/api/users/:id/active', authMiddleware, requireRole('admin'), async (req, res) => {
  const { active } = req.body;
  if (typeof active !== 'boolean') return res.status(400).json({ error: 'active precisa ser true/false' });
  if (req.params.id === req.auth.userId) {
    return res.status(400).json({ error: 'nao e possivel desativar a propria conta' });
  }
  const r = await db.query(
    `UPDATE users SET active=$1 WHERE id=$2 AND tenant_id=$3 AND role IN ('admin','driver','parent')
     RETURNING id, role, name, active`,
    [active, req.params.id, req.auth.tenantId]
  );
  if (r.rows.length === 0) return res.status(404).json({ error: 'usuario nao encontrado' });
  await logAudit(req, active ? 'reativar_usuario' : 'desativar_usuario', 'user', req.params.id, { name: r.rows[0].name });
  res.json(r.rows[0]);
});

// Perfil do usuario logado (para a tela "Minha conta").
app.get('/api/auth/me', authMiddleware, async (req, res) => {
  const r = await db.query(
    'SELECT id, role, name, email, phone, tenant_id FROM users WHERE id=$1 AND tenant_id=$2',
    [req.auth.userId, req.auth.tenantId]
  );
  if (r.rows.length === 0) return res.status(404).json({ error: 'usuario nao encontrado' });
  res.json(r.rows[0]);
});

// Usuario logado troca a propria senha (exige a senha atual).
app.put('/api/auth/password', authMiddleware, async (req, res) => {
  const { currentPassword, newPassword } = req.body;
  if (!currentPassword || !newPassword) {
    return res.status(400).json({ error: 'campos obrigatorios faltando' });
  }
  const passwordError = passwordProblem(newPassword);
  if (passwordError) return res.status(400).json({ error: passwordError });
  const r = await db.query('SELECT password_hash FROM users WHERE id=$1 AND tenant_id=$2', [
    req.auth.userId, req.auth.tenantId,
  ]);
  if (r.rows.length === 0) return res.status(404).json({ error: 'usuario nao encontrado' });
  const ok = await bcrypt.compare(currentPassword, r.rows[0].password_hash);
  // 400: a sessão continua válida; 401 faria o cliente interpretar como JWT
  // expirado e desconectar o usuário por apenas digitar a senha errada.
  if (!ok) return res.status(400).json({ error: 'senha atual incorreta' });
  const hash = await bcrypt.hash(newPassword, 10);
  // Incrementa token_version pra invalidar tokens de 30 dias emitidos antes
  // da troca; devolve um token novo ja com a versao certa, senao o proprio
  // app que acabou de trocar a senha ficaria com um token que passa a falhar
  // na proxima chamada.
  const updated = await db.query(
    'UPDATE users SET password_hash=$1, token_version=token_version+1 WHERE id=$2 RETURNING token_version',
    [hash, req.auth.userId]
  );
  const token = sign({
    userId: req.auth.userId, tenantId: req.auth.tenantId, role: req.auth.role,
    tokenVersion: updated.rows[0].token_version,
  });
  res.json({ ok: true, token });
});

// Exclusão da própria conta com confirmação de senha. Contas de motorista
// são anonimizadas para preservar o histórico obrigatório das viagens; a
// conta deixa de autenticar imediatamente. O administrador principal não é
// removido sem transferência de titularidade do tenant.
app.delete('/api/auth/account', authMiddleware, async (req, res) => {
  const { password } = req.body || {};
  if (!password) return res.status(400).json({ error: 'confirme sua senha' });
  const found = await db.query(
    'SELECT role, password_hash FROM users WHERE id=$1 AND tenant_id=$2',
    [req.auth.userId, req.auth.tenantId]
  );
  if (found.rows.length === 0) return res.status(404).json({ error: 'usuario nao encontrado' });
  if (!(await bcrypt.compare(password, found.rows[0].password_hash))) {
    return res.status(400).json({ error: 'senha incorreta' });
  }
  if (found.rows[0].role === 'admin') {
    return res.status(409).json({
      error: 'transfira a administração antes de excluir a conta principal'
    });
  }
  if (found.rows[0].role === 'driver') {
    const active = await db.query(
      `SELECT 1 FROM trips WHERE driver_user_id=$1 AND status='active' LIMIT 1`,
      [req.auth.userId]
    );
    if (active.rows.length > 0) {
      return res.status(409).json({ error: 'finalize a rota ativa antes de excluir a conta' });
    }
    await db.query(
      `UPDATE users
          SET name='Conta removida', email=$1, phone=NULL, fcm_token=NULL,
              password_hash=$2, active=false, token_version=token_version+1
        WHERE id=$3 AND tenant_id=$4`,
      [`removed-${req.auth.userId}@invalid.local`, await bcrypt.hash(crypto.randomUUID(), 10),
        req.auth.userId, req.auth.tenantId]
    );
  } else {
    await db.query('DELETE FROM users WHERE id=$1 AND tenant_id=$2', [
      req.auth.userId, req.auth.tenantId,
    ]);
  }
  res.json({ ok: true });
});

// Admin reseta a senha de outro usuario do tenant, incluindo outro admin
// (fluxo de "esqueci a senha" sem depender de e-mail: a pessoa pede pra
// qualquer admin do tenant).
app.put('/api/users/:id/password', authMiddleware, requireRole('admin'), async (req, res) => {
  const { newPassword } = req.body;
  const passwordError = passwordProblem(newPassword);
  if (passwordError) return res.status(400).json({ error: passwordError });
  const u = await db.query(
    `SELECT id FROM users WHERE id=$1 AND tenant_id=$2 AND role IN ('admin','driver','parent')`,
    [req.params.id, req.auth.tenantId]
  );
  if (u.rows.length === 0) return res.status(404).json({ error: 'usuario nao encontrado' });
  const hash = await bcrypt.hash(newPassword, 10);
  // token_version+1 invalida qualquer sessao antiga daquele usuario -- ele
  // precisa logar de novo com a senha nova (comportamento esperado do fluxo
  // de "esqueci a senha").
  await db.query(
    'UPDATE users SET password_hash=$1, token_version=token_version+1 WHERE id=$2',
    [hash, req.params.id]
  );
  await logAudit(req, 'resetar_senha', 'user', req.params.id, null);
  res.json({ ok: true });
});

// Login. Email e unico globalmente (nao so por tenant) -- os apps nunca
// mandam tenantId, entao a unicidade global e o que evita ambiguidade
// (antes, com unicidade so por tenant, um "LIMIT 1" sem ORDER BY podia
// pegar o usuario errado se dois tenants tivessem o mesmo e-mail).
// `tenantId` no body continua aceito por compatibilidade, mas ignorado.
app.post('/api/auth/login', async (req, res) => {
  const { email, password } = req.body;
  if (typeof email !== 'string' || typeof password !== 'string') {
    return res.status(400).json({ error: 'e-mail e senha obrigatorios' });
  }
  const r = await db.query('SELECT * FROM users WHERE LOWER(email)=LOWER($1) LIMIT 1', [email.trim()]);
  if (r.rows.length === 0) return res.status(401).json({ error: 'credenciais invalidas' });
  const user = r.rows[0];
  const ok = await bcrypt.compare(password, user.password_hash);
  if (!ok) return res.status(401).json({ error: 'credenciais invalidas' });
  if (!user.active) return res.status(401).json({ error: 'conta desativada' });
  db.query('UPDATE users SET last_login_at=now() WHERE id=$1', [user.id]).catch((e) =>
    console.error('[login] falha ao atualizar last_login_at', e.message)
  );
  const token = sign({
    userId: user.id, tenantId: user.tenant_id, role: user.role, tokenVersion: user.token_version,
  });
  res.json({ token, userId: user.id, role: user.role, name: user.name, tenantId: user.tenant_id });
});

// Cadastro do responsavel via codigo de convite (publico, sem auth — o
// codigo de 6 caracteres E a credencial que prova o vinculo com o aluno).
app.post('/api/auth/register-parent', async (req, res) => {
  const { code, name, email, password } = req.body;
  if (!code || !email || !password) {
    return res.status(400).json({ error: 'campos obrigatorios faltando' });
  }
  const passwordError = passwordProblem(password);
  if (passwordError) return res.status(400).json({ error: passwordError });
  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const inv = await client.query(
      'SELECT * FROM guardian_invites WHERE code=$1 FOR UPDATE',
      [code.toUpperCase()]
    );
    if (inv.rows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'codigo invalido' });
    }
    const invite = inv.rows[0];
    if (invite.used_by_user_id) {
      await client.query('ROLLBACK');
      return res.status(410).json({ error: 'codigo ja utilizado' });
    }
    if (invite.cancelled_at) {
      await client.query('ROLLBACK');
      return res.status(410).json({ error: 'codigo cancelado' });
    }
    if (new Date(invite.expires_at) < new Date()) {
      await client.query('ROLLBACK');
      return res.status(410).json({ error: 'codigo expirado' });
    }

    const normalizedEmail = email.trim().toLowerCase();
    const existing = await client.query(
      'SELECT * FROM users WHERE LOWER(email)=LOWER($1) FOR UPDATE',
      [normalizedEmail]
    );
    let userId;
    let tokenVersion = 0;
    let existingAccount = false;
    if (existing.rows.length > 0) {
      const user = existing.rows[0];
      if (user.role !== 'parent' || user.tenant_id !== invite.tenant_id) {
        await client.query('ROLLBACK');
        return res.status(409).json({ error: 'e-mail usado em outro perfil ou transportador' });
      }
      if (!(await bcrypt.compare(password, user.password_hash))) {
        await client.query('ROLLBACK');
        return res.status(409).json({ error: 'conta existente: senha incorreta' });
      }
      userId = user.id;
      tokenVersion = user.token_version;
      existingAccount = true;
    } else {
      const hash = await bcrypt.hash(password, 10);
      const u = await client.query(
        `INSERT INTO users(tenant_id, role, name, email, password_hash)
         VALUES($1,'parent',$2,$3,$4) RETURNING id`,
        [invite.tenant_id, name || 'Responsavel', normalizedEmail, hash]
      );
      userId = u.rows[0].id;
    }
    await client.query(
      `INSERT INTO student_guardians(tenant_id, student_id, guardian_user_id, relationship)
       VALUES($1,$2,$3,$4) ON CONFLICT (student_id, guardian_user_id)
       DO UPDATE SET relationship=EXCLUDED.relationship`,
      [invite.tenant_id, invite.student_id, userId, invite.relationship]
    );
    await client.query(
      'UPDATE guardian_invites SET used_by_user_id=$1 WHERE id=$2',
      [userId, invite.id]
    );
    await client.query('COMMIT');
    const student = await client.query('SELECT name FROM students WHERE id=$1', [invite.student_id]);
    const token = sign({ userId, tenantId: invite.tenant_id, role: 'parent', tokenVersion });
    res.json({ token, userId, tenantId: invite.tenant_id,
      existingAccount, studentName: student.rows[0]?.name || 'Aluno' });
  } catch (e) {
    await client.query('ROLLBACK');
    if (e.code === '23505') {
      return res.status(409).json({ error: 'ja existe um cadastro com este e-mail' });
    }
    console.error('[register-parent]', e);
    res.status(500).json({ error: 'falha no cadastro' });
  } finally {
    client.release();
  }
});

// Um responsavel que ja tem conta vincula outro filho usando um segundo
// codigo de convite (o registro publico acima so serve pra criar a
// PRIMEIRA conta -- usar o mesmo e-mail de novo daria 409). Mesmas regras
// de validacao do codigo, so que aqui vincula ao usuario ja autenticado em
// vez de criar um usuario novo.
app.post('/api/auth/link-child', authMiddleware, requireRole('parent'), async (req, res) => {
  const { code } = req.body;
  if (!code) return res.status(400).json({ error: 'codigo obrigatorio' });
  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const inv = await client.query(
      'SELECT * FROM guardian_invites WHERE code=$1 FOR UPDATE',
      [code.toUpperCase()]
    );
    if (inv.rows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'codigo invalido' });
    }
    const invite = inv.rows[0];
    if (invite.tenant_id !== req.auth.tenantId) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'codigo invalido' });
    }
    if (invite.used_by_user_id) {
      await client.query('ROLLBACK');
      return res.status(410).json({ error: 'codigo ja utilizado' });
    }
    if (invite.cancelled_at) {
      await client.query('ROLLBACK');
      return res.status(410).json({ error: 'codigo cancelado' });
    }
    if (new Date(invite.expires_at) < new Date()) {
      await client.query('ROLLBACK');
      return res.status(410).json({ error: 'codigo expirado' });
    }

    await client.query(
      `INSERT INTO student_guardians(tenant_id, student_id, guardian_user_id, relationship)
       VALUES($1,$2,$3,$4) ON CONFLICT (student_id, guardian_user_id)
       DO UPDATE SET relationship=EXCLUDED.relationship`,
      [invite.tenant_id, invite.student_id, req.auth.userId, invite.relationship]
    );
    await client.query(
      'UPDATE guardian_invites SET used_by_user_id=$1 WHERE id=$2',
      [req.auth.userId, invite.id]
    );
    await client.query('COMMIT');
    const student = await client.query('SELECT name FROM students WHERE id=$1', [invite.student_id]);
    res.json({ ok: true, studentName: student.rows[0]?.name || 'Aluno' });
  } catch (e) {
    await client.query('ROLLBACK');
    console.error('[link-child]', e);
    res.status(500).json({ error: 'falha ao vincular aluno' });
  } finally {
    client.release();
  }
});

// Salva/atualiza o token FCM do usuario logado (para push notifications).
app.post('/api/users/fcm-token', authMiddleware, async (req, res) => {
  const { fcm_token } = req.body;
  if (!fcm_token) return res.status(400).json({ error: 'fcm_token obrigatorio' });
  await db.query(
    'UPDATE users SET fcm_token=$1 WHERE id=$2 AND tenant_id=$3',
    [fcm_token, req.auth.userId, req.auth.tenantId]
  );
  res.json({ ok: true });
});

/* =========================================================================
 * CHAT — uma thread por responsavel; todo admin/driver do tenant fala nela
 * ========================================================================= */

// Resolve o parentUserId de uma thread a partir do role de quem chama:
// pai so acessa a propria thread; admin/driver escolhe via :parentUserId
// (e precisa que esse usuario seja mesmo um pai do tenant).
async function resolveChatParentId(req, res) {
  if (req.auth.role === 'parent') {
    if (req.params.parentUserId && req.params.parentUserId !== req.auth.userId) {
      res.status(403).json({ error: 'sem permissao' });
      return null;
    }
    return req.auth.userId;
  }
  const parentUserId = req.params.parentUserId;
  const p = await db.query(
    `SELECT id FROM users WHERE id=$1 AND tenant_id=$2 AND role='parent'`,
    [parentUserId, req.auth.tenantId]
  );
  if (p.rows.length === 0) {
    res.status(404).json({ error: 'responsavel nao encontrado' });
    return null;
  }
  return parentUserId;
}

// Lista as threads (um item por responsavel do tenant) com a ultima mensagem,
// para a tela "Mensagens" do motorista/admin escolher com quem falar.
// Cada thread (parent_user_id) ganha um unread_count pra quem esta chamando
// -- mensagens depois do ultimo chat_reads do proprio usuario, que nao foram
// mandadas por ele mesmo.
app.get('/api/chat/threads', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const r = await db.query(
    `SELECT u.id AS parent_user_id, u.name AS parent_name,
            (SELECT string_agg(s.name, ', ' ORDER BY s.name)
               FROM student_guardians sg
               JOIN students s ON s.id=sg.student_id
              WHERE sg.guardian_user_id=u.id AND sg.tenant_id=$1) AS student_names,
            (SELECT body FROM chat_messages cm
              WHERE cm.tenant_id = $1 AND cm.parent_user_id = u.id
              ORDER BY cm.created_at DESC LIMIT 1) AS last_message,
            (SELECT created_at FROM chat_messages cm
              WHERE cm.tenant_id = $1 AND cm.parent_user_id = u.id
              ORDER BY cm.created_at DESC LIMIT 1) AS last_at,
            (SELECT COUNT(*)::int FROM chat_messages cm
              WHERE cm.tenant_id = $1 AND cm.parent_user_id = u.id
                AND cm.sender_user_id <> $2
                AND cm.created_at > COALESCE(
                  (SELECT last_read_at FROM chat_reads
                    WHERE user_id = $2 AND parent_user_id = u.id),
                  'epoch'::timestamptz)
            ) AS unread_count
       FROM users u
      WHERE u.tenant_id = $1 AND u.role = 'parent'
      ORDER BY last_at DESC NULLS LAST, u.name ASC`,
    [req.auth.tenantId, req.auth.userId]
  );
  res.json(r.rows);
});

// Total de mensagens nao lidas de quem chama -- pai: so a propria thread;
// driver/admin: soma de todas as threads. Usado pro badge da aba Mensagens.
app.get('/api/chat/unread-count', authMiddleware, async (req, res) => {
  const r = await db.query(
    `SELECT COUNT(*) AS unread
       FROM chat_messages cm
      WHERE cm.tenant_id = $1
        AND cm.sender_user_id <> $2
        AND ($3 = 'parent' AND cm.parent_user_id = $2 OR $3 <> 'parent')
        AND cm.created_at > COALESCE(
          (SELECT last_read_at FROM chat_reads
            WHERE user_id = $2 AND parent_user_id = cm.parent_user_id),
          'epoch'::timestamptz)`,
    [req.auth.tenantId, req.auth.userId, req.auth.role]
  );
  res.json({ unread: Number(r.rows[0].unread) });
});

// Historico de uma thread. Pai: a propria (:parentUserId e opcional/ignorado
// na pratica do app, mas validado se vier). Admin/driver: escolhe qual pai.
// Abrir a thread marca como lida (upsert em chat_reads) -- e o ponto natural
// pra isso, ja que o app sempre busca o historico ao abrir uma conversa.
app.get('/api/chat/:parentUserId', authMiddleware, async (req, res) => {
  const parentUserId = await resolveChatParentId(req, res);
  if (!parentUserId) return;
  const r = await db.query(
    `SELECT cm.id, cm.sender_user_id, cm.body, cm.created_at,
            CASE
              WHEN cm.sender_user_id = cm.parent_user_id THEN EXISTS(
                SELECT 1 FROM chat_reads cr
                JOIN users reader ON reader.id=cr.user_id
                WHERE cr.parent_user_id=cm.parent_user_id
                  AND reader.role IN ('admin','driver')
                  AND cr.last_read_at >= cm.created_at
              )
              ELSE EXISTS(
                SELECT 1 FROM chat_reads cr
                WHERE cr.parent_user_id=cm.parent_user_id
                  AND cr.user_id=cm.parent_user_id
                  AND cr.last_read_at >= cm.created_at
              )
            END AS is_read
       FROM chat_messages cm
      WHERE cm.tenant_id = $1 AND cm.parent_user_id = $2
      ORDER BY created_at ASC`,
    [req.auth.tenantId, parentUserId]
  );
  // Precisa ser aguardado antes de responder -- e a propria acao de "abrir a
  // thread marca como lida", nao um efeito colateral secundario (como um
  // push). Antes rodava fire-and-forget e a resposta podia chegar ao cliente
  // antes do UPDATE terminar, fazendo a proxima chamada a /unread-count
  // ainda contar a mensagem como nao lida (race condition real, pega pelo
  // teste de integracao, nao por uso manual).
  await db.query(
    `INSERT INTO chat_reads(tenant_id, user_id, parent_user_id, last_read_at)
     VALUES($1,$2,$3,now())
     ON CONFLICT (user_id, parent_user_id) DO UPDATE SET last_read_at = now()`,
    [req.auth.tenantId, req.auth.userId, parentUserId]
  ).catch((e) => console.error('[chat] falha ao marcar como lido', e.message));
  res.json(r.rows);
});

app.post('/api/chat/:parentUserId', authMiddleware, chatLimiter, validateBody(chatMessageBody), async (req, res) => {
  const { body } = req.body;
  const parentUserId = await resolveChatParentId(req, res);
  if (!parentUserId) return;

  const r = await db.query(
    `INSERT INTO chat_messages(tenant_id, parent_user_id, sender_user_id, body)
     VALUES($1,$2,$3,$4) RETURNING *`,
    [req.auth.tenantId, parentUserId, req.auth.userId, body.trim()]
  );
  hub.broadcast(`chat:${parentUserId}`, { type: 'message', message: r.rows[0] });

  // Notifica o outro lado da conversa (nao bloqueia a resposta).
  if (req.auth.role === 'parent') {
    db.query(`SELECT id FROM users WHERE tenant_id=$1 AND role IN ('admin','driver')`, [req.auth.tenantId])
      .then((staff) =>
        push.sendToUsers(staff.rows.map((s) => s.id), 'TECO', 'Nova mensagem de um responsavel', {
          type: 'chat', parentUserId,
        })
      )
      .catch((e) => console.error('[push] falha ao notificar chat', e.message));
  } else {
    push
      .sendToUsers([parentUserId], 'TECO', 'Nova mensagem do motorista', { type: 'chat', parentUserId })
      .catch((e) => console.error('[push] falha ao notificar chat', e.message));
  }

  res.json(r.rows[0]);
});

/* =========================================================================
 * CADASTROS (todos filtrados por tenant_id — isolamento multi-tenant)
 * ========================================================================= */

// school_name (texto livre) e mantido so como fallback de exibicao pra dados
// antigos -- o cliente sempre manda school_id daqui pra frente. O JOIN abaixo
// prefere o nome/endereco da escola cadastrada quando ha vinculo.
// Admin-only: lista TODOS os alunos do tenant (nome, endereco, mensalidade).
// Responsavel usa GET /api/students/mine, que ja filtra pelos proprios filhos.
app.get('/api/students', authMiddleware, requireRole('admin'), async (req, res) => {
  const r = await db.query(
    `SELECT s.*, sc.name AS school_display_name, sc.address AS school_address
       FROM students s
       LEFT JOIN schools sc ON sc.id = s.school_id
      WHERE s.tenant_id=$1
      ORDER BY s.name`,
    [req.auth.tenantId]
  );
  res.json(r.rows);
});

async function validateSchoolId(schoolId, tenantId) {
  if (!schoolId) return true;
  const sc = await db.query('SELECT id FROM schools WHERE id=$1 AND tenant_id=$2', [schoolId, tenantId]);
  return sc.rows.length > 0;
}

app.post('/api/students', authMiddleware, requireRole('admin'), validateBody(studentBody), async (req, res) => {
  const limitError = await planLimitError(req.auth.tenantId, 'students');
  if (limitError) return res.status(409).json({ error: limitError });
  const {
    name, school_name, home_address, school_id, monthly_fee,
    photo_url, birth_date, class_period, emergency_contact_name,
    emergency_contact_phone, medical_notes, authorized_pickup, active,
    home_postal_code, home_street, home_number, home_complement,
    home_neighborhood, home_city, home_state,
    home_lat, home_lng,
  } = req.body;
  if (!(await validateSchoolId(school_id, req.auth.tenantId))) {
    return res.status(404).json({ error: 'escola nao encontrada' });
  }
  const r = await db.query(
    `INSERT INTO students(
       tenant_id, name, school_name, home_address, school_id, monthly_fee,
       photo_url, birth_date, class_period, emergency_contact_name,
       emergency_contact_phone, medical_notes, authorized_pickup, active,
       home_postal_code, home_street, home_number, home_complement,
       home_neighborhood, home_city, home_state
       , home_lat, home_lng
     ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23) RETURNING *`,
    [
      req.auth.tenantId, name, school_name || null, home_address || null, school_id || null, monthly_fee ?? null,
      photo_url || null, birth_date || null, class_period || null, emergency_contact_name || null,
      emergency_contact_phone || null, medical_notes || null, authorized_pickup || null, active ?? true,
      home_postal_code || null, home_street || null, home_number || null, home_complement || null,
      home_neighborhood || null, home_city || null, home_state || null,
      home_lat ?? null, home_lng ?? null,
    ]
  );
  await logAudit(req, 'criar_aluno', 'student', r.rows[0].id, { name });
  res.json(r.rows[0]);
});

app.put('/api/students/:id', authMiddleware, requireRole('admin'), validateBody(studentBody), async (req, res) => {
  const {
    name, school_name, home_address, school_id, monthly_fee,
    photo_url, birth_date, class_period, emergency_contact_name,
    emergency_contact_phone, medical_notes, authorized_pickup, active,
    home_postal_code, home_street, home_number, home_complement,
    home_neighborhood, home_city, home_state,
    home_lat, home_lng,
  } = req.body;
  if (!(await validateSchoolId(school_id, req.auth.tenantId))) {
    return res.status(404).json({ error: 'escola nao encontrada' });
  }
  const r = await db.query(
    `UPDATE students SET
       name=$1, school_name=$2, home_address=$3, school_id=$4, monthly_fee=$5,
       photo_url=$6, birth_date=$7, class_period=$8, emergency_contact_name=$9,
       emergency_contact_phone=$10, medical_notes=$11, authorized_pickup=$12, active=$13,
       home_postal_code=$14, home_street=$15, home_number=$16, home_complement=$17,
       home_neighborhood=$18, home_city=$19, home_state=$20,
       home_lat=$21, home_lng=$22
      WHERE id=$23 AND tenant_id=$24 RETURNING *`,
    [
      name, school_name || null, home_address || null, school_id || null, monthly_fee ?? null,
      photo_url || null, birth_date || null, class_period || null, emergency_contact_name || null,
      emergency_contact_phone || null, medical_notes || null, authorized_pickup || null, active ?? true,
      home_postal_code || null, home_street || null, home_number || null, home_complement || null,
      home_neighborhood || null, home_city || null, home_state || null,
      home_lat ?? null, home_lng ?? null,
      req.params.id, req.auth.tenantId,
    ]
  );
  if (r.rows.length === 0) return res.status(404).json({ error: 'aluno nao encontrado' });
  await logAudit(req, 'editar_aluno', 'student', req.params.id, { name });
  res.json(r.rows[0]);
});

app.delete('/api/students/:id', authMiddleware, requireRole('admin'), async (req, res) => {
  const r = await db.query(
    'DELETE FROM students WHERE id=$1 AND tenant_id=$2 RETURNING id, name',
    [req.params.id, req.auth.tenantId]
  );
  if (r.rows.length === 0) return res.status(404).json({ error: 'aluno nao encontrado' });
  await logAudit(req, 'excluir_aluno', 'student', req.params.id, { name: r.rows[0].name });
  res.json({ ok: true });
});

// Filhos do pai logado, independente de ter viagem ativa hoje -- usado na
// home do app dos pais (antes so existia GET /api/trips/active, que so
// mostra quem tem viagem rolando agora).
// IMPORTANTE: precisa vir ANTES de GET /api/students/:id -- senao o Express
// casa "mine" com o parametro :id e cai na rota admin-only por engano.
app.get('/api/students/mine', authMiddleware, requireRole('parent'), async (req, res) => {
  const r = await db.query(
    `SELECT s.id, s.name, s.home_address, sc.name AS school_name, sc.address AS school_address,
            schedule.route_name AS planned_route_name,
            schedule.planned_time_to_school, schedule.planned_time_to_home,
            schedule.days_of_week, contract.id AS contract_id,
            contract.status AS contract_status, contract.expires_at AS contract_expires_at
       FROM student_guardians sg
       JOIN students s ON s.id = sg.student_id
       LEFT JOIN schools sc ON sc.id = s.school_id
       LEFT JOIN LATERAL (
         SELECT r.name AS route_name, r.planned_time_to_school,
                r.planned_time_to_home, r.days_of_week
           FROM route_students rs
           JOIN routes r ON r.id=rs.route_id
          WHERE rs.student_id=s.id AND r.tenant_id=sg.tenant_id AND r.active=true
          ORDER BY r.name LIMIT 1
       ) schedule ON true
       LEFT JOIN LATERAL (
         SELECT c.id,c.status,c.expires_at FROM student_contracts c
          WHERE c.student_id=s.id AND c.tenant_id=sg.tenant_id
            AND c.status IN ('pending','signed') ORDER BY c.version DESC LIMIT 1
       ) contract ON true
      WHERE sg.guardian_user_id=$1 AND sg.tenant_id=$2
      ORDER BY s.name`,
    [req.auth.userId, req.auth.tenantId]
  );
  res.json(r.rows);
});

// "Perfil do aluno": dados + escola + responsaveis + ultimos pagamentos, tudo
// num round-trip so pra tela de perfil do app do motorista.
// Admin ve qualquer aluno do tenant; pai so o(s) proprio(s) filho(s) --
// usado pela tela de gestao (motorista) e pela tela "Detalhes do filho"
// (pais). `assertOwnsStudentOrAdmin` esta definida mais abaixo no arquivo,
// mas e uma function declaration (hoisted), entao o uso aqui em cima funciona.
app.get('/api/students/:id', authMiddleware, async (req, res) => {
  if (!(await assertOwnsStudentOrAdmin(req, req.params.id))) {
    return res.status(403).json({ error: 'sem permissao' });
  }
  const s = await db.query(
    `SELECT s.*, sc.name AS school_display_name, sc.address AS school_address, sc.phone AS school_phone
       FROM students s
       LEFT JOIN schools sc ON sc.id = s.school_id
      WHERE s.id=$1 AND s.tenant_id=$2`,
    [req.params.id, req.auth.tenantId]
  );
  if (s.rows.length === 0) return res.status(404).json({ error: 'aluno nao encontrado' });

  const guardians = await db.query(
    `SELECT u.id, u.name, u.email, u.phone, sg.relationship
       FROM student_guardians sg
       JOIN users u ON u.id = sg.guardian_user_id
      WHERE sg.student_id=$1 AND sg.tenant_id=$2
      ORDER BY u.name`,
    [req.params.id, req.auth.tenantId]
  );

  const payments = await db.query(
    `SELECT id, reference_month, amount, status, paid_at
       FROM payments
      WHERE student_id=$1 AND tenant_id=$2
      ORDER BY reference_month DESC
      LIMIT 12`,
    [req.params.id, req.auth.tenantId]
  );

  const invites = req.auth.role === 'admin' ? await db.query(
    `SELECT id, code, relationship, expires_at, used_by_user_id, cancelled_at, created_at,
            CASE WHEN used_by_user_id IS NOT NULL THEN 'used'
                 WHEN cancelled_at IS NOT NULL THEN 'cancelled'
                 WHEN expires_at < now() THEN 'expired'
                 ELSE 'pending' END AS status
       FROM guardian_invites
      WHERE student_id=$1 AND tenant_id=$2
      ORDER BY created_at DESC LIMIT 20`,
    [req.params.id, req.auth.tenantId]
  ) : { rows: [] };

  res.json({ ...s.rows[0], guardians: guardians.rows, payments: payments.rows, invites: invites.rows });
});

/* =========================================================================
 * CONTRATOS POR ALUNO
 * ========================================================================= */

const DEFAULT_CONTRACT_TEXT = `CONTRATO DE PRESTACAO DE SERVICO DE TRANSPORTE ESCOLAR

O CONTRATADO compromete-se a prestar o transporte escolar do ALUNO identificado neste contrato, nos dias, horarios, enderecos e escolas cadastrados no aplicativo, observadas as condicoes operacionais combinadas entre as partes.

O RESPONSAVEL declara que os dados do aluno, contatos de emergencia, pessoas autorizadas e informacoes relevantes de saude foram informados corretamente e se compromete a mante-los atualizados.

Faltas, mudancas de endereco, alteracoes de horario e situacoes excepcionais devem ser comunicadas pelos canais disponibilizados. A mensalidade, vencimento, reajustes, ferias, cancelamento e demais condicoes comerciais seguem o que estiver preenchido neste instrumento e acordado entre as partes.

O acompanhamento por GPS e as notificacoes sao recursos auxiliares e podem sofrer variacoes por sinal, bateria, internet ou disponibilidade dos servicos de terceiros. Eles nao substituem a comunicacao direta em emergencias.

Os dados pessoais serao tratados para executar o transporte, manter a seguranca do aluno, comunicar ocorrencias, cumprir obrigacoes legais e preservar evidencias desta contratacao, conforme a legislacao aplicavel e a politica de privacidade.

Ao assinar eletronicamente, o RESPONSAVEL confirma que leu integralmente o documento, concorda com suas condicoes e reconhece como evidencias a identidade da conta autenticada, data e hora, endereco IP, identificacao do dispositivo e os hashes de integridade registrados pelo sistema.`;

function sha256(value) {
  return crypto.createHash('sha256').update(String(value), 'utf8').digest('hex');
}

const planResources = {
  students: { table: 'students', limit: 'max_students', label: 'alunos', where: '' },
  staff: { table: 'users', limit: 'max_staff', label: 'usuarios da equipe', where: "AND role IN ('admin','driver')" },
  vehicles: { table: 'vehicles', limit: 'max_vehicles', label: 'veiculos', where: '' },
  schools: { table: 'schools', limit: 'max_schools', label: 'escolas', where: '' },
};
async function planLimitError(tenantId, resource) {
  const config = planResources[resource];
  if (!config) throw new Error('recurso de plano desconhecido');
  const result = await db.query(
    `SELECT COALESCE(NULLIF(s.overrides->>$2,''),'0')::int override_limit,
            p.${config.limit} plan_limit,
            (SELECT count(*) FROM ${config.table} WHERE tenant_id=$1 ${config.where})::int used
       FROM platform_subscriptions s JOIN platform_plans p ON p.id=s.plan_id
      WHERE s.tenant_id=$1`, [tenantId, config.limit]
  );
  if (!result.rows.length) return null;
  const row = result.rows[0];
  const limit = row.override_limit > 0 ? row.override_limit : row.plan_limit;
  return row.used >= limit
    ? `limite de ${config.label} do plano atingido (${limit}); altere o plano ou solicite uma liberacao`
    : null;
}

function validCpf(value) {
  const cpf = String(value || '').replace(/\D/g, '');
  if (cpf.length !== 11 || /^(\d)\1{10}$/.test(cpf)) return false;
  const digit = (size) => {
    let sum = 0;
    for (let i = 0; i < size; i++) sum += Number(cpf[i]) * (size + 1 - i);
    const mod = (sum * 10) % 11;
    return mod === 10 ? 0 : mod;
  };
  return digit(9) === Number(cpf[9]) && digit(10) === Number(cpf[10]);
}

function maskedCpf(value) {
  const cpf = String(value || '').replace(/\D/g, '');
  return `***.${cpf.slice(3, 6)}.${cpf.slice(6, 9)}-**`;
}

function formatCpf(value) {
  const cpf = String(value || '').replace(/\D/g, '');
  return cpf.length === 11
    ? `${cpf.slice(0, 3)}.${cpf.slice(3, 6)}.${cpf.slice(6, 9)}-${cpf.slice(9)}`
    : 'nao informado';
}

function encryptCpf(value) {
  return `enc:${encryptPaymentSecret(String(value).replace(/\D/g, ''))}`;
}

function decryptCpf(value) {
  if (!value) return null;
  const raw = String(value);
  if (/^\d{11}$/.test(raw)) return raw; // compatibilidade para registros anteriores
  if (!raw.startsWith('enc:')) throw new Error('formato de CPF cifrado invalido');
  return decryptPaymentSecret(raw.slice(4));
}

async function migrateLegacyContractCpfs() {
  const legacy = await db.query(
    `SELECT id,signer_cpf FROM student_contracts WHERE signer_cpf ~ '^[0-9]{11}$'`
  );
  for (const row of legacy.rows) {
    await db.query('UPDATE student_contracts SET signer_cpf=$1 WHERE id=$2 AND signer_cpf=$3',
      [encryptCpf(row.signer_cpf), row.id, row.signer_cpf]);
  }
  if (legacy.rows.length) console.log(`[security] ${legacy.rows.length} CPF(s) legado(s) cifrado(s)`);
}
migrateLegacyContractCpfs().catch((error) => console.error('[security] falha ao cifrar CPFs legados', error.message));

async function contractAccess(req, studentId) {
  if (req.auth.role === 'admin') {
    const found = await db.query('SELECT id FROM students WHERE id=$1 AND tenant_id=$2', [studentId, req.auth.tenantId]);
    return found.rows.length > 0;
  }
  if (req.auth.role !== 'parent') return false;
  const found = await db.query(
    `SELECT 1 FROM student_guardians WHERE student_id=$1 AND guardian_user_id=$2 AND tenant_id=$3`,
    [studentId, req.auth.userId, req.auth.tenantId]
  );
  return found.rows.length > 0;
}

app.get('/api/students/:id/contracts', authMiddleware, async (req, res) => {
  if (!(await contractAccess(req, req.params.id))) return res.status(403).json({ error: 'sem permissao' });
  const result = await db.query(
    `SELECT c.id, c.student_id, c.version, c.title, c.contract_text, c.contract_hash,
            c.status, c.issued_at, c.signer_name, c.signer_email,
            c.signer_relationship, c.signed_at, host(c.signer_ip) AS signer_ip,
            c.signer_user_agent, c.acceptance_text, c.evidence_hash, c.signer_cpf,
            c.revoked_at, c.revocation_reason, c.expires_at,
            c.first_downloaded_at, c.download_count,
            s.name AS student_name,
            (SELECT string_agg(gu.name, ', ' ORDER BY gu.name)
               FROM student_guardians gsg JOIN users gu ON gu.id=gsg.guardian_user_id
              WHERE gsg.student_id=c.student_id) AS guardian_names,
            t.name AS tenant_name
       FROM student_contracts c
       JOIN students s ON s.id=c.student_id
       JOIN tenants t ON t.id=c.tenant_id
      WHERE c.student_id=$1 AND c.tenant_id=$2
      ORDER BY c.version DESC`,
    [req.params.id, req.auth.tenantId]
  );
  res.json(result.rows.map((row) => ({ ...row,
    responsible_name: row.signer_name || row.guardian_names || 'nao informado',
    signer_cpf_display: row.signer_cpf ? formatCpf(decryptCpf(row.signer_cpf)) : null,
    signer_cpf_masked: row.signer_cpf ? maskedCpf(decryptCpf(row.signer_cpf)) : null,
    signer_cpf: undefined,
  })));
});

app.get('/api/contracts/settings', authMiddleware, requireRole('admin'), async (req, res) => {
  const result = await db.query(
    `SELECT name, legal_name, tax_id, legal_address, contract_title,
            contract_template, contract_validity_days, require_signed_contract
       FROM tenants WHERE id=$1`, [req.auth.tenantId]
  );
  res.json({ ...result.rows[0], default_template: DEFAULT_CONTRACT_TEXT });
});

app.put('/api/contracts/settings', authMiddleware, requireRole('admin'), async (req, res) => {
  const title = String(req.body.contract_title || '').trim();
  const template = String(req.body.contract_template || '').trim();
  const validity = Number(req.body.contract_validity_days ?? 15);
  if (title && (title.length < 5 || title.length > 160)) return res.status(400).json({ error: 'titulo invalido' });
  if (template && (template.length < 200 || template.length > 30000)) return res.status(400).json({ error: 'modelo deve ter entre 200 e 30000 caracteres' });
  if (!Number.isInteger(validity) || validity < 1 || validity > 365) return res.status(400).json({ error: 'prazo deve ficar entre 1 e 365 dias' });
  const result = await db.query(
    `UPDATE tenants SET legal_name=$1,tax_id=$2,legal_address=$3,contract_title=$4,
            contract_template=$5,contract_validity_days=$6,require_signed_contract=$7
      WHERE id=$8 RETURNING id`,
    [String(req.body.legal_name || '').trim() || null, String(req.body.tax_id || '').trim() || null,
      String(req.body.legal_address || '').trim() || null, title || null, template || null,
      validity, req.body.require_signed_contract === true, req.auth.tenantId]
  );
  await logAudit(req, 'alterar_modelo_contrato', 'tenant', req.auth.tenantId,
    { contract_validity_days: validity, require_signed_contract: req.body.require_signed_contract === true });
  res.json({ ok: result.rows.length === 1 });
});

app.get('/api/contracts', authMiddleware, requireRole('admin'), async (req, res) => {
  const result = await db.query(
    `SELECT c.id,c.student_id,c.version,c.title,c.status,c.issued_at,c.expires_at,
            c.signed_at,c.signer_name,c.first_downloaded_at,c.download_count,
            s.name AS student_name
       FROM student_contracts c JOIN students s ON s.id=c.student_id
      WHERE c.tenant_id=$1 ORDER BY
        CASE c.status WHEN 'pending' THEN 0 WHEN 'signed' THEN 1 ELSE 2 END,
        c.issued_at DESC`, [req.auth.tenantId]
  );
  const rows = result.rows.map((row) => ({ ...row,
    display_status: row.status === 'pending' && row.expires_at && new Date(row.expires_at) < new Date() ? 'expired' : row.status,
  }));
  const reminders = await db.query(
    `SELECT c.id,c.student_id,s.name,
            array_agg(DISTINCT sg.guardian_user_id) FILTER (WHERE sg.guardian_user_id IS NOT NULL) AS guardian_ids
       FROM student_contracts c JOIN students s ON s.id=c.student_id
       LEFT JOIN student_guardians sg ON sg.student_id=c.student_id
      WHERE c.tenant_id=$1 AND c.status='pending' AND c.expires_at>now()
        AND (c.last_reminder_at IS NULL OR c.last_reminder_at<now()-interval '24 hours')
        AND (c.issued_at<now()-interval '3 days' OR c.expires_at<now()+interval '3 days')
      GROUP BY c.id,s.name`, [req.auth.tenantId]
  );
  for (const reminder of reminders.rows) {
    push.sendToUsers(reminder.guardian_ids || [], 'Contrato aguardando assinatura',
      `O contrato de ${reminder.name} ainda esta pendente. Verifique antes do vencimento.`,
      { type: 'contract', studentId: reminder.student_id, studentName: reminder.name, contractId: reminder.id }
    ).catch((error) => console.error('[lembrete contrato]', error.message));
    await db.query('UPDATE student_contracts SET last_reminder_at=now() WHERE id=$1', [reminder.id]);
  }
  res.json(rows);
});

app.post('/api/contracts/bulk-issue', authMiddleware, requireRole('admin'), async (req, res) => {
  const renewSigned = req.body.renew_signed === true;
  const tenant = await db.query(
    `SELECT name,legal_name,tax_id,legal_address,contract_title,contract_template,contract_validity_days
       FROM tenants WHERE id=$1`, [req.auth.tenantId]
  );
  if (renewSigned) {
    await db.query(
      `UPDATE student_contracts SET status='revoked',revoked_at=now(),revoked_by_user_id=$1,
              revocation_reason='Renovacao em lote solicitada pelo administrador'
        WHERE tenant_id=$2 AND status IN ('pending','signed')`, [req.auth.userId, req.auth.tenantId]
    );
  } else {
    await db.query(
      `UPDATE student_contracts SET status='revoked',revoked_at=now(),revoked_by_user_id=$1,
              revocation_reason='Prazo expirado antes da emissao em lote'
        WHERE tenant_id=$2 AND status='pending' AND expires_at<now()`, [req.auth.userId, req.auth.tenantId]
    );
  }
  const students = await db.query(
    `SELECT s.id,s.name,s.home_address,s.monthly_fee,sc.name AS school_name
       FROM students s LEFT JOIN schools sc ON sc.id=s.school_id
      WHERE s.tenant_id=$1 AND s.active=true AND NOT EXISTS (
        SELECT 1 FROM student_contracts c WHERE c.student_id=s.id AND c.status IN ('pending','signed'))
      ORDER BY s.name`, [req.auth.tenantId]
  );
  let created = 0;
  for (const student of students.rows) {
    const guardians = await db.query(
      `SELECT string_agg(u.name, ', ' ORDER BY u.name) AS names,
              array_agg(u.id) AS ids
         FROM student_guardians sg JOIN users u ON u.id=sg.guardian_user_id
        WHERE sg.student_id=$1`, [student.id]
    );
    const t = tenant.rows[0];
    const values = {
      '{{ALUNO}}': student.name, '{{RESPONSAVEL}}': guardians.rows[0]?.names || 'nao informado',
      '{{ESCOLA}}': student.school_name || 'nao informada', '{{ENDERECO_ALUNO}}': student.home_address || 'nao informado',
      '{{MENSALIDADE}}': student.monthly_fee == null ? 'nao definida' : `R$ ${Number(student.monthly_fee).toFixed(2).replace('.', ',')}`,
      '{{TRANSPORTADOR}}': t.legal_name || t.name, '{{CPF_CNPJ_TRANSPORTADOR}}': t.tax_id || 'nao informado',
      '{{ENDERECO_TRANSPORTADOR}}': t.legal_address || 'nao informado',
    };
    let body = t.contract_template || DEFAULT_CONTRACT_TEXT;
    for (const [key, value] of Object.entries(values)) body = body.split(key).join(value);
    const text = `CONTRATANTE/RESPONSAVEL: ${values['{{RESPONSAVEL}}']}\nCPF DO RESPONSAVEL: registrado no ato da assinatura\nALUNO: ${student.name}\n\nCONTRATADO: ${values['{{TRANSPORTADOR}}']}\nCPF/CNPJ: ${values['{{CPF_CNPJ_TRANSPORTADOR}}']}\nENDERECO: ${values['{{ENDERECO_TRANSPORTADOR}}']}\n\n${body}`;
    const version = await db.query('SELECT COALESCE(max(version),0)+1 AS version FROM student_contracts WHERE student_id=$1', [student.id]);
    const inserted = await db.query(
      `INSERT INTO student_contracts(tenant_id,student_id,version,title,contract_text,contract_hash,issued_by_user_id,expires_at,verification_token)
       VALUES($1,$2,$3,$4,$5,$6,$7,now()+($8::text||' days')::interval,$9) RETURNING id`,
      [req.auth.tenantId, student.id, version.rows[0].version, t.contract_title || `Contrato de transporte escolar - ${student.name}`,
        text, sha256(text), req.auth.userId, t.contract_validity_days || 15, crypto.randomBytes(24).toString('base64url')]
    );
    created++;
    push.sendToUsers(guardians.rows[0]?.ids || [], 'Contrato disponivel',
      `O contrato de ${student.name} esta aguardando sua assinatura.`,
      { type: 'contract', studentId: student.id, studentName: student.name, contractId: inserted.rows[0].id }
    ).catch((error) => console.error('[push contrato lote]', error.message));
  }
  await logAudit(req, renewSigned ? 'renovar_contratos_lote' : 'emitir_contratos_lote', 'student_contract', null, { count: created });
  res.json({ ok: true, created });
});

app.post('/api/students/:id/contracts', authMiddleware, requireRole('admin'), async (req, res) => {
  const student = await db.query(
    `SELECT s.id, s.name, s.home_address, s.monthly_fee, sc.name AS school_name,
            t.name AS tenant_name, t.legal_name, t.tax_id,
            t.legal_address, t.contract_title, t.contract_template, t.contract_validity_days
       FROM students s JOIN tenants t ON t.id=s.tenant_id
       LEFT JOIN schools sc ON sc.id=s.school_id
      WHERE s.id=$1 AND s.tenant_id=$2`, [req.params.id, req.auth.tenantId]
  );
  if (!student.rows.length) return res.status(404).json({ error: 'aluno nao encontrado' });
  await db.query(
    `UPDATE student_contracts SET status='revoked',revoked_at=now(),revoked_by_user_id=$1,
            revocation_reason='Prazo de assinatura expirado; substituido por nova emissao'
      WHERE student_id=$2 AND tenant_id=$3 AND status='pending' AND expires_at<now()`,
    [req.auth.userId, req.params.id, req.auth.tenantId]
  );
  const existing = await db.query(
    `SELECT id, status FROM student_contracts WHERE student_id=$1 AND tenant_id=$2
      AND status IN ('pending','signed') LIMIT 1`, [req.params.id, req.auth.tenantId]
  );
  if (existing.rows.length) {
    return res.status(409).json({ error: 'este aluno ja possui um contrato vigente; revogue-o antes de emitir uma nova versao' });
  }
  const party = student.rows[0];
  const guardianNames = await db.query(
    `SELECT string_agg(u.name, ', ' ORDER BY u.name) AS names
       FROM student_guardians sg JOIN users u ON u.id=sg.guardian_user_id
      WHERE sg.student_id=$1 AND sg.tenant_id=$2`, [req.params.id, req.auth.tenantId]
  );
  const title = String(req.body.title || party.contract_title || `Contrato de transporte escolar - ${party.name}`).trim();
  const values = {
    '{{ALUNO}}': party.name,
    '{{RESPONSAVEL}}': guardianNames.rows[0]?.names || 'nao informado',
    '{{ESCOLA}}': party.school_name || 'nao informada',
    '{{ENDERECO_ALUNO}}': party.home_address || 'nao informado',
    '{{MENSALIDADE}}': party.monthly_fee == null ? 'nao definida' : `R$ ${Number(party.monthly_fee).toFixed(2).replace('.', ',')}`,
    '{{TRANSPORTADOR}}': party.legal_name || party.tenant_name,
    '{{CPF_CNPJ_TRANSPORTADOR}}': party.tax_id || 'nao informado',
    '{{ENDERECO_TRANSPORTADOR}}': party.legal_address || 'nao informado',
  };
  let templateText = party.contract_template || DEFAULT_CONTRACT_TEXT;
  for (const [placeholder, value] of Object.entries(values)) templateText = templateText.split(placeholder).join(value);
  const generatedText = `CONTRATANTE/RESPONSAVEL: ${values['{{RESPONSAVEL}}']}\nCPF DO RESPONSAVEL: registrado no ato da assinatura\nALUNO: ${party.name}\n\nCONTRATADO: ${values['{{TRANSPORTADOR}}']}\nCPF/CNPJ: ${values['{{CPF_CNPJ_TRANSPORTADOR}}']}\nENDERECO: ${values['{{ENDERECO_TRANSPORTADOR}}']}\n\n${templateText}`;
  const text = String(req.body.contract_text || generatedText).trim();
  if (title.length < 5 || title.length > 160) return res.status(400).json({ error: 'titulo invalido' });
  if (text.length < 200 || text.length > 30000) return res.status(400).json({ error: 'o contrato deve ter entre 200 e 30000 caracteres' });
  const version = await db.query('SELECT COALESCE(max(version),0)+1 AS version FROM student_contracts WHERE student_id=$1', [req.params.id]);
  const validity = Number(req.body.validity_days ?? party.contract_validity_days ?? 15);
  if (!Number.isInteger(validity) || validity < 1 || validity > 365) return res.status(400).json({ error: 'prazo invalido' });
  const created = await db.query(
    `INSERT INTO student_contracts(tenant_id,student_id,version,title,contract_text,contract_hash,issued_by_user_id,expires_at,verification_token)
     VALUES($1,$2,$3,$4,$5,$6,$7,now()+($8::text||' days')::interval,$9) RETURNING *`,
    [req.auth.tenantId, req.params.id, version.rows[0].version, title, text, sha256(text), req.auth.userId, validity, crypto.randomBytes(24).toString('base64url')]
  );
  await logAudit(req, 'emitir_contrato', 'student_contract', created.rows[0].id,
    { student_id: req.params.id, version: created.rows[0].version, contract_hash: created.rows[0].contract_hash });
  const guardians = await db.query(
    'SELECT guardian_user_id AS id FROM student_guardians WHERE student_id=$1 AND tenant_id=$2',
    [req.params.id, req.auth.tenantId]
  );
  push.sendToUsers(guardians.rows.map((row) => row.id), 'Contrato disponivel',
    `O contrato de ${student.rows[0].name} esta aguardando sua assinatura.`,
    { type: 'contract', studentId: req.params.id, studentName: student.rows[0].name, contractId: created.rows[0].id }
  ).catch((error) => console.error('[push contrato]', error.message));
  res.status(201).json(created.rows[0]);
});

app.post('/api/contracts/:id/challenge', authMiddleware, requireRole('parent'), async (req, res) => {
  const allowed = await db.query(
    `SELECT c.id FROM student_contracts c JOIN student_guardians sg ON sg.student_id=c.student_id
      WHERE c.id=$1 AND c.tenant_id=$2 AND c.status='pending' AND sg.guardian_user_id=$3`,
    [req.params.id, req.auth.tenantId, req.auth.userId]
  );
  if (!allowed.rows.length) return res.status(403).json({ error: 'contrato nao disponivel para assinatura' });
  const code = String(crypto.randomInt(100000, 1000000));
  const codeHash = sha256(`${req.params.id}|${req.auth.userId}|${code}|${process.env.JWT_SECRET}`);
  await db.query(
    `UPDATE contract_signing_challenges SET consumed_at=now()
      WHERE contract_id=$1 AND user_id=$2 AND consumed_at IS NULL`, [req.params.id, req.auth.userId]
  );
  await db.query(
    `INSERT INTO contract_signing_challenges(tenant_id,contract_id,user_id,code_hash,expires_at)
     VALUES($1,$2,$3,$4,now()+interval '10 minutes')`,
    [req.auth.tenantId, req.params.id, req.auth.userId, codeHash]
  );
  push.sendToUsers([req.auth.userId], 'Codigo para assinar contrato',
    `Seu codigo de confirmacao e ${code}. Ele vence em 10 minutos.`,
    { type: 'contract_code', contractId: req.params.id }
  ).catch((error) => console.error('[push codigo contrato]', error.message));
  res.json({ ok: true, expiresInMinutes: 10,
    ...(process.env.NODE_ENV !== 'production' ? { devCode: code } : {}) });
});

app.post('/api/contracts/:id/sign', authMiddleware, requireRole('parent'), async (req, res) => {
  if (req.body.accepted !== true) return res.status(400).json({ error: 'confirme a leitura e o aceite do contrato' });
  const signerName = String(req.body.signer_name || '').trim();
  if (signerName.length < 3 || signerName.length > 160) return res.status(400).json({ error: 'informe o nome completo do responsavel' });
  if (!validCpf(req.body.cpf)) return res.status(400).json({ error: 'informe um CPF valido' });
  if (typeof req.body.password !== 'string' || !req.body.password) return res.status(400).json({ error: 'confirme sua senha' });
  const verificationCode = String(req.body.verification_code || '').trim();
  if (!/^\d{6}$/.test(verificationCode)) return res.status(400).json({ error: 'informe o codigo de 6 digitos' });
  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const contract = await client.query(
      `SELECT c.*, sg.relationship, u.email, u.password_hash
         FROM student_contracts c
         JOIN student_guardians sg ON sg.student_id=c.student_id AND sg.guardian_user_id=$1
         JOIN users u ON u.id=$1
        WHERE c.id=$2 AND c.tenant_id=$3 FOR UPDATE`,
      [req.auth.userId, req.params.id, req.auth.tenantId]
    );
    if (!contract.rows.length) { await client.query('ROLLBACK'); return res.status(403).json({ error: 'sem permissao' }); }
    const c = contract.rows[0];
    if (c.status !== 'pending') { await client.query('ROLLBACK'); return res.status(409).json({ error: c.status === 'signed' ? 'contrato ja assinado' : 'contrato revogado' }); }
    if (c.expires_at && new Date(c.expires_at) < new Date()) { await client.query('ROLLBACK'); return res.status(410).json({ error: 'contrato expirado; solicite uma nova emissao' }); }
    if (!(await bcrypt.compare(req.body.password, c.password_hash))) { await client.query('ROLLBACK'); return res.status(401).json({ error: 'senha incorreta' }); }
    const challenge = await client.query(
      `SELECT * FROM contract_signing_challenges WHERE contract_id=$1 AND user_id=$2
        AND consumed_at IS NULL ORDER BY created_at DESC LIMIT 1 FOR UPDATE`,
      [c.id, req.auth.userId]
    );
    if (!challenge.rows.length || new Date(challenge.rows[0].expires_at) < new Date()) {
      await client.query('ROLLBACK'); return res.status(410).json({ error: 'codigo expirado; solicite outro' });
    }
    if (challenge.rows[0].attempts >= 5) {
      await client.query('ROLLBACK'); return res.status(429).json({ error: 'limite de tentativas atingido; solicite outro codigo' });
    }
    const expectedCodeHash = sha256(`${c.id}|${req.auth.userId}|${verificationCode}|${process.env.JWT_SECRET}`);
    if (!crypto.timingSafeEqual(Buffer.from(challenge.rows[0].code_hash), Buffer.from(expectedCodeHash))) {
      await client.query(`UPDATE contract_signing_challenges SET attempts=attempts+1,
        consumed_at=CASE WHEN attempts+1>=5 THEN now() ELSE consumed_at END WHERE id=$1`, [challenge.rows[0].id]);
      await client.query('COMMIT'); return res.status(401).json({ error: 'codigo incorreto' });
    }
    if (sha256(c.contract_text) !== c.contract_hash) { await client.query('ROLLBACK'); return res.status(409).json({ error: 'integridade do contrato invalida' }); }
    const signedAt = new Date();
    const ip = req.ip || req.socket.remoteAddress || null;
    const userAgent = String(req.get('user-agent') || 'nao informado').slice(0, 1000);
    const acceptance = 'Li integralmente o contrato, concordo com suas condicoes e assino eletronicamente como responsavel pelo aluno.';
    const cpf = String(req.body.cpf).replace(/\D/g, '');
    const evidenceHash = sha256([c.id, c.contract_hash, req.auth.userId, signerName, cpf, c.email, c.relationship, signedAt.toISOString(), ip, userAgent, acceptance].join('|'));
    const updated = await client.query(
      `UPDATE student_contracts SET status='signed', signed_by_user_id=$1, signer_name=$2,
              signer_email=$3, signer_relationship=$4, signed_at=$5, signer_ip=$6,
              signer_user_agent=$7, acceptance_text=$8, evidence_hash=$9, signer_cpf=$10
        WHERE id=$11 RETURNING *`,
      [req.auth.userId, signerName, c.email, c.relationship, signedAt, ip, userAgent, acceptance, evidenceHash, encryptCpf(cpf), c.id]
    );
    await client.query('UPDATE contract_signing_challenges SET consumed_at=now() WHERE id=$1', [challenge.rows[0].id]);
    await client.query(
      `INSERT INTO audit_log(tenant_id,actor_user_id,action,entity_type,entity_id,detail)
       VALUES($1,$2,'assinar_contrato','student_contract',$3,$4)`,
      [req.auth.tenantId, req.auth.userId, c.id,
        JSON.stringify({ student_id: c.student_id, version: c.version, evidence_hash: evidenceHash })]
    );
    await client.query('COMMIT');
    res.json(updated.rows[0]);
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally { client.release(); }
});

app.post('/api/contracts/:id/revoke', authMiddleware, requireRole('admin'), async (req, res) => {
  const reason = String(req.body.reason || '').trim();
  if (reason.length < 5 || reason.length > 500) return res.status(400).json({ error: 'informe o motivo da revogacao' });
  const updated = await db.query(
    `UPDATE student_contracts SET status='revoked', revoked_at=now(), revoked_by_user_id=$1, revocation_reason=$2
      WHERE id=$3 AND tenant_id=$4 AND status IN ('pending','signed') RETURNING id,student_id,version`,
    [req.auth.userId, reason, req.params.id, req.auth.tenantId]
  );
  if (!updated.rows.length) return res.status(404).json({ error: 'contrato vigente nao encontrado' });
  await logAudit(req, 'revogar_contrato', 'student_contract', req.params.id,
    { student_id: updated.rows[0].student_id, version: updated.rows[0].version, reason });
  res.json({ ok: true });
});

app.post('/api/contracts/:id/cancellation-request', authMiddleware, requireRole('parent'), async (req, res) => {
  const reason = String(req.body.reason || '').trim();
  if (reason.length < 10 || reason.length > 1000) return res.status(400).json({ error: 'descreva o motivo com pelo menos 10 caracteres' });
  const allowed = await db.query(
    `SELECT c.id FROM student_contracts c JOIN student_guardians sg ON sg.student_id=c.student_id
      WHERE c.id=$1 AND c.tenant_id=$2 AND c.status='signed' AND sg.guardian_user_id=$3`,
    [req.params.id, req.auth.tenantId, req.auth.userId]
  );
  if (!allowed.rows.length) return res.status(403).json({ error: 'contrato nao disponivel para cancelamento' });
  try {
    const created = await db.query(
      `INSERT INTO contract_cancellation_requests(tenant_id,contract_id,requested_by,reason)
       VALUES($1,$2,$3,$4) RETURNING id,status,requested_at`,
      [req.auth.tenantId, req.params.id, req.auth.userId, reason]
    );
    const admins = await db.query(`SELECT id FROM users WHERE tenant_id=$1 AND role='admin' AND active=true`, [req.auth.tenantId]);
    push.sendToUsers(admins.rows.map((row) => row.id), 'Solicitacao de cancelamento',
      'Um responsavel solicitou o cancelamento de um contrato.', { type: 'contract_cancellation', contractId: req.params.id }
    ).catch((error) => console.error('[push cancelamento contrato]', error.message));
    res.status(201).json(created.rows[0]);
  } catch (error) {
    if (error.code === '23505') return res.status(409).json({ error: 'ja existe uma solicitacao pendente' });
    throw error;
  }
});

app.get('/api/contracts/cancellation-requests', authMiddleware, requireRole('admin'), async (req, res) => {
  const result = await db.query(
    `SELECT cr.*,s.name AS student_name,u.name AS requester_name
       FROM contract_cancellation_requests cr JOIN student_contracts c ON c.id=cr.contract_id
       JOIN students s ON s.id=c.student_id LEFT JOIN users u ON u.id=cr.requested_by
      WHERE cr.tenant_id=$1 ORDER BY CASE cr.status WHEN 'pending' THEN 0 ELSE 1 END,cr.requested_at DESC`,
    [req.auth.tenantId]
  );
  res.json(result.rows);
});

app.post('/api/contracts/cancellation-requests/:id/resolve', authMiddleware, requireRole('admin'), async (req, res) => {
  const decision = req.body.decision;
  if (!['approved','rejected'].includes(decision)) return res.status(400).json({ error: 'decisao invalida' });
  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const updated = await client.query(
      `UPDATE contract_cancellation_requests SET status=$1,resolved_at=now(),resolved_by=$2,resolution_notes=$3
        WHERE id=$4 AND tenant_id=$5 AND status='pending' RETURNING contract_id,requested_by`,
      [decision, req.auth.userId, String(req.body.notes || '').trim() || null, req.params.id, req.auth.tenantId]
    );
    if (!updated.rows.length) { await client.query('ROLLBACK'); return res.status(404).json({ error: 'solicitacao pendente nao encontrada' }); }
    if (decision === 'approved') await client.query(
      `UPDATE student_contracts SET status='revoked',revoked_at=now(),revoked_by_user_id=$1,
              revocation_reason='Cancelamento solicitado pelo responsavel e aprovado pelo administrador'
        WHERE id=$2 AND status='signed'`, [req.auth.userId, updated.rows[0].contract_id]
    );
    await client.query('COMMIT');
    push.sendToUsers([updated.rows[0].requested_by], 'Solicitacao de cancelamento',
      decision === 'approved' ? 'Seu pedido foi aprovado.' : 'Seu pedido foi analisado e nao foi aprovado.',
      { type: 'contract_cancellation_result', contractId: updated.rows[0].contract_id }
    ).catch((error) => console.error('[push resultado cancelamento]', error.message));
    res.json({ ok: true });
  } catch (error) { await client.query('ROLLBACK'); throw error; } finally { client.release(); }
});

async function loadContractForUser(req, contractId) {
  const result = await db.query(
    `SELECT c.*, s.name AS student_name, t.name AS tenant_name,
            t.legal_name,t.tax_id,t.legal_address,u.email AS account_email,
            sg.relationship AS current_relationship,
            (SELECT string_agg(gu.name, ', ' ORDER BY gu.name)
               FROM student_guardians gsg JOIN users gu ON gu.id=gsg.guardian_user_id
              WHERE gsg.student_id=c.student_id) AS guardian_names
       FROM student_contracts c
       JOIN students s ON s.id=c.student_id
       JOIN tenants t ON t.id=c.tenant_id
       LEFT JOIN users u ON u.id=c.signed_by_user_id
       LEFT JOIN student_guardians sg ON sg.student_id=c.student_id AND sg.guardian_user_id=$1
      WHERE c.id=$2 AND c.tenant_id=$3`, [req.auth.userId, contractId, req.auth.tenantId]
  );
  if (!result.rows.length) return null;
  const row = result.rows[0];
  if (req.auth.role !== 'admin' && !(req.auth.role === 'parent' && row.current_relationship)) return null;
  if (!row.verification_token) {
    row.verification_token = crypto.randomBytes(24).toString('base64url');
    await db.query('UPDATE student_contracts SET verification_token=$1 WHERE id=$2', [row.verification_token, row.id]);
  }
  return row;
}

app.get('/contracts/verify/:token', async (req, res) => {
  const result = await db.query(
    `SELECT c.id,c.version,c.title,c.status,c.contract_text,c.contract_hash,c.evidence_hash,
            c.issued_at,c.signed_at,c.revoked_at
       FROM student_contracts c WHERE c.verification_token=$1`, [req.params.token]
  );
  if (!result.rows.length) return res.status(404).send('Comprovante nao encontrado.');
  const c = result.rows[0];
  const valid = sha256(c.contract_text) === c.contract_hash;
  res.set('Cache-Control', 'no-store');
  res.type('html').send(`<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Verificar contrato</title><style>body{font-family:Inter,system-ui;background:#f3f4f6;margin:0;padding:24px;color:#1f2937}.card{max-width:680px;margin:40px auto;background:white;padding:28px;border-radius:20px;box-shadow:0 12px 40px #0f4c5c18;border-top:5px solid #2bb3c0}.card h1{color:#0f4c5c}.ok{color:#22a06b}.bad{color:#d94c57}code{word-break:break-all;background:#f1f3f5;padding:8px;display:block;border-radius:8px}</style></head><body><main class="card"><h1>TECO</h1><h2 class="${valid ? 'ok' : 'bad'}">${valid ? 'Documento autentico' : 'Falha de integridade'}</h2><p>Status: <strong>${c.status}</strong> - Versao ${c.version}</p><p>Emitido em: ${pdfDate(c.issued_at)}${c.signed_at ? `<br>Assinado em: ${pdfDate(c.signed_at)} (Brasilia)` : ''}</p><p>Hash SHA-256 do documento:</p><code>${c.contract_hash}</code>${c.evidence_hash ? `<p>Hash SHA-256 das evidencias:</p><code>${c.evidence_hash}</code>` : ''}<p>Esta consulta confirma a integridade tecnica do registro sem expor CPF, nome, endereco ou outros dados pessoais.</p></main></body></html>`);
});

app.get('/api/contracts/:id/verify', authMiddleware, async (req, res) => {
  const contract = await loadContractForUser(req, req.params.id);
  if (!contract) return res.status(403).json({ error: 'sem permissao' });
  const contractValid = sha256(contract.contract_text) === contract.contract_hash;
  let evidenceValid = null;
  if (contract.status === 'signed') {
    const evidence = [contract.id, contract.contract_hash, contract.signed_by_user_id,
      contract.signer_name, decryptCpf(contract.signer_cpf), contract.signer_email,
      contract.signer_relationship, new Date(contract.signed_at).toISOString(),
      contract.signer_ip, contract.signer_user_agent, contract.acceptance_text].join('|');
    evidenceValid = sha256(evidence) === contract.evidence_hash;
  }
  res.json({ contractValid, evidenceValid, status: contract.status,
    contractHash: contract.contract_hash, evidenceHash: contract.evidence_hash });
});

function pdfDate(value) {
  if (!value) return 'Nao informado';
  return new Intl.DateTimeFormat('pt-BR', { timeZone: 'America/Sao_Paulo',
    dateStyle: 'short', timeStyle: 'medium' }).format(new Date(value));
}

app.get('/api/contracts/:id/pdf', authMiddleware, async (req, res) => {
  const contract = await loadContractForUser(req, req.params.id);
  if (!contract) return res.status(403).json({ error: 'sem permissao' });
  if (sha256(contract.contract_text) !== contract.contract_hash) return res.status(409).json({ error: 'integridade do contrato invalida' });
  const publicBase = process.env.PUBLIC_BASE_URL || `${req.protocol}://${req.get('host')}`;
  const verificationUrl = `${publicBase}/contracts/verify/${contract.verification_token}`;
  const qrBuffer = await QRCode.toBuffer(verificationUrl, { type: 'png', width: 220, margin: 1,
    color: { dark: '#0F4C5C', light: '#FFFFFF' } });
  const filename = `contrato-${contract.student_name.replace(/[^a-zA-Z0-9]+/g, '-').toLowerCase()}-v${contract.version}.pdf`;
  res.set('Content-Type', 'application/pdf');
  res.set('Content-Disposition', `${req.query.download === '1' ? 'attachment' : 'inline'}; filename="${filename}"`);
  res.set('Cache-Control', 'private, no-store');
  const doc = new PDFDocument({ size: 'A4', margins: { top: 52, bottom: 52, left: 58, right: 58 }, bufferPages: true,
    info: { Title: contract.title, Author: contract.legal_name || contract.tenant_name, Subject: `Contrato individual de ${contract.student_name}` } });
  doc.pipe(res);
  doc.fillColor('#0F4C5C').font('Helvetica-Bold').fontSize(18).text('TECO', { align: 'center' });
  doc.moveDown(.3).fillColor('#202124').fontSize(15).text(contract.title, { align: 'center' });
  doc.moveDown(.4).font('Helvetica').fontSize(9).fillColor('#666666')
    .text(`Aluno: ${contract.student_name}   |   Versao: ${contract.version}   |   Emitido em: ${pdfDate(contract.issued_at)}`, { align: 'center' });
  doc.moveDown(1).font('Helvetica-Bold').fontSize(10.5).fillColor('#202124').text('Identificacao das partes');
  doc.font('Helvetica').fontSize(10)
    .text(`Aluno: ${contract.student_name}`)
    .text(`Responsavel: ${contract.signer_name || contract.guardian_names || 'nao informado'}`)
    .text(`CPF do responsavel: ${contract.signer_cpf ? formatCpf(decryptCpf(contract.signer_cpf)) : 'sera registrado no ato da assinatura'}`);
  doc.moveDown(1.5).fillColor('#202124').fontSize(10.5).text(contract.contract_text, { align: 'justify', lineGap: 3 });
  doc.moveDown(1.5).font('Helvetica-Bold').fontSize(12).fillColor('#0F4C5C').text('Comprovante da assinatura eletronica');
  doc.moveDown(.5).font('Helvetica').fontSize(9.5).fillColor('#202124');
  if (contract.status === 'signed') {
    doc.text(`Assinante: ${contract.signer_name}`);
    doc.text(`CPF: ${formatCpf(decryptCpf(contract.signer_cpf))}   |   E-mail: ${contract.signer_email}`);
    doc.text(`Vinculo: ${contract.signer_relationship}   |   Data/hora: ${pdfDate(contract.signed_at)} (Brasilia)`);
    doc.text(`IP registrado: ${contract.signer_ip || 'nao informado'}`);
    doc.text(`Dispositivo: ${contract.signer_user_agent || 'nao informado'}`);
    doc.moveDown(.6).text(contract.acceptance_text || 'Aceite eletronico registrado.');
  } else {
    doc.text(contract.status === 'revoked' ? `REVOGADO: ${contract.revocation_reason || ''}` : 'AGUARDANDO ASSINATURA');
  }
  doc.moveDown(1).font('Courier').fontSize(7.5).fillColor('#444444')
    .text(`HASH DO DOCUMENTO (SHA-256)\n${contract.contract_hash}\n\nHASH DAS EVIDENCIAS (SHA-256)\n${contract.evidence_hash || 'Ainda nao gerado'}`);
  if (doc.y > 650) doc.addPage();
  doc.moveDown(1).font('Helvetica-Bold').fontSize(10).fillColor('#0F4C5C').text('Verifique a autenticidade');
  const qrY = doc.y + 6;
  doc.image(qrBuffer, 58, qrY, { width: 86 });
  doc.font('Helvetica').fontSize(8).fillColor('#444444')
    .text('Escaneie o QR Code para conferir os hashes diretamente no TECO. A pagina publica nao exibe dados pessoais.', 154, qrY + 18, { width: 380 });
  doc.font('Courier').fontSize(6.5).text(verificationUrl, 154, qrY + 54, { width: 380 });
  doc.y = qrY + 94;
  const pages = doc.bufferedPageRange();
  for (let i = 0; i < pages.count; i++) {
    doc.switchToPage(i);
    doc.font('Helvetica').fontSize(8).fillColor('#777777')
      .text(`Contrato ${contract.id} - Pagina ${i + 1} de ${pages.count}`, 58, 778, { align: 'center', width: 479, lineBreak: false });
  }
  doc.end();
  await db.query(
    `UPDATE student_contracts SET first_downloaded_at=COALESCE(first_downloaded_at,now()),
            download_count=download_count+1 WHERE id=$1`, [contract.id]
  );
});

/* =========================================================================
 * ESCOLAS
 * ========================================================================= */

app.get('/api/schools', authMiddleware, requireRole('admin'), async (req, res) => {
  const r = await db.query('SELECT * FROM schools WHERE tenant_id=$1 ORDER BY name', [req.auth.tenantId]);
  res.json(r.rows);
});

app.post('/api/schools', authMiddleware, requireRole('admin'), validateBody(schoolBody), async (req, res) => {
  const limitError = await planLimitError(req.auth.tenantId, 'schools');
  if (limitError) return res.status(409).json({ error: limitError });
  const { name, address, phone, postal_code, street, number, complement,
    neighborhood, city, state, lat, lng } = req.body;
  if (!name) return res.status(400).json({ error: 'nome obrigatorio' });
  try {
    const r = await db.query(
      `INSERT INTO schools(tenant_id, name, address, phone, postal_code, street,
        number, complement, neighborhood, city, state, lat, lng)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING *`,
      [req.auth.tenantId, name, address || null, phone || null, postal_code || null,
        street || null, number || null, complement || null, neighborhood || null,
        city || null, state || null, lat ?? null, lng ?? null]
    );
    res.json(r.rows[0]);
  } catch (e) {
    if (e.code === '23505') return res.status(409).json({ error: 'ja existe uma escola com este nome' });
    console.error('[criar escola]', e);
    res.status(500).json({ error: 'falha ao criar escola' });
  }
});

app.put('/api/schools/:id', authMiddleware, requireRole('admin'), validateBody(schoolBody), async (req, res) => {
  const { name, address, phone, postal_code, street, number, complement,
    neighborhood, city, state, lat, lng } = req.body;
  try {
    const r = await db.query(
      `UPDATE schools SET name=$1, address=$2, phone=$3, postal_code=$4, street=$5,
        number=$6, complement=$7, neighborhood=$8, city=$9, state=$10, lat=$11, lng=$12
       WHERE id=$13 AND tenant_id=$14 RETURNING *`,
      [name, address || null, phone || null, postal_code || null, street || null,
        number || null, complement || null, neighborhood || null, city || null,
        state || null, lat ?? null, lng ?? null, req.params.id, req.auth.tenantId]
    );
    if (r.rows.length === 0) return res.status(404).json({ error: 'escola nao encontrada' });
    res.json(r.rows[0]);
  } catch (e) {
    if (e.code === '23505') return res.status(409).json({ error: 'ja existe uma escola com este nome' });
    console.error('[atualizar escola]', e);
    res.status(500).json({ error: 'falha ao atualizar escola' });
  }
});

app.delete('/api/schools/:id', authMiddleware, requireRole('admin'), async (req, res) => {
  const r = await db.query(
    'DELETE FROM schools WHERE id=$1 AND tenant_id=$2 RETURNING id',
    [req.params.id, req.auth.tenantId]
  );
  if (r.rows.length === 0) return res.status(404).json({ error: 'escola nao encontrada' });
  res.json({ ok: true });
});

// Leitura liberada pra driver tambem (precisa listar veiculos pra poder
// trocar a van do dia ao iniciar uma viagem) -- so cadastrar/editar continua
// admin-only, abaixo.
app.get('/api/vehicles', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const r = await db.query('SELECT * FROM vehicles WHERE tenant_id=$1 ORDER BY plate', [req.auth.tenantId]);
  res.json(r.rows);
});

app.post('/api/vehicles', authMiddleware, requireRole('admin'), validateBody(vehicleBody), async (req, res) => {
  const limitError = await planLimitError(req.auth.tenantId, 'vehicles');
  if (limitError) return res.status(409).json({ error: limitError });
  const { plate, model, capacity, year, color, document_expiry, status } = req.body;
  const r = await db.query(
    `INSERT INTO vehicles(tenant_id, plate, model, capacity, year, color, document_expiry, status)
     VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`,
    [req.auth.tenantId, plate, model || null, capacity ?? null, year ?? null, color || null, document_expiry || null, status || 'available']
  );
  res.json(r.rows[0]);
});

app.put('/api/vehicles/:id', authMiddleware, requireRole('admin'), validateBody(vehicleBody), async (req, res) => {
  const { plate, model, capacity, year, color, document_expiry, status } = req.body;
  const r = await db.query(
    `UPDATE vehicles SET plate=$1, model=$2, capacity=$3, year=$4, color=$5, document_expiry=$6, status=$7
      WHERE id=$8 AND tenant_id=$9 RETURNING *`,
    [plate, model || null, capacity ?? null, year ?? null, color || null, document_expiry || null, status || 'available', req.params.id, req.auth.tenantId]
  );
  if (r.rows.length === 0) return res.status(404).json({ error: 'veiculo nao encontrado' });
  res.json(r.rows[0]);
});

app.delete('/api/vehicles/:id', authMiddleware, requireRole('admin'), async (req, res) => {
  const r = await db.query('DELETE FROM vehicles WHERE id=$1 AND tenant_id=$2 RETURNING id, plate', [req.params.id, req.auth.tenantId]);
  if (r.rows.length === 0) return res.status(404).json({ error: 'veiculo nao encontrado' });
  await logAudit(req, 'excluir_veiculo', 'vehicle', req.params.id, { plate: r.rows[0].plate });
  res.json({ ok: true });
});

// Gera um codigo de convite (valido por 7 dias) para o responsavel de um
// aluno se auto-cadastrar via POST /api/auth/register-parent. O app do
// motorista mostra esse codigo grande + QR na tela "Convidar responsavel".
app.post('/api/students/:id/invite', authMiddleware, requireRole('admin'), async (req, res) => {
  const relationship = String(req.body.relationship || 'Responsavel legal').trim();
  const allowedRelationships = ['Mae', 'Pai', 'Avo', 'Tio ou tia', 'Responsavel legal', 'Outro'];
  if (!allowedRelationships.includes(relationship)) {
    return res.status(400).json({ error: 'parentesco invalido' });
  }
  const st = await db.query(
    'SELECT id FROM students WHERE id=$1 AND tenant_id=$2',
    [req.params.id, req.auth.tenantId]
  );
  if (st.rows.length === 0) return res.status(404).json({ error: 'aluno nao encontrado' });

  const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = generateInviteCode();
    try {
      const r = await db.query(
        `INSERT INTO guardian_invites(tenant_id, student_id, code, relationship, expires_at)
         VALUES($1,$2,$3,$4,$5) RETURNING id, code, relationship, expires_at, created_at`,
        [req.auth.tenantId, req.params.id, code, relationship, expiresAt]
      );
      return res.json(r.rows[0]);
    } catch (e) {
      if (e.code === '23505') continue; // colisao de codigo (raro) - tenta de novo
      console.error('[gerar convite]', e);
      return res.status(500).json({ error: 'falha ao gerar convite' });
    }
  }
  res.status(500).json({ error: 'nao foi possivel gerar um codigo unico, tente novamente' });
});

app.get('/api/students/:id/invites', authMiddleware, requireRole('admin'), async (req, res) => {
  const student = await db.query('SELECT 1 FROM students WHERE id=$1 AND tenant_id=$2',
    [req.params.id, req.auth.tenantId]);
  if (student.rows.length === 0) return res.status(404).json({ error: 'aluno nao encontrado' });
  const result = await db.query(
    `SELECT id, code, relationship, expires_at, used_by_user_id, cancelled_at, created_at,
            CASE WHEN used_by_user_id IS NOT NULL THEN 'used'
                 WHEN cancelled_at IS NOT NULL THEN 'cancelled'
                 WHEN expires_at < now() THEN 'expired'
                 ELSE 'pending' END AS status
       FROM guardian_invites WHERE student_id=$1 AND tenant_id=$2
      ORDER BY created_at DESC LIMIT 20`,
    [req.params.id, req.auth.tenantId]);
  res.json(result.rows);
});

app.delete('/api/students/:studentId/invites/:inviteId', authMiddleware, requireRole('admin'), async (req, res) => {
  const result = await db.query(
    `UPDATE guardian_invites SET cancelled_at=now()
      WHERE id=$1 AND student_id=$2 AND tenant_id=$3
        AND used_by_user_id IS NULL AND cancelled_at IS NULL AND expires_at >= now()
      RETURNING id`,
    [req.params.inviteId, req.params.studentId, req.auth.tenantId]);
  if (result.rows.length === 0) return res.status(404).json({ error: 'convite pendente nao encontrado' });
  res.json({ ok: true });
});

app.post('/api/routes', authMiddleware, requireRole('admin'), validateBody(routeBody), async (req, res) => {
  const { name, vehicle_id, driver_user_id, days_of_week, planned_time,
    planned_time_to_school, planned_time_to_home, active } = req.body;

  if (vehicle_id) {
    const v = await db.query(
      'SELECT id FROM vehicles WHERE id=$1 AND tenant_id=$2',
      [vehicle_id, req.auth.tenantId]
    );
    if (v.rows.length === 0) return res.status(404).json({ error: 'veiculo nao encontrado' });
  }
  if (driver_user_id) {
    const d = await db.query(
      `SELECT id FROM users WHERE id=$1 AND tenant_id=$2 AND role='driver'`,
      [driver_user_id, req.auth.tenantId]
    );
    if (d.rows.length === 0) return res.status(404).json({ error: 'motorista nao encontrado' });
  }

  const r = await db.query(
    `INSERT INTO routes(tenant_id, name, vehicle_id, driver_user_id, days_of_week,
                        planned_time, planned_time_to_school, planned_time_to_home, active)
     VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *`,
    [req.auth.tenantId, name, vehicle_id || null, driver_user_id || null,
      days_of_week || null, planned_time || null, planned_time_to_school || null,
      planned_time_to_home || null, active ?? true]
  );
  await logAudit(req, 'criar_rota', 'route', r.rows[0].id, {
    name, vehicle_id: vehicle_id || null, driver_user_id: driver_user_id || null,
    days_of_week: days_of_week || null,
  });
  res.json(r.rows[0]);
});

app.get('/api/routes', authMiddleware, async (req, res) => {
  if (req.auth.role === 'parent') {
    const own = await db.query(
      `SELECT DISTINCT r.* FROM routes r
         JOIN route_students rs ON rs.route_id=r.id
         JOIN student_guardians sg ON sg.student_id=rs.student_id
        WHERE r.tenant_id=$1 AND sg.guardian_user_id=$2
        ORDER BY r.name`,
      [req.auth.tenantId, req.auth.userId]
    );
    return res.json(own.rows);
  }
  const r = await db.query(
    `SELECT * FROM routes WHERE tenant_id=$1
      AND ($2='admin' OR driver_user_id=$3) ORDER BY name`,
    [req.auth.tenantId, req.auth.role, req.auth.userId]
  );
  res.json(r.rows);
});

app.put('/api/routes/:id', authMiddleware, requireRole('admin'), validateBody(routeBody), async (req, res) => {
  const { name, vehicle_id, driver_user_id, days_of_week, planned_time,
    planned_time_to_school, planned_time_to_home, active } = req.body;
  if (vehicle_id) {
    const v = await db.query('SELECT id FROM vehicles WHERE id=$1 AND tenant_id=$2', [vehicle_id, req.auth.tenantId]);
    if (v.rows.length === 0) return res.status(404).json({ error: 'veiculo nao encontrado' });
  }
  if (driver_user_id) {
    const d = await db.query(
      `SELECT id FROM users WHERE id=$1 AND tenant_id=$2 AND role='driver'`,
      [driver_user_id, req.auth.tenantId]
    );
    if (d.rows.length === 0) return res.status(404).json({ error: 'motorista nao encontrado' });
  }
  const r = await db.query(
    `UPDATE routes SET name=$1, vehicle_id=$2, driver_user_id=$3,
            days_of_week=$4, planned_time=$5, planned_time_to_school=$6,
            planned_time_to_home=$7, active=$8
      WHERE id=$9 AND tenant_id=$10 RETURNING *`,
    [name, vehicle_id || null, driver_user_id || null, days_of_week || null,
      planned_time || null, planned_time_to_school || null,
      planned_time_to_home || null, active ?? true, req.params.id,
      req.auth.tenantId]
  );
  if (r.rows.length === 0) return res.status(404).json({ error: 'rota nao encontrada' });
  await logAudit(req, 'editar_rota', 'route', req.params.id, {
    name, vehicle_id: vehicle_id || null, driver_user_id: driver_user_id || null,
    days_of_week: days_of_week || null,
  });
  res.json(r.rows[0]);
});

app.delete('/api/routes/:id', authMiddleware, requireRole('admin'), async (req, res) => {
  const r = await db.query(
    'DELETE FROM routes WHERE id=$1 AND tenant_id=$2 RETURNING id, name',
    [req.params.id, req.auth.tenantId]
  );
  if (r.rows.length === 0) return res.status(404).json({ error: 'rota nao encontrada' });
  await logAudit(req, 'excluir_rota', 'route', req.params.id, { name: r.rows[0].name });
  res.json({ ok: true });
});

app.delete('/api/routes/:id/students/:studentId', authMiddleware, requireRole('admin'), async (req, res) => {
  await db.query(
    'DELETE FROM route_students WHERE route_id=$1 AND student_id=$2 AND tenant_id=$3',
    [req.params.id, req.params.studentId, req.auth.tenantId]
  );
  res.json({ ok: true });
});

// Vincula um responsavel (user parent) a um aluno.
app.post('/api/students/:id/guardians', authMiddleware, requireRole('admin'), async (req, res) => {
  const { guardian_user_id } = req.body;
  const relationship = String(req.body.relationship || 'Responsavel legal').trim();
  const allowedRelationships = ['Mae', 'Pai', 'Avo', 'Tio ou tia', 'Responsavel legal', 'Outro'];
  if (!allowedRelationships.includes(relationship)) {
    return res.status(400).json({ error: 'parentesco invalido' });
  }
  const st = await db.query(
    'SELECT id FROM students WHERE id=$1 AND tenant_id=$2',
    [req.params.id, req.auth.tenantId]
  );
  if (st.rows.length === 0) return res.status(404).json({ error: 'aluno nao encontrado' });
  const g = await db.query(
    `SELECT id FROM users WHERE id=$1 AND tenant_id=$2 AND role='parent'`,
    [guardian_user_id, req.auth.tenantId]
  );
  if (g.rows.length === 0) return res.status(404).json({ error: 'responsavel nao encontrado' });
  await db.query(
    `INSERT INTO student_guardians(tenant_id, student_id, guardian_user_id, relationship)
     VALUES($1,$2,$3,$4) ON CONFLICT (student_id, guardian_user_id)
     DO UPDATE SET relationship=EXCLUDED.relationship`,
    [req.auth.tenantId, req.params.id, guardian_user_id, relationship]
  );
  res.json({ ok: true });
});

// Vincula um aluno a uma rota (confirma que rota e aluno sao do mesmo tenant).
app.post('/api/routes/:id/students', authMiddleware, requireRole('admin'), async (req, res) => {
  const { student_id } = req.body;
  const serviceDirection = ['all', 'to_school', 'to_home'].includes(req.body.service_direction)
    ? req.body.service_direction : 'all';
  const rt = await db.query(
    'SELECT id FROM routes WHERE id=$1 AND tenant_id=$2',
    [req.params.id, req.auth.tenantId]
  );
  if (rt.rows.length === 0) return res.status(404).json({ error: 'rota nao encontrada' });
  const st = await db.query(
    'SELECT id FROM students WHERE id=$1 AND tenant_id=$2',
    [student_id, req.auth.tenantId]
  );
  if (st.rows.length === 0) return res.status(404).json({ error: 'aluno nao encontrado' });
  const conflicts = await db.query(
    `SELECT r.id, r.name, r.days_of_week, rs.service_direction
       FROM route_students rs JOIN routes r ON r.id=rs.route_id
      WHERE rs.student_id=$1 AND rs.tenant_id=$2 AND r.id<>$3`,
    [student_id, req.auth.tenantId, req.params.id]
  );
  const targetRoute = await db.query('SELECT days_of_week FROM routes WHERE id=$1', [req.params.id]);
  const daySet = (value) => value ? new Set(String(value).split(',')) : new Set(['1','2','3','4','5','6','7']);
  const targetDays = daySet(targetRoute.rows[0]?.days_of_week);
  const directionOverlaps = (a, b) => a === 'all' || b === 'all' || a === b;
  const conflict = conflicts.rows.find((row) => directionOverlaps(row.service_direction, serviceDirection) &&
    [...daySet(row.days_of_week)].some((day) => targetDays.has(day)));
  if (conflict) {
    return res.status(409).json({ error: `aluno ja atende esse sentido nos mesmos dias em ${conflict.name}` });
  }
  // Novo vinculo vai pro fim da fila de embarque.
  const pos = await db.query('SELECT COALESCE(max(position)+1, 0) AS next FROM route_students WHERE route_id=$1', [
    req.params.id,
  ]);
  await db.query(
    `INSERT INTO route_students(tenant_id, route_id, student_id, position, service_direction)
     VALUES($1,$2,$3,$4,$5) ON CONFLICT (route_id, student_id)
     DO UPDATE SET service_direction=EXCLUDED.service_direction`,
    [req.auth.tenantId, req.params.id, student_id, pos.rows[0].next, serviceDirection]
  );
  res.json({ ok: true });
});

// Reordena a fila de embarque de uma rota (quem pega primeiro). Recebe a
// lista completa de student ids na nova ordem.
app.put('/api/routes/:id/students/reorder', authMiddleware, requireRole('admin'), async (req, res) => {
  const { studentIds } = req.body;
  if (!Array.isArray(studentIds)) return res.status(400).json({ error: 'studentIds precisa ser uma lista' });
  const rt = await db.query('SELECT id FROM routes WHERE id=$1 AND tenant_id=$2', [req.params.id, req.auth.tenantId]);
  if (rt.rows.length === 0) return res.status(404).json({ error: 'rota nao encontrada' });
  for (let i = 0; i < studentIds.length; i++) {
    await db.query(
      'UPDATE route_students SET position=$1 WHERE route_id=$2 AND student_id=$3 AND tenant_id=$4',
      [i, req.params.id, studentIds[i], req.auth.tenantId]
    );
  }
  res.json({ ok: true });
});

// Alunos ja vinculados a uma rota (fora do contexto de uma viagem especifica
// -- usado na tela de gestao de rotas para saber quem ja esta cadastrado).
app.get('/api/routes/:id/students', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const direction = ['to_school', 'to_home'].includes(req.query.direction)
    ? req.query.direction : null;
  const rt = await db.query('SELECT id, driver_user_id FROM routes WHERE id=$1 AND tenant_id=$2', [req.params.id, req.auth.tenantId]);
  if (rt.rows.length === 0) return res.status(404).json({ error: 'rota nao encontrada' });
  if (req.auth.role === 'driver' && rt.rows[0].driver_user_id &&
      rt.rows[0].driver_user_id !== req.auth.userId) {
    return res.status(403).json({ error: 'rota atribuida a outro motorista' });
  }
  const r = await db.query(
    `SELECT s.id, s.name, COALESCE(sc.name, s.school_name) AS school_name,
            rs.position, rs.service_direction
       FROM route_students rs
       JOIN students s ON s.id = rs.student_id
       LEFT JOIN schools sc ON sc.id = s.school_id
      WHERE rs.route_id = $1 AND rs.tenant_id = $2
        AND ($3::text IS NULL OR rs.service_direction IN ('all', $3))
      ORDER BY rs.position, s.name`,
    [req.params.id, req.auth.tenantId, direction]
  );
  res.json(r.rows);
});

/* =========================================================================
 * FINANCEIRO — controle manual de mensalidade (sem gateway de pagamento)
 * ========================================================================= */

// Normaliza "YYYY-MM" (ou vazio) pro dia 1 daquele mes; usa o mes atual se
// nao vier nada.
app.get('/api/payment-provider', authMiddleware, requireRole('admin'), async (req, res) => {
  const r = await db.query(
    `SELECT provider, pix_key, merchant_name, active, updated_at,
            (api_token_enc IS NOT NULL) AS token_configured
       FROM payment_provider_configs WHERE tenant_id=$1`, [req.auth.tenantId]);
  res.json(r.rows[0] || { provider: 'manual_pix', active: false, token_configured: false });
});

app.put('/api/payment-provider', authMiddleware, requireRole('admin'), async (req, res) => {
  const provider = String(req.body?.provider || '');
  const pixKey = String(req.body?.pix_key || '').trim().slice(0, 200) || null;
  const merchantName = String(req.body?.merchant_name || '').trim().slice(0, 200) || null;
  const apiToken = String(req.body?.api_token || '').trim();
  if (!['manual_pix', 'mercado_pago'].includes(provider)) return res.status(400).json({ error: 'provedor nao suportado' });
  if (provider === 'manual_pix' && !pixKey) return res.status(400).json({ error: 'informe a chave PIX' });
  const current = await db.query('SELECT api_token_enc FROM payment_provider_configs WHERE tenant_id=$1', [req.auth.tenantId]);
  const encryptedToken = apiToken ? encryptPaymentSecret(apiToken) : current.rows[0]?.api_token_enc || null;
  if (provider === 'mercado_pago' && !encryptedToken) return res.status(400).json({ error: 'informe o Access Token do Mercado Pago' });
  await db.query(
    `INSERT INTO payment_provider_configs(tenant_id, provider, api_token_enc, pix_key, merchant_name, active, updated_by)
     VALUES($1,$2,$3,$4,$5,true,$6)
     ON CONFLICT (tenant_id) DO UPDATE SET provider=$2, api_token_enc=$3,
       pix_key=$4, merchant_name=$5, active=true, updated_by=$6, updated_at=now()`,
    [req.auth.tenantId, provider, encryptedToken, pixKey, merchantName, req.auth.userId]);
  await logAudit(req, 'configurar', 'payment_provider', req.auth.tenantId, { provider, tokenChanged: Boolean(apiToken) });
  res.json({ ok: true, provider, token_configured: Boolean(encryptedToken) });
});

app.delete('/api/payment-provider', authMiddleware, requireRole('admin'), async (req, res) => {
  await db.query('UPDATE payment_provider_configs SET active=false, updated_at=now() WHERE tenant_id=$1', [req.auth.tenantId]);
  await logAudit(req, 'desativar', 'payment_provider', req.auth.tenantId, null);
  res.json({ ok: true });
});

app.post('/api/payments/:id/checkout', authMiddleware, requireRole('admin'), async (req, res) => {
  const payment = await db.query(
    `SELECT p.*, s.name AS student_name,
            (SELECT u.email FROM student_guardians sg JOIN users u ON u.id=sg.guardian_user_id
              WHERE sg.student_id=s.id LIMIT 1) AS payer_email
       FROM payments p JOIN students s ON s.id=p.student_id
      WHERE p.id=$1 AND p.tenant_id=$2`, [req.params.id, req.auth.tenantId]);
  if (payment.rows.length === 0) return res.status(404).json({ error: 'cobranca nao encontrada' });
  if (payment.rows[0].status === 'paid') return res.status(409).json({ error: 'cobranca ja esta paga' });
  const config = await db.query('SELECT * FROM payment_provider_configs WHERE tenant_id=$1 AND active=true', [req.auth.tenantId]);
  if (config.rows.length === 0) return res.status(409).json({ error: 'configure um provedor de pagamento' });
  const cfg = config.rows[0];
  if (cfg.provider === 'manual_pix') {
    await db.query(`UPDATE payments SET provider='manual_pix', provider_status='awaiting_manual_confirmation' WHERE id=$1`, [req.params.id]);
    return res.json({ provider: 'manual_pix', pix_key: cfg.pix_key, merchant_name: cfg.merchant_name });
  }
  const accessToken = decryptPaymentSecret(cfg.api_token_enc);
  const baseUrl = process.env.PUBLIC_BASE_URL || `${req.protocol}://${req.get('host')}`;
  const mpResponse = await fetch('https://api.mercadopago.com/checkout/preferences', {
    method: 'POST', headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      items: [{ id: payment.rows[0].id, title: `Transporte escolar - ${payment.rows[0].student_name}`, quantity: 1, currency_id: 'BRL', unit_price: Number(payment.rows[0].amount) }],
      payer: payment.rows[0].payer_email ? { email: payment.rows[0].payer_email } : undefined,
      external_reference: payment.rows[0].id,
      notification_url: `${baseUrl}/api/webhooks/mercado-pago/${req.auth.tenantId}`,
    }),
  });
  const mp = await mpResponse.json();
  if (!mpResponse.ok || !mp.id || !mp.init_point) {
    console.error('[payment] Mercado Pago rejeitou preferencia', mpResponse.status, mp.message || mp.error);
    return res.status(502).json({ error: 'Mercado Pago rejeitou a cobranca; confira a credencial' });
  }
  await db.query(`UPDATE payments SET provider='mercado_pago', external_id=$1, checkout_url=$2, provider_status='pending' WHERE id=$3`, [mp.id, mp.init_point, req.params.id]);
  res.json({ provider: 'mercado_pago', checkout_url: mp.init_point, external_id: mp.id });
});

app.post('/api/webhooks/mercado-pago/:tenantId', async (req, res) => {
  res.json({ received: true });
  const paymentId = req.body?.data?.id || req.query['data.id'];
  if (!paymentId || !/^[0-9]+$/.test(String(paymentId))) return;
  try {
    const config = await db.query(`SELECT api_token_enc FROM payment_provider_configs WHERE tenant_id=$1 AND provider='mercado_pago' AND active=true`, [req.params.tenantId]);
    if (!config.rows[0]?.api_token_enc) return;
    const token = decryptPaymentSecret(config.rows[0].api_token_enc);
    const verified = await fetch(`https://api.mercadopago.com/v1/payments/${paymentId}`, { headers: { Authorization: `Bearer ${token}` } });
    if (!verified.ok) return;
    const mp = await verified.json();
    if (!mp.external_reference) return;
    await db.query(
      `UPDATE payments SET provider_status=$1,
         status=CASE WHEN $1='approved' THEN 'paid' ELSE status END,
         paid_at=CASE WHEN $1='approved' THEN COALESCE(paid_at, now()) ELSE paid_at END,
         payment_method=CASE WHEN $1='approved' THEN 'Mercado Pago' ELSE payment_method END
       WHERE id=$2 AND tenant_id=$3 AND provider='mercado_pago'`,
      [mp.status, mp.external_reference, req.params.tenantId]);
  } catch (error) {
    console.error('[payment] falha ao processar webhook Mercado Pago', error.message);
  }
});

function parseReferenceMonth(month) {
  if (month && /^\d{4}-\d{2}$/.test(month)) return `${month}-01`;
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-01`;
}

// Cria uma cobranca 'pending' por aluno com monthly_fee definido, pro mes
// pedido. Idempotente (ON CONFLICT DO NOTHING) -- pode clicar de novo sem
// duplicar. Retorna quantos criou e quais alunos foram pulados sem mensalidade.
app.post('/api/payments/generate', authMiddleware, requireRole('admin'), async (req, res) => {
  const refMonth = parseReferenceMonth(req.body.month);
  const students = await db.query(
    'SELECT id, name, monthly_fee FROM students WHERE tenant_id=$1',
    [req.auth.tenantId]
  );
  const withFee = students.rows.filter((s) => s.monthly_fee != null);
  const skipped = students.rows.filter((s) => s.monthly_fee == null).map((s) => s.name);

  let created = 0;
  for (const s of withFee) {
    const r = await db.query(
      `INSERT INTO payments(tenant_id, student_id, reference_month, amount)
       VALUES($1,$2,$3,$4) ON CONFLICT (student_id, reference_month) DO NOTHING RETURNING id`,
      [req.auth.tenantId, s.id, refMonth, s.monthly_fee]
    );
    if (r.rows.length > 0) created++;
  }
  res.json({ created, skipped });
});

app.get('/api/payments', authMiddleware, requireRole('admin'), async (req, res) => {
  const refMonth = parseReferenceMonth(req.query.month);
  const r = await db.query(
    `SELECT p.*, s.name AS student_name
       FROM payments p
       JOIN students s ON s.id = p.student_id
      WHERE p.tenant_id=$1 AND p.reference_month=$2
      ORDER BY s.name`,
    [req.auth.tenantId, refMonth]
  );
  res.json(r.rows);
});

app.put('/api/payments/:id', authMiddleware, requireRole('admin'), validateBody(paymentUpdateBody), async (req, res) => {
  const { status, amount, notes, payment_method, paid_at } = req.body;
  const current = await db.query('SELECT * FROM payments WHERE id=$1 AND tenant_id=$2', [
    req.params.id, req.auth.tenantId,
  ]);
  if (current.rows.length === 0) return res.status(404).json({ error: 'cobranca nao encontrada' });

  const next = {
    status: status || current.rows[0].status,
    amount: amount ?? current.rows[0].amount,
    notes: notes ?? current.rows[0].notes,
    paymentMethod: payment_method ?? current.rows[0].payment_method,
  };
  // Estornar (volta pra pending) limpa forma de pagamento e data efetiva.
  // Marcar como pago usa a data efetiva informada, ou agora se nao vier.
  const paidAt = next.status === 'paid' ? (paid_at ? new Date(paid_at) : new Date()) : null;
  if (next.status !== 'paid') next.paymentMethod = null;
  const r = await db.query(
    `UPDATE payments SET status=$1, amount=$2, notes=$3, paid_at=$4, payment_method=$5
      WHERE id=$6 AND tenant_id=$7 RETURNING *`,
    [next.status, next.amount, next.notes, paidAt, next.paymentMethod, req.params.id, req.auth.tenantId]
  );
  if (status && status !== current.rows[0].status) {
    await logAudit(req, status === 'paid' ? 'marcar_pagamento_pago' : 'estornar_pagamento', 'payment', req.params.id, {
      amount: next.amount, payment_method: next.paymentMethod,
    });
  }
  res.json(r.rows[0]);
});

app.get('/api/payments/summary', authMiddleware, requireRole('admin'), async (req, res) => {
  const refMonth = parseReferenceMonth(req.query.month);
  const r = await db.query(
    `SELECT count(*) FILTER (WHERE status='paid') AS paid,
            count(*) FILTER (WHERE status='pending') AS pending,
            count(*) AS total,
            coalesce(sum(amount) FILTER (WHERE status='paid'), 0) AS paid_amount,
            coalesce(sum(amount), 0) AS total_amount
       FROM payments WHERE tenant_id=$1 AND reference_month=$2`,
    [req.auth.tenantId, refMonth]
  );
  res.json(r.rows[0]);
});

// Status de pagamento dos proprios filhos (so leitura -- e ledger manual, o
// pai nao paga por aqui).
app.get('/api/payments/mine', authMiddleware, requireRole('parent'), async (req, res) => {
  const refMonth = parseReferenceMonth(req.query.month);
  const r = await db.query(
    `SELECT p.student_id, p.status, p.amount, p.provider, p.checkout_url,
            p.provider_status, cfg.pix_key, cfg.merchant_name
       FROM payments p
       JOIN student_guardians sg ON sg.student_id = p.student_id
       LEFT JOIN payment_provider_configs cfg ON cfg.tenant_id=p.tenant_id AND cfg.active=true
      WHERE sg.guardian_user_id=$1 AND sg.tenant_id=$2 AND p.reference_month=$3`,
    [req.auth.userId, req.auth.tenantId, refMonth]
  );
  res.json(r.rows);
});

/* =========================================================================
 * DASHBOARD — resumo pra home do app do motorista
 * ========================================================================= */

app.get('/api/dashboard/summary', authMiddleware, requireRole('admin'), async (req, res) => {
  const refMonth = parseReferenceMonth();
  const [students, vehicles, routes, activeTrips, payments] = await Promise.all([
    db.query('SELECT count(*) FROM students WHERE tenant_id=$1', [req.auth.tenantId]),
    db.query('SELECT count(*) FROM vehicles WHERE tenant_id=$1', [req.auth.tenantId]),
    db.query('SELECT count(*) FROM routes WHERE tenant_id=$1', [req.auth.tenantId]),
    db.query(`SELECT count(*) FROM trips WHERE tenant_id=$1 AND status='active'`, [req.auth.tenantId]),
    db.query(
      `SELECT count(*) FILTER (WHERE status='pending') AS pending,
              count(*) FILTER (WHERE status='paid') AS paid
         FROM payments WHERE tenant_id=$1 AND reference_month=$2`,
      [req.auth.tenantId, refMonth]
    ),
  ]);
  res.json({
    totalStudents: Number(students.rows[0].count),
    totalVehicles: Number(vehicles.rows[0].count),
    totalRoutes: Number(routes.rows[0].count),
    activeTripsToday: Number(activeTrips.rows[0].count),
    pendingPayments: Number(payments.rows[0].pending),
    paidThisMonth: Number(payments.rows[0].paid),
  });
});

/* =========================================================================
 * RELATORIOS — historico (o Financeiro do dia a dia so mostra o mes atual)
 * ========================================================================= */

app.get('/api/reports/financial-history', authMiddleware, requireRole('admin'), async (req, res) => {
  const months = Math.min(Math.max(Number(req.query.months) || 6, 1), 24);
  const r = await db.query(
    `SELECT to_char(reference_month, 'YYYY-MM') AS month,
            count(*) AS total,
            count(*) FILTER (WHERE status='paid') AS paid,
            count(*) FILTER (WHERE status='pending') AS pending,
            coalesce(sum(amount), 0) AS total_amount,
            coalesce(sum(amount) FILTER (WHERE status='paid'), 0) AS paid_amount
       FROM payments
      WHERE tenant_id=$1 AND reference_month >= date_trunc('month', now()) - ($2 || ' months')::interval
      GROUP BY reference_month
      ORDER BY reference_month DESC`,
    [req.auth.tenantId, months - 1]
  );
  res.json(r.rows);
});

// Ultimas viagens finalizadas, com filtro opcional por motorista/rota/veiculo
// e paginacao. duration_seconds vem de started_at/finished_at;  distance_km
// e a soma Haversine entre pings consecutivos de locations (aproximacao em
// linha reta entre pontos, nao rota real).
app.get('/api/reports/trips', authMiddleware, requireRole('admin'), async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 20, 100);
  const offset = Math.max(Number(req.query.offset) || 0, 0);
  const driverId = req.query.driverId || null;
  const routeId = req.query.routeId || null;
  const vehicleId = req.query.vehicleId || null;
  const r = await db.query(
    `SELECT t.id, t.direction, t.started_at, t.finished_at,
            r.name AS route_name, u.name AS driver_name, v.plate AS vehicle_plate,
            EXTRACT(EPOCH FROM (t.finished_at - t.started_at))::int AS duration_seconds,
            (SELECT COUNT(*) FROM trip_events te WHERE te.trip_id = t.id) AS event_count,
            (SELECT COUNT(DISTINCT te.student_id) FROM trip_events te WHERE te.trip_id = t.id) AS student_count,
            (SELECT COALESCE(SUM(
                6371 * 2 * ASIN(SQRT(
                  POWER(SIN(RADIANS(loc.lat - loc.prev_lat) / 2), 2) +
                  COS(RADIANS(loc.prev_lat)) * COS(RADIANS(loc.lat)) *
                  POWER(SIN(RADIANS(loc.lng - loc.prev_lng) / 2), 2)
                ))
              ), 0)
              FROM (
                SELECT lat, lng,
                       LAG(lat) OVER (ORDER BY recorded_at) AS prev_lat,
                       LAG(lng) OVER (ORDER BY recorded_at) AS prev_lng
                  FROM locations WHERE trip_id = t.id
              ) loc
              WHERE loc.prev_lat IS NOT NULL
            ) AS distance_km
       FROM trips t
       JOIN routes r ON r.id = t.route_id
       JOIN users u ON u.id = t.driver_user_id
       LEFT JOIN vehicles v ON v.id = t.vehicle_id
      WHERE t.tenant_id=$1 AND t.status='finished'
        AND ($2::uuid IS NULL OR t.driver_user_id = $2)
        AND ($3::uuid IS NULL OR t.route_id = $3)
        AND ($4::uuid IS NULL OR t.vehicle_id = $4)
      ORDER BY t.finished_at DESC
      LIMIT $5 OFFSET $6`,
    [req.auth.tenantId, driverId, routeId, vehicleId, limit, offset]
  );
  res.json(r.rows);
});

// Detalhe de uma viagem pra tela de relatorios (timeline de eventos +
// metadados) -- reaproveita o mesmo formato de GET /api/trips/:id/events,
// so que sem exigir vinculo de responsavel (admin ve qualquer viagem do tenant).
app.get('/api/reports/trips/:id', authMiddleware, requireRole('admin'), async (req, res) => {
  const trip = await db.query(
    `SELECT t.id, t.direction, t.started_at, t.finished_at,
            r.name AS route_name, u.name AS driver_name, v.plate AS vehicle_plate
       FROM trips t
       JOIN routes r ON r.id = t.route_id
       JOIN users u ON u.id = t.driver_user_id
       LEFT JOIN vehicles v ON v.id = t.vehicle_id
      WHERE t.id=$1 AND t.tenant_id=$2`,
    [req.params.id, req.auth.tenantId]
  );
  if (trip.rows.length === 0) return res.status(404).json({ error: 'viagem nao encontrada' });
  const events = await db.query(
    `SELECT te.id, te.type, te.at, s.name AS student_name
       FROM trip_events te
       JOIN students s ON s.id = te.student_id
      WHERE te.trip_id=$1 AND te.tenant_id=$2
      ORDER BY te.at ASC`,
    [req.params.id, req.auth.tenantId]
  );
  res.json({ ...trip.rows[0], events: events.rows });
});

// Historico de viagens finalizadas envolvendo um aluno especifico (pai ve os
// proprios filhos; admin ve qualquer aluno do tenant) -- reusa
// `assertOwnsStudentOrAdmin`, definida mais abaixo mas hoisted como funcao
// nomeada, entao o uso aqui em cima do arquivo funciona normalmente.
app.get('/api/trips/history', authMiddleware, async (req, res) => {
  const studentId = req.query.studentId;
  if (!studentId) return res.status(400).json({ error: 'studentId obrigatorio' });
  if (!(await assertOwnsStudentOrAdmin(req, studentId))) {
    return res.status(403).json({ error: 'sem permissao' });
  }
  const limit = Math.min(Number(req.query.limit) || 20, 100);
  const offset = Math.max(Number(req.query.offset) || 0, 0);
  const r = await db.query(
    `SELECT t.id, t.direction, t.started_at, t.finished_at, r.name AS route_name, u.name AS driver_name,
            (SELECT te.type FROM trip_events te WHERE te.trip_id=t.id AND te.student_id=$2 ORDER BY te.at DESC LIMIT 1) AS last_event_type,
            (SELECT te.at FROM trip_events te WHERE te.trip_id=t.id AND te.student_id=$2 ORDER BY te.at DESC LIMIT 1) AS last_event_at
       FROM trips t
       JOIN routes r ON r.id = t.route_id
       JOIN users u ON u.id = t.driver_user_id
       JOIN route_students rs ON rs.route_id = t.route_id AND rs.student_id = $2
        AND rs.service_direction IN ('all', t.direction)
      WHERE t.tenant_id=$1 AND t.status='finished'
      ORDER BY t.finished_at DESC
      LIMIT $3 OFFSET $4`,
    [req.auth.tenantId, studentId, limit, offset]
  );
  res.json(r.rows);
});

// Central de notificacoes: uniao de eventos recentes ja existentes (sem
// tabela nova) -- embarque/desembarque e mensagens de chat pro pai;
// mensagens de chat e faltas avisadas pra staff (driver/admin). Cada evento
// vira uma linha generica {type, message, created_at, entity_id}, mais facil
// de renderizar numa lista so no app do que expor os formatos originais.
app.get('/api/notifications', authMiddleware, async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 30, 100);
  let r;
  if (req.auth.role === 'parent') {
    r = await db.query(
      `SELECT * FROM (
         SELECT 'trip_event' AS type,
                s.name || ' ' || CASE
                  WHEN te.type='boarded' THEN 'embarcou na van'
                  WHEN te.type='not_found' THEN 'nao foi localizado no ponto'
                  ELSE 'chegou / desceu' END AS message,
                te.at AS created_at, te.trip_id::text AS entity_id
           FROM trip_events te
           JOIN students s ON s.id = te.student_id
           JOIN student_guardians sg ON sg.student_id = s.id
          WHERE sg.guardian_user_id=$1 AND te.tenant_id=$2
         UNION ALL
         SELECT 'approaching' AS type,
                s.name || ': chegada prevista em aproximadamente 5 minutos' AS message,
                ta.created_at, ta.trip_id::text AS entity_id
           FROM trip_alerts ta
           JOIN students s ON s.id=ta.student_id
           JOIN student_guardians sg ON sg.student_id=ta.student_id
          WHERE sg.guardian_user_id=$1 AND ta.tenant_id=$2
         UNION ALL
         SELECT 'chat' AS type,
                'Nova mensagem: ' || left(cm.body, 80) AS message,
                cm.created_at, cm.id::text AS entity_id
           FROM chat_messages cm
          WHERE cm.tenant_id=$2 AND cm.parent_user_id=$1 AND cm.sender_user_id != $1
       ) x
       WHERE x.created_at > COALESCE(
         (SELECT notifications_cleared_at FROM users WHERE id=$1), '-infinity'::timestamptz
       )
       ORDER BY created_at DESC LIMIT $3`,
      [req.auth.userId, req.auth.tenantId, limit]
    );
  } else {
    r = await db.query(
      `SELECT * FROM (
         SELECT 'chat' AS type,
                'Nova mensagem de ' || u.name || ': ' || left(cm.body, 80) AS message,
                cm.created_at, cm.id::text AS entity_id
           FROM chat_messages cm
           JOIN users u ON u.id = cm.parent_user_id
          WHERE cm.tenant_id=$1 AND cm.sender_user_id = cm.parent_user_id
         UNION ALL
         SELECT 'absence' AS type,
                s.name || ' -- falta avisada para ' || to_char(ab.date, 'DD/MM') AS message,
                ab.created_at, ab.id::text AS entity_id
           FROM absences ab
           JOIN students s ON s.id = ab.student_id
          WHERE ab.tenant_id=$1
            AND ($4='admin' OR EXISTS (
              SELECT 1 FROM route_students rs
              JOIN routes rt ON rt.id=rs.route_id
              WHERE rs.student_id=ab.student_id AND rt.driver_user_id=$2
                AND (ab.direction='all' OR rs.service_direction='all' OR rs.service_direction=ab.direction)
            ))
       ) x
       WHERE x.created_at > COALESCE(
         (SELECT notifications_cleared_at FROM users WHERE id=$2), '-infinity'::timestamptz
       )
       ORDER BY created_at DESC LIMIT $3`,
      [req.auth.tenantId, req.auth.userId, limit, req.auth.role]
    );
  }
  res.json(r.rows);
});

app.delete('/api/notifications', authMiddleware, async (req, res) => {
  await db.query(
    'UPDATE users SET notifications_cleared_at=now() WHERE id=$1 AND tenant_id=$2',
    [req.auth.userId, req.auth.tenantId]
  );
  res.json({ ok: true });
});

// Auditoria administrativa: quem alterou o que (reset de senha, pagamento,
// criar/editar/excluir aluno/rota/veiculo/usuario). So admin.
app.get('/api/audit-log', authMiddleware, requireRole('admin'), async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, 200);
  const offset = Math.max(Number(req.query.offset) || 0, 0);
  const entityType = req.query.entityType || null;
  const r = await db.query(
    `SELECT al.id, al.action, al.entity_type, al.entity_id, al.detail, al.created_at,
            u.name AS actor_name
       FROM audit_log al
       LEFT JOIN users u ON u.id = al.actor_user_id
      WHERE al.tenant_id=$1
        AND ($2::text IS NULL OR al.entity_type = $2)
      ORDER BY al.created_at DESC
      LIMIT $3 OFFSET $4`,
    [req.auth.tenantId, entityType, limit, offset]
  );
  res.json(r.rows);
});

/* =========================================================================
 * FALTA AVULSA — pai (ou admin) avisa que o aluno nao vai numa data
 * ========================================================================= */

async function assertOwnsStudentOrAdmin(req, studentId) {
  if (req.auth.role === 'admin') {
    const s = await db.query('SELECT id FROM students WHERE id=$1 AND tenant_id=$2', [studentId, req.auth.tenantId]);
    return s.rows.length > 0;
  }
  const sg = await db.query(
    'SELECT 1 FROM student_guardians WHERE student_id=$1 AND guardian_user_id=$2 AND tenant_id=$3',
    [studentId, req.auth.userId, req.auth.tenantId]
  );
  return sg.rows.length > 0;
}

app.post('/api/absences', authMiddleware, async (req, res) => {
  const { student_id, date, notes } = req.body;
  const direction = ['all', 'to_school', 'to_home'].includes(req.body.direction)
    ? req.body.direction : 'all';
  if (!student_id || !date) return res.status(400).json({ error: 'student_id e date obrigatorios' });
  if (!(await assertOwnsStudentOrAdmin(req, student_id))) {
    return res.status(403).json({ error: 'sem permissao' });
  }
  const r = await db.query(
    `INSERT INTO absences(tenant_id, student_id, date, direction, notes, created_by)
     VALUES($1,$2,$3,$4,$5,$6)
     ON CONFLICT (student_id, date, direction) DO UPDATE SET notes=EXCLUDED.notes
     RETURNING *`,
    [req.auth.tenantId, student_id, date, direction, notes || null, req.auth.userId]
  );
  const recipients = await db.query(
    `SELECT DISTINCT id FROM (
       SELECT id FROM users WHERE tenant_id=$1 AND role='admin' AND active=true
       UNION SELECT rt.driver_user_id FROM routes rt
         JOIN route_students rs ON rs.route_id=rt.id
        WHERE rt.tenant_id=$1 AND rs.student_id=$2 AND rt.driver_user_id IS NOT NULL
          AND ($3='all' OR rs.service_direction IN ('all', $3))
       UNION SELECT t.driver_user_id FROM trips t
         JOIN route_students rs ON rs.route_id=t.route_id
          AND rs.service_direction IN ('all', t.direction)
        WHERE t.tenant_id=$1 AND rs.student_id=$2 AND t.status='active'
     ) recipients WHERE id IS NOT NULL`,
    [req.auth.tenantId, student_id, direction]
  );
  const student = await db.query('SELECT name FROM students WHERE id=$1', [student_id]);
  const directionLabel = direction === 'to_school' ? 'na ida' : direction === 'to_home' ? 'na volta' : 'na ida e na volta';
  push.sendToUsers(recipients.rows.map((row) => row.id), 'Falta informada',
    `${student.rows[0]?.name || 'Aluno'} nao vai em ${date} (${directionLabel}).`,
    { type: 'absence', studentId: String(student_id), date: String(date), direction })
    .catch((e) => console.error('[push falta]', e));
  res.json(r.rows[0]);
});

app.get('/api/dashboard/today', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const driverFilter = req.auth.role === 'driver' ? req.auth.userId : null;
  const [routes, absences, activeTrips, completedTrips, incompleteStudents, expiringVehicles] = await Promise.all([
    db.query(
      `SELECT r.id, r.name, r.planned_time_to_school, r.planned_time_to_home,
              v.plate AS vehicle_plate, u.name AS driver_name,
              count(rs.student_id)::int AS student_count,
              count(rs.student_id) FILTER (WHERE rs.service_direction IN ('all','to_school'))::int AS to_school_count,
              count(rs.student_id) FILTER (WHERE rs.service_direction IN ('all','to_home'))::int AS to_home_count,
              EXISTS(SELECT 1 FROM trips t WHERE t.route_id=r.id AND t.direction='to_school'
                AND (t.started_at AT TIME ZONE 'America/Sao_Paulo')::date=(now() AT TIME ZONE 'America/Sao_Paulo')::date) AS to_school_started,
              EXISTS(SELECT 1 FROM trips t WHERE t.route_id=r.id AND t.direction='to_home'
                AND (t.started_at AT TIME ZONE 'America/Sao_Paulo')::date=(now() AT TIME ZONE 'America/Sao_Paulo')::date) AS to_home_started
         FROM routes r
         LEFT JOIN vehicles v ON v.id=r.vehicle_id
         LEFT JOIN users u ON u.id=r.driver_user_id
         LEFT JOIN route_students rs ON rs.route_id=r.id
        WHERE r.tenant_id=$1 AND r.active=true
          AND ($2::uuid IS NULL OR r.driver_user_id=$2)
          AND (r.days_of_week IS NULL OR r.days_of_week='' OR
               extract(isodow from now() AT TIME ZONE 'America/Sao_Paulo')::int::text = ANY(string_to_array(r.days_of_week, ',')))
        GROUP BY r.id, v.plate, u.name ORDER BY r.name`,
      [req.auth.tenantId, driverFilter]),
    db.query(
      `SELECT DISTINCT ab.id, ab.student_id, s.name AS student_name,
              ab.direction, ab.notes, r.name AS route_name
         FROM absences ab
         JOIN students s ON s.id=ab.student_id
         JOIN route_students rs ON rs.student_id=s.id
         JOIN routes r ON r.id=rs.route_id
        WHERE ab.tenant_id=$1
          AND ab.date=(now() AT TIME ZONE 'America/Sao_Paulo')::date
          AND ($2::uuid IS NULL OR r.driver_user_id=$2)
          AND (ab.direction='all' OR rs.service_direction='all' OR rs.service_direction=ab.direction)
          AND (r.days_of_week IS NULL OR r.days_of_week='' OR
               extract(isodow from now() AT TIME ZONE 'America/Sao_Paulo')::int::text = ANY(string_to_array(r.days_of_week, ',')))
        ORDER BY s.name`,
      [req.auth.tenantId, driverFilter]),
    db.query(
      `SELECT t.id, t.direction, t.started_at, r.name AS route_name,
              v.plate AS vehicle_plate,
              extract(epoch from (now()-t.started_at))::int AS duration_seconds,
              count(DISTINCT te.student_id) FILTER (WHERE te.type='boarded')::int AS boarded_count,
              count(DISTINCT te.student_id) FILTER (WHERE te.type IN ('dropped','not_found'))::int AS completed_count
         FROM trips t JOIN routes r ON r.id=t.route_id
         LEFT JOIN vehicles v ON v.id=t.vehicle_id
         LEFT JOIN trip_events te ON te.trip_id=t.id
        WHERE t.tenant_id=$1 AND t.status='active'
          AND ($2::uuid IS NULL OR t.driver_user_id=$2)
        GROUP BY t.id, r.name, v.plate ORDER BY t.started_at DESC`,
      [req.auth.tenantId, driverFilter]),
    db.query(
      `SELECT count(*)::int AS count FROM trips
        WHERE tenant_id=$1 AND status='finished'
          AND (finished_at AT TIME ZONE 'America/Sao_Paulo')::date=(now() AT TIME ZONE 'America/Sao_Paulo')::date
          AND ($2::uuid IS NULL OR driver_user_id=$2)`,
      [req.auth.tenantId, driverFilter]),
    db.query(
      `SELECT id, name FROM students WHERE tenant_id=$1 AND active=true
        AND (home_address IS NULL OR trim(home_address)='' OR home_lat IS NULL OR home_lng IS NULL
             OR school_id IS NULL OR emergency_contact_phone IS NULL OR trim(emergency_contact_phone)='')
        ORDER BY name LIMIT 20`, [req.auth.tenantId]),
    db.query(
      `SELECT id, plate, document_expiry FROM vehicles WHERE tenant_id=$1
        AND document_expiry IS NOT NULL AND document_expiry <= CURRENT_DATE + 30
        ORDER BY document_expiry`, [req.auth.tenantId]),
  ]);
  res.json({ routes: routes.rows, absences: absences.rows,
    activeTrips: activeTrips.rows, activeTrip: activeTrips.rows[0] || null,
    brasiliaTime: new Intl.DateTimeFormat('en-GB', { timeZone: 'America/Sao_Paulo', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date()),
    completedTripsToday: completedTrips.rows[0]?.count || 0,
    incompleteStudents: req.auth.role === 'admin' ? incompleteStudents.rows : [],
    expiringVehicles: req.auth.role === 'admin' ? expiringVehicles.rows : [] });
});

app.delete('/api/absences/:id', authMiddleware, async (req, res) => {
  const a = await db.query('SELECT student_id, date, direction FROM absences WHERE id=$1 AND tenant_id=$2', [
    req.params.id, req.auth.tenantId,
  ]);
  if (a.rows.length === 0) return res.status(404).json({ error: 'falta nao encontrada' });
  if (!(await assertOwnsStudentOrAdmin(req, a.rows[0].student_id))) {
    return res.status(403).json({ error: 'sem permissao' });
  }
  const operational = await db.query(
    `SELECT t.status,
            EXISTS(SELECT 1 FROM trip_events te WHERE te.trip_id=t.id
                    AND te.student_id=$2 AND te.type='boarded') AS boarded
       FROM trips t JOIN route_students rs ON rs.route_id=t.route_id
      WHERE t.tenant_id=$1 AND rs.student_id=$2
        AND (t.started_at AT TIME ZONE 'America/Sao_Paulo')::date=$3
        AND ($4='all' OR t.direction=$4)
        AND rs.service_direction IN ('all', t.direction)
        AND t.status IN ('active','finished')`,
    [req.auth.tenantId, a.rows[0].student_id, a.rows[0].date, a.rows[0].direction]
  );
  if (operational.rows.some((trip) => trip.boarded || trip.status === 'finished')) {
    return res.status(409).json({ error: 'nao e possivel cancelar a falta depois do embarque ou do fim da rota' });
  }
  const recipients = await db.query(
    `SELECT DISTINCT rt.driver_user_id AS id FROM routes rt
       JOIN route_students rs ON rs.route_id=rt.id
      WHERE rt.tenant_id=$1 AND rs.student_id=$2 AND rt.driver_user_id IS NOT NULL
        AND ($3='all' OR rs.service_direction IN ('all', $3))
     UNION SELECT id FROM users WHERE tenant_id=$1 AND role='admin' AND active=true`,
    [req.auth.tenantId, a.rows[0].student_id, a.rows[0].direction]
  );
  const student = await db.query('SELECT name FROM students WHERE id=$1', [a.rows[0].student_id]);
  await db.query('DELETE FROM absences WHERE id=$1', [req.params.id]);
  push.sendToUsers(recipients.rows.map((row) => row.id), 'Falta cancelada',
    `${student.rows[0]?.name || 'Aluno'} voltou para a rota de ${a.rows[0].date}.`,
    { type: 'absence_cancelled', studentId: String(a.rows[0].student_id) })
    .catch((e) => console.error('[push cancelar falta]', e));
  res.json({ ok: true });
});

// Faltas futuras dos proprios filhos do pai logado.
app.get('/api/absences/mine', authMiddleware, requireRole('parent'), async (req, res) => {
  const r = await db.query(
    `SELECT ab.id, ab.student_id, ab.date, ab.direction, ab.notes
       FROM absences ab
       JOIN student_guardians sg ON sg.student_id = ab.student_id
      WHERE sg.guardian_user_id=$1 AND sg.tenant_id=$2 AND ab.date >= CURRENT_DATE
      ORDER BY ab.date`,
    [req.auth.userId, req.auth.tenantId]
  );
  res.json(r.rows);
});

// Faltas do dia (pro motorista ver quem nao vem antes de sair).
app.get('/api/absences', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const date = /^\d{4}-\d{2}-\d{2}$/.test(req.query.date) ? req.query.date : new Date().toISOString().slice(0, 10);
  const r = await db.query(
    `SELECT ab.id, ab.student_id, s.name AS student_name, ab.direction, ab.notes
       FROM absences ab
       JOIN students s ON s.id = ab.student_id
      WHERE ab.tenant_id=$1 AND ab.date=$2
      ORDER BY s.name`,
    [req.auth.tenantId, date]
  );
  res.json(r.rows);
});

/* =========================================================================
 * VIAGENS + RASTREAMENTO
 * ========================================================================= */

// Motorista inicia uma viagem numa rota + direcao. Retorna o tripId.
app.post('/api/trips/start', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const { route_id, direction, vehicle_id } = req.body;
  if (!['to_school', 'to_home'].includes(direction)) {
    return res.status(400).json({ error: 'direction invalida' });
  }
  const active = await db.query(
    `SELECT id FROM trips
      WHERE driver_user_id=$1 AND status='active'
      LIMIT 1`,
    [req.auth.userId]
  );
  if (active.rows.length > 0) {
    return res.status(409).json({
      error: 'ja existe uma viagem ativa para este motorista',
      tripId: active.rows[0].id,
    });
  }
  // Confirma que a rota pertence ao tenant, esta ativa e, quando possui um
  // motorista fixo, que nao esta sendo iniciada por outro motorista.
  const rt = await db.query(
    `SELECT r.id, r.vehicle_id, r.driver_user_id, r.active, r.days_of_week,
            (SELECT count(*) FROM route_students rs
              WHERE rs.route_id=r.id AND rs.service_direction IN ('all', $3)) AS student_count
       FROM routes r WHERE r.id=$1 AND r.tenant_id=$2`,
    [route_id, req.auth.tenantId, direction]
  );
  if (rt.rows.length === 0) return res.status(404).json({ error: 'rota nao encontrada' });
  if (!rt.rows[0].active) return res.status(409).json({ error: 'rota inativa' });
  if (rt.rows[0].days_of_week) {
    const today = new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/Sao_Paulo', weekday: 'short'
    }).format(new Date());
    const isoDay = ({ Mon: '1', Tue: '2', Wed: '3', Thu: '4', Fri: '5', Sat: '6', Sun: '7' })[today];
    if (!String(rt.rows[0].days_of_week).split(',').includes(isoDay)) {
      return res.status(409).json({ error: 'esta rota nao esta programada para hoje' });
    }
  }
  if (Number(rt.rows[0].student_count) === 0) {
    return res.status(409).json({ error: 'rota sem alunos vinculados' });
  }
  if (req.auth.role === 'driver' && rt.rows[0].driver_user_id && rt.rows[0].driver_user_id !== req.auth.userId) {
    return res.status(403).json({ error: 'rota atribuida a outro motorista' });
  }

  const contractRule = await db.query('SELECT require_signed_contract FROM tenants WHERE id=$1', [req.auth.tenantId]);
  if (contractRule.rows[0]?.require_signed_contract) {
    const unsigned = await db.query(
      `SELECT s.name FROM route_students rs JOIN students s ON s.id=rs.student_id
        WHERE rs.route_id=$1 AND rs.service_direction IN ('all',$2)
          AND NOT EXISTS (SELECT 1 FROM student_contracts c
            WHERE c.student_id=s.id AND c.tenant_id=$3 AND c.status='signed')
        ORDER BY s.name`, [route_id, direction, req.auth.tenantId]
    );
    if (unsigned.rows.length) return res.status(409).json({
      error: `contrato pendente para: ${unsigned.rows.map((row) => row.name).join(', ')}`,
      unsignedStudents: unsigned.rows,
    });
  }

  // Por padrao usa o veiculo da rota; se vier vehicle_id explicito (troca
  // pontual, ex.: van quebrou), confirma que pertence ao tenant.
  let tripVehicleId = rt.rows[0].vehicle_id;
  if (vehicle_id) {
    const v = await db.query('SELECT id FROM vehicles WHERE id=$1 AND tenant_id=$2', [vehicle_id, req.auth.tenantId]);
    if (v.rows.length === 0) return res.status(404).json({ error: 'veiculo nao encontrado' });
    tripVehicleId = vehicle_id;
  }

  // Lotacao e uma regra de seguranca, nao apenas um aviso visual. Considera
  // somente alunos que realmente farao este trajeto hoje.
  if (tripVehicleId) {
    const occupancy = await db.query(
      `SELECT v.capacity,
              count(rs.student_id) FILTER (WHERE ab.id IS NULL)::int AS passenger_count
         FROM vehicles v
         JOIN routes r ON r.id=$2 AND r.tenant_id=$3
         LEFT JOIN route_students rs ON rs.route_id=r.id
          AND rs.service_direction IN ('all', $4)
         LEFT JOIN absences ab ON ab.student_id=rs.student_id
          AND ab.date=(now() AT TIME ZONE 'America/Sao_Paulo')::date
          AND ab.direction IN ('all', $4)
        WHERE v.id=$1 AND v.tenant_id=$3
        GROUP BY v.capacity`,
      [tripVehicleId, route_id, req.auth.tenantId, direction]
    );
    const capacity = Number(occupancy.rows[0]?.capacity || 0);
    const passengerCount = Number(occupancy.rows[0]?.passenger_count || 0);
    if (capacity > 0 && passengerCount > capacity) {
      return res.status(409).json({
        error: `lotacao excedida: ${passengerCount} alunos para ${capacity} lugares`,
        passengerCount, capacity,
      });
    }
  }

  let r;
  try {
    r = await db.query(
      `INSERT INTO trips(tenant_id, route_id, driver_user_id, direction, vehicle_id)
       VALUES($1,$2,$3,$4,$5) RETURNING id`,
      [req.auth.tenantId, route_id, req.auth.userId, direction, tripVehicleId || null]
    );
  } catch (error) {
    if (error.code === '23505' && error.constraint === 'idx_trips_one_active_per_driver') {
      const current = await db.query(
        `SELECT id FROM trips WHERE driver_user_id=$1 AND status='active' LIMIT 1`,
        [req.auth.userId]
      );
      return res.status(409).json({
        error: 'ja existe uma viagem ativa para este motorista',
        tripId: current.rows[0]?.id,
      });
    }
    throw error;
  }
  const tripId = r.rows[0].id;

  // Avisa os pais dos alunos da rota que a van saiu (nao bloqueia a resposta).
  db.query(
    `SELECT DISTINCT sg.guardian_user_id
       FROM route_students rs
       JOIN student_guardians sg ON sg.student_id = rs.student_id
      WHERE rs.route_id = $1 AND rs.service_direction IN ('all', $2)`,
    [route_id, direction]
  )
    .then((parents) =>
      push.sendToUsers(
        parents.rows.map((p) => p.guardian_user_id),
        'TECO',
        'A van iniciou a rota',
        { type: 'trip_started', tripId }
      )
    )
    .catch((e) => console.error('[push] falha ao notificar inicio de rota', e.message));

  res.json({ tripId });
});

// Motorista so finaliza a propria viagem; admin finaliza qualquer uma do tenant.
app.post('/api/trips/:id/finish', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const pending = await db.query(
    `SELECT s.id, s.name
       FROM trips t
       JOIN route_students rs ON rs.route_id=t.route_id
        AND rs.service_direction IN ('all', t.direction)
       JOIN students s ON s.id=rs.student_id
       LEFT JOIN absences ab ON ab.student_id=s.id
        AND ab.date=(t.started_at AT TIME ZONE 'America/Sao_Paulo')::date
        AND ab.direction IN ('all', t.direction)
      WHERE t.id=$1 AND t.tenant_id=$2 AND t.status='active'
        AND ($3='admin' OR t.driver_user_id=$4)
        AND ab.id IS NULL
        AND EXISTS (
          SELECT 1 FROM trip_events te
           WHERE te.trip_id=t.id AND te.student_id=s.id AND te.type='boarded'
        )
        AND NOT EXISTS (
          SELECT 1 FROM trip_events te
           WHERE te.trip_id=t.id AND te.student_id=s.id AND te.type='dropped'
        )
      ORDER BY rs.position, s.name`,
    [req.params.id, req.auth.tenantId, req.auth.role, req.auth.userId]
  );
  if (pending.rows.length > 0) {
    return res.status(409).json({
      error: 'confirme o desembarque de todos os alunos antes de finalizar',
      pendingStudents: pending.rows
    });
  }
  const r = await db.query(
    `UPDATE trips SET status='finished', finished_at=now()
     WHERE id=$1 AND tenant_id=$2 AND ($3='admin' OR driver_user_id=$4)
     RETURNING id`,
    [req.params.id, req.auth.tenantId, req.auth.role, req.auth.userId]
  );
  if (r.rows.length === 0) return res.status(404).json({ error: 'viagem nao encontrada' });
  // Avisa quem esta olhando o mapa ao vivo que a viagem acabou -- sem isso a
  // tela do pai fica mostrando a ultima posicao como se ainda fosse atual.
  hub.broadcast(req.params.id, { type: 'trip_finished', tripId: req.params.id });
  res.json({ ok: true });
});

async function tripGuardianIds(tripId, tenantId) {
  const guardians = await db.query(
    `SELECT DISTINCT sg.guardian_user_id
       FROM trips t
       JOIN route_students rs ON rs.route_id=t.route_id
        AND rs.service_direction IN ('all', t.direction)
       JOIN student_guardians sg ON sg.student_id=rs.student_id
      WHERE t.id=$1 AND t.tenant_id=$2`,
    [tripId, tenantId]
  );
  return guardians.rows.map((row) => row.guardian_user_id);
}

function paymentCipherKey() {
  const secret = process.env.PAYMENT_CONFIG_ENCRYPTION_KEY || process.env.JWT_SECRET;
  if (!secret || secret.length < 16) throw new Error('chave de criptografia de pagamentos ausente');
  return crypto.createHash('sha256').update(secret).digest();
}

function encryptPaymentSecret(value) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', paymentCipherKey(), iv);
  const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return [iv.toString('base64url'), cipher.getAuthTag().toString('base64url'), encrypted.toString('base64url')].join('.');
}

function decryptPaymentSecret(value) {
  const [ivRaw, tagRaw, encryptedRaw] = String(value).split('.');
  const decipher = crypto.createDecipheriv('aes-256-gcm', paymentCipherKey(), Buffer.from(ivRaw, 'base64url'));
  decipher.setAuthTag(Buffer.from(tagRaw, 'base64url'));
  return Buffer.concat([decipher.update(Buffer.from(encryptedRaw, 'base64url')), decipher.final()]).toString('utf8');
}

app.post('/api/trips/:id/cancel', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const reason = String(req.body?.reason || '').trim().slice(0, 500);
  if (reason.length < 3) return res.status(400).json({ error: 'informe o motivo do cancelamento' });
  const r = await db.query(
    `UPDATE trips SET status='cancelled', cancelled_at=now(), finished_at=now(), cancellation_reason=$5
      WHERE id=$1 AND tenant_id=$2 AND status='active' AND ($3='admin' OR driver_user_id=$4)
      RETURNING id`,
    [req.params.id, req.auth.tenantId, req.auth.role, req.auth.userId, reason]
  );
  if (r.rows.length === 0) return res.status(404).json({ error: 'viagem ativa nao encontrada' });
  const ids = await tripGuardianIds(req.params.id, req.auth.tenantId);
  hub.broadcast(req.params.id, { type: 'trip_cancelled', tripId: req.params.id, reason });
  push.sendToUsers(ids, 'Rota cancelada', reason, { type: 'trip_cancelled', tripId: req.params.id })
    .catch((e) => console.error('[push] falha ao notificar cancelamento', e.message));
  await logAudit(req, 'cancel', 'trip', req.params.id, { reason });
  res.json({ ok: true });
});

app.post('/api/trips/:id/incidents', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const allowed = ['delay', 'breakdown', 'accident', 'student_missing', 'school_closed', 'sos', 'other'];
  const type = String(req.body?.type || 'other');
  const description = String(req.body?.description || '').trim().slice(0, 500);
  if (!allowed.includes(type)) return res.status(400).json({ error: 'tipo de ocorrencia invalido' });
  if (description.length < 3) return res.status(400).json({ error: 'descreva a ocorrencia' });
  const trip = await db.query(
    `SELECT id FROM trips WHERE id=$1 AND tenant_id=$2 AND status='active'
      AND ($3='admin' OR driver_user_id=$4)`,
    [req.params.id, req.auth.tenantId, req.auth.role, req.auth.userId]
  );
  if (trip.rows.length === 0) return res.status(404).json({ error: 'viagem ativa nao encontrada' });
  const inserted = await db.query(
    `INSERT INTO trip_incidents(tenant_id, trip_id, type, description, created_by)
     VALUES($1,$2,$3,$4,$5) RETURNING id, created_at`,
    [req.auth.tenantId, req.params.id, type, description, req.auth.userId]
  );
  const titles = { delay: 'Atraso na rota', breakdown: 'Van com problema', accident: 'Ocorrencia urgente', student_missing: 'Aluno nao localizado', school_closed: 'Escola fechada', sos: 'SOS - emergencia na rota', other: 'Aviso sobre a rota' };
  const ids = await tripGuardianIds(req.params.id, req.auth.tenantId);
  const payload = { type: 'trip_incident', incidentType: type, description, tripId: req.params.id };
  hub.broadcast(req.params.id, payload);
  push.sendToUsers(ids, titles[type], description, payload)
    .catch((e) => console.error('[push] falha ao notificar ocorrencia', e.message));
  await logAudit(req, 'create', 'trip_incident', inserted.rows[0].id, { tripId: req.params.id, type });
  res.json({ id: inserted.rows[0].id, created_at: inserted.rows[0].created_at });
});

app.put('/api/trips/:id/vehicle', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const vehicleId = String(req.body?.vehicle_id || '');
  const vehicle = await db.query(
    'SELECT id, plate, model FROM vehicles WHERE id=$1 AND tenant_id=$2 AND status=$3',
    [vehicleId, req.auth.tenantId, 'available']
  );
  if (vehicle.rows.length === 0) return res.status(404).json({ error: 'veiculo disponivel nao encontrado' });
  const changed = await db.query(
    `UPDATE trips SET vehicle_id=$5 WHERE id=$1 AND tenant_id=$2 AND status='active'
      AND ($3='admin' OR driver_user_id=$4) RETURNING id`,
    [req.params.id, req.auth.tenantId, req.auth.role, req.auth.userId, vehicleId]
  );
  if (changed.rows.length === 0) return res.status(404).json({ error: 'viagem ativa nao encontrada' });
  const ids = await tripGuardianIds(req.params.id, req.auth.tenantId);
  const label = `${vehicle.rows[0].plate}${vehicle.rows[0].model ? ` - ${vehicle.rows[0].model}` : ''}`;
  push.sendToUsers(ids, 'Troca de veiculo', `A rota continuara no veiculo ${label}.`,
    { type: 'vehicle_changed', tripId: req.params.id })
    .catch((e) => console.error('[push] falha ao notificar troca de veiculo', e.message));
  await logAudit(req, 'update', 'trip_vehicle', req.params.id, { vehicleId, label });
  res.json({ ok: true, vehicle: vehicle.rows[0] });
});

// A propria viagem ativa do motorista logado (ou do admin, se foi ele quem
// iniciou) -- usado pro app restaurar o estado "rota em andamento" depois
// de o processo ser morto pelo Android (o app perde _activeTripId em
// memoria, mas a viagem continua aberta no servidor).
app.get('/api/trips/mine/active', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const r = await db.query(
    `SELECT t.id AS trip_id, t.route_id, r.name AS route_name, t.direction,
            t.vehicle_id, t.started_at
       FROM trips t
       JOIN routes r ON r.id = t.route_id
      WHERE t.tenant_id = $1 AND t.driver_user_id = $2 AND t.status = 'active'
      LIMIT 1`,
    [req.auth.tenantId, req.auth.userId]
  );
  res.json(r.rows[0] || null);
});

// Viagens ativas hoje que envolvem algum filho do pai logado (para a tela
// "lista de filhos / viagem ativa" do app dos pais).
app.get('/api/trips/active', authMiddleware, requireRole('parent'), async (req, res) => {
  const r = await db.query(
    `SELECT DISTINCT t.id AS trip_id, t.direction, t.started_at, r.name AS route_name,
            v.plate AS vehicle_plate, v.model AS vehicle_model, v.color AS vehicle_color,
            s.id AS student_id, s.name AS student_name,
            event.type AS last_event_type, event.at AS last_event_at,
            location.recorded_at AS location_recorded_at,
            location.lat AS current_lat, location.lng AS current_lng,
            location.speed AS current_speed,
            COALESCE(er.active, false) AS emergency_return_active,
            er.reason AS emergency_return_reason,
            CASE WHEN COALESCE(er.active, false) THEN s.home_lat
                 WHEN t.direction='to_school' THEN sc.lat ELSE s.home_lat END AS target_lat,
            CASE WHEN COALESCE(er.active, false) THEN s.home_lng
                 WHEN t.direction='to_school' THEN sc.lng ELSE s.home_lng END AS target_lng
       FROM trips t
       JOIN routes r ON r.id = t.route_id
       LEFT JOIN vehicles v ON v.id=t.vehicle_id
       JOIN route_students rs ON rs.route_id = t.route_id
        AND rs.service_direction IN ('all', t.direction)
       JOIN students s ON s.id = rs.student_id
       JOIN student_guardians sg ON sg.student_id = s.id
       LEFT JOIN schools sc ON sc.id=s.school_id
       LEFT JOIN LATERAL (
         SELECT te.type, te.at FROM trip_events te
          WHERE te.trip_id=t.id AND te.student_id=s.id
          ORDER BY te.at DESC LIMIT 1
       ) event ON true
       LEFT JOIN LATERAL (
         SELECT tl.recorded_at, tl.lat, tl.lng, tl.speed FROM trip_last_location tl
          WHERE tl.trip_id=t.id ORDER BY tl.recorded_at DESC LIMIT 1
       ) location ON true
       LEFT JOIN trip_emergency_returns er
         ON er.trip_id=t.id AND er.student_id=s.id
      WHERE t.tenant_id = $1
        AND t.status = 'active'
        AND sg.guardian_user_id = $2
        AND (COALESCE(event.type, '') NOT IN ('dropped','not_found') OR COALESCE(er.active, false))
      ORDER BY t.started_at DESC`,
    [req.auth.tenantId, req.auth.userId]
  );
  res.json(r.rows);
});

// Alunos da rota de uma viagem, com o ultimo evento (boarded/dropped) de cada um.
// Usado pela tela do motorista para os botoes Embarcou/Desceu.
app.get('/api/trips/:id/students', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const r = await db.query(
    `SELECT s.id, s.name, s.home_address, s.home_lat, s.home_lng, s.emergency_contact_phone,
            s.authorized_pickup, s.medical_notes,
            s.school_id, COALESCE(sc.name, s.school_name) AS school_name,
            sc.address AS school_address, sc.lat AS school_lat, sc.lng AS school_lng,
            (SELECT te.type FROM trip_events te
              WHERE te.trip_id = $1 AND te.student_id = s.id
              ORDER BY te.at DESC LIMIT 1) AS last_status,
            (ab.id IS NOT NULL) AS absent,
            COALESCE(er.active, false) AS emergency_return_active,
            EXISTS(SELECT 1 FROM trip_alerts ta
                    WHERE ta.trip_id=$1 AND ta.student_id=s.id
                      AND ta.type='approaching_5min') AS approaching_alert_sent
       FROM trips t
       JOIN route_students rs ON rs.route_id = t.route_id
        AND rs.service_direction IN ('all', t.direction)
       JOIN students s ON s.id = rs.student_id
       LEFT JOIN schools sc ON sc.id=s.school_id
       LEFT JOIN absences ab ON ab.student_id = s.id
        AND ab.date = (t.started_at AT TIME ZONE 'America/Sao_Paulo')::date
        AND ab.direction IN ('all', t.direction)
       LEFT JOIN trip_emergency_returns er
         ON er.trip_id=t.id AND er.student_id=s.id
      WHERE t.id = $1 AND t.tenant_id = $2
        AND ($3='admin' OR t.driver_user_id=$4)
      ORDER BY rs.position, s.name`,
    [req.params.id, req.auth.tenantId, req.auth.role, req.auth.userId]
  );
  res.json(r.rows);
});

// Plano de paradas preparado para rotas com uma ou varias escolas. A ordem
// continua manual: na ida busca os alunos e depois agrupa as escolas; na
// volta passa pelas escolas e depois entrega os alunos na ordem cadastrada.
app.get('/api/trips/:id/stops', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const trip = await db.query(
    `SELECT id, direction FROM trips WHERE id=$1 AND tenant_id=$2
      AND ($3='admin' OR driver_user_id=$4)`,
    [req.params.id, req.auth.tenantId, req.auth.role, req.auth.userId]
  );
  if (trip.rows.length === 0) return res.status(404).json({ error: 'viagem nao encontrada' });
  const students = await db.query(
    `SELECT s.id, s.name, s.home_address, s.home_lat, s.home_lng,
            s.school_id, COALESCE(sc.name, s.school_name, 'Escola nao informada') AS school_name,
            sc.address AS school_address, sc.lat AS school_lat, sc.lng AS school_lng,
            rs.position
       FROM trips t
       JOIN route_students rs ON rs.route_id=t.route_id
        AND rs.service_direction IN ('all', t.direction)
       JOIN students s ON s.id=rs.student_id
       LEFT JOIN schools sc ON sc.id=s.school_id
       LEFT JOIN absences ab ON ab.student_id=s.id
        AND ab.date=(t.started_at AT TIME ZONE 'America/Sao_Paulo')::date
        AND ab.direction IN ('all', t.direction)
      WHERE t.id=$1 AND t.tenant_id=$2 AND ab.id IS NULL
      ORDER BY rs.position, s.name`,
    [req.params.id, req.auth.tenantId, direction]
  );
  const homes = students.rows.map((s) => ({
    type: 'home', student_id: s.id, name: s.name, address: s.home_address,
    lat: s.home_lat, lng: s.home_lng,
  }));
  const schoolMap = new Map();
  for (const s of students.rows) {
    const key = s.school_id || `legacy:${s.school_name}`;
    if (!schoolMap.has(key)) {
      schoolMap.set(key, {
        type: 'school', school_id: s.school_id, name: s.school_name,
        address: s.school_address, lat: s.school_lat, lng: s.school_lng,
        students: [],
      });
    }
    schoolMap.get(key).students.push({ id: s.id, name: s.name });
  }
  const schools = [...schoolMap.values()];
  const stops = trip.rows[0].direction === 'to_school'
    ? [...homes, ...schools]
    : [...schools, ...homes];
  res.json({ direction: trip.rows[0].direction, school_count: schools.length, stops });
});

// Reativa o acompanhamento de uma criança que já havia chegado, mudando o
// destino operacional dela para casa sem alterar a rota dos demais alunos.
app.post('/api/trips/:id/students/:studentId/emergency-return', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const reason = String(req.body?.reason || '').trim().slice(0, 500) || null;
  const student = await db.query(
    `SELECT s.id, s.name
       FROM trips t
       JOIN route_students rs ON rs.route_id=t.route_id
        AND rs.service_direction IN ('all', t.direction)
       JOIN students s ON s.id=rs.student_id
      WHERE t.id=$1 AND s.id=$2 AND t.tenant_id=$3 AND t.status='active'
        AND ($4='admin' OR t.driver_user_id=$5)`,
    [req.params.id, req.params.studentId, req.auth.tenantId, req.auth.role, req.auth.userId]
  );
  if (student.rows.length === 0) return res.status(404).json({ error: 'aluno ou viagem ativa nao encontrado' });
  const latest = await db.query(
    `SELECT type FROM trip_events WHERE trip_id=$1 AND student_id=$2 ORDER BY at DESC LIMIT 1`,
    [req.params.id, req.params.studentId]
  );
  if (latest.rows[0]?.type !== 'dropped') {
    return res.status(409).json({ error: 'o retorno de emergencia so pode iniciar depois da chegada' });
  }
  await db.query(
    `INSERT INTO trip_emergency_returns(trip_id, student_id, tenant_id, reason, active, started_at, finished_at)
     VALUES($1,$2,$3,$4,true,now(),NULL)
     ON CONFLICT (trip_id, student_id) DO UPDATE
       SET reason=EXCLUDED.reason, active=true, started_at=now(), finished_at=NULL`,
    [req.params.id, req.params.studentId, req.auth.tenantId, reason]
  );
  const boarded = await db.query(
    `INSERT INTO trip_events(tenant_id, trip_id, student_id, type)
     VALUES($1,$2,$3,'boarded') RETURNING *`,
    [req.auth.tenantId, req.params.id, req.params.studentId]
  );
  hub.broadcast(req.params.id, {
    type: 'emergency_return', tripId: req.params.id,
    studentId: req.params.studentId, studentName: student.rows[0].name,
    reason, createdAt: boarded.rows[0].at,
  });
  db.query(
    `SELECT guardian_user_id FROM student_guardians WHERE student_id=$1`,
    [req.params.studentId]
  ).then((parents) => push.sendToUsers(
    parents.rows.map((p) => p.guardian_user_id),
    'Retorno de emergência',
    `${student.rows[0].name} está retornando para casa${reason ? `: ${reason}` : '.'}`,
    { type: 'emergency_return', tripId: req.params.id, studentId: req.params.studentId }
  )).catch((e) => console.error('[push] falha no retorno de emergencia', e.message));
  res.json({ ok: true });
});

// Alerta automatico calculado pelo app do motorista a partir do GPS e da
// proxima parada na ordem da rota. O banco impede envio duplicado.
app.post('/api/trips/:id/students/:studentId/approaching', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const check = await db.query(
    `SELECT s.name
       FROM trips t
       JOIN route_students rs ON rs.route_id=t.route_id
        AND rs.service_direction IN ('all', t.direction)
       JOIN students s ON s.id=rs.student_id
      WHERE t.id=$1 AND t.tenant_id=$2 AND t.status='active'
        AND s.id=$3 AND ($4='admin' OR t.driver_user_id=$5)`,
    [req.params.id, req.auth.tenantId, req.params.studentId, req.auth.role, req.auth.userId]
  );
  if (check.rows.length === 0) return res.status(404).json({ error: 'aluno ou viagem ativa nao encontrado' });

  const inserted = await db.query(
    `INSERT INTO trip_alerts(tenant_id, trip_id, student_id, type)
     VALUES($1,$2,$3,'approaching_5min')
     ON CONFLICT (trip_id, student_id, type) DO NOTHING
     RETURNING id, created_at`,
    [req.auth.tenantId, req.params.id, req.params.studentId]
  );
  if (inserted.rows.length === 0) return res.json({ ok: true, alreadySent: true });

  const studentName = check.rows[0].name;
  const guardians = await db.query(
    'SELECT guardian_user_id FROM student_guardians WHERE student_id=$1 AND tenant_id=$2',
    [req.params.studentId, req.auth.tenantId]
  );
  const payload = {
    type: 'approaching', tripId: req.params.id,
    studentId: req.params.studentId, studentName,
    createdAt: inserted.rows[0].created_at,
  };
  hub.broadcast(req.params.id, payload);
  push.sendToUsers(
    guardians.rows.map((row) => row.guardian_user_id),
    'A van esta chegando',
    `${studentName}: chegada prevista em aproximadamente 5 minutos`,
    { type: 'approaching', tripId: req.params.id, studentId: req.params.studentId }
  ).catch((e) => console.error('[push] falha ao notificar aproximacao', e.message));

  res.json({ ok: true, alreadySent: false });
});

// Recebe pings de GPS do app do motorista (flutter_background_geolocation).
// Aceita um objeto unico OU um array (quando a lib faz batch) -- validado
// (lat/lng na faixa geografica valida, lote limitado a 200 itens) antes de
// chegar aqui.
app.post('/api/trips/:id/locations', authMiddleware, requireRole('driver', 'admin'), validateBody(locationsBody), async (req, res) => {
  const tripId = req.params.id;
  const tenantId = req.auth.tenantId;

  // Confirma que a viagem pertence ao tenant e (se motorista comum) a ele
  // mesmo -- antes o comentario prometia essa checagem mas o SQL nao filtrava
  // driver_user_id, entao qualquer motorista do tenant injetava posicao em
  // qualquer viagem ativa.
  const trip = await db.query(
    `SELECT id FROM trips
      WHERE id=$1 AND tenant_id=$2 AND status=$3 AND ($4='admin' OR driver_user_id=$5)`,
    [tripId, tenantId, 'active', req.auth.role, req.auth.userId]
  );
  if (trip.rows.length === 0) return res.status(404).json({ error: 'viagem ativa nao encontrada' });

  const items = Array.isArray(req.body) ? req.body : [req.body];
  const values = [];
  const placeholders = [];
  const normalized = items.map((p) => ({
    lat: p.lat, lng: p.lng, speed: p.speed ?? null, heading: p.heading ?? null,
    accuracy: p.accuracy ?? null, recorded_at: p.recorded_at || new Date().toISOString(),
  }));
  normalized.forEach((p, index) => {
    const offset = index * 8;
    placeholders.push(`($${offset + 1},$${offset + 2},$${offset + 3},$${offset + 4},$${offset + 5},$${offset + 6},$${offset + 7},$${offset + 8})`);
    values.push(tenantId, tripId, p.lat, p.lng, p.speed, p.heading, p.accuracy, p.recorded_at);
  });
  await db.query(
    `INSERT INTO locations(tenant_id,trip_id,lat,lng,speed,heading,accuracy,recorded_at)
     VALUES ${placeholders.join(',')}`,
    values
  );
  const last = normalized.reduce((newest, item) =>
    new Date(item.recorded_at) > new Date(newest.recorded_at) ? item : newest);

  if (last) {
    await db.query(
      `INSERT INTO trip_last_location(trip_id, tenant_id, lat, lng, speed, heading, recorded_at)
       VALUES($1,$2,$3,$4,$5,$6,$7)
       ON CONFLICT (trip_id) DO UPDATE
         SET lat=$3, lng=$4, speed=$5, heading=$6, recorded_at=$7`,
      [tripId, tenantId, last.lat, last.lng, last.speed, last.heading, last.recorded_at]
    );
    // Retransmite em tempo real para os pais inscritos nesta viagem.
    hub.broadcast(tripId, { type: 'location', tripId, ...last });
  }
  res.json({ ok: true, received: items.length });
});

// Ultima posicao conhecida (fallback quando o WebSocket ainda nao conectou).
// So o app dos pais chama este endpoint -- mesma checagem de vinculo
// (parentCanWatch) usada em /events e no WS, que antes faltava aqui: sem
// ela, qualquer usuario autenticado do tenant conseguia ver a posicao de
// qualquer viagem, mesmo sem filho vinculado a ela.
app.get('/api/trips/:id/location', authMiddleware, requireRole('parent'), async (req, res) => {
  const allowed = await parentCanWatch(req.auth.tenantId, req.auth.userId, req.params.id);
  if (!allowed) return res.status(403).json({ error: 'sem permissao' });
  const r = await db.query(
    'SELECT lat, lng, speed, heading, recorded_at FROM trip_last_location WHERE trip_id=$1 AND tenant_id=$2',
    [req.params.id, req.auth.tenantId]
  );
  res.json(r.rows[0] || null);
});

// Registra embarque/desembarque de um aluno.
app.post('/api/trips/:id/events', authMiddleware, requireRole('driver', 'admin'), validateBody(tripEventBody), async (req, res) => {
  const { student_id, type, lat, lng, received_by } = req.body;
  // Confirma que a viagem existe, e do tenant, esta ativa, que quem chama e
  // o motorista dela (ou admin), e que o aluno realmente esta na rota dessa
  // viagem -- sem isso, qualquer motorista do tenant podia fabricar eventos
  // pra viagem/aluno de outra pessoa so trocando o id na chamada.
  const tripCheck = await db.query(
    `SELECT t.id FROM trips t
      WHERE t.id=$1 AND t.tenant_id=$2 AND t.status='active'
        AND ($3='admin' OR t.driver_user_id=$4)`,
    [req.params.id, req.auth.tenantId, req.auth.role, req.auth.userId]
  );
  if (tripCheck.rows.length === 0) return res.status(404).json({ error: 'viagem ativa nao encontrada' });
  const studentCheck = await db.query(
    `SELECT s.id FROM students s
       JOIN route_students rs ON rs.student_id = s.id
       JOIN trips t ON t.route_id = rs.route_id
        AND rs.service_direction IN ('all', t.direction)
      WHERE s.id=$1 AND s.tenant_id=$2 AND t.id=$3`,
    [student_id, req.auth.tenantId, req.params.id]
  );
  if (studentCheck.rows.length === 0) return res.status(404).json({ error: 'aluno nao pertence a esta viagem' });

  // Torna o toque repetido/retry idempotente: sem isto, dois requests iguais
  // geravam duas linhas e duas notificacoes para o responsavel.
  const latest = await db.query(
    `SELECT * FROM trip_events
      WHERE trip_id=$1 AND student_id=$2 AND tenant_id=$3
      ORDER BY at DESC LIMIT 1`,
    [req.params.id, student_id, req.auth.tenantId]
  );
  if (latest.rows[0]?.type === type) {
    return res.json({ ...latest.rows[0], alreadyRecorded: true });
  }

  const r = await db.query(
    `INSERT INTO trip_events(tenant_id, trip_id, student_id, type, lat, lng, received_by)
     VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *`,
    [req.auth.tenantId, req.params.id, student_id, type, lat ?? null, lng ?? null,
      type === 'dropped' ? received_by?.trim() || null : null]
  );
  if (type === 'dropped') {
    await db.query(
      `UPDATE trip_emergency_returns SET active=false, finished_at=now()
        WHERE trip_id=$1 AND student_id=$2 AND tenant_id=$3 AND active=true`,
      [req.params.id, student_id, req.auth.tenantId]
    );
  }
  hub.broadcast(req.params.id, { type: 'event', event: r.rows[0] });

  // Notifica os responsaveis do aluno (nao bloqueia a resposta).
  db.query(
    `SELECT s.name AS student_name, sg.guardian_user_id
       FROM students s
       JOIN student_guardians sg ON sg.student_id = s.id
      WHERE s.id = $1 AND s.tenant_id = $2`,
    [student_id, req.auth.tenantId]
  )
    .then((info) => {
      if (info.rows.length === 0) return;
      const studentName = info.rows[0].student_name;
      const when = new Date(r.rows[0].at);
      const timeBrasilia = brasiliaTimeFormatter.format(when);
      const action = type === 'boarded'
        ? 'embarcou na van'
        : type === 'not_found'
          ? 'nao foi localizado no ponto'
          : 'chegou / desceu';
      const receiver = type === 'dropped' && received_by
        ? `, recebido por ${received_by.trim()}`
        : '';
      return push.sendToUsers(
        info.rows.map((row) => row.guardian_user_id),
        'TECO',
        `${studentName} ${action} às ${timeBrasilia}${receiver}`,
        { type: 'trip_event', tripId: req.params.id, eventType: type, studentId: student_id }
      );
    })
    .catch((e) => console.error('[push] falha ao notificar evento', e.message));

  res.json(r.rows[0]);
});

// Corrige o último toque feito por engano enquanto a viagem ainda está ativa.
// Só o evento mais recente daquele aluno pode ser removido, evitando reescrever
// silenciosamente um histórico antigo ou já finalizado.
app.delete('/api/trips/:id/students/:studentId/last-event', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const removed = await db.query(
    `DELETE FROM trip_events te
      USING trips t
      WHERE te.id = (
        SELECT last_te.id FROM trip_events last_te
         WHERE last_te.trip_id=$1 AND last_te.student_id=$2 AND last_te.tenant_id=$3
         ORDER BY last_te.at DESC LIMIT 1
      )
        AND te.trip_id=t.id AND t.id=$1 AND t.tenant_id=$3 AND t.status='active'
        AND ($4='admin' OR t.driver_user_id=$5)
      RETURNING te.*`,
    [req.params.id, req.params.studentId, req.auth.tenantId, req.auth.role, req.auth.userId]
  );
  if (removed.rows.length === 0) {
    return res.status(404).json({ error: 'evento recente nao encontrado' });
  }
  hub.broadcast(req.params.id, {
    type: 'event_corrected', tripId: req.params.id,
    studentId: req.params.studentId, removedEventId: removed.rows[0].id,
  });
  res.json({ ok: true, removed: removed.rows[0] });
});

// Eventos (embarque/desembarque) de uma viagem, em ordem cronologica —
// usado pela tela "Timeline do dia" do app dos pais.
app.get('/api/trips/:id/events', authMiddleware, requireRole('parent'), async (req, res) => {
  const allowed = await parentHasStudentOnTrip(req.auth.tenantId, req.auth.userId, req.params.id);
  if (!allowed) return res.status(403).json({ error: 'sem permissao' });
  const r = await db.query(
    `SELECT te.id, te.type, te.at, te.received_by, s.name AS student_name
       FROM trip_events te
       JOIN students s ON s.id = te.student_id
       JOIN student_guardians sg ON sg.student_id=te.student_id
      WHERE te.trip_id = $1 AND te.tenant_id = $2
        AND sg.guardian_user_id=$3
      ORDER BY te.at ASC`,
    [req.params.id, req.auth.tenantId, req.auth.userId]
  );
  res.json(r.rows);
});

/* =========================================================================
 * WEBSOCKET — pais acompanham uma viagem em tempo real
 * ========================================================================= */
const server = http.createServer(app);
const wss = new WebSocketServer({ noServer: true });

async function parentHasStudentOnTrip(tenantId, userId, tripId) {
  const r = await db.query(
    `SELECT 1 FROM trips t
       JOIN route_students rs ON rs.route_id=t.route_id
        AND rs.service_direction IN ('all', t.direction)
       JOIN student_guardians sg ON sg.student_id=rs.student_id
      WHERE t.id=$1 AND t.tenant_id=$2 AND sg.guardian_user_id=$3
      LIMIT 1`,
    [tripId, tenantId, userId]
  );
  return r.rows.length > 0;
}

// Um pai so pode assinar viagens de rotas em que seu filho esta matriculado.
async function parentCanWatch(tenantId, userId, tripId) {
  const r = await db.query(
    `SELECT 1
       FROM trips t
      JOIN route_students rs ON rs.route_id = t.route_id
       AND rs.service_direction IN ('all', t.direction)
      JOIN student_guardians sg ON sg.student_id = rs.student_id
      LEFT JOIN LATERAL (
        SELECT te.type FROM trip_events te
         WHERE te.trip_id=t.id AND te.student_id=rs.student_id
         ORDER BY te.at DESC LIMIT 1
      ) event ON true
      LEFT JOIN trip_emergency_returns er
        ON er.trip_id=t.id AND er.student_id=rs.student_id
      WHERE t.id = $1
        AND t.tenant_id = $2
        AND sg.guardian_user_id = $3
        AND t.status='active'
        AND (COALESCE(event.type, '') NOT IN ('dropped','not_found') OR COALESCE(er.active, false))
      LIMIT 1`,
    [tripId, tenantId, userId]
  );
  return r.rows.length > 0;
}

// Um admin/driver so pode entrar na thread de um pai do proprio tenant.
async function staffCanChatWith(tenantId, parentUserId) {
  const r = await db.query(
    `SELECT 1 FROM users WHERE id=$1 AND tenant_id=$2 AND role='parent'`,
    [parentUserId, tenantId]
  );
  return r.rows.length > 0;
}

server.on('upgrade', async (req, socket, head) => {
  const query = Object.fromEntries(new URL(req.url, 'http://localhost').searchParams);
  const authHeader = req.headers.authorization || '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : null;
  const auth = await verifyToken(token);
  if (!auth) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }

  if (query.tripId) {
    const tripId = query.tripId;
    // Admin/driver do tenant podem observar; pai precisa ter vinculo.
    let allowed = false;
    if (auth.role === 'admin' || auth.role === 'driver') {
      const trip = await db.query(
        `SELECT 1 FROM trips WHERE id=$1 AND tenant_id=$2
          AND ($3='admin' OR driver_user_id=$4)`,
        [tripId, auth.tenantId, auth.role, auth.userId]
      );
      allowed = trip.rows.length > 0;
    }
    if (!allowed && auth.role === 'parent') {
      allowed = await parentCanWatch(auth.tenantId, auth.userId, tripId);
    }
    if (!allowed) {
      socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      hub.subscribe(tripId, ws);
      ws.send(JSON.stringify({ type: 'subscribed', tripId }));
    });
    return;
  }

  if (query.chatWith) {
    const parentUserId = query.chatWith;
    let allowed = false;
    if (auth.role === 'parent') {
      allowed = parentUserId === auth.userId;
    } else if (auth.role === 'admin' || auth.role === 'driver') {
      allowed = await staffCanChatWith(auth.tenantId, parentUserId);
    }
    if (!allowed) {
      socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      hub.subscribe(`chat:${parentUserId}`, ws);
      ws.send(JSON.stringify({ type: 'subscribed', chatWith: parentUserId }));
    });
    return;
  }

  socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
  socket.destroy();
});

// Handler de erro final: qualquer excecao/rejeicao nao tratada numa rota
// (capturada pelo express-async-errors) cai aqui. Loga o detalhe completo
// so no servidor -- o cliente recebe uma mensagem generica, nunca a
// mensagem crua do driver do banco (podia revelar nome de coluna/constraint).
app.use((err, _req, res, _next) => {
  console.error('[erro nao tratado]', err);
  res.status(500).json({ error: 'erro interno' });
});

module.exports = { app, server };

// So sobe sozinho quando rodado direto (`node src/server.js` / `npm start`);
// os testes importam { app, server } e chamam server.listen(0, ...) eles
// mesmos, numa porta livre, sem depender de um processo externo rodando.
if (require.main === module) {
  const PORT = process.env.PORT || 3000;
  server.listen(PORT, () => {
    console.log(`API em http://localhost:${PORT}`);
    startMaintenance();
  });
}
