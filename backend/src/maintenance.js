const db = require('./db');

const GPS_CLEANUP_LOCK = 0x56414945; // "VAIE"; evita dois servidores limpando juntos.

async function cleanupGpsHistory() {
  const retentionDays = Math.min(90, Math.max(1, Number(process.env.GPS_RETENTION_DAYS) || 30));
  const batchSize = Math.min(50000, Math.max(1000,
    Number(process.env.GPS_CLEANUP_BATCH_SIZE || process.env.GPS_CLEANUP_BATCH) || 10000));
  const client = await db.pool.connect();
  let deleted = 0;
  const startedAt = Date.now();
  try {
    const lock = await client.query('SELECT pg_try_advisory_lock($1) acquired', [GPS_CLEANUP_LOCK]);
    if (!lock.rows[0].acquired) return { skipped: true, deleted: 0 };
    while (true) {
      const result = await client.query(
        `DELETE FROM locations WHERE id IN (
           SELECT id FROM locations
            WHERE recorded_at < now() - ($1::int * interval '1 day')
            ORDER BY recorded_at LIMIT $2
         )`, [retentionDays, batchSize]
      );
      deleted += result.rowCount;
      if (result.rowCount < batchSize) break;
    }
    await client.query(`INSERT INTO platform_maintenance_runs(job_name,status,affected_rows,duration_ms,detail)
      VALUES('gps_retention','success',$1,$2,$3)`,
    [deleted, Date.now() - startedAt, { retentionDays, batchSize }]);
    return { skipped: false, deleted, retentionDays };
  } catch (error) {
    await client.query(`INSERT INTO platform_maintenance_runs(job_name,status,affected_rows,duration_ms,detail)
      VALUES('gps_retention','failed',$1,$2,$3)`,
    [deleted, Date.now() - startedAt, { error: error.message }]).catch(() => {});
    throw error;
  } finally {
    await client.query('SELECT pg_advisory_unlock($1)', [GPS_CLEANUP_LOCK]).catch(() => {});
    client.release();
  }
}

function startMaintenance() {
  const run = () => cleanupGpsHistory()
    .then((result) => console.log('[manutencao GPS]', result))
    .catch((error) => console.error('[manutencao GPS]', error.message));
  const first = setTimeout(run, 60000);
  const daily = setInterval(run, 24 * 60 * 60 * 1000);
  first.unref();
  daily.unref();
  return { first, daily };
}

module.exports = { cleanupGpsHistory, startMaintenance };
