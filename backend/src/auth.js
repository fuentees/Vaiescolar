const jwt = require('jsonwebtoken');
require('dotenv').config();
const db = require('./db');

const SECRET = process.env.JWT_SECRET || 'dev-secret';

// Em producao, um JWT_SECRET ausente/fraco deixa todo token forjavel --
// recusa subir em vez de rodar inseguro silenciosamente.
if (process.env.NODE_ENV === 'production') {
  if (!process.env.JWT_SECRET || process.env.JWT_SECRET === 'dev-secret' || process.env.JWT_SECRET.length < 16) {
    throw new Error('JWT_SECRET ausente ou fraco (minimo 16 caracteres) -- obrigatorio em producao (NODE_ENV=production).');
  }
}

function sign(payload) {
  return jwt.sign(payload, SECRET, { expiresIn: '30d' });
}

// Confere a assinatura/expiracao do JWT e que a "versao" do token ainda bate
// com a do usuario no banco -- trocar/resetar a senha incrementa
// token_version, invalidando na hora qualquer token de 30 dias emitido antes
// disso (sem precisar de uma blacklist separada).
async function checkTokenVersion(decoded) {
  const r = await db.query('SELECT token_version FROM users WHERE id=$1 AND tenant_id=$2', [
    decoded.userId, decoded.tenantId,
  ]);
  if (r.rows.length === 0) return false;
  return r.rows[0].token_version === decoded.tokenVersion;
}

// Middleware: valida o Bearer token e injeta { userId, tenantId, role } em req.auth
async function authMiddleware(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'sem token' });
  try {
    const decoded = jwt.verify(token, SECRET);
    if (!(await checkTokenVersion(decoded))) {
      return res.status(401).json({ error: 'token invalido' });
    }
    req.auth = decoded;
    next();
  } catch {
    return res.status(401).json({ error: 'token invalido' });
  }
}

// Extrai token de query string (usado no handshake do WebSocket).
async function verifyToken(token) {
  try {
    const decoded = jwt.verify(token, SECRET);
    if (!(await checkTokenVersion(decoded))) return null;
    return decoded;
  } catch {
    return null;
  }
}

function requireRole(...roles) {
  return (req, res, next) => {
    if (!roles.includes(req.auth.role)) {
      return res.status(403).json({ error: 'sem permissao' });
    }
    next();
  };
}

module.exports = { sign, authMiddleware, verifyToken, requireRole, SECRET };
