import 'package:firebase_messaging/firebase_messaging.dart';
import 'api.dart';

/// Precisa ser top-level para funcionar como background message handler do
/// FCM. Mensagens com payload "notification" ja sao exibidas automaticamente
/// pelo SO quando o app esta em background/terminado; nada a fazer aqui.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

typedef PushTapHandler = void Function(Map<String, dynamic> data);
typedef PushForegroundHandler = void Function(
    String title, String body, Map<String, dynamic> data);

/// Pede permissao de notificacao, registra o token FCM no backend e
/// encaminha toques em notificacoes (ex.: "nova mensagem de um responsavel")
/// para quem estiver ouvindo via [onTap] -- normalmente abre o chat.
class PushService {
  static PushTapHandler? onTap;
  static PushForegroundHandler? onForeground;
  static bool _initialized = false;

  /// Usado pela tela "Status do dispositivo" pra mostrar se o push ja foi
  /// registrado nesta sessao (Firebase pode falhar silenciosamente se o app
  /// nao tiver `google-services.json` configurado -- ver `main.dart`).
  static bool get isInitialized => _initialized;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    final token = await messaging.getToken();
    if (token != null) await Api.registerFcmToken(token);
    messaging.onTokenRefresh.listen(Api.registerFcmToken);

    FirebaseMessaging.onMessageOpenedApp
        .listen((message) => onTap?.call(message.data));

    FirebaseMessaging.onMessage.listen((message) {
      onForeground?.call(
        message.notification?.title ?? 'Nova notificacao',
        message.notification?.body ?? '',
        message.data,
      );
    });

    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) onTap?.call(initialMessage.data);
  }
}
