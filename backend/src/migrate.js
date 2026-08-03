const fs = require('fs');
const path = require('path');
const { pool } = require('./db');

(async () => {
  const sql = fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8');
  await pool.query(sql);
  console.log('Migrations aplicadas com sucesso.');
  await pool.end();
})().catch((e) => {
  console.error('Erro na migration:', e);
  process.exit(1);
});
