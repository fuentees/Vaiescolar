# App Motorista (Flutter)

Rastreamento em 1o plano com stack **100% gratuita** (sem licenca paga):
`geolocator` (GPS) + `flutter_foreground_task` (mantem o app vivo com uma
notificacao persistente enquanto a rota esta ativa) + `sqflite` (fila
offline de pings).

## Setup
```bash
flutter create .          # gera as pastas android/ e ios/ nativas (ja rodado neste repo)
flutter pub get
flutter analyze           # 0 issues (validado com Flutter 3.44.8)
flutter build apk --debug # build nativo real, ja validado (ver abaixo)
flutter run
```

`lib/config.dart` usa `String.fromEnvironment` com o default de sempre
(`http://10.0.2.2:3000`, que ja aponta pro emulador Android na mesma porta do
`backend`) — nao precisa mudar nada pra continuar testando no emulador. Pra
apontar pra um ambiente real (device fisico, producao), builde assim:
```bash
flutter build apk --dart-define=API_BASE=https://sua-api.com --dart-define=WS_BASE=wss://sua-api.com
```
`flutter analyze`
e `flutter build apk --debug` rodam limpos neste ambiente, e o app **ja foi
testado de verdade num emulador Android** (AVD `google_apis` API 35): login,
onboarding, rastreamento em 1o plano com posicoes reais persistindo na fila
offline, chat com reconexao de WebSocket, push notification (chegando e
com toque abrindo o chat certo) e todas as telas de gestao (alunos, rotas,
veiculos, usuarios) foram validadas com toques reais via `adb`, nao so com
`flutter analyze`. Falta so o build para iOS (precisa de macOS).

## Revisao de UX/produto — P0 corrigidos nesta rodada
- **Boot nao bloqueia mais esperando o Firebase**: `main()` so faz
  `Api.loadToken()` (rapido, local) antes de `runApp()` — Firebase/push
  virou uma funcao fire-and-forget chamada logo depois. Media ~16s ate a
  Activity aparecer no emulador; agora fica em ~3-4s. Splash propria (gerada
  com `flutter_native_splash`, cor `AppColors.primary`) substitui a splash
  branca padrao do Flutter enquanto nao existe logotipo definitivo.
- **Viagem ativa sobrevive a um kill do processo**: se o Android mata o app
  com uma rota em andamento, `_activeTripId` (so memoria) se perdia e a home
  voltava a mostrar "Iniciar rota" mesmo com a viagem ainda aberta no
  servidor. Agora, no `initState` da home, o app confere
  `GET /api/trips/mine/active` contra o que tinha salvo localmente
  (`TrackingService.persistedTripId`, em `SharedPreferences`) e, se o
  backend confirma uma viagem aberta que o app nao sabia, mostra um dialog
  "Viagem em aberto desde HH:MM — Continuar rastreamento / Finalizar
  viagem". Testado forcando `am force-stop` com uma rota ativa e reabrindo.
- **Confirmacao em acoes perigosas**: FINALIZAR ROTA agora pede confirmacao
  (mostrando rota + direcao + horario de inicio) antes de encerrar, com
  `SnackBar` de sucesso e, se a chamada falhar, mensagem de erro sem zerar o
  estado local (permite tentar de novo em vez de "perder" a viagem
  visualmente enquanto ela continua ativa no servidor). Marcar "Desceu" sem
  "Embarcou" registrado antes tambem pede confirmacao (o caminho normal —
  embarque, depois desembarque — nao pede nada, so o caso de pular etapa).
- **Bug real corrigido no caminho**: `Api.finishTrip` nao checava
  `res.statusCode` (sempre "funcionava" do ponto de vista do app, mesmo se o
  servidor retornasse erro) — agora retorna `bool`, e a home so limpa o
  estado local de viagem ativa se o servidor confirmou.
- **`lib/services/api_result.dart`** (novo): `ApiResult<T>` (`data`/`empty`/
  `offline`/`unauthorized`/`serverError`) + tratamento global de 401 (desloga
  e volta pro login sozinho). Fundacao pronta; a migracao tela por tela
  acontece nas proximas rodadas, conforme cada uma e mexida.

Aviso do Gradle (nao bloqueia o build): `flutter_foreground_task` ainda usa
o Kotlin Gradle Plugin "legado" em vez do Built-in Kotlin do Flutter —
versoes futuras do Flutter podem exigir uma atualizacao do pacote. Sem
acao necessaria por enquanto.

## Telas
- **Login** — autentica motorista (ou admin) via `POST /api/auth/login`.
  Tem links para "Sou novo aqui — criar conta" e "Esqueci minha senha"
  (dica explicando o fluxo assistido pelo admin, ja que nao ha email/SMS).
- **Cadastro** (`register_tenant_screen.dart`) — onboarding de um operador
  novo: cria o tenant + a conta admin do dono (`POST /api/auth/register-tenant`)
  e ja entra logado. E como uma van nova comeca a usar o produto sem
  depender de ninguem criar a conta manualmente.
- **Inicio** (`home_screen.dart`) — saudacao com o nome de quem esta logado e,
  so pro admin, a grade de estatisticas (Alunos/Veiculos/Rotas ativas hoje/
  Pendencias financeiras via `GET /api/dashboard/summary`, cada card
  navegavel pra tela correspondente).
- **Rota** (`active_route_screen.dart`) — antes de iniciar: dropdown de rota +
  direcao (ida/volta) + **veiculo** (pre-selecionado com o da rota, mas
  trocavel — pra quando a van quebra e o motorista pega outra naquele dia) e
  o botao INICIAR ROTA, que **recusa iniciar uma rota sem nenhum aluno
  vinculado** (checagem client-side contra `GET /api/routes/:id/students`
  antes de chamar `POST /api/trips/start`, com mensagem explicando o motivo).
  Com a rota ativa, a mesma tela vira a tela operacional: contador "N de M
  alunos", lista dos alunos da rota (`GET /api/trips/:id/students`, **na
  ordem de embarque configurada na rota**) com botoes grandes Embarcou/
  Desceu, chip laranja "Ausente" quando o responsavel avisou falta pra
  aquele dia, icone pra **ligar pro contato de emergencia** (`tel:`, so
  aparece se o aluno tiver telefone cadastrado), icone pra navegar ate o
  endereco, icone pra abrir o convite do responsavel, e FINALIZAR ROTA fixo
  no rodape. Antes essa marcacao de presenca era uma tela separada
  (`trip_students_screen.dart`, removida) — fundida aqui pra nao exigir uma
  navegacao extra durante a viagem.
- **Convidar responsavel** (`invite_screen.dart`) — gera e mostra o codigo de
  6 caracteres (`POST /api/students/:id/invite`, valido por 7 dias) em texto
  grande + QR (`qr_flutter`) para o pai escanear ou digitar no app dele.
- **Alunos** (`students_screen.dart` + `student_form_screen.dart`) — lista,
  exclui e abre o **cadastro/edicao como pagina propria** (antes era um
  `AlertDialog` — ganhou campos demais pra caber num dialog confortavelmente).
  `Form`/`TextFormField` com validacao de verdade, confirmacao ao sair com
  alteracao nao salva. Campos: nome, escola (dropdown + "+" pra criar uma
  nova sem sair da tela), turma/periodo, data de nascimento, endereco,
  mensalidade, URL de foto, ativo/inativo, contato de emergencia (nome +
  telefone, com mascara `(00) 00000-0000`), pessoas autorizadas a buscar, e
  **observacoes medicas** (dado
  sensivel — o backend so devolve esse campo pro admin, que e o unico papel
  com acesso a essa tela). Tocar num aluno abre o **perfil**
  (`student_detail_screen.dart`): escola (com endereco), endereco
  residencial, mensalidade, lista de responsaveis (nome/e-mail/telefone,
  com atalho pro convite) e o historico dos ultimos pagamentos com status
  colorido. So visivel pro **admin**, dentro da aba Gestao.
- **Escolas** (`schools_screen.dart`) — cadastro de escolas (nome, endereco,
  telefone). Alunos passam a vincular a uma escola daqui em vez de texto
  livre. So admin.
- **Rotas** (`routes_screen.dart` + `route_detail_screen.dart`) — lista,
  cria/edita (dialog com `Form`) e exclui rotas; dias da semana (chips
  Seg-Dom), horario planejado (`showTimePicker`), ativa/inativa; vincula/
  remove alunos delas e define **a ordem de embarque arrastando**
  (`ReorderableListView`, com `onReorderItem` — API atual do Flutter, ja que
  `onReorder` esta deprecated — antes eram setas ▲▼). Tambem so admin.
- **Veiculos** (`vehicles_screen.dart`) — lista, cria, **edita e exclui**
  (antes so criava) via dialog com `Form`: placa, modelo, ano, cor,
  capacidade, validade de documento (`showDatePicker`, com aviso na lista
  quando vence em menos de 30 dias), status disponivel/manutencao (badge
  vermelho na lista quando em manutencao). So admin.
- **Equipe e responsaveis** (`users_screen.dart`) — lista quem tem conta no
  tenant (agora com secao "Administradores" tambem — um tenant pode ter mais
  de um admin, ex.: socio/gerente), cria novas contas (motorista, responsavel
  ou outro admin), **edita nome/telefone** (telefone com mascara `(00) 00000-
  0000` via `mask_text_input_formatter`), reseta a senha de qualquer um deles
  (fluxo de "esqueci a senha" assistido pelo admin, ja que o produto nao tem
  email/SMS), e **desativa/reativa** contas em vez de excluir (login passa a
  rejeitar contas desativadas; nao deixa desativar a propria conta). Todos os
  dialogs viraram `StatefulWidget`s proprios com `Form`/dispose(), mostrar/
  ocultar senha, e validacao com mensagem visivel. So admin.
- **Relatorios** (`reports_screen.dart`) — cards de resumo do mes (faturado/
  recebido/pendente/inadimplencia), grafico de barras (faturado vs recebido
  por mes, `CustomPainter` proprio, sem lib de charting) com seletor de
  periodo (3/6/12 meses), e lista paginada ("Carregar mais") de viagens
  finalizadas com filtro por motorista/rota/veiculo, mostrando duracao,
  distancia (Haversine entre pings de GPS — aproximacao em linha reta) e
  quantidade de alunos por viagem. Tocar numa viagem abre
  `trip_detail_report_screen.dart` (timeline de embarque/desembarque,
  mesmo visual da timeline do `app_pais`). Exportacao CSV das viagens
  listadas via `share_plus`. So admin.
- **Financeiro** (`finance_screen.dart`) — controle manual de mensalidade:
  seletor de mes, card de resumo (pago/pendente/total + valor recebido),
  busca por nome e filtro pago/pendente, indicador visual de atraso
  (pendente com competencia de mes anterior), botao "Gerar cobrancas do mes"
  (cria uma cobranca pendente por aluno com mensalidade definida, avisando
  quem foi pulado por nao ter mensalidade), e um menu por cobranca com
  **"Marcar como pago"** (dialog: valor, data efetiva, forma de pagamento,
  observacao) e **"Estornar"** (confirmacao, volta pra pendente e limpa forma
  de pagamento/data). Exportacao CSV via `share_plus`. Sem gateway de
  pagamento — e so um ledger pra saber quem deve. So admin.
- **Minha conta** (`profile_screen.dart`) — dados da propria conta, atalhos
  pra **Configuracoes** e **Status do dispositivo**, trocar a propria senha e
  sair. Disponivel para qualquer usuario logado.
- **Notificacoes** (`notifications_screen.dart`) — feed unico de mensagens de
  chat recebidas + faltas avisadas pelos pais (`GET /api/notifications`),
  acessivel pelo sino no AppBar da aba Inicio.
- **Configuracoes** (`settings_screen.dart`) — tema claro/escuro/automatico
  (persistido via `SharedPreferences`, aplicado na hora em todo o app), versao
  do app (`package_info_plus`), atalhos pra Central de ajuda e Privacidade.
- **Status do dispositivo** (`device_status_screen.dart`) — GPS ligado,
  permissao de localizacao, conexao com a internet (`connectivity_plus`) e
  push registrado — diagnostico rapido quando "o app nao esta enviando minha
  posicao".
- **Auditoria** (`audit_screen.dart`, dentro de Gestao) — quem alterou o que
  (reset de senha, ativar/desativar conta, criar/editar/excluir aluno,
  excluir rota/veiculo, marcar pagamento/estornar), com filtro por tipo de
  entidade. So admin.
- **Central de ajuda** e **Privacidade e termos** (`help_screen.dart`,
  `privacy_screen.dart`) — FAQ e politica estaticos, acessiveis via
  Configuracoes. A politica esta marcada **RASCUNHO** — texto provisorio,
  precisa de revisao antes de publicar nas lojas.
- **Mensagens** (`chat_threads_screen.dart` + `chat_screen.dart`) — uma
  thread por responsavel do tenant; qualquer admin/driver pode falar nela
  (nao ha thread por motorista especifico). Reconecta o WebSocket
  automaticamente ao voltar do segundo plano, e recebe push (FCM) quando um
  responsavel manda mensagem com o app em segundo plano — tocar na
  notificacao abre esta tela direto. Lista de threads com **busca por nome**
  (so aparece com mais de 5 responsaveis) e **badge de nao lidas** por
  thread + total na aba (bottom nav). Conversa individual com **separadores
  de dia** ("Hoje"/"Ontem"/data), **status por mensagem** (enviando/enviado/
  falhou, com toque pra tentar de novo), autoscroll garantido, e aviso fixo
  de que o chat nao e canal de emergencia.

**Bug real encontrado testando o badge**: `unread_count` vem do backend como
`COUNT(*)` (bigint do Postgres, que o driver `pg` serializa como **string**
no JSON pra nao perder precisao) — o cast `(t['unread_count'] as num?)` no
Flutter quebrava com "type 'String' is not a subtype of type 'num?'" e
derrubava a tela de mensagens inteira. Corrigido no backend (`COUNT(*)::int`
na query, que ja serializa como numero de verdade) em vez de flexibilizar o
cast no app — mais simples e evita o mesmo bug em outro consumidor futuro do
mesmo campo.

## Navegacao (bottom nav, substituiu o drawer de 10 itens)
`app_shell.dart` — `BottomNavigationBar` com **Inicio / Rota / Mensagens** pra
todo mundo, mais **Gestao** so pro admin (motorista comum ve 3 abas, nao 4).
`management_hub_screen.dart` reune Alunos/Escolas/Rotas/Veiculos/Equipe/
Financeiro/Relatorios (o que antes ficava solto no drawer) numa lista dentro
da aba Gestao. "Minha conta" deixou de ser um item de menu e virou um icone
de pessoa no AppBar de cada aba (Inicio/Rota/Gestao). Motorista comum abre o
app direto na aba **Rota** (o que ele usa no dia a dia); admin abre em
**Inicio** (dashboard). O backend continua rejeitando com 403 mesmo que a UI
escondesse esses itens — a restricao real e sempre no servidor.

## Tela "Rota" — cronometro, GPS, alertas, navegar (P1 fase 2)
- **Cronometro e indicador de GPS**: `TrackingService` ganhou dois
  `ValueNotifier`s (`lastSentAt`, `gpsOnline`) atualizados a cada tentativa
  de flush do envio de localizacao; `active_route_screen.dart` roda um
  `Timer.periodic` de 1s enquanto a rota esta ativa pra mostrar o tempo
  decorrido desde o inicio e "Ultimo envio: ha Ns" (ou "Sem sinal de GPS
  ainda" se o ultimo envio falhou). Testado ao vivo: cronometro incrementando
  em tempo real, indicador atualizando a cada envio bem-sucedido (~15s).
- **Navegar ate o endereco do aluno**: icone novo por aluno (so aparece se
  `home_address` estiver preenchido — backend passou a incluir esse campo em
  `GET /api/trips/:id/students`, que antes so retornava id/nome/status/
  ausencia) abre o Google Maps via `url_launcher` (nova dependencia) com o
  endereco como destino. Testado: abre o app do Maps de verdade no emulador.
- **Alertas do dia** (aba Inicio, so admin): faltas marcadas pra hoje, rotas
  sem veiculo escolhido, rotas sem nenhum aluno vinculado, e **rotas com mais
  alunos vinculados que a capacidade do veiculo escolhido** (compara
  `route_students.length` com `vehicles.capacity`, quando ambos existem) —
  cada alerta e um card tocavel. Testado com dado real: "Rota Manha" (sem
  `vehicle_id` definido) aparece corretamente como alerta.
- **Confirmacao ao sair do app com rota ativa**: `PopScope` na tela "Rota"
  intercepta o botao voltar do Android quando ha uma viagem em andamento
  (`canPop: !tracking`) e confirma antes de fechar o app de verdade
  (`SystemNavigator.pop()`) — evita fechar o app sem querer no meio de uma
  rota. Testado: botao voltar mostra o dialog; "Cancelar" mantem o app aberto
  com a rota intacta.

**Bug real de layout encontrado testando as setas de reordenar** (historico —
as setas ▲▼ foram substituidas por arrastar/`ReorderableListView` depois,
ver Fase 5 abaixo): a linha de acoes de cada aluno em
`route_detail_screen.dart` com `IconButton`s no tamanho padrao nao cabia ao
lado do nome numa tela de 320dp — o nome quebrava letra por letra em vez de
palavra por palavra. Corrigido reduzindo cada `IconButton`
(`padding: EdgeInsets.zero`,
`constraints: BoxConstraints(minWidth: 28, minHeight: 28)`,
`visualDensity: VisualDensity.compact`) — o mesmo cuidado vale pra qualquer
`trailing` com mais de um botao numa `ListTile`.

**Bugs de overflow encontrados testando no emulador** (nao pegos por
`flutter analyze`, so aparecem rodando de verdade num aparelho/emulador
pequeno com o teclado aberto): os cards de estatistica da home estouravam
por poucos pixels (`childAspectRatio` grande demais pro conteudo de duas
linhas) e a tela de convite (`invite_screen.dart`, de uma rodada anterior)
nunca tinha sido envolvida num `SingleChildScrollView`. Ambos corrigidos.
Todos os dialogs com varios campos + texto de erro (perfil, veiculos,
usuarios, alunos) ja usam `SingleChildScrollView` por esse mesmo motivo.

**Bug real encontrado testando a invalidacao de token (rodada de seguranca
do backend)**: `Api.routes()` e `Api.tripStudents()` em `lib/services/api.dart`
faziam `jsonDecode(res.body) as List<dynamic>` sem checar `res.statusCode`
antes. Um 401 (corpo `{"error": "..."}`, nao uma lista) quebrava o cast com
uma excecao nao tratada e derrubava a tela (`driver_home.dart` chamando
`Api.routes()` no `_load`). So apareceu ao testar um token antigo sendo
rejeitado de verdade; `flutter analyze` nao pega esse tipo de erro em tempo
de execucao. Corrigido checando `res.statusCode != 200` antes do cast, mesmo
padrao ja usado no resto do arquivo (e em 100% do `app_pais`, que nao tinha
esse bug).

## Financeiro e Relatorios (P1 fase 6) — dois bugs reais encontrados testando ao vivo

Novo `lib/utils/money.dart` (`formatMoney`/`asNum`) compartilhado pelas duas
telas. Ambos os bugs abaixo escaparam de `flutter analyze` e `node --test`
(que passavam limpos) e so apareceram testando o ciclo completo no emulador
(marcar pago -> estornar -> conferir Relatorios):

- **"Estornar" nao fazia nada, sem erro visivel**: o app sempre manda os 4
  campos opcionais do `PUT /api/payments/:id` no corpo (usando `null`
  explicito pros que nao mudaram, nunca omite a chave) — e o backend
  rejeitava `amount: null` com 400 porque o schema zod correspondente nao
  tinha `.nullable()` (so `.optional()`, que aceita chave ausente mas nao
  `null` explicito). Como `_reverse()` no `finance_screen.dart` nao checava o
  `bool` de retorno de `Api.updatePayment`, o erro nunca chegava na tela — o
  botao "Estornar" so recarregava a lista com o mesmo estado de antes,
  parecendo simplesmente nao fazer nada. Corrigido no backend (detalhes no
  README dele) e no app: `_reverse()` agora mostra um `SnackBar` de erro se
  a chamada falhar, em vez de recarregar silenciosamente.
- **Tela de Relatorios crashava ao abrir**: `_summary['total_amount']`/
  `paid_amount` (e o mesmo campo dentro de cada mes do historico financeiro)
  fazem cast direto `as num?` em `reports_screen.dart` — mas colunas
  `numeric`/`decimal` do Postgres (caso de `amount` e de `SUM(amount)`)
  chegam como **String** no JSON (o driver `pg` evita converter pra `double`
  do JS por perda de precisao), nao como numero. A tela quebrava assim que
  abria com "type 'String' is not a subtype of type 'num?' in type cast".
  `formatMoney` (ja usado no Financeiro) ja era tolerante a isso via
  `num.tryParse`; os getters novos do Relatorios e o `CustomPainter` do
  grafico nao eram. Corrigido extraindo esse parsing tolerante pra um
  helper `asNum()` em `lib/utils/money.dart`, usado em todo campo numerico
  vindo do backend nas duas telas (a mesma categoria de bug do
  `unread_count` como bigint->String, documentada acima, mas causada por
  `numeric` em vez de `bigint` — os dois tipos do Postgres que o driver `pg`
  serializa como String por padrao).

## Paginas novas + estado de manutencao (P1 fase 7)

Fecha o P1 do review de UX/produto. Alem das telas ja descritas acima
(Notificacoes, Configuracoes, Status do dispositivo, Auditoria, Ajuda,
Privacidade):

- **Tema persistido**: `lib/services/theme_controller.dart` (`ValueNotifier`
  compartilhado, mesmo padrao ja usado no app — sem lib de state management
  nova). `main.dart` carrega a preferencia salva antes do `runApp` e o
  `MaterialApp` escuta o notifier via `ValueListenableBuilder`, entao trocar
  o tema em Configuracoes aplica na hora em qualquer tela aberta.
- **Estado de manutencao**: `maintenance_screen.dart` (tela cheia,
  "Nao foi possivel conectar ao VaiEscolar" + "Tentar novamente") aparece no
  lugar do dashboard do admin quando a chamada critica de boot
  (`GET /api/dashboard/summary`) falha por rede/servidor — usa o
  `apiCall`/`ApiResult` ja existente (fundacao da fase 0) direto no
  `home_screen.dart`, sem precisar mudar `Api.dashboardSummary()` (que
  continua com seu fallback ad-hoc pros outros consumidores).
- **`GET /api/students/:id` deixou de ser so-leitura-pro-motorista-admin**:
  o backend relaxou a permissao pra tambem aceitar o pai dono do aluno (ver
  `backend/README.md`) — sem efeito nesta tela (`student_detail_screen.dart`
  ja era admin-only e continua sendo, so o motorista/admin usa esse endpoint
  aqui).

**Verificado no emulador**: sino de notificacoes abrindo o feed real (mensagens
de chat de sessoes de teste anteriores, com "ha Nh" correto); Auditoria vazia
antes de qualquer acao, populada com "Pagamento estornado"/"Pagamento marcado
como pago" (+ nome de quem fez + horario) apos usar o fluxo do Financeiro, e o
filtro "Pagamentos" restringindo a lista corretamente; Status do dispositivo
mostrando os 4 indicadores corretos (GPS ligado, permissao "so com o app
aberto", Wi-Fi, push registrado); Configuracoes trocando pra tema escuro e
aplicando em toda a UI instantaneamente (inclusive nas telas de Ajuda/
Privacidade abertas a partir dali), depois voltando pra automatico.

## Push notifications (Firebase Cloud Messaging)
Configurado com `firebase_core` + `firebase_messaging` (`push_service.dart`),
mesmo padrao do `app_pais`: pede permissao, registra o token FCM no backend
(`POST /api/users/fcm-token`) e reencaminha o toque na notificacao pra tela
certa via `PushService.onTap`. Testado de ponta a ponta num emulador real —
mensagem enviada pelo app dos pais chega como notificacao do sistema aqui,
e tocar nela abre "Mensagens" direto.

Se for gerar seu proprio `android/app/google-services.json` via Firebase
Console/CLI/Management API, **confira se so tem uma `api_key`** no bloco do
seu app — se aparecer mais de uma (ex.: uma chave de Maps restrita junto com
a chave real do Firebase), o plugin `google-services` usa a **primeira** da
lista como `google_api_key`, e se essa primeira nao tiver permissao para as
APIs do Firebase Installations/Messaging, toda notificacao push falha
silenciosamente com `FIS_AUTH_ERROR` (visivel so no `adb logcat`, nao no
`flutter analyze`).

## Rastreamento: como funciona
1. Ao tocar **INICIAR ROTA**: pede permissao de localizacao + notificacao,
   inicia o `flutter_foreground_task` (notificacao "Rota em andamento") e
   abre um stream do `geolocator` (`bestForNavigation`, `distanceFilter: 20`).
2. Cada posicao e gravada primeiro na fila local (SQLite via `sqflite`).
   Um timer de 15s (e cada novo ping) tenta enviar o lote pendente para
   `POST /api/trips/:id/locations`. Sucesso remove da fila; falha ou sem
   rede mantem os pings para a proxima tentativa -- nada se perde numa area
   sem sinal.
3. Ao tocar **FINALIZAR ROTA**: tenta drenar a fila uma ultima vez, para o
   stream e encerra o foreground service.

`tracking_service.dart` usa a API do `flutter_foreground_task` 8.17.0
(`TaskHandler.onStart(DateTime, TaskStarter)` /
`onDestroy(DateTime)` / `onRepeatEvent(DateTime)`), ja validada com
`flutter analyze` (0 issues). Se voce atualizar o pacote para uma versao
major diferente, confira essas assinaturas de novo — elas mudam entre
majors.

## Permissoes obrigatorias
- **Android**: ja declaradas em `android/app/src/main/AndroidManifest.xml`
  (`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `FOREGROUND_SERVICE`,
  `FOREGROUND_SERVICE_LOCATION`, `POST_NOTIFICATIONS`, `INTERNET`).
- **iOS**: ja declaradas em `ios/Runner/Info.plist`
  (`NSLocationWhenInUseUsageDescription`,
  `NSLocationAlwaysAndWhenInUseUsageDescription`, `UIBackgroundModes` com
  `location`). So nao foi *testado* — precisa de macOS/Xcode para o
  primeiro build iOS, indisponivel neste ambiente.

Mostre uma tela explicativa **antes** do dialogo nativo de permissao (boa
pratica de conversao e transparencia com o motorista sobre por que a
localizacao e coletada).

## Privacidade
A localizacao so e coletada enquanto uma rota esta ativa (nunca em segundo
plano fora disso). Deixe isso explicito para o motorista na propria UI e na
politica de privacidade do produto.
