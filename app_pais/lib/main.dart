import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'services/api.dart';
import 'services/api_http.dart';
import 'services/push_service.dart';
import 'services/theme_controller.dart';
import 'services/app_refresh_signal.dart';
import 'screens/login_screen.dart';
import 'screens/app_shell.dart';
import 'screens/parent_map.dart';
import 'screens/chat_screen.dart';
import 'theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Api.loadToken();
  await ThemeController.load();

  // 401 em qualquer chamada de API (token invalido/expirado, senha trocada
  // em outro lugar) desloga e volta pro login de um so lugar, em vez de cada
  // tela ter que tratar isso sozinha.
  Future<void> handleUnauthorized() async {
    await Api.logout();
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  ApiHttp.onUnauthorized = handleUnauthorized;

  // Firebase e opcional aqui: sem google-services.json/GoogleService-Info.plist
  // configurados, initializeApp lanca e o app segue funcionando sem push.
  // Nao e await'ado antes do runApp -- podia levar ~16s no emulador e
  // prendia o app na splash. A UI sobe imediatamente; push fica disponivel
  // alguns segundos depois, sem bloquear nada visivel.
  _initPushInBackground();

  runApp(const PaisApp());
}

void _initPushInBackground() async {
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    PushService.onTap = (data) {
      if (data['type'] == 'chat') {
        navigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => const ChatScreen()),
        );
        return;
      }
      final tripId = data['tripId'] as String?;
      if (tripId != null) {
        navigatorKey.currentState?.push(
          MaterialPageRoute(
              builder: (_) =>
                  ParentMap(token: Api.token ?? '', tripId: tripId)),
        );
      }
    };
    PushService.onForeground = (title, body, data) {
      if (data['type'] == 'trip_started' ||
          data['type'] == 'trip_event' ||
          data['type'] == 'approaching') {
        AppRefreshSignal.notifyTripsChanged();
      }
      final context = navigatorKey.currentContext;
      if (context == null) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(body.isEmpty ? title : '$title\n$body'),
          action: SnackBarAction(
              label: 'Abrir', onPressed: () => PushService.onTap?.call(data)),
        ));
    };
    if (Api.token != null) await PushService.init();
  } catch (e) {
    if (kDebugMode) print('Firebase nao configurado - push desativado: $e');
  }
}

class PaisApp extends StatelessWidget {
  const PaisApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, mode, _) => MaterialApp(
        navigatorKey: navigatorKey,
        title: 'TECO',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: mode,
        locale: const Locale('pt', 'BR'),
        supportedLocales: const [Locale('pt', 'BR')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Api.token == null ? const LoginScreen() : const AppShell(),
      ),
    );
  }
}
