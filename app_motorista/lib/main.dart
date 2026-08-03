import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'services/api.dart';
import 'services/api_http.dart';
import 'services/push_service.dart';
import 'services/theme_controller.dart';
import 'screens/login_screen.dart';
import 'screens/app_shell.dart';
import 'screens/chat_threads_screen.dart';
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

  // Firebase e opcional aqui: sem google-services.json configurado, initializeApp
  // lanca e o app segue funcionando sem push (so nao avisa de mensagem nova).
  // Nao e await'ado antes do runApp -- inicializar o Firebase/registrar o
  // token de push podia levar ~16s no emulador, deixando o app preso na
  // splash. A UI sobe imediatamente; push fica disponivel alguns segundos
  // depois, sem bloquear nada visivel.
  _initPushInBackground();

  runApp(const MotoristaApp());
}

void _initPushInBackground() async {
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    PushService.onTap = (data) {
      if (data['type'] == 'chat') {
        navigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => const ChatThreadsScreen()),
        );
      }
    };
    PushService.onForeground = (title, body, data) {
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

class MotoristaApp extends StatelessWidget {
  const MotoristaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, mode, _) => MaterialApp(
        navigatorKey: navigatorKey,
        title: 'VaiEscolar Motorista',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: mode,
        home: Api.token == null ? const LoginScreen() : const AppShell(),
      ),
    );
  }
}
