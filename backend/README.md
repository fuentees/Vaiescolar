# Backend — VaiEscolar API

Node + Express + PostgreSQL + WebSocket + push (FCM). Multi-tenant.

## Passos
```bash
cp .env.example .env        # ajuste DATABASE_URL, JWT_SECRET e (opcional) push
npm install
npm run migrate             # cria as tabelas
npm start                   # sobe a API em http://localhost:3000
npm test                    # roda a suite de integracao (node --test, contra o mesmo Postgres)
```

### Banco de dados: Postgres local ou Supabase
Qualquer um serve, contanto que `DATABASE_URL` aponte para ele — o backend usa
Postgres puro (`pg` + SQL simples), sem nada especifico de um provedor:
- **Local**: `createdb vaiescolar` (ou crie pelo seu cliente Postgres).
- **Supabase**: crie um projeto, pegue a connection string em
  *Settings > Database > Connection string* (prefira o **Session pooler**,
  não o *Transaction pooler* da porta 6543) e garanta `?sslmode=require` no
  final da URL. Usado **só como Postgres gerenciado** — Auth, Realtime e RLS
  do Supabase não entram em jogo; login (bcrypt+JWT), tempo real (`ws`) e
  push (FCM) continuam sendo os deste backend.

### Push notifications (Firebase Cloud Messaging)
**Já configurado e testado neste projeto** (Firebase project "vaiescolar"),
nos dois apps: `backend/firebase-service-account.json` existe (fora do git,
coberto pelo `.gitignore`) e `GOOGLE_APPLICATION_CREDENTIALS` aponta pra ele
no `.env`. Testado de ponta a ponta em ambos: token FCM real registrado,
notificação real recebida na bandeja do sistema com o app em segundo plano,
e toque na notificação abrindo a tela certa (chat) no app.

**Pegadinha real encontrada ao testar `app_motorista`**: o `google-services.json`
baixado via Firebase Management API trouxe **duas** `api_key` para o app
(a chave do Google Maps, alem da chave real do Firebase) — o plugin
`google-services` usa a **primeira** da lista como `google_api_key`, e como
essa primeira era a chave restrita só a "Maps SDK for Android", toda chamada
do Firebase Installations/Messaging vinha rejeitada (`FIS_AUTH_ERROR`,
"Firebase Installations Service is unavailable"). Sintoma enganoso: parecia
um problema de emulador/rede, mas rodava igual em duas tentativas e o
`app_pais` (cujo `google-services.json` só tinha a chave certa) funcionava
normalmente no mesmo emulador. Fix: manter só a `api_key` real do Firebase
nesse arquivo (a do Maps não precisa estar ali — ela é usada direto no
`AndroidManifest.xml`, se for o caso).

Para replicar em outro projeto Firebase do zero:
1. Crie um projeto em https://console.firebase.google.com (grátis).
2. *Project settings > Service accounts > Generate new private key* — baixa
   um JSON.
3. Salve como `backend/firebase-service-account.json` e aponte
   `GOOGLE_APPLICATION_CREDENTIALS=./firebase-service-account.json` no `.env`.
4. Sem essa variável, a API sobe normalmente e só loga um aviso; os
   endpoints que disparam push (`trips/start`, `trips/:id/events`)
   continuam funcionando, so que sem enviar nada.

**Nota de API**: `firebase-admin` v14+ usa API modular — `src/push.js`
importa de `firebase-admin/app` e `firebase-admin/messaging`, não do objeto
default de `require('firebase-admin')` (esse não tem mais `.credential`/
`.messaging()`). Isso quebrou na primeira tentativa e só foi pego testando
o envio de verdade, não com `node --check`.

## Fluxo de teste rapido (curl) — ponta a ponta motorista -> backend -> pais
```bash
BASE=http://localhost:3000

# 1) cria o operador + admin
ADMIN_TOKEN=$(curl -s $BASE/api/auth/register-tenant -H 'content-type: application/json' \
  -d '{"tenantName":"Van do Ze","name":"Ze","email":"ze@van.com","password":"123456"}' | jq -r .token)

# 2) admin cria o motorista
curl -s $BASE/api/users -H "authorization: Bearer $ADMIN_TOKEN" -H 'content-type: application/json' \
  -d '{"role":"driver","name":"Joao Motorista","email":"joao@van.com","password":"123456"}'
DRIVER_TOKEN=$(curl -s $BASE/api/auth/login -H 'content-type: application/json' \
  -d '{"email":"joao@van.com","password":"123456"}' | jq -r .token)

# 3) cria aluno, rota, vincula aluno a rota
STUDENT_ID=$(curl -s $BASE/api/students -H "authorization: Bearer $ADMIN_TOKEN" -H 'content-type: application/json' \
  -d '{"name":"Joaozinho","school_name":"Escola Alfa"}' | jq -r .id)
ROUTE_ID=$(curl -s $BASE/api/routes -H "authorization: Bearer $ADMIN_TOKEN" -H 'content-type: application/json' \
  -d '{"name":"Rota Manha"}' | jq -r .id)
curl -s $BASE/api/routes/$ROUTE_ID/students -H "authorization: Bearer $ADMIN_TOKEN" -H 'content-type: application/json' \
  -d "{\"student_id\":\"$STUDENT_ID\"}"

# 4) gera o codigo de convite do aluno (o motorista mostraria isso como texto grande + QR)
CODE=$(curl -s $BASE/api/students/$STUDENT_ID/invite -H "authorization: Bearer $ADMIN_TOKEN" | jq -r .code)
echo "Codigo de convite: $CODE"

# 5) o pai se auto-cadastra com o codigo (endpoint publico, sem token)
PARENT_TOKEN=$(curl -s $BASE/api/auth/register-parent -H 'content-type: application/json' \
  -d "{\"code\":\"$CODE\",\"name\":\"Maria Mae\",\"email\":\"maria@mae.com\",\"password\":\"123456\"}" | jq -r .token)

# 5b) tentar usar o mesmo codigo de novo deve falhar com 410 (codigo ja utilizado)
curl -s -o /dev/null -w '%{http_code}\n' $BASE/api/auth/register-parent -H 'content-type: application/json' \
  -d "{\"code\":\"$CODE\",\"name\":\"Outra Pessoa\",\"email\":\"outra@mae.com\",\"password\":\"123456\"}"

# 6) motorista inicia a viagem (dispara push "A van iniciou a rota" para os pais da rota)
TRIP_ID=$(curl -s $BASE/api/trips/start -H "authorization: Bearer $DRIVER_TOKEN" -H 'content-type: application/json' \
  -d "{\"route_id\":\"$ROUTE_ID\",\"direction\":\"to_school\"}" | jq -r .tripId)

# 7) simula um ping de GPS (o app do motorista faz isso via geolocator + fila offline)
curl -s $BASE/api/trips/$TRIP_ID/locations -H "authorization: Bearer $DRIVER_TOKEN" -H 'content-type: application/json' \
  -d '{"lat":-23.55,"lng":-46.63,"speed":8.3,"heading":90,"accuracy":5}'

# 8) confirma a ultima posicao (fallback antes do WS conectar)
curl -s $BASE/api/trips/$TRIP_ID/location -H "authorization: Bearer $PARENT_TOKEN"

# 9) pai ve a viagem ativa do filho
curl -s $BASE/api/trips/active -H "authorization: Bearer $PARENT_TOKEN"

# 10) motorista registra embarque do aluno (dispara push "Joaozinho embarcou na van as HH:MM")
curl -s $BASE/api/trips/$TRIP_ID/events -H "authorization: Bearer $DRIVER_TOKEN" -H 'content-type: application/json' \
  -d "{\"student_id\":\"$STUDENT_ID\",\"type\":\"boarded\",\"lat\":-23.55,\"lng\":-46.63}"

# 11) pai ve a timeline de eventos da viagem
curl -s $BASE/api/trips/$TRIP_ID/events -H "authorization: Bearer $PARENT_TOKEN"

# 12) WebSocket do pai (deve conectar e receber location/event)
wscat -c "ws://localhost:3000/ws?token=$PARENT_TOKEN&tripId=$TRIP_ID"
```

Requer `jq` instalado para extrair os campos do JSON acima (ou adapte manualmente).

## Endpoints principais
**Auth / onboarding**
- `POST /api/auth/register-tenant` — **público**; cria tenant + admin do zero (autoatendimento, sem precisar de outro admin), retorna `{token, userId, role, name, tenantId}`
- `POST /api/auth/login` — login (driver/parent/admin)
- `POST /api/auth/register-parent` — **público**; cadastro do pai via codigo de convite (`{code, name, email, password}`); 404 se codigo invalido, 410 se ja usado ou expirado
- `POST /api/auth/link-child` (auth, role `parent`) `{code}` — um pai que **ja
  tem conta** vincula outro filho usando um segundo codigo de convite. Sem
  isso, usar um segundo codigo com o mesmo e-mail dava 409 no
  `register-parent` — nao dava pra ter mais de um filho na van.
- `GET  /api/auth/me` (auth) — dados do usuario logado (nome, email, telefone, role)
- `PUT  /api/auth/password` (auth) — troca a propria senha (`{currentPassword, newPassword}`); 401 se a senha atual estiver errada
- `POST /api/users/fcm-token` (auth) — salva/atualiza o token FCM do usuario logado

**Cadastros (admin)** — so o admin do tenant (quem fez o `register-tenant`)
tem essas permissoes; um motorista comum (`role: driver`) recebe 403.
Tenant pode ter **mais de um admin** (ex.: socio/gerente) — `role` aceita
`admin` tambem em `POST /api/users`, e `GET /api/users` lista os tres papeis.
- `GET  /api/users` — lista admins, motoristas e responsaveis do tenant
- `POST /api/users` — cria motorista, responsavel ou outro admin (`{role, name, email, password, phone?}`); 409 se o email ja existe
- `PUT  /api/users/:id` — edita nome/telefone (nao muda role/email/senha)
- `PUT  /api/users/:id/active` — desativa/reativa a conta (`{active: bool}`);
  login passa a rejeitar contas desativadas; nao deixa desativar a propria
  conta (400)
- `PUT  /api/users/:id/password` — reseta a senha de qualquer usuario do tenant, incluindo outro admin (fluxo de "esqueci a senha" assistido, sem precisar da senha atual)
- `GET/POST /api/students` / `PUT /api/students/:id` / `DELETE /api/students/:id`
- `POST /api/students/:id/invite` — gera codigo de convite (7 dias) para o responsavel do aluno
- `GET/POST /api/routes` / `PUT /api/routes/:id` / `DELETE /api/routes/:id`
- `POST /api/routes/:id/students` (vincula aluno a rota, vai pro fim da fila
  de embarque) / `GET /api/routes/:id/students` (lista quem ja esta na rota,
  em ordem de embarque) / `DELETE /api/routes/:id/students/:studentId`
  (remove o aluno da rota, sem excluir o cadastro dele)
- `PUT /api/routes/:id/students/reorder` `{studentIds: [...]}` — reordena a
  fila de embarque da rota (quem pega primeiro).
- `GET /api/vehicles` (driver/admin — so leitura) / `POST /api/vehicles` /
  `PUT /api/vehicles/:id` / `DELETE /api/vehicles/:id` (admin) — frota do
  tenant (`{plate, model?, capacity?, year?, color?, document_expiry?, status?}`,
  `status` em `available`/`maintenance`)
- `GET/POST /api/schools` / `PUT/DELETE /api/schools/:id` — cadastro de escolas
  (nome, endereco, telefone). Alunos vinculam por `school_id` em vez de digitar
  o nome toda vez.
- `GET /api/students/:id` — "perfil do aluno": dados + escola + responsaveis
  (nome/e-mail/telefone) + ultimos 12 pagamentos, num round-trip so. **Admin
  ve qualquer aluno do tenant; pai so o(s) proprio(s) filho(s)** (via
  `assertOwnsStudentOrAdmin`) — antes era admin-only, relaxado na fase 7 pra
  alimentar a tela "Detalhes do filho" do app dos pais.
- `GET /api/students/mine` (role `parent`) — os proprios filhos do pai logado,
  independente de ter viagem ativa hoje (base da home do app dos pais).
- `GET /api/trips/history?studentId=&limit=&offset=` — viagens finalizadas
  envolvendo um aluno especifico (admin ve qualquer um; pai so os proprios
  filhos), com `last_event_type`/`last_event_at` indicando se aquele aluno
  chegou a embarcar/descer naquele dia especifico (algumas viagens da rota
  podem ter acontecido sem ele).

**Financeiro (admin)** — controle manual de mensalidade, sem gateway de
pagamento: o admin gera as cobrancas do mes e marca pago/pendente; nenhum
dinheiro de verdade passa pelo sistema.
- `POST /api/payments/generate` `{month:"YYYY-MM"}` — cria uma cobranca
  `pending` por aluno com `monthly_fee` definido (`students.monthly_fee`).
  Idempotente — pode chamar de novo sem duplicar. Retorna quantas criou e
  quais alunos foram pulados por nao ter mensalidade.
- `GET /api/payments?month=YYYY-MM` — cobrancas do mes, com nome do aluno.
- `PUT /api/payments/:id` `{status?, amount?, notes?, payment_method?, paid_at?}`
  — marca pago/pendente. Marcar como `paid` usa `paid_at` se vier, senao
  `now()`; voltar pra `pending` ("estornar") sempre limpa `payment_method` e
  `paid_at`, independente do que foi mandado nesses campos.
- `GET /api/payments/summary?month=YYYY-MM` — `{total, paid, pending,
  total_amount, paid_amount}`.
- `GET /api/payments/mine?month=YYYY-MM` (role `parent`) — status de
  pagamento dos proprios filhos (so leitura).

**Notificacoes e auditoria**
- `GET /api/notifications?limit=30` — central de notificacoes: uniao de
  eventos recentes ja existentes, sem tabela nova. Pai ve embarque/
  desembarque dos proprios filhos + mensagens de chat recebidas; staff
  (driver/admin) ve mensagens de chat recebidas + faltas avisadas pelos
  pais. Cada linha vem no formato generico `{type, message, created_at,
  entity_id}`.
- `GET /api/audit-log?entityType=&limit=&offset=` (admin) — quem alterou o
  que (`action`, `entity_type`, `entity_id`, `detail` JSON, `actor_name`,
  `created_at`), mais recente primeiro. `entityType` filtra por
  `user`/`student`/`route`/`vehicle`/`payment`.

**Dashboard (admin)**:
- `GET /api/dashboard/summary` — `{totalStudents, totalVehicles, totalRoutes,
  activeTripsToday, pendingPayments, paidThisMonth}` num round-trip so, pra
  home do app do motorista.

**Relatorios (admin)** — o Financeiro do dia a dia so mostra o mes atual:
- `GET /api/reports/financial-history?months=N` — historico de `payments`
  agrupados por mes (`N` de 1 a 24, default 6): `{month, total, paid,
  pending, total_amount, paid_amount}[]`.
- `GET /api/reports/trips?driverId=&routeId=&vehicleId=&limit=&offset=` —
  viagens finalizadas, mais recente primeiro, com filtro opcional por
  motorista/rota/veiculo e paginacao (`limit` max 100, default 20). Cada
  viagem inclui `duration_seconds`, `event_count`, `student_count` e
  `distance_km` (soma de distancias Haversine entre pings de GPS
  consecutivos daquela viagem — aproximacao em linha reta, nao segue ruas).
- `GET /api/reports/trips/:id` — detalhe de uma viagem: metadados (rota,
  motorista, veiculo, horarios) + `events[]` (timeline de embarque/
  desembarque), pro drill-down a partir da lista de relatorios.

**Falta avulsa** — o pai (ou admin) avisa que o aluno nao vai numa data
especifica; o motorista ve isso na tela de presenca daquele dia.
- `POST /api/absences` (auth) `{student_id, date, notes?}` — pai so pode
  marcar falta de filho vinculado; admin, de qualquer aluno do tenant.
  Idempotente (`ON CONFLICT ... DO UPDATE`).
- `DELETE /api/absences/:id` (auth) — cancela; mesma checagem de posse.
- `GET /api/absences/mine` (role `parent`) — faltas futuras dos proprios filhos.
- `GET /api/absences?date=YYYY-MM-DD` (driver/admin) — faltas do dia.
- `GET /api/trips/:id/students` ganha o campo `absent` (bool) por aluno,
  cruzando com a data da viagem.

**Chat pais <-> motorista/admin** — uma thread por responsavel; todo
admin/driver do tenant fala nela (nao ha conversa 1-a-1 entre um motorista
especifico e o pai, e sim "a van" toda).
- `GET  /api/chat/threads` (driver/admin) — uma linha por responsavel do tenant, com a ultima mensagem e `unread_count` (mensagens depois do ultimo `chat_reads` de quem chama)
- `GET  /api/chat/unread-count` (auth) — total de nao lidas de quem chama (pai: so a propria thread; driver/admin: soma de todas); usado pro badge da aba Mensagens
- `GET  /api/chat/:parentUserId` — historico da thread (pai: so a propria; driver/admin: escolhe qual); abrir a thread marca como lida (upsert em `chat_reads`)
- `POST /api/chat/:parentUserId` — envia mensagem (max 1000 caracteres, rate limit de 30/min); retransmite via WS e dispara push pro outro lado
- `WS /ws?token=...&chatWith=<parentUserId>` — mesmo endpoint WS das viagens, so troca `tripId` por `chatWith`

**Viagens / rastreamento**
- `POST /api/trips/start` (driver/admin) `{route_id, direction, vehicle_id?}` — cria trip; por padrao usa o veiculo da rota, mas aceita `vehicle_id` pra trocar pontualmente (van quebrou, motorista pegou outra); dispara push "A van iniciou a rota" para os pais da rota
- `POST /api/trips/:id/finish` (driver/admin) — alem de finalizar, manda um broadcast `{type: 'trip_finished'}` pro hub da viagem (WS), pro mapa do pai avisar que a viagem acabou em vez de ficar mostrando a ultima posicao como se ainda fosse atual
- `GET  /api/trips/mine/active` (driver/admin) — a propria viagem ativa de quem chama (ou `null`); usado pelo app do motorista pra restaurar o estado "rota em andamento" depois de o processo Android ser morto e o app perder isso da memoria.
- `GET  /api/trips/active` (parent) — viagens ativas dos filhos do pai logado
- `GET  /api/trips/:id/students` (driver/admin) — alunos da rota + ultimo status (embarcou/desceu) + `home_address` (usado pelo botao "navegar ate o endereco" do app do motorista)
- `POST /api/trips/:id/locations` (driver/admin) — ping ou array de pings de GPS; validado (lat -90..90, lng -180..180, lote maximo 200 itens — 400 caso contrario)
- `GET  /api/trips/:id/location` — ultima posicao (fallback antes do WS conectar)
- `POST /api/trips/:id/events` (driver/admin) — embarque/desembarque; dispara push ao(s) responsavel(is) do aluno; lat/lng validados se presentes
- `GET  /api/trips/:id/events` (parent) — eventos da viagem em ordem cronologica, para a timeline
- `WS   /ws?token=...&tripId=...` — pais/driver/admin acompanham ao vivo (pai so entra se tiver filho vinculado a rota da viagem — 403 caso contrario)

## Revisao de UX/produto — P0 corrigidos
Uma segunda revisao (apos a de seguranca) trouxe 6 bugs P0 (bloqueadores de
lancamento). Cada um foi verificado no codigo antes de aceitar:

- **WebSocket sem `await`** (`server.on('upgrade', ...)`): `verifyToken(query.token)`
  virou `async` na rodada de seguranca anterior, mas esse call site nao foi
  atualizado — `auth` ficava sempre uma Promise truthy (nunca `null`), entao
  a checagem `if (!auth)` nunca disparava, mas `auth.role` ficava `undefined`,
  rejeitando com 403 **toda** conexao de mapa ao vivo/chat. Era pior do que
  parecia: nao era "pode rejeitar as vezes", rejeitava sempre. Corrigido
  adicionando o `await` que faltava; testado ao vivo (login real, start de
  trip real, `ws://` conectando e recebendo `{"type":"subscribed"}`).
- **Validacao de payload/coordenadas** (`src/validation.js`, novo — `zod`
  como dependencia nova): schemas reutilizaveis pra lat/lng, dinheiro
  nao-negativo, texto curto e inteiro nao-negativo, aplicados em
  `/api/trips/:id/locations` (incluindo o limite de 200 itens por lote),
  `/api/trips/:id/events`, `/api/payments/:id`, `/api/vehicles`,
  `/api/students`, `/api/routes`. Testado com `node --test` (novo
  `test/validation.test.js`) e via curl simulando payloads invalidos.
- Os outros 3 itens P0 (restaurar viagem ativa, Firebase nao-bloqueante,
  confirmar acoes perigosas) sao principalmente client-side — detalhes nos
  READMEs de `app_motorista`/`app_pais`.

## Chat (P1 fase 4) — badge de nao lidas, limite, rate limit
Tabela nova `chat_reads` (uma linha por leitor+thread, `last_read_at`).
Abrir uma thread (`GET /api/chat/:parentUserId`, ja chamado pelos dois apps
pra buscar o historico) marca ela como lida automaticamente — nao precisou
de endpoint novo pra isso. `GET /api/chat/threads` ganhou `unread_count` por
thread; `GET /api/chat/unread-count` e o total pro badge da aba Mensagens.
Mensagem limitada a 1000 caracteres (`zod`) e um rate limit proprio de
30/min (alem do limite geral de `/api`).

**Dois bugs reais encontrados no caminho** (nao no codigo novo em si, mas
expostos por ele):
- **Migration nao era re-executavel**: `ALTER TABLE users ADD CONSTRAINT
  users_email_key ...` (da rodada de seguranca) nao tinha um `DROP
  CONSTRAINT IF EXISTS` correspondente antes — rodar `npm run migrate` uma
  segunda vez (pra criar a tabela `chat_reads` nova) falhava com "relation
  already exists" **antes** de chegar na tabela nova, ja que o arquivo inteiro
  roda como uma unica query. Corrigido adicionando o `DROP CONSTRAINT IF
  EXISTS users_email_key` que faltava — mesmo padrao ja usado pra constraint
  antiga na linha de cima.
- **`COUNT(*)` do Postgres virava string no JSON**: `unread_count` (agregado
  via subquery `COUNT(*)`) e um `bigint` pro Postgres, e o driver `pg` serializa
  `bigint` como string em JS pra nao perder precisao — o app recebia
  `"unread_count": "6"` (string) em vez de `6` (numero), e o cast `as num?`
  no Flutter quebrava com "type 'String' is not a subtype of type 'num?'".
  Corrigido fazendo `COUNT(*)::int` na query (cabe tranquilo num `int`, que o
  driver ja serializa como numero de verdade). Only apareceu testando no
  emulador com dados reais, nao com `node --test` (o teste comparava o valor
  certo via `Number(...)`, que aceita string ou numero igual, entao nao
  pegava a inconsistencia de tipo do JSON).

**Nota de processo** (nao e bug de codigo, mas custou tempo de debug):
reiniciar o backend so checando "a porta 3000 responde" nao garante que o
processo novo substituiu o antigo — se o `Stop-Process` do processo anterior
falhar silenciosamente, o `npm start` novo morre com `EADDRINUSE` e o
processo velho (com codigo desatualizado) continua servindo. A partir desta
rodada, todo restart confirma explicitamente que a porta ficou livre
(`Get-NetTCPConnection` vazio) antes de subir a instancia nova.

## Campos novos e cadastros (P1 fase 5)
Colunas novas em `students` (`photo_url`, `birth_date`, `class_period`,
`emergency_contact_name`, `emergency_contact_phone`, `medical_notes`,
`authorized_pickup`, `active`), `routes` (`days_of_week`, `planned_time`,
`active`), `vehicles` (`year`, `color`, `document_expiry`, `status`) e
`users` (`active`, `last_login_at`). `PUT/DELETE /api/vehicles/:id` e
`PUT /api/users/:id`/`PUT /api/users/:id/active` sao endpoints novos; os
demais so ganharam campos nos handlers ja existentes.

**LGPD**: `medical_notes` e dado sensivel. `GET /api/students/:id` (que
retorna esse campo via `s.*`) ja era **admin-only** antes desta rodada —
nao precisou de guarda nova, so confirmar que continua assim. `GET
/api/students/mine` (parent) nunca selecionou esse campo.

**Bug de idempotencia da migration corrigido no caminho**: a `ALTER TABLE
users ADD CONSTRAINT users_email_key ...` de uma rodada anterior nao tinha
o `DROP CONSTRAINT IF EXISTS` correspondente — rodar `npm run migrate` uma
segunda vez (pra aplicar as colunas novas desta rodada) falhava com
"relation already exists" antes de chegar nelas, ja que o arquivo inteiro
roda como uma unica query. Corrigido adicionando o `DROP` que faltava.

`node --test` novo (`test/accounts.test.js`): editar/excluir veiculo,
editar usuario, desativar/reativar conta + login rejeitando conta
desativada, e a trava de "nao pode desativar a propria conta".

## Escolas, financeiro e dashboard — bugs reais encontrados testando
- **Ordem de rotas do Express**: `GET /api/students/mine` precisa vir
  **antes** de `GET /api/students/:id` no arquivo — senao o Express casa
  `"mine"` com o parametro `:id` e cai na rota admin-only por engano (o pai
  levava 403 tentando ver os proprios filhos). So apareceu testando de
  verdade com um token de pai, nao com `node --check`.
- **Migracao de `school_name` pra `schools`**: a migration (`schema.sql`)
  cria um registro em `schools` pra cada `school_name` distinto ja existente
  e liga automaticamente via `students.school_id` — testado com os alunos
  de teste (`Escola Alfa`, `Escola Gama`), ambos migraram certinho sem
  precisar reeditar nada manualmente.
- **`monthly_fee` nulo vira `0`**: mesmo bug de padrao que ja tinha aparecido
  em `vehicles.capacity` — `capacity ?? null` em vez de `capacity || 0`.
  Nos novos endpoints ja nasceu certo (`monthly_fee ?? null`), mas serve de
  lembrete: nunca usar `||` pra campos numericos opcionais quando `0` e um
  valor valido.

## Multiplos filhos, faltas, multi-admin, substituicao, ordem de embarque, relatorios — bug real encontrado
Testando `GET /api/students/mine` (novo endpoint pra um pai logado listar os
proprios filhos), a chamada dava 403 mesmo com um token de pai valido. Causa:
`GET /api/students/mine` foi escrito **depois** de `GET /api/students/:id`
no arquivo — o Express casa a string `"mine"` com o parametro `:id` e a
chamada caia na rota admin-only por engano (mesma classe de bug ja vista
antes com `routes/:id/students`). Corrigido movendo `/mine` pra antes de
`/:id` no codigo. Todos os outros endpoints desta rodada (link-child,
absences, multi-admin, veiculo por viagem, reorder, relatorios) foram
testados via curl ponta a ponta antes de mexer no frontend, incluindo casos
de erro (codigo de convite reusado deve dar 410, pai tentando marcar falta
de aluno de outro responsavel deve dar 403).

## Seguranca — revisao e correcoes (isolamento multi-tenant)
Uma revisao de seguranca encontrou falhas reais de isolamento entre tenants/
familias e higiene de producao. Cada achado foi verificado lendo o codigo
atual (nao aceito de olhos fechados) e, nos criticos, confirmado com um
ataque simulado via curl (responsavel tentando ver aluno de outra familia,
motorista tentando mexer em viagem alheia) antes e depois do fix.

**Isolamento (criticos/altos) — corrigidos:**
- `GET /api/students` nao tinha `requireRole('admin')` — qualquer responsavel
  autenticado listava alunos, enderecos e mensalidades de **todas** as
  familias do tenant. `GET /api/students/mine` continua sendo o caminho certo
  pro responsavel ver os proprios filhos.
- `POST /api/trips/:id/events` nao validava a viagem (nem tenant, nem se
  estava ativa, nem se o aluno pertencia a rota da viagem) — dava pra
  registrar embarque/desembarque em qualquer trip de qualquer tenant so
  sabendo o id.
- `POST /api/trips/:id/finish` e `POST /api/trips/:id/locations` nao
  restringiam ao `driver_user_id` dono da viagem — um motorista conseguia
  finalizar ou reportar posicao em viagem de outro motorista.
- `GET /api/trips/:id/location` nao checava vinculo do responsavel com a
  viagem — corrigido com `requireRole('parent')` + a mesma checagem de posse
  ja usada em `/events` e no handshake do WS.
- Login simplificado pra sempre `WHERE email=$1`: email agora e
  **globalmente unico** (antes era unico por tenant, e como o app nunca manda
  `tenantId` no login, isso podia resolver pro usuario errado).

**Invalidacao de token (`token_version`):**
- Trocar ou resetar a senha (`PUT /api/auth/password`,
  `PUT /api/users/:id/password`) agora incrementa `users.token_version`.
  `authMiddleware`/`verifyToken` viraram `async` e comparam a versao do JWT
  com a do banco a cada request — invalida na hora qualquer token de 30 dias
  emitido antes da troca, sem precisar de uma blacklist.
- Efeito colateral esperado: tokens emitidos **antes** desta mudanca nao tem
  `tokenVersion` no payload e passam a ser rejeitados (401) na primeira
  chamada apos o deploy — equivalente a forcar um novo login em todas as
  sessoes antigas. Testado nos dois apps: o login volta a funcionar
  normalmente, e a troca de senha *depois* da mudanca devolve um token novo
  na mesma resposta (`Api._updateToken`), sem deslogar o usuario.
- Bug real encontrado testando esse efeito colateral: `app_motorista`'s
  `Api.routes()` e `Api.tripStudents()` faziam `jsonDecode(res.body) as
  List<dynamic>` sem checar `res.statusCode` antes — um 401 (corpo
  `{"error":...}`) quebrava o cast e derrubava a tela com uma excecao nao
  tratada. Corrigido checando o status antes do cast (mesmo padrao ja usado
  em todo o resto do arquivo, e em 100% do `app_pais`).

**Hardening (medios) — corrigidos:**
- `express-async-errors` + middleware de erro final: erros em rotas `async`
  agora sao capturados, logados no servidor (`console.error`) e respondidos
  como `{error: 'erro interno'}` generico — nunca mais `detail: e.message`
  cru pro cliente (7 ocorrencias removidas).
- `express-rate-limit`: limiter mais restrito (20 req/15min) em
  `/api/auth/login`, `register-tenant`, `register-parent`, `link-child`;
  limiter geral (300/15min) no resto de `/api`.
- CORS configuravel via `CORS_ORIGIN` (lista separada por virgula, default
  `*`) — nao afeta os apps mobile (CORS e coisa de browser), e prepara
  terreno pra um eventual painel web.
- Boot-time guard: se `NODE_ENV=production` e `JWT_SECRET` estiver ausente,
  igual a `'dev-secret'` ou com menos de 16 caracteres, o processo recusa
  subir com uma mensagem clara, em vez de rodar inseguro silenciosamente.

**Testes automatizados (novo, `backend/test/`):** sem framework novo — Node
ja tem `node --test` embutido. Integracao contra o mesmo Postgres de dev
(nao ha camada de mock em lugar nenhum do backend), criando um tenant isolado
por teste e limpando via cascade-delete. Rodar com `npm test`. Cobre
exatamente a logica que os achados expuseram como fragil: isolamento de
`/students`, `/events`, `/location`; login sem `tenantId`; invalidacao de
token apos troca de senha.

**Segredo do Firebase:** `firebase-service-account.json` foi movido pra fora
da arvore do projeto (`GOOGLE_APPLICATION_CREDENTIALS` no `.env` aponta pro
caminho externo), e um `.gitignore` na raiz do monorepo cobre segredos e
artefatos de build. **Pendente, so o dono da conta pode fazer**: rotacionar
essa chave no console do Firebase, ja que ela foi compartilhada nesta
conversa antes da mudanca.

## Seguranca — pendente (hardening antes de producao)
- Validacao de payload (ex.: zod) em todas as rotas.
- Row Level Security no Postgres como segunda camada de isolamento.
- HTTPS/WSS obrigatorio (hoje o dev roda em http/ws puro).
- LGPD: consentimento dos responsaveis no cadastro (checkbox com politica de privacidade),
  minimizacao de dados de menores, retencao limitada do historico de `locations` (ex.: 90 dias).
- Login sem `tenantId` no app: hoje qualquer 401 (token expirado, senha
  trocada em outro lugar) so aparece pro usuario como telas vazias — nenhum
  dos dois apps redireciona automaticamente pro login ao receber um 401.
  Funciona (o usuario so precisa deslogar/logar de novo manualmente), mas um
  interceptor global seria a solucao mais robusta.

## Financeiro e relatorios (P1 fase 6) — dois bugs reais encontrados testando ao vivo

Coluna nova `payments.payment_method`. `PUT /api/payments/:id` passou a
aceitar/persistir forma de pagamento e data efetiva; `GET /api/reports/trips`
ganhou filtros (`driverId`/`routeId`/`vehicleId`), paginacao (`offset`) e os
campos calculados `duration_seconds`/`event_count`/`student_count`/
`distance_km`; `GET /api/reports/financial-history` ganhou `?months=`; novo
`GET /api/reports/trips/:id` pro drill-down. `node --test` novo
(`test/reports.test.js`, 4 testes) cobrindo filtro/paginacao/`?months=`/detalhe.

Os dois bugs abaixo so apareceram testando o fluxo completo no emulador
(criar cobranca -> marcar paga -> **estornar**) — `node --test` e `flutter
analyze` passaram limpos o tempo todo, porque nenhum dos dois cobria o
formato exato de payload/resposta que expôs o problema:

- **"Estornar" pagamento falhava com 400, silenciosamente**: `paymentUpdateBody`
  (zod) tinha `amount: z.number().nonnegative().optional()` — sem
  `.nullable()`. O app_motorista sempre manda os 4 campos opcionais no corpo
  do `PUT /api/payments/:id`, usando `null` explicito pros que nao mudaram
  (nao omite a chave). Zod's `.optional()` sozinho so aceita a chave
  **ausente** (`undefined`); um `null` explicito no JSON e um valor real que
  falha a validacao de `z.number()`. Resultado: todo "Estornar" (que manda
  `amount: null`) recebia 400 do backend, e a tela so recarregava a lista sem
  mostrar erro nenhum ao usuario (o codigo Flutter nao checava o retorno
  bool de `Api.updatePayment` nesse call site) — parecia que o botao nao
  fazia nada. Corrigido em duas pontas: `amount` ganhou `.nullable()` no
  schema (os outros 3 campos opcionais ja tinham), e o app passou a mostrar
  um `SnackBar` de erro se a chamada falhar, em vez de recarregar
  silenciosamente. Teste de regressao novo em `test/validation.test.js`
  mandando exatamente esse payload (`amount/notes/payment_method/paid_at`
  todos `null` explicitos) e esperando 200.
- **Numeric do Postgres vira String no JSON** (mesma familia do bug de
  `bigint`->String ja documentado acima pro `unread_count`, mas com outra
  causa): colunas `numeric`/`decimal` — caso de `payments.amount` e das somas
  `SUM(amount)` em `/api/payments/summary` e `/api/reports/financial-history`
  — o driver `pg` tambem devolve como **String** por padrao (mesma razao:
  evitar perda de precisao ao converter pra `double` do JS). O card de
  resumo do Relatorios fazia `_summary['total_amount'] as num?` direto e
  quebrava a tela inteira com "type 'String' is not a subtype of type
  'num?'" assim que abria. `formatMoney` (usado no Financeiro) ja era
  tolerante a isso (`num.tryParse`), mas os getters novos do Relatorios
  (`_pendingAmount`/`_inadimplenciaPct`) e o `CustomPainter` do grafico
  faziam o cast direto. Corrigido no lado Flutter com um helper
  compartilhado `asNum()` (`app_motorista/lib/utils/money.dart`) usado em
  todo lugar que consome campo numerico vindo do backend — mais generico do
  que forcar `::numeric->float` em cada query, ja que qualquer novo campo
  monetario cairia na mesma pegadinha.

## Paginas novas (P1 fase 7) — notificacoes, historico, auditoria

Ultima fase do P1: ~9 paginas novas nos dois apps (central de notificacoes,
historico de viagens do pai, detalhes do filho, central de ajuda,
privacidade/termos, configuracoes, status do dispositivo, auditoria, estado
de manutencao). Trabalho de backend desta fase:

- **`GET /api/notifications`** — uniao via `UNION ALL` de subqueries
  tipadas (`trip_events`+`student_guardians` pro pai, `chat_messages`+
  `absences` pro staff), cada uma projetando pro mesmo formato generico
  `{type, message, created_at, entity_id}`. Sem tabela nova — e só uma
  leitura agregada do que ja existe.
- **`GET /api/trips/history`** — reusa `assertOwnsStudentOrAdmin` (ja
  existente, usada em `/absences`) pra decidir quem pode ver o historico de
  qual aluno; junta `trips` com `route_students` do aluno (nao com
  `trip_events`, pra nao perder viagens em que o aluno nao chegou a
  embarcar) e faz um `LEFT JOIN`-like via subquery pro ultimo evento
  daquele aluno naquela viagem especifica.
- **`GET /api/students/:id` deixou de ser admin-only**: agora aceita admin
  OU o(s) responsavel(is) do aluno (mesma funcao `assertOwnsStudentOrAdmin`),
  pra alimentar a nova tela "Detalhes do filho" do app dos pais sem duplicar
  a query numa rota separada. Testado que um pai sem vinculo com o aluno
  continua levando 403.
- **Auditoria administrativa**: tabela nova `audit_log` (so-insercao, sem FK
  pra entidade — o registro tem que sobreviver a exclusao do que descreve) +
  helper `logAudit(req, action, entityType, entityId, detail)` chamado nos
  pontos que alteram dado sensivel: resetar senha, desativar/reativar
  usuario, criar/editar/excluir aluno, excluir rota/veiculo, marcar
  pagamento como pago/estornar. `GET /api/audit-log` (admin) lista com
  filtro por tipo de entidade.

`node --test` novo (`test/fase7.test.js`, 6 testes): historico exige
`studentId` e respeita posse; notificacoes devolvem embarque pro pai e chat
pro staff; `GET /api/students/:id` aceita o pai dono e rejeita outro pai;
auditoria registra reset de senha e exige admin. Um detalhe pego escrevendo
o teste de auditoria: teve que checar o 403 (role errada) **antes** de
resetar a senha do usuario de teste, porque resetar incrementa o
`token_version` dele — se o token usado pra checar o 403 for o mesmo token
do usuario que acabou de ter a senha resetada, a chamada volta 401 (token
invalido) em vez de 403 (sem permissao), testando a coisa errada.

## Dependencias — nota de seguranca
`firebase-admin` foi atualizado para a v14.2.0 (`npm audit fix --force`),
reduzindo de 8 para 6 vulnerabilidades moderadas transitivas (`google-gax`/
`@google-cloud/*` -> `uuid` antigo, bounds check em UUIDs fornecidos
externamente — nao afeta este backend porque nenhum UUID de terceiros passa
por esse caminho). Testado apos o upgrade: `node --check` em todos os
arquivos, `push.js` carrega sem erro, e o fluxo completo (login, criar
viagem, disparo de push em no-op) continua funcionando. As 6 restantes so
seriam eliminadas com um *downgrade* para `firebase-admin@10.x`, o que nao
faz sentido perseguir.
