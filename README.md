# TECO — Transporte Escolar Conectado

Monorepo com tres partes:

| Pasta            | O que e                                                          |
|------------------|-------------------------------------------------------------------|
| `backend/`       | API multi-tenant (Node + PostgreSQL + WebSocket + push via FCM)  |
| `app_motorista/` | App Flutter do motorista (rastreamento, gestao de alunos/rotas, convites, chat) |
| `app_pais/`      | App Flutter dos pais (mapa ao vivo, timeline, push, chat)        |

## Painel administrativo global

O controle comercial da plataforma fica em `/platform/` e e separado do
administrador de cada transportadora. O painel inclui visao geral, clientes,
planos e limites, assinaturas, cobrancas e links de pagamento, armazenamento,
suporte, comunicados, saude dos servicos e auditoria global.

Para habilitar um administrador existente como proprietario da plataforma:

```bash
cd backend
npm run platform:promote -- administrador@dominio.com
```

Somente usuarios `admin` explicitamente promovidos acessam `/api/platform/*`.
Transportadoras suspensas ou canceladas deixam de autenticar nos aplicativos,
e os limites do plano sao aplicados no servidor ao cadastrar alunos, equipe,
veiculos e escolas. Provedores de PIX, boleto e cartao podem fornecer a URL de
pagamento ao gerar uma fatura; a confirmacao automatica deve ser feita por
webhook assinado do provedor antes de ativar a cobranca em producao.

## Gestao e chat (adicionados nesta rodada)
O motorista/admin agora tem, no proprio app (drawer de navegacao), telas
para **cadastrar alunos e rotas** (antes so dava via curl) e **conversar com
os responsaveis** (chat simples reaproveitando o WebSocket ja existente).
Cadastro de alunos/rotas continua restrito ao **admin** do tenant (quem fez
o onboarding) — motorista comum (`role: driver`) nao ve essas opcoes no
menu, ja que o backend rejeitaria com 403.

**Dois bugs reais encontrados testando no emulador** (nao pegos por
`flutter analyze`):
1. Logado como motorista comum (nao-admin), o botao "Salvar" de um novo
   aluno simplesmente nao fazia nada visivel — o backend retornava 403 e a
   UI nao tratava isso. Corrigido escondendo Alunos/Rotas do menu quando
   `role != admin`.
2. O app dos pais crashava ("Null check operator used on a null value") ao
   abrir o chat, porque a sessao ja estava salva de antes de eu adicionar o
   campo `userId` ao login. Corrigido com uma migracao defensiva: sessao
   sem `userId` forca um novo login em vez de quebrar.

Pagamentos/cobranca ficaram de fora desta rodada (decisao explicita).

## Fechando as lacunas do MVP (rodada seguinte)
Depois da rodada de gestao+chat acima, revisitamos o produto perguntando "o
que falta pra alguem usar isso de verdade sem eu intermediar" e fechamos:
- **Cadastro de operador novo** (`register_tenant_screen.dart` no app do
  motorista) — antes so existia via curl; agora tem uma tela de onboarding
  completa (cria tenant + admin, `POST /api/auth/register-tenant`).
- **Push do chat chegando pro motorista** — o app do motorista ganhou
  `firebase_messaging` (antes so o app dos pais tinha). Testado de ponta a
  ponta: mensagem do pai chega como notificacao real no motorista, e tocar
  nela abre "Mensagens" direto.
- **Gestao de veiculos** (`vehicles_screen.dart`) e **gestao de
  motoristas/responsaveis** (`users_screen.dart`, com criacao de conta e
  reset de senha) no app do motorista.
- **Editar/excluir** alunos, rotas e o vinculo aluno-rota, direto na UI
  (antes so dava via curl).
- **Tela de perfil** (`profile_screen.dart`) nos dois apps — ver os proprios
  dados, trocar a propria senha, sair.
- **"Esqueci minha senha"** nos dois apps — como o produto nao tem
  email/SMS, e um fluxo assistido: o admin reseta a senha de qualquer
  motorista/responsavel pela tela "Motoristas e responsaveis"
  (`PUT /api/users/:id/password`); a propria pessoa troca a senha depois
  que loga de novo, ou a qualquer momento via "Minha conta".

**Bug real encontrado testando push no app do motorista**: o
`google-services.json` baixado pra esse app trouxe **duas** `api_key` (a
chave do Google Maps, restrita, e a chave real do Firebase) — o plugin
`google-services` usa a **primeira** da lista, e como essa era a do Maps,
toda chamada do Firebase Installations/Messaging vinha rejeitada
(`FIS_AUTH_ERROR`). Rodou igual em duas tentativas, parecendo um problema de
emulador; so ficou claro comparando com o `app_pais` (cujo arquivo so tinha
uma chave) funcionando no mesmo emulador. Corrigido deixando so a `api_key`
real do Firebase no arquivo. Detalhes em `backend/README.md`.

**Bug real de backend encontrado testando veiculos pela UI**: capacidade em
branco no formulario virava `0` no banco em vez de `null` (`capacity || 0`
em vez de `capacity ?? null`) — a UI mostrava "0 lugares" para um veiculo
sem capacidade informada. Corrigido em `POST /api/vehicles`.

## Home, escolas, perfil do aluno e financeiro (rodada mais recente)
O pedido dessa rodada foi deixar o produto "mais organizado": uma home de
verdade nos dois apps, escola como cadastro proprio (em vez de texto livre),
uma tela que junte os dados do aluno com quem e o responsavel dele, e algum
controle financeiro. Decisoes tomadas com o usuario antes de implementar:
financeiro e **controle manual** (sem gateway de pagamento — o admin marca
pago/pendente, nenhum dinheiro de verdade passa pelo sistema, evitando
depender de outra conta externa como aconteceu com Firebase/Maps).

- **Escolas** (`schools_screen.dart`) — cadastro proprio (nome, endereco,
  telefone). A migration ja converteu os `school_name` de texto livre
  existentes em registros reais e ligou os alunos automaticamente
  (`students.school_id`). Alunos passam a vincular por dropdown.
- **Perfil do aluno** (`student_detail_screen.dart`) — escola, endereco,
  mensalidade, responsaveis vinculados (nome/e-mail/telefone) e historico de
  pagamentos, tudo numa tela so (`GET /api/students/:id`).
- **Financeiro** (`finance_screen.dart` + `/api/payments/*`) — o admin gera
  as cobrancas do mes com um toque (usa a mensalidade de cada aluno,
  idempotente) e marca pago/pendente num chip tocavel. O app dos pais mostra
  o status (so leitura) no card do proprio filho.
- **Home redesenhada nos dois apps**: o motorista ganhou um dashboard
  (saudacao + cards de Alunos/Veiculos/Rotas ativas hoje/Pendencias
  financeiras, `GET /api/dashboard/summary`) acima do card de iniciar/
  finalizar rota de sempre. O app dos pais trocou "Viagens ativas" (so
  mostrava algo com uma rota rolando) por "Meus filhos": todos os filhos
  sempre visiveis, com escola e status de pagamento, e o atalho pro mapa
  aparecendo so quando ha viagem ativa.

**Bugs reais encontrados testando de ponta a ponta no emulador** (roteiro:
`flutter analyze` limpo primeiro, depois toques reais via `adb` — os quatro
abaixo so apareceram na segunda etapa):
1. **Ordem de rotas do Express**: `GET /api/students/mine` foi escrito
   *depois* de `GET /api/students/:id` no codigo — o Express casa `"mine"`
   com o parametro `:id` e a chamada caia na rota admin-only por engano
   (pai levava 403 tentando ver os proprios filhos). Corrigido invertendo a
   ordem das duas rotas.
2. **`monthly_fee` nulo virando `0`**: mesmo padrao de bug do `capacity` da
   rodada anterior (`|| 0` em vez de `?? null`); os endpoints novos ja
   nasceram certos, mas quase se repetiu.
3. **Overflow nos cards de estatistica da home**: `childAspectRatio` grande
   demais pro conteudo de duas linhas ("Pendencias financeiras" quebra em
   duas linhas) — so apareceu rodando no emulador pequeno (320x640), nao no
   `flutter analyze`. Ajustado o aspect ratio e o padding dos cards.
4. **Overflow na tela de convite** (`invite_screen.dart`, de uma rodada
   anterior): nunca tinha sido envolvida num `SingleChildScrollView` —
   passou despercebido ate essa rodada de testes mais extensiva pelas telas
   existentes. Corrigido.

## Revisao pos-entrega: "os botoes e paginas estao mesmo corretos?"
Antes de seguir pra proxima rodada, reconferimos o app do motorista de novo
(perguntado diretamente se tinha certeza que estava tudo certo) — dessa vez
tocando um card/tela por vez, com screenshot de verificacao antes de cada
proximo toque, ja que a rodada anterior teve bastante instabilidade de
automacao. Achado real: `GET /api/routes/:id/students` ainda lia a coluna
antiga `school_name` em vez de fazer o JOIN com a tabela `schools` nova —
como o dialog de aluno so salva `school_id` agora, a tela de detalhe da rota
mostrava "Escola nao informada" pra qualquer aluno editado depois da
migracao, mesmo ele tendo escola cadastrada certinho em todo o resto do app.
Corrigido com `COALESCE(sc.name, s.school_name)`.

## Fechando mais lacunas do transportador (multiplos filhos, faltas, multi-admin, substituicao, ordem de embarque, relatorios)
Perguntamos "o app cobre todas as lacunas do transportador?" e a resposta
honesta foi nao — faltavam 5 cenarios reais do dia a dia de quem opera uma
van escolar:
- **Um responsavel com mais de um filho nao conseguia se cadastrar pro
  segundo** (o mais grave — cenario comum de irmãos na mesma van). Cada
  convite criava uma conta nova; usar um segundo codigo com o mesmo e-mail
  dava erro de duplicidade. Resolvido com `POST /api/auth/link-child`: um
  pai ja logado vincula outro filho com um novo codigo, sem criar conta
  nova. Tela nova no app dos pais: "Adicionar outro filho".
- **Falta avulsa**: pai avisa que o filho nao vai numa data especifica
  (`absences`), o motorista ve um chip "Ausente" na tela de presenca do dia.
- **Multi-admin**: um tenant agora pode ter mais de um administrador (ex.:
  socio/gerente) — antes so existia a conta de quem fez o cadastro inicial.
- **Troca de veiculo pontual**: a van usada numa viagem agora fica registrada
  por viagem (`trips.vehicle_id`), nao so no cadastro fixo da rota — o
  motorista pode trocar antes de iniciar (van quebrou, pegou outra naquele
  dia). A troca de *motorista* ja funcionava sem mudanca nenhuma (qualquer
  motorista logado ja podia escolher qualquer rota e iniciar).
- **Ordem de embarque**: a lista de alunos de uma rota agora tem sequencia
  (setas ▲▼ na tela de gestao da rota), refletida na tela de presenca do
  motorista.
- **Relatorios**: historico financeiro dos ultimos 6 meses e as ultimas
  viagens finalizadas (rota, motorista, veiculo) — o Financeiro do dia a dia
  so mostrava o mes atual.

**Bug real encontrado testando a nova tela de reordenar** (`route_detail_screen.dart`):
tres `IconButton`s (▲▼ + remover) no tamanho padrao nao cabiam ao lado do
nome do aluno numa tela de 320dp — o nome quebrava letra por letra em vez de
palavra por palavra. Corrigido reduzindo cada botao
(`constraints: BoxConstraints(minWidth: 28, minHeight: 28)` +
`visualDensity: VisualDensity.compact`). Todos os outros endpoints/telas
novos desta rodada foram validados via curl (incluindo casos de erro: codigo
de convite reusado -> 410, pai marcando falta de aluno de outro responsavel
-> 403) e depois na UI real do emulador, um passo de cada vez.

## Revisao de seguranca: isolamento multi-tenant e higiene de producao
O usuario trouxe uma revisao de seguranca detalhada (com referencias de
arquivo/linha) apontando 12 achados. Cada um foi verificado lendo o codigo
atual antes de aceitar — 11 confirmados reais (alguns piores do que a
revisao descrevia, ex.: `POST /api/trips/:id/events` nem checava o tenant da
viagem, nao so o status), 1 descartado (a revisao dizia que a documentacao
tinha "encoding corrompido"; na verdade e portugues deliberadamente sem
acento, escolha consistente de estilo, nao corrupcao).

Corrigido: dois isolamentos criticos (`GET /api/students` sem restricao de
admin, `POST /api/trips/:id/events` sem validar a viagem) que permitiam a um
responsavel ou motorista acessar/manipular dados de outras familias dentro
do mesmo tenant; mais tres isolamentos altos (finish/locations/location de
viagem sem checar posse); invalidacao de token via `token_version` (troca de
senha derruba tokens antigos de 30 dias); email globalmente unico (login sem
`tenantId` deixava de ser ambiguo); rate limiting, remocao de mensagens de
erro cruas pro cliente, CORS configuravel, boot guard de `JWT_SECRET` fraco;
suite de testes de integracao nova (`node --test`, 6 testes cobrindo
exatamente essa logica); segredo do Firebase movido pra fora da arvore do
projeto; `config.dart` dos dois apps configuravel via `--dart-define`.
Detalhes completos (o que foi corrigido e o que ainda fica pendente) em
`backend/README.md`.

**Efeito colateral e bug real encontrados verificando no emulador**: como
tokens emitidos antes da mudanca nao tem `tokenVersion` no payload, a
primeira chamada de cada sessao antiga apos o deploy voltava 401 (esperado —
equivale a forcar um novo login geral). Isso expos um bug pre-existente e
real no `app_motorista`: `Api.routes()` e `Api.tripStudents()` faziam o cast
`jsonDecode(res.body) as List<dynamic>` sem checar `res.statusCode` antes, e
um 401 (corpo `{"error": ...}`) quebrava esse cast com uma excecao nao
tratada, derrubando a tela inicial do motorista. Corrigido (mesmo padrao ja
usado no resto do arquivo e em 100% do `app_pais`, que nao tinha esse bug).
Verificado depois, um passo de cada vez: login, troca da propria senha sem
deslogar (`Api._updateToken`), todas as telas de admin (Alunos/Escolas/
Rotas/Veiculos/Equipe/Financeiro/Relatorios) e um ciclo completo de viagem
(iniciar -> marcar presenca -> finalizar) — nos dois apps, logados como
motorista, responsavel e admin.

## Revisao de UX/produto — P0 corrigidos, P1 em andamento
Uma segunda revisao trouxe 6 bugs P0 (bloqueadores de lancamento) e uma lista
extensa de melhorias P1 de interface/produto. Dado o tamanho do P1 (nova
navegacao nos dois apps, tela dedicada de viagem ativa, redesign de duas
homes, mapa/chat/financeiro/relatorios melhorados, formularios padronizados,
campos novos e ~9 paginas novas), a implementacao esta sendo feita em fases
sequenciais, cada uma testada no emulador antes de avancar — plano completo
no historico da conversa.

**Os 6 P0 ja fechados:**
- **WebSocket sem `await`** — a pior: uma regressao real da propria rodada
  de seguranca anterior (`verifyToken` virou `async` mas um call site nao foi
  atualizado), rejeitando com 403 **toda** conexao de mapa ao vivo/chat.
  Corrigido e testado ao vivo. Detalhes em `backend/README.md`.
- **Viagem ativa sobrevive a um kill do processo** — novo endpoint
  `GET /api/trips/mine/active` + persistencia local + dialog de restauracao
  no `app_motorista`. Testado forcando `am force-stop` com uma rota ativa.
- **Boot nao bloqueia mais esperando o Firebase** — de ~16s ate a primeira
  tela pra ~3-4s nos dois apps, com uma splash propria (`flutter_native_splash`)
  no lugar da branca padrao do Flutter.
- **`ApiResult<T>`** (`data`/`empty`/`offline`/`unauthorized`/`serverError`)
  + tratamento global de 401 (desloga e volta pro login sozinho) — fundacao
  nova nos dois apps, migrada tela por tela nas fases seguintes.
- **Confirmacao em acoes perigosas** — FINALIZAR ROTA (com rota/direcao/
  horario) e marcar "Desceu" sem "Embarcou" registrado antes.
- **Validacao de payload/coordenadas no backend** — `zod` (nova dependencia),
  lat/lng na faixa geografica valida, lote de GPS limitado a 200 itens,
  valores financeiros nao-negativos.

**P1 — Fase 1+2 (navegacao + home/rota do motorista) feitas:**
- **Bottom nav substitui o drawer/AppBar apertado nos dois apps.**
  `app_motorista`: Inicio/Rota/Mensagens pra todo mundo, mais Gestao
  (Alunos/Escolas/Rotas/Veiculos/Equipe/Financeiro/Relatorios, antes soltos
  num drawer de 10 itens) so pro admin — motorista comum ve 3 abas e abre
  direto em "Rota" (a acao do dia a dia dele), admin abre em "Inicio"
  (dashboard). `app_pais`: Inicio/Localizacao/Mensagens/Conta substituem 3
  `IconButton`s espremidos no AppBar de "Meus filhos" (apertado em 320px);
  "Adicionar outro filho" virou um card na lista em vez de um icone.
- **Tela de rota do motorista fundida**: iniciar rota, marcar presenca
  (Embarcou/Desceu) e finalizar viraram uma unica tela (`active_route_screen.dart`)
  com contador "N de M alunos" — antes marcar presenca exigia navegar pra uma
  tela separada (`trip_students_screen.dart`, removida).
- **Aba "Localizacao" nova** (`app_pais`): mostra o mapa da viagem ativa mais
  recente entre todos os filhos, ou explica quando o rastreamento vai
  aparecer — a bottom nav precisa de um destino direto, nao so o card do
  filho.
- Restante do P1 (redesign de conteudo das homes com alertas do dia,
  cronometro/indicador de GPS na tela de rota, mapa/chat/financeiro/
  relatorios melhorados, formularios padronizados, campos novos, ~9 paginas
  novas) segue em fases seguintes.

**P1 — Fase 2 polish (motorista) feita:**
- Cronometro + indicador de GPS online/offline + "ultimo envio: ha Ns" na
  tela "Rota" (`TrackingService` ganhou `ValueNotifier`s pra isso).
- Botao "navegar ate o endereco" por aluno (backend passou a incluir
  `home_address` em `GET /api/trips/:id/students`; `url_launcher` nova
  dependencia).
- "Alertas do dia" na aba Inicio (admin): faltas de hoje, rotas sem veiculo,
  rotas sem alunos vinculados.
- Confirmacao antes de sair do app com uma rota ativa (`PopScope`).

**P1 — Fase 3 (mapa + fuso horario) feita:**
- Marcadores de casa/escola (geocodificados via `geocoding`), indicador de
  conexao do WebSocket, aviso de GPS desatualizado, botao "centralizar na
  van", painel expandido (aluno + rota + direcao + status).
- **Bug real de fuso horario corrigido em 5 pontos** do `app_pais` (mapa,
  chat, timeline) — os horarios apareciam 3h atrasados (UTC) pro usuario no
  Brasil.
- **Bug real encontrado testando o aviso de "viagem finalizada"**: o
  broadcast via WebSocket so chega se o app estiver conectado no momento
  exato em que o motorista finaliza a rota — se o app dos pais estava em
  segundo plano (o SO derruba o WS), o aviso nunca chegava e o mapa ficava
  mostrando a viagem como se ainda estivesse rolando. Corrigido conferindo
  via REST (`GET /api/trips/active`) sempre que a tela do mapa carrega ou
  reconecta, em vez de confiar so no broadcast ao vivo.

**P1 — Fase 4 (chat) feita:**
- Tabela nova `chat_reads` + badge de nao lidas (por thread no app do
  motorista, total na aba nos dois apps), separadores de dia, status de
  mensagem (enviando/enviado/falhou com retry), autoscroll garantido, aviso
  fixo de "nao e canal de emergencia", busca de conversas (motorista),
  limite de 1000 caracteres + rate limit de 30 msgs/min por mensagem.
- **Dois bugs reais corrigidos no caminho**: a migration nao era
  re-executavel (uma `ADD CONSTRAINT` de uma rodada anterior sem `DROP ...
  IF EXISTS` correspondente); `COUNT(*)` do Postgres serializa como string
  no JSON (`pg` faz isso pra `bigint` nao perder precisao), quebrando um
  cast `as num?` no Flutter e derrubando a tela de mensagens — corrigido
  fazendo `COUNT(*)::int` na query em vez de flexibilizar o cast no app.
- **Licao de processo**: reiniciar o backend so checando "a porta responde"
  nao garante que o processo novo substituiu o antigo (um `Stop-Process`
  que falha silenciosamente deixa o processo velho, com codigo desatualizado,
  respondendo na mesma porta). A partir desta rodada, todo restart confirma
  que a porta ficou livre antes de subir a instancia nova.

**P1 — Fase 5 (formularios + campos novos) feita:**
- Cadastro/edicao de aluno virou **pagina propria** (`student_form_screen.dart`,
  antes era dialog) com `Form`/`TextFormField`, confirmacao ao sair com
  alteracao pendente, e campos novos: foto (URL), data de nascimento,
  turma/periodo, contato de emergencia, pessoas autorizadas a buscar,
  **observacoes medicas** (dado sensivel — so admin ve, e essa tela ja era
  admin-only) e ativo/inativo.
- Rotas ganharam dias da semana, horario planejado e ativa/inativa. Veiculos
  ganharam ano, cor, validade de documento (com aviso de vencimento) e
  status disponivel/manutencao, alem de **editar e excluir** (antes so
  criava). Equipe ganhou **editar conta** e **desativar/reativar** (em vez
  de excluir — login rejeita conta desativada).
- Todos os dialogs de cadastro viraram `StatefulWidget`s proprios com
  `Form`, `dispose()` nos controllers, mostrar/ocultar senha, e validacao
  com mensagem visivel (antes era checagem manual silenciosa).
- **Bug real de idempotencia da migration corrigido no caminho**: uma `ADD
  CONSTRAINT` de uma rodada anterior (email unico) nao tinha o `DROP
  CONSTRAINT IF EXISTS` correspondente — rodar a migration de novo (pras
  colunas novas desta rodada) falhava antes de chegar nelas.

**Correcao a Fase 5 (itens marcados "feita" que na verdade tinham ficado pra
tras)**: revisando o plano de novo apos a Fase 7, cinco itens do escopo
original da Fase 5 nunca tinham sido implementados, sem terem sido anotados
como pendencia deliberada em lugar nenhum — corrigido agora:
- **Mascara de telefone** (`(00) 00000-0000`, `mask_text_input_formatter`,
  nova dependencia) aplicada em Equipe (`users_screen.dart`, criar/editar) e
  no contato de emergencia do aluno (`student_form_screen.dart`).
- **Arrastar pra reordenar alunos da rota** (`ReorderableListView` com
  `onReorderItem` — a API atual, ja que `onReorder` esta deprecated desde o
  Flutter 3.41) substituindo as setas ▲▼ em `route_detail_screen.dart`.
- **Alerta de capacidade excedida**: rota com mais alunos vinculados que a
  capacidade do veiculo escolhido aparece em "Alertas do dia".
- **Bloqueio de iniciar rota sem alunos**: `active_route_screen.dart` confere
  `GET /api/routes/:id/students` antes de chamar `POST /api/trips/start` e
  mostra uma mensagem explicando o motivo, em vez de deixar iniciar uma
  viagem vazia.
- **Botao "ligar" pro contato de emergencia** na tela "Rota" (`tel:`, so
  aparece se o aluno tiver telefone cadastrado) — backend passou a incluir
  `emergency_contact_phone` em `GET /api/trips/:id/students`.
- **Visualizacao no mapa com enderecos dos alunos** (`google_maps_flutter`
  no `app_motorista`) continua pendente: a chave do Google Maps ja
  configurada esta restrita ao pacote+SHA-1 do `app_pais` especificamente, e
  adicionar o `app_motorista` a essa mesma chave requer acesso ao Google
  Cloud Console que so o dono da conta tem. Combinado com o usuario: ele vai
  adicionar `com.example.app_motorista` + o SHA-1 do keystore de debug
  (mesmo ja documentado abaixo) como um segundo app permitido na mesma
  chave, e avisa quando estiver pronto pra essa parte ser implementada.

**P1 — Fase 6 (financeiro + relatorios do motorista) feita:**
- Financeiro ganhou menu "Marcar como pago" (valor, data efetiva, forma de
  pagamento, observacao) e "Estornar" (confirmacao, limpa forma de
  pagamento/data), busca por nome, filtro pago/pendente, indicador de
  atraso, e exportacao CSV.
- Relatorios ganhou cards de resumo do mes (faturado/recebido/pendente/
  inadimplencia), grafico de barras por mes (`CustomPainter` proprio, sem
  lib de charting), filtro de viagens por motorista/rota/veiculo, paginacao,
  drill-down por viagem (`trip_detail_report_screen.dart`, timeline de
  embarque/desembarque) e exportacao CSV. Backend ganhou `duration_seconds`/
  `distance_km` (Haversine entre pings de GPS)/contagem de eventos e alunos
  por viagem.
- **Dois bugs reais corrigidos no caminho, os dois so aparecendo testando o
  ciclo completo no emulador** (`node --test`/`flutter analyze` passavam
  limpos): "Estornar" pagamento retornava 400 do backend porque o schema
  zod de `amount` nao aceitava `null` explicito (o app sempre manda os 4
  campos opcionais no corpo, usando `null` pros que nao mudaram) — e como o
  app nao checava o erro, o botao parecia simplesmente nao fazer nada; e a
  tela de Relatorios crashava ao abrir porque colunas `numeric`/`decimal`
  do Postgres (`amount`, somas de `amount`) chegam como **String** no JSON
  (mesma familia do bug de `bigint`->String da Fase 4, mas por um tipo
  Postgres diferente), e os cards de resumo faziam `as num?` direto sem a
  tolerancia que `formatMoney` ja tinha. Detalhes em `backend/README.md` e
  `app_motorista/README.md`.

**P1 — Fase 7 (paginas novas, ultima fase do P1) feita:**
- **Central de notificacoes** (os dois apps): `GET /api/notifications` novo
  agrega eventos recentes ja existentes (embarque/desembarque, chat, faltas
  avisadas) num feed so, sem tabela nova.
- **Historico de viagens do filho** (app_pais): `GET /api/trips/history?
  studentId=` novo, com indicador de embarque/desembarque por viagem.
- **Detalhes completos do filho** (app_pais): `GET /api/students/:id`
  deixou de ser admin-only — passou a aceitar tambem o(s) responsavel(is)
  do proprio aluno.
- **Central de ajuda** e **Privacidade e termos** (os dois apps): FAQ e
  politica estaticos; a politica esta marcada **RASCUNHO** ate revisao do
  dono do produto. O checkbox de consentimento do cadastro dos pais agora
  abre essa pagina.
- **Configuracoes** (os dois apps): tema claro/escuro/automatico persistido
  (`ValueNotifier` + `SharedPreferences`, mesmo padrao ja usado no app) e
  versao do app (`package_info_plus`).
- **Status do dispositivo** (app_motorista): GPS, permissao de localizacao,
  conexao (`connectivity_plus`) e push registrado — diagnostico rapido pra
  quando o motorista relata problema de rastreamento.
- **Auditoria administrativa**: tabela nova `audit_log` + helper `logAudit`
  chamado em reset de senha, ativar/desativar conta, criar/editar/excluir
  aluno, excluir rota/veiculo, marcar pagamento/estornar. Tela nova
  (`app_motorista`, admin) lista com filtro por tipo de entidade.
- **Estado de manutencao** (os dois apps): tela dedicada "Nao foi possivel
  conectar ao VaiEscolar" no lugar do dashboard/lista vazia quando a chamada
  critica de boot (dashboard do admin / lista de filhos) falha por rede ou
  servidor — usa a fundacao `ApiResult` da fase 0.

**Dois bugs reais corrigidos no caminho** (achados escrevendo os testes, nao
no emulador desta vez): o teste de auditoria pegaria 401 em vez de 403 se
checasse a permissao **depois** de resetar a senha do proprio token usado no
teste (resetar incrementa `token_version`, invalidando o token que checaria
o 403) — corrigido invertendo a ordem no teste; e a rota nova
`app.get('/api/trips/history', ...)` chama `assertOwnsStudentOrAdmin`, uma
funcao definida mais abaixo no arquivo — funciona porque e uma *function
declaration* (JS faz hoisting), mas exigiu deixar um comentario explicito no
codigo pra quem for mexer depois nao achar que e um bug de ordem de
declaracao.

## Stack (100% gratuita/open-source)

| Camada | Tecnologia |
|---|---|
| Apps moveis | Flutter 3.x / Dart |
| Localizacao | `geolocator` |
| Servico em 1o plano (Android) | `flutter_foreground_task` |
| Mapa | `google_maps_flutter` (estilo customizado) |
| Push notifications | Firebase Cloud Messaging (`firebase_messaging`) |
| Fila offline de pings | `sqflite` |
| Fontes | `google_fonts` (Manrope) |
| Backend | Node 18+ / Express / `pg` / `ws` / JWT / bcrypt / `firebase-admin` |
| Banco | PostgreSQL 14+ (local ou Supabase, so como Postgres gerenciado) |
| Realtime | WebSocket nativo (`ws`) |

Nao ha nenhuma dependencia com licenca paga (trocamos o
`flutter_background_geolocation` da Transistorsoft por `geolocator` +
`flutter_foreground_task`, ambos gratuitos).

## Ambiente local ja instalado nesta maquina
- **Flutter 3.44.8** (stable) em `C:\flutter`, via `git clone --depth 1`.
- **JDK 17** (Microsoft OpenJDK) em
  `C:\Program Files\Microsoft\jdk-17.0.20.8-hotspot`.
- **Android SDK** em `C:\Android\sdk` (platform-tools, platforms 34/35/36,
  build-tools 28.0.3/35.0.0/36.0.0, NDK, CMake — licencas aceitas).
- **Emulador Android** (`vaiescolar_test`, Android 15 x86_64 google_apis,
  headless) — usado para testar os dois apps de verdade, ver abaixo.
- `JAVA_HOME`, `ANDROID_HOME` e os `bin`/`platform-tools` correspondentes
  ja estao no PATH do usuario (persistente entre sessoes de terminal).
- **Falta**: Visual Studio (so necessario para apps Windows desktop, fora
  do escopo) e Xcode (build iOS — precisa de macOS).

## Testado de verdade num emulador (nao so analise estatica)
Instalei os APKs debug dos dois apps no emulador `vaiescolar_test` e rodei o
loop completo contra o backend real (Supabase), controlando tudo via `adb`
(tap, texto, screenshots, `adb emu geo fix` para simular GPS):
motorista faz login → carrega "Rota Manha" do backend → concede permissao de
localizacao/notificacao (dialogos reais do Android) → INICIAR ROTA → fila
offline envia um ping de GPS real que chega no backend → marca "Embarcou" →
app dos pais (outra instancia, mesmo emulador) mostra a mesma viagem, o
card de status e a timeline.

Isso encontrou e corrigiu um bug real que `flutter analyze`/`build` nunca
pegariam: o WebSocket do app dos pais nao reconectava depois do app voltar
do segundo plano (o SO derruba a conexao). Corrigido com
`WidgetsBindingObserver` em `parent_map.dart` — reconecta e busca o ultimo
estado conhecido (posicao + evento) sempre que o app volta ao 1o plano.
Detalhes em `app_pais/README.md`.

Na rodada de gestao/perfil/push do motorista, repeti o mesmo metodo (toques
reais via `adb`, screenshots, `uiautomator dump` para achar coordenadas
exatas) para validar cada tela nova: veiculos, motoristas/responsaveis
(criar conta + resetar senha, confirmado logando via curl com a senha
nova), editar/excluir aluno e rota, perfil (com erro de senha errada
confirmado end-to-end), e o loop completo de push do chat nos dois sentidos
(motorista -> pai e pai -> motorista, com toque na notificacao abrindo o
chat certo nos dois apps).

## Firebase — configurado e testado com push real
Projeto Firebase real ("vaiescolar") conectado de ponta a ponta:
- `backend/firebase-service-account.json` — credencial que voce forneceu,
  salva localmente (coberta pelo `.gitignore`, nunca vai pro git).
- `push.js` **corrigido**: `firebase-admin` v14 mudou pra API modular
  (`admin.credential`/`admin.messaging()` nao existem mais no objeto
  default) — reescrito para `require('firebase-admin/app')` +
  `require('firebase-admin/messaging')`. So descobri isso testando de
  verdade (dry-run de envio), nao teria pego so com `node --check`.
- **App Android registrado automaticamente** no projeto Firebase via
  Firebase Management API (usando a propria service account para gerar um
  token OAuth2 e chamar a API REST — sem precisar abrir o console). Baixei
  o `google-services.json` resultante e apliquei em
  `app_pais/android/app/google-services.json`, com o plugin Gradle
  (`com.google.gms.google-services`) registrado em
  `android/settings.gradle.kts` e `android/app/build.gradle.kts`.
- **Testado no emulador**: o app pegou um token FCM real, registrou no
  backend (`POST /api/users/fcm-token`), e uma notificacao push real
  chegou na bandeja do sistema com o app em segundo plano.

## Google Maps — configurado e testado renderizando de verdade
Chave criada no mesmo projeto Google Cloud do Firebase ("vaiescolar"),
restrita por app Android (`com.example.app_pais` + SHA-1 do keystore de
debug `1A:6A:B2:0C:8E:D3:63:52:B3:E4:A5:7B:4C:44:58:1A:41:A4:DD:74`) —
aplicada em `app_pais/android/app/src/main/AndroidManifest.xml`. Se algum
dia precisar gerar uma build de release (keystore diferente), adicione o
SHA-1 daquele keystore na mesma chave ou crie uma nova.

Testado no emulador: os tiles do mapa carregaram de verdade (com o estilo
customizado do `assets/map_style.json` aplicado — POIs ocultos, visual
clean) e o marcador da van desenhado programaticamente apareceu
corretamente sobre o mapa.

## Ajustes finais (tudo que dava pra corrigir sem depender de conta externa)
- **Permissoes iOS**: `Info.plist` dos dois apps e `AppDelegate.swift` do
  app_pais (`GMSServices.provideAPIKey`) ja escritos — nao *testados* (build
  iOS exige Xcode/macOS), mas prontos para quando houver um Mac disponivel.
- **Marcador customizado da van**: `app_pais/lib/services/van_icon.dart`
  desenha o icone em tempo de execucao (Canvas -> PNG), sem depender de um
  asset PNG externo. Validado sem erros no emulador.
- **`npm audit` do backend**: `firebase-admin` atualizado para v14.2.0,
  reduzindo de 8 para 6 vulnerabilidades moderadas (as restantes so
  desapareceriam com um downgrade, que nao faz sentido). Retestado o fluxo
  completo apos o upgrade — nada quebrou.

## Ordem para subir tudo
1. `backend/` — crie o banco, rode as migrations, suba a API (Firebase e
   opcional, so afeta o push).
2. `app_motorista/` — aponte para a API, faca login, cadastre um aluno,
   gere o convite dele e inicie uma rota.
3. `app_pais/` — aponte para a API, use o codigo do convite para se
   cadastrar e acompanhe o mapa/timeline.

Cada pasta tem seu proprio README com os passos e o teste ponta a ponta.

## Arquitetura do loop de rastreamento + push
```
[App Motorista] --(POST pings GPS, fila offline)--> [Backend] --(WebSocket)--> [App Pais]
   geolocator + foreground_task                        guarda ultima posicao      mapa ao vivo
   (GPS puro, so com rota ativa)                        + retransmite p/ inscritos + timeline
                                                         |
                                                         +--(FCM)--> notificacao push
                                                             ("van saiu", "Fulano embarcou")
```

## Onboarding do responsavel (sem atrito)
O motorista nunca digita o cadastro de um pai. Ele gera, para cada aluno,
um **codigo de convite** de 6 caracteres (`POST /api/students/:id/invite`,
valido por 7 dias, mostrado como texto grande + QR). O pai abre o app,
toca em "Tenho um codigo", digita (ou escaneia) e se auto-cadastra
(`POST /api/auth/register-parent`), ja vinculado ao aluno certo.

## Isolamento multi-tenant
Cada operador (motorista/empresa) e um `tenant`. TODA tabela tem `tenant_id`
e TODA query filtra por ele. Um tenant nunca enxerga dados de outro.

## Sobre o banco: Postgres local ou Supabase
O backend usa Postgres puro (`pg` + SQL simples), entao tanto faz se o banco
roda localmente ou em um projeto Supabase — e so trocar a `DATABASE_URL`.
O que **nao** entra em jogo e a camada de BaaS do Supabase (Auth, Realtime,
Row Level Security via painel): autenticacao continua sendo bcrypt + JWT
proprios, e o tempo real continua sendo o WebSocket (`ws`) deste backend.
Veja `backend/README.md` para os detalhes da connection string.

## Criterios de aceite
- [x] Backend sobe, migrations criam todas as tabelas, `/health` responde.
      Testado contra um projeto Supabase real.
- [x] Fluxo curl completo funciona, incluindo cadastro de pai por codigo.
      Testado ponta a ponta: tenant -> motorista -> aluno -> rota -> convite
      -> cadastro do pai -> viagem -> ping -> evento -> timeline.
- [x] Codigo de convite invalido (404), ja usado (410) e expirado (410) sao
      rejeitados. Testado.
- [x] Pai nao consegue assinar via WS uma viagem sem filho vinculado (403);
      pai vinculado conecta normalmente. Testado com um script `ws`.
- [x] Nenhuma query sem filtro de `tenant_id` (revisao estatica de todos os
      endpoints).
- [x] Pings sem rede ficam na fila local (sqflite) e sao reenviados quando
      a rede volta. Testado num emulador real: o ping de GPS ficou na fila,
      o timer de flush enviou, e o backend recebeu e persistiu a posicao.
- [x] Push de "embarcou" chega com o app dos pais fechado. **Testado com um
      projeto Firebase real**: notificacao "VaiEscolar — Joaozinho embarcou
      na van as HH:MM" apareceu na bandeja do sistema com o app em segundo
      plano no emulador.
- [x] `flutter analyze` limpo nos dois apps (Flutter 3.44.8, 0 issues),
      `flutter test` passando, `flutter build apk --debug` gerando APK
      valido, e **os dois apps rodados de ponta a ponta num emulador
      Android real** (login, permissoes, rota, GPS, embarque, mapa,
      timeline — ver secao acima). Dark mode implementado via
      `ThemeMode.system` (nao forcado visualmente no teste).
- [x] Marcador recebe heading via WebSocket e aplica rotacao (`Marker.rotation`).
      **Testado com chave real do Google Maps**: os tiles do mapa (estilo
      customizado, POIs ocultos) e o marcador da van desenhado
      programaticamente (`van_icon.dart`) renderizaram de verdade no
      emulador, mostrando ruas reais do Centro Historico de Sao Paulo.
- [x] Nenhuma dependencia com licenca paga.
- [x] Escolas viram cadastro proprio e a migration liga os alunos existentes
      automaticamente. Testado: `Escola Alfa`/`Escola Gama` migraram sem
      acao manual, e o dropdown de escola no app funciona.
- [x] Financeiro manual: gerar cobrancas do mes, marcar pago/pendente, e o
      app dos pais refletindo o status. Testado de ponta a ponta com curl e
      depois pela UI real do emulador (toggle de status, contador de
      resumo, mes sem cobranca ainda).
- [x] Perfil do aluno mostra responsavel(is) vinculado(s) corretamente.
      Testado: `Joaozinho` -> `Maria Mae` aparece certo na tela.
- [x] Home dos dois apps redesenhada e validada no emulador (cards de
      estatistica do motorista, "Meus filhos" com escola + status de
      pagamento + atalho de mapa condicional no app dos pais).
- [x] Responsavel com mais de um filho consegue vincular o segundo via
      codigo, sem criar conta duplicada. Testado: Maria (que ja tinha
      Joaozinho) vinculou Pedro com um segundo codigo pela tela "Adicionar
      outro filho".
- [x] Falta avulsa: pai marca/cancela, motorista ve o chip "Ausente" na tela
      de presenca do dia certo. Testado de ponta a ponta, incluindo o pai
      SEM vinculo com o aluno levando 403 ao tentar marcar falta dele.
- [x] Tenant aceita mais de um admin. Testado: segunda conta admin criada e
      logada com sucesso, aparecendo na secao "Administradores".
- [x] Viagem grava o veiculo realmente usado (pode diferir do cadastrado na
      rota). Testado: trip iniciada com veiculo diferente do padrao aparece
      certo em Relatorios.
- [x] Ordem de embarque de uma rota e configuravel e reflete na tela de
      presenca do motorista. Testado: reordenado via setas na UI, nova ordem
      confirmada na tela de presenca da viagem seguinte.
- [x] Relatorios mostra historico financeiro (6 meses) e ultimas viagens
      (com veiculo usado). Testado com dados reais acumulados nas rodadas
      anteriores.

## Pendencias que so voce resolve (exigem hardware que nao tenho aqui)
- ~~Projeto Firebase real~~ — **feito**, ver secao acima.
- ~~Chave real do Google Maps~~ — **feito**: chave criada, restrita ao
  pacote `com.example.app_pais` + SHA-1 do keystore de debug, aplicada em
  `AndroidManifest.xml` e testada renderizando o mapa de verdade.
- **macOS/Xcode** — unico jeito de compilar/testar o build iOS. O codigo
  (Info.plist, AppDelegate.swift) ja esta pronto; falta so o
  `GoogleService-Info.plist` (precisa adicionar o app iOS no console do
  Firebase) e um Mac pra compilar/rodar.

## Roadmap (fora do escopo desta fase)
- Geofence automatico (embarque/desembarque por proximidade) e ETA
  ("a van chega em 5 min").
- Gateway de pagamento real (Pix/cartao via Mercado Pago ou similar) com
  cobranca automatica — hoje o financeiro e um ledger manual (o admin marca
  pago/pendente); contratos em PDF.
- Portal web dos pais (React/Next).
- Email/SMS para recuperacao de senha self-service (hoje e assistida pelo admin).

## LGPD / seguranca (isolamento + hardening feitos, resto anotado)
- Senhas com bcrypt; JWT e credenciais do Firebase fora do git (e fora da
  arvore do projeto — ver secao de revisao de seguranca acima).
- Consentimento do responsavel via checkbox no cadastro (app dos pais).
- Localizacao so e coletada com a rota ativa (nunca em segundo plano fora
  disso) — deixar isso explicito na politica de privacidade.
- Isolamento entre tenants/familias revisado e corrigido (5 endpoints),
  invalidacao de token por troca de senha, rate limiting, CORS configuravel,
  boot guard de `JWT_SECRET` fraco, suite de testes de integracao. Ver secao
  acima.
- Pendente antes de producao: validacao de payload (zod), Row Level Security
  no Postgres, HTTPS/WSS, retencao limitada do historico de `locations`
  (ex.: 90 dias), rotacionar a chave do Firebase (foi compartilhada nesta
  conversa). Detalhes em `backend/README.md`.
