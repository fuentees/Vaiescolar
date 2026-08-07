const { Pool } = require('pg');
require('dotenv').config();

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: Math.min(50, Math.max(2, Number(process.env.DB_POOL_MAX) || 10)),
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 10000,
  statement_timeout: Math.min(60000, Math.max(5000, Number(process.env.DB_STATEMENT_TIMEOUT_MS) || 30000)),
  application_name: 'vaiescolar-api',
});

module.exports = {
  query: (text, params) => pool.query(text, params),
  pool,
  stats: () => ({
    total: pool.totalCount,
    idle: pool.idleCount,
    waiting: pool.waitingCount,
    max: pool.options.max,
  }),
};
