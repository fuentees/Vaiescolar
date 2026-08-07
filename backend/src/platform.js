const express = require('express');
const crypto = require('crypto');
const { authMiddleware } = require('./auth');

module.exports = function createPlatformRouter({ db, push, hub }) {
  const router = express.Router();

  async function requirePlatformOwner(req, res, next) {
    const found = await db.query(
      'SELECT is_platform_owner FROM users WHERE id=$1 AND is_platform_owner=true',
      [req.auth.userId]
    );
    if (!found.rows.length) return res.status(403).json({ error: 'acesso exclusivo do administrador global' });
    next();
  }

  async function audit(req, action, entityType, entityId, tenantId, detail) {
    await db.query(
      `INSERT INTO platform_audit_log(actor_user_id,action,entity_type,entity_id,tenant_id,detail,ip,user_agent)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,
      [req.auth.userId, action, entityType, entityId ? String(entityId) : null,
        tenantId || null, detail || null, req.ip, req.get('user-agent') || null]
    );
  }

  router.use(authMiddleware, requirePlatformOwner);

  router.get('/me', async (req, res) => {
    const result = await db.query('SELECT id,name,email FROM users WHERE id=$1', [req.auth.userId]);
    res.json(result.rows[0]);
  });

  router.get('/dashboard', async (_req, res) => {
    const [tenants, people, finance, trips, storage, alerts] = await Promise.all([
      db.query(`SELECT count(*)::int total,
        count(*) FILTER(WHERE status='active')::int active,
        count(*) FILTER(WHERE status='trial')::int trial,
        count(*) FILTER(WHERE status IN ('past_due','suspended'))::int attention,
        count(*) FILTER(WHERE created_at>=date_trunc('month',now()))::int new_this_month
        FROM tenants`),
      db.query(`SELECT
        (SELECT count(*) FROM students)::int students,
        (SELECT count(*) FROM users WHERE role='parent')::int guardians,
        (SELECT count(*) FROM users WHERE role IN ('admin','driver'))::int staff,
        (SELECT count(*) FROM vehicles)::int vehicles,
        (SELECT count(*) FROM schools)::int schools`),
      db.query(`SELECT
        (SELECT COALESCE(sum(amount),0) FROM platform_invoices WHERE status='paid' AND paid_at>=date_trunc('month',now()))::numeric revenue_month,
        (SELECT COALESCE(sum(amount),0) FROM platform_invoices WHERE status IN ('pending','overdue'))::numeric receivable,
        (SELECT count(*) FROM platform_invoices WHERE status='overdue')::int overdue_count,
        (SELECT COALESCE(sum(CASE WHEN s.billing_cycle='annual' THEN p.annual_price/12 ELSE p.monthly_price END),0)
           FROM platform_subscriptions s LEFT JOIN platform_plans p ON p.id=s.plan_id
          WHERE s.status IN ('active','trial'))::numeric mrr`),
      db.query(`SELECT count(*) FILTER(WHERE started_at>=date_trunc('month',now()))::int trips_month,
        count(*) FILTER(WHERE status='active')::int active FROM trips`),
      db.query(`SELECT COALESCE(sum(size_bytes),0)::bigint bytes FROM platform_storage_objects WHERE deleted_at IS NULL`),
      db.query(`SELECT
        count(*) FILTER(WHERE status IN ('open','in_progress') AND priority IN ('high','critical'))::int critical_tickets,
        count(*) FILTER(WHERE status IN ('open','in_progress','waiting'))::int open_tickets
        FROM platform_support_tickets`),
    ]);
    res.json({ tenants: tenants.rows[0], people: people.rows[0], finance: finance.rows[0],
      trips: trips.rows[0], storage: storage.rows[0], alerts: alerts.rows[0], generatedAt: new Date() });
  });

  router.get('/tenants', async (req, res) => {
    const search = String(req.query.search || '').trim();
    const status = String(req.query.status || '').trim();
    const result = await db.query(
      `SELECT t.id,t.name,t.plan,t.status,t.created_at,t.trial_ends_at,t.suspended_at,
              t.legal_email,t.legal_phone,p.name plan_name,p.monthly_price,
              ps.status subscription_status,ps.current_period_end,
              (SELECT count(*) FROM students s WHERE s.tenant_id=t.id)::int students,
              (SELECT count(*) FROM users u WHERE u.tenant_id=t.id)::int users,
              (SELECT count(*) FROM vehicles v WHERE v.tenant_id=t.id)::int vehicles,
              (SELECT count(*) FROM schools sc WHERE sc.tenant_id=t.id)::int schools,
              COALESCE((SELECT sum(size_bytes) FROM platform_storage_objects so
                WHERE so.tenant_id=t.id AND so.deleted_at IS NULL),0)::bigint storage_bytes,
              p.storage_limit_mb
         FROM tenants t LEFT JOIN platform_subscriptions ps ON ps.tenant_id=t.id
         LEFT JOIN platform_plans p ON p.id=ps.plan_id
        WHERE ($1='' OR t.name ILIKE '%'||$1||'%' OR t.legal_email ILIKE '%'||$1||'%')
          AND ($2='' OR t.status=$2)
        ORDER BY t.created_at DESC LIMIT 500`, [search, status]
    );
    res.json(result.rows);
  });

  router.get('/tenants/:id', async (req, res) => {
    const result = await db.query(
      `SELECT t.*,ps.id subscription_id,ps.status subscription_status,ps.billing_cycle,
        ps.current_period_start,ps.current_period_end,ps.trial_ends_at subscription_trial_ends_at,
        ps.overrides,p.id plan_id,p.name plan_name,p.monthly_price,p.annual_price,
        p.max_students,p.max_staff,p.max_vehicles,p.max_schools,p.storage_limit_mb,p.features
       FROM tenants t LEFT JOIN platform_subscriptions ps ON ps.tenant_id=t.id
       LEFT JOIN platform_plans p ON p.id=ps.plan_id WHERE t.id=$1`, [req.params.id]
    );
    if (!result.rows.length) return res.status(404).json({ error: 'transportadora nao encontrada' });
    const [counts, invoices, storage] = await Promise.all([
      db.query(`SELECT (SELECT count(*) FROM students WHERE tenant_id=$1)::int students,
        (SELECT count(*) FROM users WHERE tenant_id=$1)::int users,
        (SELECT count(*) FROM vehicles WHERE tenant_id=$1)::int vehicles,
        (SELECT count(*) FROM schools WHERE tenant_id=$1)::int schools,
        (SELECT count(*) FROM trips WHERE tenant_id=$1)::int trips`, [req.params.id]),
      db.query('SELECT * FROM platform_invoices WHERE tenant_id=$1 ORDER BY created_at DESC LIMIT 20', [req.params.id]),
      db.query(`SELECT category,count(*)::int objects,COALESCE(sum(size_bytes),0)::bigint bytes
        FROM platform_storage_objects WHERE tenant_id=$1 AND deleted_at IS NULL GROUP BY category`, [req.params.id]),
    ]);
    res.json({ ...result.rows[0], counts: counts.rows[0], invoices: invoices.rows, storage: storage.rows });
  });

  router.put('/tenants/:id', async (req, res) => {
    const status = String(req.body.status || 'active');
    if (!['trial','active','past_due','suspended','cancelled'].includes(status)) return res.status(400).json({ error: 'status invalido' });
    const result = await db.query(
      `UPDATE tenants SET name=$1,status=$2,legal_email=$3,legal_phone=$4,
        trial_ends_at=$5,suspended_at=CASE WHEN $2='suspended' THEN COALESCE(suspended_at,now()) ELSE NULL END,
        cancellation_scheduled_at=$6,retention_until=$7 WHERE id=$8 RETURNING *`,
      [String(req.body.name || '').trim(), status, req.body.legal_email || null, req.body.legal_phone || null,
        req.body.trial_ends_at || null, req.body.cancellation_scheduled_at || null,
        req.body.retention_until || null, req.params.id]
    );
    if (!result.rows.length) return res.status(404).json({ error: 'transportadora nao encontrada' });
    await audit(req, 'atualizar_transportadora', 'tenant', req.params.id, req.params.id, { status, name: result.rows[0].name });
    res.json(result.rows[0]);
  });

  router.put('/tenants/:id/subscription', async (req, res) => {
    const plan = await db.query('SELECT id,code FROM platform_plans WHERE id=$1 AND active=true', [req.body.plan_id]);
    if (!plan.rows.length) return res.status(400).json({ error: 'plano invalido' });
    const cycle = req.body.billing_cycle === 'annual' ? 'annual' : 'monthly';
    const status = ['trial','active','past_due','paused','cancelled'].includes(req.body.status) ? req.body.status : 'active';
    const result = await db.query(
      `INSERT INTO platform_subscriptions(tenant_id,plan_id,status,billing_cycle,current_period_start,current_period_end,trial_ends_at,overrides)
       VALUES($1,$2,$3,$4,now(),now()+CASE WHEN $4='annual' THEN interval '1 year' ELSE interval '1 month' END,$5,$6)
       ON CONFLICT(tenant_id) DO UPDATE SET plan_id=EXCLUDED.plan_id,status=EXCLUDED.status,
         billing_cycle=EXCLUDED.billing_cycle,current_period_end=EXCLUDED.current_period_end,
         trial_ends_at=EXCLUDED.trial_ends_at,overrides=EXCLUDED.overrides,updated_at=now() RETURNING *`,
      [req.params.id, plan.rows[0].id, status, cycle, req.body.trial_ends_at || null, req.body.overrides || {}]
    );
    await db.query('UPDATE tenants SET plan=$1,status=$2 WHERE id=$3',
      [plan.rows[0].code, status === 'paused' ? 'suspended' : status === 'cancelled' ? 'cancelled' : status, req.params.id]);
    await audit(req, 'alterar_assinatura', 'subscription', result.rows[0].id, req.params.id, { plan: plan.rows[0].code, cycle, status });
    res.json(result.rows[0]);
  });

  router.get('/plans', async (_req, res) => {
    const result = await db.query(`SELECT p.*,(SELECT count(*) FROM platform_subscriptions s WHERE s.plan_id=p.id)::int subscribers
      FROM platform_plans p ORDER BY monthly_price`);
    res.json(result.rows);
  });

  router.post('/plans', async (req, res) => {
    const fields = ['code','name','monthly_price','annual_price','max_students','max_staff','max_vehicles','max_schools','storage_limit_mb','history_months'];
    if (!String(req.body.code || '').match(/^[a-z0-9_-]{2,30}$/) || !String(req.body.name || '').trim()) return res.status(400).json({ error: 'codigo ou nome invalido' });
    const values = fields.map((key) => req.body[key]);
    const result = await db.query(`INSERT INTO platform_plans(${fields.join(',')},features)
      VALUES(${fields.map((_, i) => `$${i + 1}`).join(',')},$${fields.length + 1}) RETURNING *`, [...values, req.body.features || {}]);
    await audit(req, 'criar_plano', 'plan', result.rows[0].id, null, { code: result.rows[0].code });
    res.status(201).json(result.rows[0]);
  });

  router.put('/plans/:id', async (req, res) => {
    const result = await db.query(`UPDATE platform_plans SET name=$1,monthly_price=$2,annual_price=$3,
      max_students=$4,max_staff=$5,max_vehicles=$6,max_schools=$7,storage_limit_mb=$8,
      history_months=$9,features=$10,active=$11,updated_at=now() WHERE id=$12 RETURNING *`,
      [req.body.name, req.body.monthly_price, req.body.annual_price || null, req.body.max_students,
        req.body.max_staff, req.body.max_vehicles, req.body.max_schools, req.body.storage_limit_mb,
        req.body.history_months, req.body.features || {}, req.body.active !== false, req.params.id]);
    if (!result.rows.length) return res.status(404).json({ error: 'plano nao encontrado' });
    await audit(req, 'atualizar_plano', 'plan', req.params.id, null, { name: result.rows[0].name });
    res.json(result.rows[0]);
  });

  router.get('/invoices', async (req, res) => {
    const status = String(req.query.status || '');
    const result = await db.query(`SELECT i.*,t.name tenant_name FROM platform_invoices i JOIN tenants t ON t.id=i.tenant_id
      WHERE ($1='' OR i.status=$1) ORDER BY i.created_at DESC LIMIT 500`, [status]);
    res.json(result.rows);
  });

  router.post('/invoices', async (req, res) => {
    const amount = Number(req.body.amount);
    if (!req.body.tenant_id || !Number.isFinite(amount) || amount < 0) return res.status(400).json({ error: 'transportadora ou valor invalido' });
    const reference = crypto.randomBytes(18).toString('base64url');
    const publicBase = process.env.PUBLIC_BASE_URL || `${req.protocol}://${req.get('host')}`;
    const paymentUrl = String(req.body.payment_url || '').trim() || `${publicBase}/pay/${reference}`;
    const result = await db.query(`INSERT INTO platform_invoices(tenant_id,subscription_id,amount,status,due_at,description,provider,payment_url,external_reference)
      SELECT $1,id,$2,'pending',$3,$4,$5,$6,$7 FROM platform_subscriptions WHERE tenant_id=$1 RETURNING *`,
      [req.body.tenant_id, amount, req.body.due_at || null, String(req.body.description || 'Assinatura TECO'),
        req.body.provider || 'manual', paymentUrl, reference]);
    if (!result.rows.length) return res.status(409).json({ error: 'transportadora sem assinatura configurada' });
    await audit(req, 'gerar_fatura', 'invoice', result.rows[0].id, req.body.tenant_id, { amount, paymentUrl });
    res.status(201).json(result.rows[0]);
  });

  router.post('/invoices/:id/status', async (req, res) => {
    const status = String(req.body.status || '');
    if (!['pending','paid','overdue','cancelled','refunded'].includes(status)) return res.status(400).json({ error: 'status invalido' });
    const result = await db.query(`UPDATE platform_invoices SET status=$1,
      paid_at=CASE WHEN $1='paid' THEN COALESCE(paid_at,now()) ELSE paid_at END,updated_at=now()
      WHERE id=$2 RETURNING *`, [status, req.params.id]);
    if (!result.rows.length) return res.status(404).json({ error: 'fatura nao encontrada' });
    await audit(req, 'alterar_fatura', 'invoice', req.params.id, result.rows[0].tenant_id, { status });
    res.json(result.rows[0]);
  });

  router.get('/storage', async (_req, res) => {
    const result = await db.query(`SELECT t.id,t.name,p.storage_limit_mb,
      COALESCE(sum(o.size_bytes) FILTER(WHERE o.deleted_at IS NULL),0)::bigint used_bytes,
      count(o.id) FILTER(WHERE o.deleted_at IS NULL)::int objects
      FROM tenants t LEFT JOIN platform_subscriptions s ON s.tenant_id=t.id
      LEFT JOIN platform_plans p ON p.id=s.plan_id LEFT JOIN platform_storage_objects o ON o.tenant_id=t.id
      GROUP BY t.id,t.name,p.storage_limit_mb ORDER BY used_bytes DESC`);
    res.json(result.rows);
  });

  router.get('/support', async (req, res) => {
    const status = String(req.query.status || '');
    const result = await db.query(`SELECT st.*,t.name tenant_name,u.name assigned_name FROM platform_support_tickets st
      LEFT JOIN tenants t ON t.id=st.tenant_id LEFT JOIN users u ON u.id=st.assigned_to
      WHERE ($1='' OR st.status=$1) ORDER BY CASE st.priority WHEN 'critical' THEN 1 WHEN 'high' THEN 2 ELSE 3 END,st.created_at DESC`, [status]);
    res.json(result.rows);
  });

  router.post('/support', async (req, res) => {
    if (!String(req.body.subject || '').trim() || String(req.body.description || '').trim().length < 5) return res.status(400).json({ error: 'assunto e descricao obrigatorios' });
    const result = await db.query(`INSERT INTO platform_support_tickets(tenant_id,subject,description,priority,created_by)
      VALUES($1,$2,$3,$4,$5) RETURNING *`, [req.body.tenant_id || null, req.body.subject.trim(), req.body.description.trim(),
      ['low','normal','high','critical'].includes(req.body.priority) ? req.body.priority : 'normal', req.auth.userId]);
    await audit(req, 'abrir_chamado', 'support_ticket', result.rows[0].id, req.body.tenant_id, { subject: req.body.subject });
    res.status(201).json(result.rows[0]);
  });

  router.put('/support/:id', async (req, res) => {
    const status = ['open','in_progress','waiting','resolved','closed'].includes(req.body.status) ? req.body.status : 'open';
    const result = await db.query(`UPDATE platform_support_tickets SET status=$1,priority=$2,assigned_to=$3,
      updated_at=now(),resolved_at=CASE WHEN $1 IN ('resolved','closed') THEN now() ELSE NULL END WHERE id=$4 RETURNING *`,
      [status, req.body.priority || 'normal', req.body.assigned_to || null, req.params.id]);
    if (!result.rows.length) return res.status(404).json({ error: 'chamado nao encontrado' });
    await audit(req, 'atualizar_chamado', 'support_ticket', req.params.id, result.rows[0].tenant_id, { status });
    res.json(result.rows[0]);
  });

  router.get('/announcements', async (_req, res) => {
    const result = await db.query('SELECT * FROM platform_announcements ORDER BY created_at DESC LIMIT 200');
    res.json(result.rows);
  });

  router.post('/announcements', async (req, res) => {
    if (!String(req.body.title || '').trim() || !String(req.body.message || '').trim()) return res.status(400).json({ error: 'titulo e mensagem obrigatorios' });
    const audience = req.body.audience || {};
    const sendNow = req.body.send_now === true;
    const result = await db.query(`INSERT INTO platform_announcements(title,message,audience,status,scheduled_at,sent_at,created_by)
      VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *`, [req.body.title.trim(), req.body.message.trim(), audience,
      sendNow ? 'sent' : req.body.scheduled_at ? 'scheduled' : 'draft', req.body.scheduled_at || null, sendNow ? new Date() : null, req.auth.userId]);
    if (sendNow) {
      const users = await db.query(`SELECT u.id FROM users u JOIN tenants t ON t.id=u.tenant_id
        WHERE u.role IN ('admin','driver') AND ($1::text IS NULL OR t.status=$1)`, [audience.tenant_status || null]);
      push.sendToUsers(users.rows.map((row) => row.id), req.body.title.trim(), req.body.message.trim(),
        { type: 'platform_announcement', announcementId: result.rows[0].id }).catch(() => {});
    }
    await audit(req, sendNow ? 'enviar_comunicado' : 'criar_comunicado', 'announcement', result.rows[0].id, null, { audience });
    res.status(201).json(result.rows[0]);
  });

  router.get('/audit', async (req, res) => {
    const result = await db.query(`SELECT a.*,u.name actor_name,t.name tenant_name FROM platform_audit_log a
      LEFT JOIN users u ON u.id=a.actor_user_id LEFT JOIN tenants t ON t.id=a.tenant_id
      ORDER BY a.created_at DESC LIMIT $1`, [Math.min(Number(req.query.limit) || 200, 500)]);
    res.json(result.rows);
  });

  router.get('/health', async (_req, res) => {
    const started = Date.now();
    await db.query('SELECT 1');
    const [capacity, maintenance] = await Promise.all([
      db.query(`SELECT
        (SELECT count(*) FROM trips WHERE status='active')::int active_trips,
        (SELECT count(*) FROM locations WHERE recorded_at>=now()-interval '24 hours')::int gps_points_24h,
        (SELECT count(*) FROM users WHERE last_login_at>=now()-interval '24 hours')::int active_users_24h`),
      db.query(`SELECT job_name,status,affected_rows,duration_ms,detail,created_at
        FROM platform_maintenance_runs ORDER BY created_at DESC LIMIT 5`),
    ]);
    res.json({ api: 'online', database: 'online', pushNotifications: push.isConfigured() ? 'configured' : 'not_configured',
      billingProvider: process.env.PLATFORM_BILLING_PROVIDER || 'manual', responseMs: Date.now() - started,
      node: process.version, checkedAt: new Date(), databasePool: db.stats(), websocket: hub.stats(),
      capacity: capacity.rows[0], maintenance: maintenance.rows });
  });

  return router;
};
