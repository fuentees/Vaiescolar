-- Extensao para UUIDs
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Operador (motorista autonomo ou empresa). Raiz do isolamento multi-tenant.
CREATE TABLE IF NOT EXISTS tenants (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL,
  plan       TEXT NOT NULL DEFAULT 'basic',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Usuarios: motoristas, pais/responsaveis e admin do tenant.
CREATE TABLE IF NOT EXISTS users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  role          TEXT NOT NULL CHECK (role IN ('admin','driver','parent')),
  name          TEXT NOT NULL,
  email         TEXT NOT NULL,
  phone         TEXT,
  password_hash TEXT NOT NULL,
  fcm_token     TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, email)
);
CREATE INDEX IF NOT EXISTS idx_users_tenant ON users(tenant_id);

-- Email globalmente unico: o login nao recebe tenantId de nenhum dos apps,
-- entao "unico so por tenant" deixava o login ambiguo se dois tenants
-- tivessem o mesmo e-mail (`SELECT ... LIMIT 1` sem ORDER BY podia pegar o
-- usuario errado). Migracao segura -- checada antes: sem duplicatas hoje.
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_tenant_id_email_key;
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_email_key;
ALTER TABLE users ADD CONSTRAINT users_email_key UNIQUE (email);

-- Versao do token: incrementada ao trocar/resetar senha, invalida na hora
-- os tokens de 30 dias emitidos antes da troca (sem precisar de blacklist).
ALTER TABLE users ADD COLUMN IF NOT EXISTS token_version INT NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS notifications_cleared_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS vehicles (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  plate      TEXT NOT NULL,
  model      TEXT,
  capacity   INT DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_vehicles_tenant ON vehicles(tenant_id);

-- Escolas: cadastro proprio (antes "escola" era so um texto livre no aluno).
CREATE TABLE IF NOT EXISTS schools (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  address    TEXT,
  phone      TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, name)
);
CREATE INDEX IF NOT EXISTS idx_schools_tenant ON schools(tenant_id);
ALTER TABLE schools ADD COLUMN IF NOT EXISTS postal_code TEXT;
ALTER TABLE schools ADD COLUMN IF NOT EXISTS street TEXT;
ALTER TABLE schools ADD COLUMN IF NOT EXISTS number TEXT;
ALTER TABLE schools ADD COLUMN IF NOT EXISTS complement TEXT;
ALTER TABLE schools ADD COLUMN IF NOT EXISTS neighborhood TEXT;
ALTER TABLE schools ADD COLUMN IF NOT EXISTS city TEXT;
ALTER TABLE schools ADD COLUMN IF NOT EXISTS state CHAR(2);
ALTER TABLE schools ADD COLUMN IF NOT EXISTS lat DOUBLE PRECISION;
ALTER TABLE schools ADD COLUMN IF NOT EXISTS lng DOUBLE PRECISION;

CREATE TABLE IF NOT EXISTS students (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  school_name  TEXT,
  home_address TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_students_tenant ON students(tenant_id);

-- school_name (texto livre) fica mantido so por compatibilidade com dados
-- antigos -- o cliente passa a mandar sempre school_id daqui pra frente.
ALTER TABLE students ADD COLUMN IF NOT EXISTS school_id UUID REFERENCES schools(id) ON DELETE SET NULL;
ALTER TABLE students ADD COLUMN IF NOT EXISTS monthly_fee NUMERIC(10,2);
ALTER TABLE students ADD COLUMN IF NOT EXISTS home_postal_code TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS home_street TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS home_number TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS home_complement TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS home_neighborhood TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS home_city TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS home_state CHAR(2);
ALTER TABLE students ADD COLUMN IF NOT EXISTS home_lat DOUBLE PRECISION;
ALTER TABLE students ADD COLUMN IF NOT EXISTS home_lng DOUBLE PRECISION;

-- Migra os school_name de texto livre ja existentes para registros reais em
-- schools (idempotente: so roda pra quem ainda nao tem school_id).
INSERT INTO schools (tenant_id, name)
  SELECT DISTINCT tenant_id, school_name FROM students
   WHERE school_name IS NOT NULL AND school_id IS NULL
  ON CONFLICT DO NOTHING;
UPDATE students s SET school_id = sc.id
  FROM schools sc
 WHERE s.school_id IS NULL AND s.school_name = sc.name AND s.tenant_id = sc.tenant_id;

-- Vinculo aluno <-> responsavel (um pai pode ter varios filhos e vice-versa).
CREATE TABLE IF NOT EXISTS student_guardians (
  tenant_id        UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  student_id       UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  guardian_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  relationship     TEXT NOT NULL DEFAULT 'Responsavel legal',
  PRIMARY KEY (student_id, guardian_user_id)
);
ALTER TABLE student_guardians ADD COLUMN IF NOT EXISTS relationship TEXT NOT NULL DEFAULT 'Responsavel legal';

-- Convites por codigo: como o pai entra no sistema sem o motorista precisar
-- cadastrar o email de ninguem. O admin gera um codigo para o aluno; o pai
-- usa esse codigo para se auto-cadastrar (POST /api/auth/register-parent).
CREATE TABLE IF NOT EXISTS guardian_invites (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  student_id      UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  code            CHAR(6) NOT NULL UNIQUE,
  relationship    TEXT NOT NULL DEFAULT 'Responsavel legal',
  expires_at      TIMESTAMPTZ NOT NULL,
  used_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE guardian_invites ADD COLUMN IF NOT EXISTS relationship TEXT NOT NULL DEFAULT 'Responsavel legal';
CREATE INDEX IF NOT EXISTS idx_invites_tenant ON guardian_invites(tenant_id);
CREATE INDEX IF NOT EXISTS idx_invites_code ON guardian_invites(code);

CREATE TABLE IF NOT EXISTS routes (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name           TEXT NOT NULL,
  vehicle_id     UUID REFERENCES vehicles(id) ON DELETE SET NULL,
  driver_user_id UUID REFERENCES users(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_routes_tenant ON routes(tenant_id);

CREATE TABLE IF NOT EXISTS route_students (
  tenant_id  UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  route_id   UUID NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
  student_id UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  PRIMARY KEY (route_id, student_id)
);
-- Ordem de embarque dentro da rota (quem pega primeiro). Alunos antigos
-- ficam todos com 0 (empate por nome); novos vinculos vao pro fim da fila.
ALTER TABLE route_students ADD COLUMN IF NOT EXISTS position INT NOT NULL DEFAULT 0;

-- Uma viagem concreta (ida ou volta) de uma rota, num dia.
CREATE TABLE IF NOT EXISTS trips (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  route_id       UUID NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
  driver_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  direction      TEXT NOT NULL CHECK (direction IN ('to_school','to_home')),
  status         TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','finished')),
  started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_trips_tenant ON trips(tenant_id);
CREATE INDEX IF NOT EXISTS idx_trips_active ON trips(tenant_id, status);
-- A verificacao no endpoint melhora a mensagem; este indice e a garantia
-- definitiva contra duas requisicoes simultaneas iniciarem duas viagens.
CREATE UNIQUE INDEX IF NOT EXISTS idx_trips_one_active_per_driver
  ON trips(driver_user_id) WHERE status = 'active';
-- Veiculo realmente usado nessa viagem -- por padrao o da rota, mas pode ser
-- trocado na hora de iniciar (motorista usando outra van naquele dia).
ALTER TABLE trips ADD COLUMN IF NOT EXISTS vehicle_id UUID REFERENCES vehicles(id) ON DELETE SET NULL;
ALTER TABLE trips ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;
ALTER TABLE trips ADD COLUMN IF NOT EXISTS cancellation_reason TEXT;
ALTER TABLE trips DROP CONSTRAINT IF EXISTS trips_status_check;
ALTER TABLE trips ADD CONSTRAINT trips_status_check CHECK (status IN ('active','finished','cancelled'));

-- Ocorrencias operacionais (atraso, pane, acidente etc.) comunicadas aos
-- responsaveis enquanto a viagem esta ativa.
CREATE TABLE IF NOT EXISTS trip_incidents (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  trip_id     UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  type        TEXT NOT NULL CHECK (type IN ('delay','breakdown','accident','student_missing','school_closed','other')),
  description TEXT,
  created_by  UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ
);
ALTER TABLE trip_incidents DROP CONSTRAINT IF EXISTS trip_incidents_type_check;
ALTER TABLE trip_incidents ADD CONSTRAINT trip_incidents_type_check
  CHECK (type IN ('delay','breakdown','accident','student_missing','school_closed','sos','other'));
CREATE INDEX IF NOT EXISTS idx_trip_incidents_trip ON trip_incidents(trip_id, created_at DESC);

-- Historico completo de posicoes (breadcrumb / auditoria).
CREATE TABLE IF NOT EXISTS locations (
  id           BIGSERIAL PRIMARY KEY,
  tenant_id    UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  trip_id      UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  lat          DOUBLE PRECISION NOT NULL,
  lng          DOUBLE PRECISION NOT NULL,
  speed        DOUBLE PRECISION,
  heading      DOUBLE PRECISION,
  accuracy     DOUBLE PRECISION,
  recorded_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_locations_trip ON locations(trip_id, recorded_at);

-- Ultima posicao conhecida por viagem (leitura rapida O(1)).
CREATE TABLE IF NOT EXISTS trip_last_location (
  trip_id     UUID PRIMARY KEY REFERENCES trips(id) ON DELETE CASCADE,
  tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  lat         DOUBLE PRECISION NOT NULL,
  lng         DOUBLE PRECISION NOT NULL,
  speed       DOUBLE PRECISION,
  heading     DOUBLE PRECISION,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Eventos de presenca (embarque/desembarque).
CREATE TABLE IF NOT EXISTS trip_events (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  trip_id     UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  student_id  UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  type        TEXT NOT NULL CHECK (type IN ('boarded','dropped')),
  lat         DOUBLE PRECISION,
  lng         DOUBLE PRECISION,
  at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_events_trip ON trip_events(trip_id, at);
ALTER TABLE trip_events DROP CONSTRAINT IF EXISTS trip_events_type_check;
ALTER TABLE trip_events ADD CONSTRAINT trip_events_type_check
  CHECK (type IN ('boarded','dropped','not_found'));
-- Pessoa ou instituição que recebeu o aluno no desembarque. Mantém a
-- rastreabilidade sem alterar eventos antigos, que ficam com valor nulo.
ALTER TABLE trip_events ADD COLUMN IF NOT EXISTS received_by TEXT;

CREATE TABLE IF NOT EXISTS trip_emergency_returns (
  trip_id       UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  student_id    UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  reason        TEXT,
  active        BOOLEAN NOT NULL DEFAULT true,
  started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at   TIMESTAMPTZ,
  PRIMARY KEY (trip_id, student_id)
);

-- Alertas operacionais enviados pelo motorista antes de chegar a uma parada.
-- A chave unica impede toque duplo de disparar duas notificacoes iguais.
CREATE TABLE IF NOT EXISTS trip_alerts (
  id         BIGSERIAL PRIMARY KEY,
  tenant_id  UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  trip_id    UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  student_id UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  type       TEXT NOT NULL CHECK (type IN ('approaching_5min')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (trip_id, student_id, type)
);
CREATE INDEX IF NOT EXISTS idx_trip_alerts_trip ON trip_alerts(trip_id, created_at);

-- Chat pais <-> motorista/admin. Uma thread por responsavel (parent_user_id):
-- todo o pessoal do tenant (admin/driver) fala com aquele pai na mesma thread,
-- o que evita ter que modelar conversas multi-participante.
CREATE TABLE IF NOT EXISTS chat_messages (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  parent_user_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sender_user_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  body            TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_chat_thread ON chat_messages(tenant_id, parent_user_id, created_at);

-- Financeiro: controle manual de mensalidade (sem gateway de pagamento --
-- o admin marca pago/pendente; nao ha dinheiro de verdade passando por aqui).
-- Um registro por aluno por mes; "gerar cobrancas do mes" cria os pendentes
-- em lote usando students.monthly_fee.
CREATE TABLE IF NOT EXISTS payments (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  student_id      UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  reference_month DATE NOT NULL,
  amount          NUMERIC(10,2) NOT NULL,
  status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','paid')),
  paid_at         TIMESTAMPTZ,
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (student_id, reference_month)
);
CREATE INDEX IF NOT EXISTS idx_payments_tenant ON payments(tenant_id);
CREATE INDEX IF NOT EXISTS idx_payments_student ON payments(student_id, reference_month);

-- Falta avulsa: o pai (ou admin) avisa que o aluno nao vai numa data
-- especifica. Uma linha por aluno por dia; o motorista ve isso na tela de
-- presenca da viagem daquele dia.
CREATE TABLE IF NOT EXISTS absences (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  student_id UUID NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  date       DATE NOT NULL,
  notes      TEXT,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (student_id, date)
);
ALTER TABLE absences ADD COLUMN IF NOT EXISTS direction TEXT NOT NULL DEFAULT 'all';
ALTER TABLE absences DROP CONSTRAINT IF EXISTS absences_direction_check;
ALTER TABLE absences ADD CONSTRAINT absences_direction_check CHECK (direction IN ('all','to_school','to_home'));
ALTER TABLE absences DROP CONSTRAINT IF EXISTS absences_student_id_date_key;
CREATE UNIQUE INDEX IF NOT EXISTS idx_absences_student_date_direction
  ON absences(student_id, date, direction);
CREATE INDEX IF NOT EXISTS idx_absences_tenant ON absences(tenant_id);
CREATE INDEX IF NOT EXISTS idx_absences_date ON absences(tenant_id, date);

-- Ultima leitura de cada usuario em cada thread de chat (thread = o
-- parent_user_id da conversa) -- usado pra calcular badge de nao lidas.
-- Uma linha por (leitor, thread); staff (driver/admin) tem leitura propria
-- por thread, pai so tem a propria thread.
CREATE TABLE IF NOT EXISTS chat_reads (
  tenant_id      UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  parent_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  last_read_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, parent_user_id)
);

-- Campos novos de aluno (P1 fase 5). medical_notes e dado sensivel (LGPD) --
-- so admin le esse campo especifico (ver GET /api/students/:id).
ALTER TABLE students ADD COLUMN IF NOT EXISTS photo_url TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS birth_date DATE;
ALTER TABLE students ADD COLUMN IF NOT EXISTS class_period TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS emergency_contact_name TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS emergency_contact_phone TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS medical_notes TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS authorized_pickup TEXT;
ALTER TABLE students ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT true;

-- Campos novos de rota.
ALTER TABLE routes ADD COLUMN IF NOT EXISTS days_of_week TEXT;
ALTER TABLE routes ADD COLUMN IF NOT EXISTS planned_time TIME;
ALTER TABLE routes ADD COLUMN IF NOT EXISTS planned_time_to_school TIME;
ALTER TABLE routes ADD COLUMN IF NOT EXISTS planned_time_to_home TIME;
ALTER TABLE routes ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT true;

-- Campos novos de veiculo.
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS year INT;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS color TEXT;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS document_expiry DATE;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'available'
  CHECK (status IN ('available', 'maintenance'));

-- Desativar conta em vez de excluir (soft toggle); last_login_at pra
-- eventualmente mostrar "ultimo acesso" na tela de equipe.
ALTER TABLE users ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMPTZ;

-- Forma de pagamento (P1 fase 6) -- opcional, so preenchido quando marca como pago.
ALTER TABLE payments ADD COLUMN IF NOT EXISTS payment_method TEXT;
ALTER TABLE payments ADD COLUMN IF NOT EXISTS provider TEXT;
ALTER TABLE payments ADD COLUMN IF NOT EXISTS external_id TEXT;
ALTER TABLE payments ADD COLUMN IF NOT EXISTS checkout_url TEXT;
ALTER TABLE payments ADD COLUMN IF NOT EXISTS provider_status TEXT;

-- Credenciais de pagamento por empresa. O token e sempre cifrado pela API;
-- nenhum endpoint devolve o valor original ao aplicativo.
CREATE TABLE IF NOT EXISTS payment_provider_configs (
  tenant_id       UUID PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,
  provider        TEXT NOT NULL CHECK (provider IN ('manual_pix','mercado_pago')),
  api_token_enc   TEXT,
  pix_key         TEXT,
  merchant_name   TEXT,
  active          BOOLEAN NOT NULL DEFAULT true,
  updated_by      UUID REFERENCES users(id) ON DELETE SET NULL,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Auditoria administrativa (P1 fase 7): quem alterou o que, em cima de dado
-- sensivel (reset de senha, status de pagamento, criar/editar/excluir
-- aluno/rota/veiculo/usuario). So-insercao; sem FK pra entidade (o registro
-- tem que sobreviver mesmo depois de excluir o que ele descreve).
CREATE TABLE IF NOT EXISTS audit_log (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  action        TEXT NOT NULL,
  entity_type   TEXT NOT NULL,
  entity_id     TEXT,
  detail        JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_tenant ON audit_log(tenant_id, created_at DESC);
