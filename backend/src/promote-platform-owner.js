const { pool } = require('./db');

const email = String(process.argv[2] || '').trim().toLowerCase();
if (!email || !email.includes('@')) {
  console.error('Uso: node src/promote-platform-owner.js email@dominio.com');
  process.exit(1);
}

(async () => {
  const result = await pool.query(
    `UPDATE users SET is_platform_owner=true
      WHERE lower(email)=$1 AND role='admin' RETURNING id,email`, [email]
  );
  if (!result.rows.length) throw new Error('administrador nao encontrado');
  console.log(`Administrador global habilitado: ${result.rows[0].email}`);
  await pool.end();
})().catch(async (error) => {
  console.error(error.message);
  await pool.end().catch(() => {});
  process.exit(1);
});
