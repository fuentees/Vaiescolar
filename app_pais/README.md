# App Pais (Flutter)

Mapa ao vivo estilizado + timeline do dia + push notifications (FCM), com
stack **100% gratuita**.

## Setup
```bash
flutter create .          # ja rodado neste repo
flutter pub get
flutter analyze           # 0 issues (validado com Flutter 3.44.8)
flutter build apk --debug # build nativo real, ja validado (ver abaixo)
flutter run
```

`lib/config.dart` usa `String.fromEnvironment` com o default de sempre
(`http://10.0.2.2:3000`, que ja aponta pro emulador Android) — nao precisa
mudar nada pra continuar testando no emulador. Pra apontar pra um ambiente
real (device fisico, producao), builde assim:
```bash
flutter build apk --dart-define=API_BASE=https://sua-api.com --dart-define=WS_BASE=wss://sua-api.com
```
`flutter analyze`, `flutter test` e
`flutter build apk --debug` ja rodaram limpos neste ambiente — o APK debug
compila e linka de verdade, incluindo `firebase_core`, `firebase_messaging`,
`google_maps_flutter` e `mobile_scanner` (mesmo sem projeto Firebase real:
o build so falha em runtime se `Firebase.initializeApp()` nao achar
configuracao, e isso ja esta tratado com try/catch). Falta so `flutter run`
num dispositivo/emulador conectado e a configuracao do Firebase/Google Maps
abaixo.

## Revisao de UX/produto — P0 corrigido nesta rodada
**Boot nao bloqueia mais esperando o Firebase**: `main()` so faz
`Api.loadToken()` (rapido, local) antes de `runApp()` — Firebase/push virou
uma funcao fire-and-forget chamada logo depois. Media ~16s ate a Activity
aparecer no emulador; agora fica em ~3-4s. Splash propria (gerada com
`flutter_native_splash`, cor `AppColors.primary`) substitui a splash branca
padrao do Flutter enquanto nao existe logotipo definitivo.

Tambem ganhou `lib/services/api_result.dart` (`ApiResult<T>` — `loading`
implicito/`data`/`empty`/`offline`/`unauthorized`/`serverError`) e um
tratamento global de 401: qualquer chamada de API que volte token invalido
desloga e volta pro login sozinha, em vez de cada tela ter que checar isso
(hoje uma fundacao pronta pra usar; a migracao tela por tela acontece nas
proximas rodadas, conforme cada uma e mexida).

## Navegacao (bottom nav, substituiu os 3 icones do AppBar)
`app_shell.dart` — `BottomNavigationBar` com **Inicio / Localizacao /
Mensagens / Conta**. Antes, "adicionar filho", chat e perfil eram 3
`IconButton`s pequenos espremidos no AppBar de "Meus filhos" (apertado em
telas de 320px) — agora sao abas de verdade. "Adicionar outro filho" deixou
de ser um icone e virou um card no fim da lista "Meus filhos", com texto
explicito. "Localizacao" (`location_tab_screen.dart`, novo) mostra o mapa da
viagem ativa mais recente entre todos os filhos, ou explica quando o
rastreamento vai aparecer se nao houver nenhuma agora — antes o unico jeito
de chegar no mapa era pelo card do filho, e a bottom nav precisa de um
destino direto.

Aviso do Gradle (nao bloqueia o build): `mobile_scanner` ainda usa o Kotlin
Gradle Plugin "legado" em vez do Built-in Kotlin do Flutter — versoes
futuras do Flutter podem exigir uma atualizacao do pacote. Sem acao
necessaria por enquanto.

## Telas
- **Login** (`login_screen.dart`) — autentica via `POST /api/auth/login`; so
  aceita usuarios com `role: parent`; tem os links "Tenho um codigo" e
  "Esqueci minha senha" (dica explicando que o motorista/admin reseta a
  senha pelo app dele, ja que nao ha email/SMS no produto).
- **Tenho um codigo** (`register_with_code_screen.dart`) — cadastro via
  codigo de convite (`POST /api/auth/register-parent`): campo de 6
  caracteres (com opcao de **escanear QR** via `mobile_scanner`), nome,
  e-mail, senha e checkbox de consentimento (LGPD).
- **Meus filhos** (`children_list_screen.dart`, tela inicial) — lista
  **todos** os filhos do pai logado (`GET /api/students/mine`), nao so quem
  tem viagem ativa hoje. Cada card mostra escola, status de pagamento do mes
  (badge verde "Pago" / laranja "Pendente", via `GET /api/payments/mine` —
  so leitura, e um ledger manual do admin), um botao **"Marcar falta"**
  (`showDatePicker`, default amanha) ou, se ja tem falta marcada, "Falta em
  DD/MM" com um X pra cancelar, e — so quando ha uma viagem rolando pra
  aquele aluno (`GET /api/trips/active`) — um atalho pro mapa. Antes era
  "Viagens ativas": so mostrava algo quando havia rota rolando, senao so um
  estado vazio generico.
- **Adicionar outro filho** (`link_child_screen.dart`, card no fim da lista
  de "Meus filhos") — um pai que **ja tem conta** vincula outro filho com um
  segundo codigo de convite (`POST /api/auth/link-child`), reaproveitando o
  mesmo campo de codigo + escaneamento de QR de "Tenho um codigo". Antes,
  usar um segundo codigo com o mesmo e-mail dava erro de cadastro duplicado
  — nao dava pra ter mais de um filho na van pela mesma conta.
- **Mapa ao vivo** (`parent_map.dart`) — mapa com **estilo customizado**
  (`assets/map_style.json`, POIs ocultos, visual clean), marcador com
  interpolacao suave (~1s, ~20 frames) e **rotacao pelo heading**, painel com
  aluno + **rota + direcao** + status atual + horario. Ao abrir, busca a
  ultima posicao **e** o ultimo evento ja registrado (`GET /api/trips/:id/location`
  + `GET /api/trips/:id/events`), entao o painel ja nasce com o status certo
  em vez de sempre mostrar o texto generico. O WebSocket e reconectado
  automaticamente quando o app volta do segundo plano (`WidgetsBindingObserver`
  + `didChangeAppLifecycleState`) — o SO derruba a conexao quando o app fica
  em background e ela nao voltava sozinha antes dessa correcao (achado
  testando de verdade num emulador, nao so com `flutter analyze`).
- **Timeline do dia** (`timeline_screen.dart`) — `GET /api/trips/:id/events`
  em uma linha do tempo vertical, visual pensado para o pai tirar print.
- **Chat** (`chat_screen.dart`, aba Mensagens) — conversa com "o motorista"
  do tenant (qualquer admin/driver responde na mesma thread). Reconecta o
  WebSocket automaticamente ao voltar do segundo plano, igual ao mapa.
  Recebe push quando o motorista/admin manda mensagem; tocar na notificacao
  abre esta tela direto (`PushService.onTap` verifica `data['type'] ==
  'chat'`). Separadores de dia ("Hoje"/"Ontem"/data), status por mensagem
  (enviando/enviado/falhou, toque pra tentar de novo), autoscroll garantido,
  aviso fixo de que nao e canal de emergencia, e **badge de nao lidas** na
  aba (poll a cada 20s em `AppShell` via `GET /api/chat/unread-count`, e
  reconferido ao entrar na aba — abrir a thread ja marca como lida no
  backend).
- **Minha conta** (`profile_screen.dart`, icone de pessoa na tela de Viagens
  ativas) — dados da propria conta, atalho pra **Configuracoes**, trocar a
  propria senha e sair.
- **Detalhes do filho** (`student_detail_screen.dart`, botao "Detalhes" no
  card do filho) — escola, endereco, contato de emergencia, pessoas
  autorizadas a buscar, observacoes medicas, responsaveis vinculados e
  ultimos pagamentos (`GET /api/students/:id`, que deixou de ser admin-only
  — ver `backend/README.md`). Tem um atalho pro **Historico de viagens**.
- **Historico de viagens** (`trip_history_screen.dart`) — viagens finalizadas
  envolvendo aquele filho especifico (`GET /api/trips/history?studentId=`),
  paginado, indicando se ele chegou a embarcar/descer em cada uma.
- **Notificacoes** (`notifications_screen.dart`) — feed unico de embarque/
  desembarque dos filhos + mensagens de chat (`GET /api/notifications`),
  acessivel pelo sino no AppBar de "Meus filhos".
- **Configuracoes** (`settings_screen.dart`) — tema claro/escuro/automatico
  (persistido, aplicado na hora), versao do app, atalhos pra Central de ajuda
  e Privacidade e termos.
- **Central de ajuda** e **Privacidade e termos** (`help_screen.dart`,
  `privacy_screen.dart`) — FAQ e politica estaticos. A politica esta marcada
  **RASCUNHO** — texto provisorio, precisa de revisao antes de publicar. O
  checkbox de consentimento em "Tenho um codigo" agora abre essa pagina ao
  tocar em "Politica de Privacidade" (`RichText` + `TapGestureRecognizer`).

**Nota de migracao**: sessoes salvas antes do `userId` existir no login
causavam um crash ("Null check operator") ao abrir o chat. `Api.loadToken()`
agora detecta isso e forca logout, pedindo login de novo -- achado testando
no emulador com uma sessao antiga ja salva.

## Paginas novas + estado de manutencao (P1 fase 7)

Fecha o P1 do review de UX/produto. Alem das telas ja descritas acima
(Detalhes do filho, Historico de viagens, Notificacoes, Configuracoes, Ajuda,
Privacidade):

- **Tema persistido**: `lib/services/theme_controller.dart` -- identico ao do
  `app_motorista` (`ValueNotifier` + `SharedPreferences`, sem lib de state
  management nova). `main.dart` carrega a preferencia antes do `runApp`.
- **Estado de manutencao**: `maintenance_screen.dart` aparece no lugar de
  "Meus filhos" quando a chamada critica de boot (`GET /api/students/mine`)
  falha por rede/servidor, usando `apiCall`/`ApiResult` (fundacao da fase 0)
  direto em `children_list_screen.dart`. As outras chamadas da tela (viagens
  ativas, pagamentos, faltas) continuam com o fallback silencioso de sempre
  -- so a lista de filhos em si e tratada como critica.
- **Card do filho reorganizado**: o toque no card virou tres acoes
  explicitas lado a lado ("Detalhes", "Acompanhar no mapa" -- so com viagem
  ativa -- e "Marcar falta"), no lugar de um unico `ListTile.onTap`
  condicional que só abria o mapa. Ficou mais claro que "Detalhes" sempre
  existe, mesmo sem viagem rolando.

## Mapa — melhorias (P1 fase 3)
- **Marcadores de casa e escola**: geocodifica `home_address`/`school_address`
  (ja retornados por `GET /api/students/mine`, sem endpoint novo) uma vez via
  `geocoding` (nova dependencia — a v3.0.0 inicial quebrava o build por causa
  de `geocoding_android` compilado contra uma API do Android antiga demais
  pra `androidx.lifecycle` 2.7.0; resolvido indo pra `geocoding: ^5.0.0`, que
  tambem mudou a API de funcao top-level `locationFromAddress(...)` pra
  `Geocoding().locationFromAddress(...)`). Falha silenciosamente (sem
  marcador) se o endereco nao geocodificar — testado no emulador: nao
  apareceu (esse ambiente nao tem os servicos de geocoding do Google
  totalmente configurados), mas nao quebrou nada.
- **Indicador de conexao do WebSocket**: `LiveLocation` ganhou um
  `ValueNotifier<bool> connected` (usa `WebSocketChannel.ready` +
  `onError`/`onDone`); um icone de wifi no AppBar reflete isso ao vivo.
- **Aviso de GPS desatualizado**: se a ultima posicao/evento passou de 5
  minutos, mostra um aviso no painel (`_isStale`), com um `Timer.periodic` de
  30s reavaliando mesmo sem posicao nova chegar — evita mostrar uma posicao
  velha como se fosse atual.
- **Botao "centralizar na van"**: `FloatingActionButton.small` sobre o mapa.
- **Aviso quando a viagem termina**: backend manda um broadcast
  `{type: 'trip_finished'}` (`hub.broadcast`) em `POST /api/trips/:id/finish`.
  **Bug real encontrado testando**: se o app estava em segundo plano no
  momento exato em que o motorista finaliza (o WS ja caiu, so reconecta
  quando o app volta ao 1o plano), esse broadcast nunca chegava e o mapa
  ficava mostrando a viagem como se ainda estivesse rolando. Corrigido
  conferindo via REST (`GET /api/trips/active`, ja usado em "Meus filhos") se
  a viagem ainda esta na lista de ativas sempre que a tela carrega/reconecta
  — nao so contando com o broadcast ao vivo. Testado ponta a ponta: finalizar
  a viagem com o app dos pais em segundo plano e depois voltar mostra
  "Viagem finalizada" corretamente.
- **Resumo textual do status** (`Semantics`) abaixo do card, pra quem usa
  leitor de tela.

## Correcao de fuso horario (bug real, 5 pontos)
`parent_map.dart`, `chat_screen.dart`, `chat_socket.dart` e
`live_location.dart` faziam `DateTime.parse(iso)` sem `.toLocal()` sobre
colunas `TIMESTAMPTZ` do backend — o horario mostrado no chat, na timeline e
no mapa ficava **3h atrasado** (UTC) pro usuario no Brasil. Corrigido
adicionando `.toLocal()` nesses 5 pontos. **Excecao que fica como esta**:
`children_list_screen.dart._formatDate` opera sobre `absences.date`, uma
coluna `DATE` pura (nao `TIMESTAMPTZ`) — adicionar `.toLocal()` ali
introduziria um bug de virar o dia errado (meia-noite UTC de um dia vira
21h do dia anterior em UTC-3).

## Push notifications (Firebase Cloud Messaging)
**Ja configurado e testado** com o projeto Firebase "vaiescolar":
- `android/app/google-services.json` — baixado via Firebase Management API
  (app Android `com.example.app_pais` registrado automaticamente com a
  service account do backend, sem precisar abrir o console).
- Plugin `com.google.gms.google-services` aplicado em
  `android/settings.gradle.kts` e `android/app/build.gradle.kts`.
- **iOS**: falta `GoogleService-Info.plist` (precisa adicionar o app iOS no
  console do Firebase e baixar o arquivo — nao automatizado, mas o restante
  do setup iOS, incluindo `GMSServices.provideAPIKey`, ja esta no codigo).

Testado no emulador: `Firebase.initializeApp()` inicializa com sucesso, o
app recebe um token FCM real e registra em `POST /api/users/fcm-token`, e
uma notificacao push real ("VaiEscolar — Fulano embarcou na van as HH:MM")
aparece na bandeja do sistema com o app em segundo plano.

Para replicar em outro projeto Firebase: crie o projeto, adicione um app
Android com o `applicationId` do seu projeto, baixe o `google-services.json`
e coloque em `android/app/google-services.json` (o plugin Gradle ja esta
aplicado). Sem esse arquivo, o app funciona normalmente (mapa, timeline,
convite) — so o push fica desativado (o `main.dart` captura o erro do
`Firebase.initializeApp()` e segue).

## Google Maps API Key
- **Android**: **ja configurada e testada** em
  `android/app/src/main/AndroidManifest.xml` (`com.google.android.geo.API_KEY`).
  Chave restrita ao pacote `com.example.app_pais` + SHA-1 do keystore de
  debug — se for gerar uma build de release, adicione o SHA-1 daquele
  keystore na mesma chave (ou crie uma separada) no Google Cloud Console.
  Testado no emulador: mapa com o estilo customizado e o marcador da van
  renderizando de verdade.
- **iOS**: placeholder `GMSServices.provideAPIKey("COLOQUE_SUA_CHAVE_AQUI")`
  em `ios/Runner/AppDelegate.swift` — troque pela chave real (pode ser a
  mesma do Android, ou restrinja uma separada por Bundle ID) e rode
  `pod install` num macOS antes do primeiro build iOS.

## Permissao de camera (para escanear QR)
- **Android**: `CAMERA`, `INTERNET` e `POST_NOTIFICATIONS` ja estao
  declaradas em `android/app/src/main/AndroidManifest.xml`.
- **iOS**: `NSCameraUsageDescription` ja esta em `ios/Runner/Info.plist`.

## Marcador customizado da van
`lib/services/van_icon.dart` desenha a "van amarela estilizada" em tempo de
execucao (Canvas -> PNG -> `BitmapDescriptor.bytes`) em vez de depender de
um asset PNG externo — resolve o pedido do design system sem precisar gerar
uma imagem binaria fora do codigo. `parent_map.dart` usa esse icone assim
que fica pronto (com o marcador padrao amarelo do Maps como fallback
enquanto carrega). **Testado e confirmado visualmente** no emulador com a
chave real do Google Maps — o icone aparece corretamente sobre o mapa. Para
trocar por uma arte feita por designer, basta substituir o conteudo de
`buildVanMarkerIcon()` por `BitmapDescriptor.fromAssetImage(...)` apontando
pro seu PNG.

## Testado de verdade num emulador Android
Rodei os dois apps lado a lado num emulador Android 15 (x86_64, headless)
contra o backend real (Supabase): login, "Rota Manha" carregada do backend,
permissoes nativas de localizacao/notificacao concedidas, INICIAR ROTA
disparando pings de GPS reais (via `adb emu geo fix`) que chegaram no
backend, embarque marcado no app do motorista aparecendo no app dos pais.
Foi assim que o bug de reconexao do WebSocket acima foi encontrado — so
apareceu ao alternar entre os dois apps de verdade, nao em analise estatica.
Nesta rodada, o mesmo metodo (toques reais via `adb`, nao so
`flutter analyze`) confirmou: chat com push chegando de verdade em ambos os
apps, toque na notificacao abrindo o chat certo, tela de perfil com dados
reais, e a dica de "esqueci minha senha".

Na rodada seguinte (multiplos filhos, faltas), o mesmo metodo (dessa vez com
`uiautomator dump` pra achar coordenadas exatas em vez de estimar, depois de
alguns toques perdidos por ir rapido demais) confirmou: vincular um segundo
filho a uma conta ja logada usando um codigo de convite novo, marcar falta
pra amanha com o date picker, cancelar a falta, e conferir que o
`GET /api/students/mine` do backend (que tinha um bug real de ordem de
rotas do Express, ver `backend/README.md`) funciona certo depois da correcao.

## Como testar o loop completo (incluindo push)
1. Suba o backend com Firebase configurado (veja `backend/README.md`).
2. No app do motorista: cadastre um aluno, gere o convite
   ("Convidar responsavel") e anote o codigo.
3. Neste app: toque em "Tenho um codigo", digite o codigo e crie a conta.
4. No app do motorista: inicie a rota (dispara push "A van iniciou a
   rota"). Marque presenca do aluno (dispara push "Fulano embarcou").
5. Neste app: com o app **fechado**, os pushes devem chegar; ao tocar neles
   o mapa da viagem deve abrir direto. Com o app aberto, o mapa e a
   timeline devem atualizar em tempo real via WebSocket.
