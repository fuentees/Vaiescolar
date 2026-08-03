import 'package:firebase_messaging/firebase_messaging.dart';
import 'api.dart';

/// Precisa ser top-level (fora de qualquer classe) para funcionar como
/// background message handler do FCM -- registrado em main.dart via
/// FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler).
/// Mensagens com payload "notification" ja sao exibidas automaticamente pelo
/// SO quando o app esta em background/terminado; nada a fazer aqui.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

typedef PushTapHandler = void Function(Map<String, dynamic> data);
typedef PushForegroundHandler = void Function(
    String title, String body, Map<String, dynamic> data);

/// Pede permissao de notificacao, registra o token FCM no backend e
/// encaminha toques em notificacoes (app aberto pelo push) para quem
/// estiver ouvindo via [onTap] -- normalmente abre o mapa da viagem.
class PushService {
  static PushTapHandler? onTap;
  static PushForegroundHandler? onForeground;
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    final token = await messaging.getToken();
    if (token != null) await Api.registerFcmToken(token);
    messaging.onTokenRefresh.listen(Api.registerFcmToken);

    // App em 1o/2o plano e o usuario toca na notificacao.
    FirebaseMessaging.onMessageOpenedApp
        .listen((message) => onTap?.call(message.data));

    // Em primeiro plano o sistema nao desenha automaticamente a notificacao.
    // A UI exibe um SnackBar para o aviso nao desaparecer silenciosamente.
    FirebaseMessaging.onMessage.listen((message) {
      onForeground?.call(
        message.notification?.title ?? 'Nova notificacao',
        message.notification?.body ?? '',
        message.data,
      );
    });

    // App estava fechado e foi aberto por um toque na notificacao.
    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) onTap?.call(initialMessage.data);
  }
}
