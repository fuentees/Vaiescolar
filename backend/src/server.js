require('express-async-errors'); // faz erro/rejeicao nao tratada numa rota async cair no error handler abaixo em vez de travar a request (Express 4 nao faz isso sozinho)
const express = require('express');
const cors = require('cors');
const http = require('http');
const path = require('path');
const { WebSocketServer } = require('ws');
const bcrypt = require('bcryptjs');
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');
require('dotenv').config();

const db = require('./db');
const { sign, authMiddleware, verifyToken, requireRole } = require('./auth');
const hub = require('./hub');
const push = require('./push');
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
// Apps mobile nao sao afetados por CORS (so navegadores aplicam essa
// politica) -- fica configuravel via env pra quando/se existir um painel
// web administrativo que precise ser restrito a uma origem especifica.
app.use(cors({ origin: process.env.CORS_ORIGIN ? process.env.CORS_ORIGIN.split(',') : '*' }));
app.use(express.json());
app.get('/health', (_req, res) => res.json({ ok: true }));
app.get('/app-version/:app', (req, res) => {
  const versions = {
    motorista: {
      version: '0.2.0', buildNumber: 2,
      url: 'https://vaiescolar.onrender.com/downloads/VaiEscolar-Motorista.apk',
      notes: 'Notificações sonoras, chat com leitura e melhorias no mapa.',
    },
    responsavel: {
      version: '0.2.0', buildNumber: 2,
      url: 'https://vaiescolar.onrender.com/downloads/VaiEscolar-Responsavel.zip',
      notes: 'Notificações sonoras, chat com leitura e melhorias no mapa.',
    },
  };
  const version = versions[req.params.app];
  if (!version) return res.status(404).json({ error: 'app nao encontrado' });
  res.json({ ...version, mandatory: false });
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

// Rate limit mais restrito nos endpoints publicos de auth (forca bruta de
// login/senha, spam de cadastro/convite); geral mais frouxo no resto da API.
const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 20, standardHeaders: true, legacyHeaders: false });
const apiLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 300, standardHeaders: true, legacyHeaders: false });
// Chat especifico: 30 msgs/min por IP, alem do limite geral de /api -- evita
// spam/flood de uma conversa sem travar o resto da API.
const chatLimiter = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: true, legacyHeaders: false });
app.use('/api/auth/login', authLimiter);
app.use('/api/auth/register-tenant', authLimiter);
app.use('/api/auth/register-parent', authLimiter);
app.use('/api/auth/link-child', authLimiter);
app.use('/api', apiLimiter);

/* =========================================================================
 * AUTENTICACAO / ONBOARDING
 * ========================================================================= */

// Cria um novo operador (tenant) + usuario admin. Onboarding do motorista dono.
app.post('/api/auth/register-tenant', async (req, res) => {
  const { tenantName, name, email, password } = req.body;
  if (!tenantName || !email || !password) {
    return res.status(400).json({ error: 'campos obrigatorios faltando' });
  }
  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const t = await client.query(
      'INSERT INTO tenants(name) VALUES($1) RETURNING id',
      [tenantName]
    );
    const tenantId = t.rows[0].id;
    const hash = await bcrypt.hash(password, 10);
    const u = await client.query(
      `INSERT INTO users(tenant_id, role, name, email, password_hash)
       VALUES($1,'admin',$2,$3,$4) RETURNING id, role`,
      [tenantId, name || 'Admin', email, hash]
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
  const hash = await bcrypt.hash(password, 10);
  try {
    const r = await db.query(
      `INSERT INTO users(tenant_id, role, name, email, phone, password_hash)
       VALUES($1,$2,$3,$4,$5,$6) RETURNING id, role, name, email`,
      [req.auth.tenantId, role, name, email, phone || null, hash]
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
  const r = await db.query('SELECT password_hash FROM users WHERE id=$1 AND tenant_id=$2', [
    req.auth.userId, req.auth.tenantId,
  ]);
  if (r.rows.length === 0) return res.status(404).json({ error: 'usuario nao encontrado' });
  const ok = await bcrypt.compare(currentPassword, r.rows[0].password_hash);
  if (!ok) return res.status(401).json({ error: 'senha atual incorreta' });
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

// Admin reseta a senha de outro usuario do tenant, incluindo outro admin
// (fluxo de "esqueci a senha" sem depender de e-mail: a pessoa pede pra
// qualquer admin do tenant).
app.put('/api/users/:id/password', authMiddleware, requireRole('admin'), async (req, res) => {
  const { newPassword } = req.body;
  if (!newPassword || newPassword.length < 6) {
    return res.status(400).json({ error: 'nova senha precisa ter ao menos 6 caracteres' });
  }
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
  const r = await db.query('SELECT * FROM users WHERE email=$1 LIMIT 1', [email]);
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
    if (new Date(invite.expires_at) < new Date()) {
      await client.query('ROLLBACK');
      return res.status(410).json({ error: 'codigo expirado' });
    }

    const hash = await bcrypt.hash(password, 10);
    const u = await client.query(
      `INSERT INTO users(tenant_id, role, name, email, password_hash)
       VALUES($1,'parent',$2,$3,$4) RETURNING id`,
      [invite.tenant_id, name || 'Responsavel', email, hash]
    );
    const userId = u.rows[0].id;
    await client.query(
      `INSERT INTO student_guardians(tenant_id, student_id, guardian_user_id)
       VALUES($1,$2,$3) ON CONFLICT DO NOTHING`,
      [invite.tenant_id, invite.student_id, userId]
    );
    await client.query(
      'UPDATE guardian_invites SET used_by_user_id=$1 WHERE id=$2',
      [userId, invite.id]
    );
    await client.query('COMMIT');
    const token = sign({ userId, tenantId: invite.tenant_id, role: 'parent', tokenVersion: 0 });
    res.json({ token, userId, tenantId: invite.tenant_id });
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
    if (new Date(invite.expires_at) < new Date()) {
      await client.query('ROLLBACK');
      return res.status(410).json({ error: 'codigo expirado' });
    }

    await client.query(
      `INSERT INTO student_guardians(tenant_id, student_id, guardian_user_id)
       VALUES($1,$2,$3) ON CONFLICT DO NOTHING`,
      [invite.tenant_id, invite.student_id, req.auth.userId]
    );
    await client.query(
      'UPDATE guardian_invites SET used_by_user_id=$1 WHERE id=$2',
      [req.auth.userId, invite.id]
    );
    await client.query('COMMIT');
    res.json({ ok: true });
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
  db.query(
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
        push.sendToUsers(staff.rows.map((s) => s.id), 'VaiEscolar', 'Nova mensagem de um responsavel', {
          type: 'chat', parentUserId,
        })
      )
      .catch((e) => console.error('[push] falha ao notificar chat', e.message));
  } else {
    push
      .sendToUsers([parentUserId], 'VaiEscolar', 'Nova mensagem do motorista', { type: 'chat', parentUserId })
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
    `SELECT s.id, s.name, s.home_address, sc.name AS school_name, sc.address AS school_address
       FROM student_guardians sg
       JOIN students s ON s.id = sg.student_id
       LEFT JOIN schools sc ON sc.id = s.school_id
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
    `SELECT u.id, u.name, u.email, u.phone
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

  res.json({ ...s.rows[0], guardians: guardians.rows, payments: payments.rows });
});

/* =========================================================================
 * ESCOLAS
 * ========================================================================= */

app.get('/api/schools', authMiddleware, requireRole('admin'), async (req, res) => {
  const r = await db.query('SELECT * FROM schools WHERE tenant_id=$1 ORDER BY name', [req.auth.tenantId]);
  res.json(r.rows);
});

app.post('/api/schools', authMiddleware, requireRole('admin'), validateBody(schoolBody), async (req, res) => {
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
        `INSERT INTO guardian_invites(tenant_id, student_id, code, expires_at)
         VALUES($1,$2,$3,$4) RETURNING code, expires_at`,
        [req.auth.tenantId, req.params.id, code, expiresAt]
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

app.post('/api/routes', authMiddleware, requireRole('admin'), validateBody(routeBody), async (req, res) => {
  const { name, vehicle_id, driver_user_id, days_of_week, planned_time, active } = req.body;

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
    `INSERT INTO routes(tenant_id, name, vehicle_id, driver_user_id, days_of_week, planned_time, active)
     VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *`,
    [req.auth.tenantId, name, vehicle_id || null, driver_user_id || null, days_of_week || null, planned_time || null, active ?? true]
  );
  res.json(r.rows[0]);
});

app.get('/api/routes', authMiddleware, async (req, res) => {
  const r = await db.query(
    'SELECT * FROM routes WHERE tenant_id=$1 ORDER BY name',
    [req.auth.tenantId]
  );
  res.json(r.rows);
});

app.put('/api/routes/:id', authMiddleware, requireRole('admin'), validateBody(routeBody), async (req, res) => {
  const { name, vehicle_id, driver_user_id, days_of_week, planned_time, active } = req.body;
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
    `UPDATE routes SET name=$1, vehicle_id=$2, driver_user_id=$3, days_of_week=$4, planned_time=$5, active=$6
      WHERE id=$7 AND tenant_id=$8 RETURNING *`,
    [name, vehicle_id || null, driver_user_id || null, days_of_week || null, planned_time || null, active ?? true, req.params.id, req.auth.tenantId]
  );
  if (r.rows.length === 0) return res.status(404).json({ error: 'rota nao encontrada' });
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
    `INSERT INTO student_guardians(tenant_id, student_id, guardian_user_id)
     VALUES($1,$2,$3) ON CONFLICT DO NOTHING`,
    [req.auth.tenantId, req.params.id, guardian_user_id]
  );
  res.json({ ok: true });
});

// Vincula um aluno a uma rota (confirma que rota e aluno sao do mesmo tenant).
app.post('/api/routes/:id/students', authMiddleware, requireRole('admin'), async (req, res) => {
  const { student_id } = req.body;
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
  // Novo vinculo vai pro fim da fila de embarque.
  const pos = await db.query('SELECT COALESCE(max(position)+1, 0) AS next FROM route_students WHERE route_id=$1', [
    req.params.id,
  ]);
  await db.query(
    `INSERT INTO route_students(tenant_id, route_id, student_id, position)
     VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`,
    [req.auth.tenantId, req.params.id, student_id, pos.rows[0].next]
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
app.get('/api/routes/:id/students', authMiddleware, requireRole('admin'), async (req, res) => {
  const rt = await db.query('SELECT id FROM routes WHERE id=$1 AND tenant_id=$2', [req.params.id, req.auth.tenantId]);
  if (rt.rows.length === 0) return res.status(404).json({ error: 'rota nao encontrada' });
  const r = await db.query(
    `SELECT s.id, s.name, COALESCE(sc.name, s.school_name) AS school_name, rs.position
       FROM route_students rs
       JOIN students s ON s.id = rs.student_id
       LEFT JOIN schools sc ON sc.id = s.school_id
      WHERE rs.route_id = $1 AND rs.tenant_id = $2
      ORDER BY rs.position, s.name`,
    [req.params.id, req.auth.tenantId]
  );
  res.json(r.rows);
});

/* =========================================================================
 * FINANCEIRO — controle manual de mensalidade (sem gateway de pagamento)
 * ========================================================================= */

// Normaliza "YYYY-MM" (ou vazio) pro dia 1 daquele mes; usa o mes atual se
// nao vier nada.
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
    `SELECT p.student_id, p.status, p.amount
       FROM payments p
       JOIN student_guardians sg ON sg.student_id = p.student_id
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
                s.name || ' ' || CASE WHEN te.type='boarded' THEN 'embarcou na van' ELSE 'chegou / desceu' END AS message,
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
       ) x ORDER BY created_at DESC LIMIT $3`,
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
       ) x ORDER BY created_at DESC LIMIT $2`,
      [req.auth.tenantId, limit]
    );
  }
  res.json(r.rows);
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
  if (!student_id || !date) return res.status(400).json({ error: 'student_id e date obrigatorios' });
  if (!(await assertOwnsStudentOrAdmin(req, student_id))) {
    return res.status(403).json({ error: 'sem permissao' });
  }
  const r = await db.query(
    `INSERT INTO absences(tenant_id, student_id, date, notes, created_by)
     VALUES($1,$2,$3,$4,$5)
     ON CONFLICT (student_id, date) DO UPDATE SET notes=EXCLUDED.notes
     RETURNING *`,
    [req.auth.tenantId, student_id, date, notes || null, req.auth.userId]
  );
  res.json(r.rows[0]);
});

app.delete('/api/absences/:id', authMiddleware, async (req, res) => {
  const a = await db.query('SELECT student_id FROM absences WHERE id=$1 AND tenant_id=$2', [
    req.params.id, req.auth.tenantId,
  ]);
  if (a.rows.length === 0) return res.status(404).json({ error: 'falta nao encontrada' });
  if (!(await assertOwnsStudentOrAdmin(req, a.rows[0].student_id))) {
    return res.status(403).json({ error: 'sem permissao' });
  }
  await db.query('DELETE FROM absences WHERE id=$1', [req.params.id]);
  res.json({ ok: true });
});

// Faltas futuras dos proprios filhos do pai logado.
app.get('/api/absences/mine', authMiddleware, requireRole('parent'), async (req, res) => {
  const r = await db.query(
    `SELECT ab.id, ab.student_id, ab.date, ab.notes
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
    `SELECT ab.id, ab.student_id, s.name AS student_name, ab.notes
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
    `SELECT r.id, r.vehicle_id, r.driver_user_id, r.active,
            (SELECT count(*) FROM route_students rs WHERE rs.route_id=r.id) AS student_count
       FROM routes r WHERE r.id=$1 AND r.tenant_id=$2`,
    [route_id, req.auth.tenantId]
  );
  if (rt.rows.length === 0) return res.status(404).json({ error: 'rota nao encontrada' });
  if (!rt.rows[0].active) return res.status(409).json({ error: 'rota inativa' });
  if (Number(rt.rows[0].student_count) === 0) {
    return res.status(409).json({ error: 'rota sem alunos vinculados' });
  }
  if (req.auth.role === 'driver' && rt.rows[0].driver_user_id && rt.rows[0].driver_user_id !== req.auth.userId) {
    return res.status(403).json({ error: 'rota atribuida a outro motorista' });
  }

  // Por padrao usa o veiculo da rota; se vier vehicle_id explicito (troca
  // pontual, ex.: van quebrou), confirma que pertence ao tenant.
  let tripVehicleId = rt.rows[0].vehicle_id;
  if (vehicle_id) {
    const v = await db.query('SELECT id FROM vehicles WHERE id=$1 AND tenant_id=$2', [vehicle_id, req.auth.tenantId]);
    if (v.rows.length === 0) return res.status(404).json({ error: 'veiculo nao encontrado' });
    tripVehicleId = vehicle_id;
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
      WHERE rs.route_id = $1`,
    [route_id]
  )
    .then((parents) =>
      push.sendToUsers(
        parents.rows.map((p) => p.guardian_user_id),
        'VaiEscolar',
        'A van iniciou a rota',
        { type: 'trip_started', tripId }
      )
    )
    .catch((e) => console.error('[push] falha ao notificar inicio de rota', e.message));

  res.json({ tripId });
});

// Motorista so finaliza a propria viagem; admin finaliza qualquer uma do tenant.
app.post('/api/trips/:id/finish', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
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
            s.id AS student_id, s.name AS student_name
       FROM trips t
       JOIN routes r ON r.id = t.route_id
       JOIN route_students rs ON rs.route_id = t.route_id
       JOIN students s ON s.id = rs.student_id
       JOIN student_guardians sg ON sg.student_id = s.id
      WHERE t.tenant_id = $1
        AND t.status = 'active'
        AND sg.guardian_user_id = $2
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
            (SELECT te.type FROM trip_events te
              WHERE te.trip_id = $1 AND te.student_id = s.id
              ORDER BY te.at DESC LIMIT 1) AS last_status,
            (ab.id IS NOT NULL) AS absent,
            EXISTS(SELECT 1 FROM trip_alerts ta
                    WHERE ta.trip_id=$1 AND ta.student_id=s.id
                      AND ta.type='approaching_5min') AS approaching_alert_sent
       FROM trips t
       JOIN route_students rs ON rs.route_id = t.route_id
       JOIN students s ON s.id = rs.student_id
       LEFT JOIN absences ab ON ab.student_id = s.id AND ab.date = t.started_at::date
      WHERE t.id = $1 AND t.tenant_id = $2
      ORDER BY rs.position, s.name`,
    [req.params.id, req.auth.tenantId]
  );
  res.json(r.rows);
});

// Alerta automatico calculado pelo app do motorista a partir do GPS e da
// proxima parada na ordem da rota. O banco impede envio duplicado.
app.post('/api/trips/:id/students/:studentId/approaching', authMiddleware, requireRole('driver', 'admin'), async (req, res) => {
  const check = await db.query(
    `SELECT s.name
       FROM trips t
       JOIN route_students rs ON rs.route_id=t.route_id
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
  let last = null;
  for (const p of items) {
    const recordedAt = p.recorded_at || new Date().toISOString();
    await db.query(
      `INSERT INTO locations(tenant_id, trip_id, lat, lng, speed, heading, accuracy, recorded_at)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,
      [tenantId, tripId, p.lat, p.lng, p.speed ?? null, p.heading ?? null, p.accuracy ?? null, recordedAt]
    );
    last = { lat: p.lat, lng: p.lng, speed: p.speed ?? null, heading: p.heading ?? null, recorded_at: recordedAt };
  }

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
  const { student_id, type, lat, lng } = req.body;
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
    `INSERT INTO trip_events(tenant_id, trip_id, student_id, type, lat, lng)
     VALUES($1,$2,$3,$4,$5,$6) RETURNING *`,
    [req.auth.tenantId, req.params.id, student_id, type, lat ?? null, lng ?? null]
  );
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
      const hh = String(when.getHours()).padStart(2, '0');
      const mm = String(when.getMinutes()).padStart(2, '0');
      const action = type === 'boarded' ? 'embarcou na van' : 'chegou / desceu';
      return push.sendToUsers(
        info.rows.map((row) => row.guardian_user_id),
        'VaiEscolar',
        `${studentName} ${action} as ${hh}:${mm}`,
        { type: 'trip_event', tripId: req.params.id, eventType: type, studentId: student_id }
      );
    })
    .catch((e) => console.error('[push] falha ao notificar evento', e.message));

  res.json(r.rows[0]);
});

// Eventos (embarque/desembarque) de uma viagem, em ordem cronologica —
// usado pela tela "Timeline do dia" do app dos pais.
app.get('/api/trips/:id/events', authMiddleware, requireRole('parent'), async (req, res) => {
  const allowed = await parentCanWatch(req.auth.tenantId, req.auth.userId, req.params.id);
  if (!allowed) return res.status(403).json({ error: 'sem permissao' });
  const r = await db.query(
    `SELECT te.id, te.type, te.at, s.name AS student_name
       FROM trip_events te
       JOIN students s ON s.id = te.student_id
      WHERE te.trip_id = $1 AND te.tenant_id = $2
      ORDER BY te.at ASC`,
    [req.params.id, req.auth.tenantId]
  );
  res.json(r.rows);
});

/* =========================================================================
 * WEBSOCKET — pais acompanham uma viagem em tempo real
 * ========================================================================= */
const server = http.createServer(app);
const wss = new WebSocketServer({ noServer: true });

// Um pai so pode assinar viagens de rotas em que seu filho esta matriculado.
async function parentCanWatch(tenantId, userId, tripId) {
  const r = await db.query(
    `SELECT 1
       FROM trips t
       JOIN route_students rs ON rs.route_id = t.route_id
       JOIN student_guardians sg ON sg.student_id = rs.student_id
      WHERE t.id = $1
        AND t.tenant_id = $2
        AND sg.guardian_user_id = $3
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
  const auth = await verifyToken(query.token);
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
      const trip = await db.query('SELECT 1 FROM trips WHERE id=$1 AND tenant_id=$2', [tripId, auth.tenantId]);
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
  server.listen(PORT, () => console.log(`API em http://localhost:${PORT}`));
}
