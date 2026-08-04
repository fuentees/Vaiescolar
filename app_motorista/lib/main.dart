import 'package:app_pais/screens/app_shell.dart' as parent_shell;
import 'package:app_pais/screens/chat_screen.dart' as parent_chat;
import 'package:app_pais/screens/parent_map.dart' as parent_map;
import 'package:app_pais/services/api.dart' as parent_api;
import 'package:app_pais/services/api_http.dart' as parent_http;
import 'package:app_pais/services/push_service.dart' as parent_push;
import 'package:app_pais/services/host_actions.dart' as parent_host;
import 'package:app_pais/services/app_refresh_signal.dart' as parent_refresh;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'screens/app_shell.dart' as driver_shell;
import 'screens/chat_threads_screen.dart';
import 'screens/profile_selector_screen.dart';
import 'services/api.dart' as driver_api;
import 'services/api_http.dart' as driver_http;
import 'services/profile_mode.dart';
import 'services/push_service.dart' as driver_push;
import 'services/theme_controller.dart';
import 'theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();
AppProfile? _initialProfile;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([
    driver_api.Api.loadToken(),
    parent_api.Api.loadToken(),
    ThemeController.load(),
  ]);
  _initialProfile = await ProfileMode.load();

  // Quem atualiza o antigo app do motorista preserva a sessao, mas ainda
  // nao tem `selected_app_profile`. Descobre o papel pelo servidor uma vez.
  if (_initialProfile == null && driver_api.Api.token != null) {
    final me = await driver_api.Api.me();
    final role = me?['role'] as String?;
    if (role == 'admin' || role == 'driver') {
      _initialProfile = AppProfile.driver;
      await ProfileMode.save(_initialProfile!);
    } else if (role == 'parent') {
      _initialProfile = AppProfile.parent;
      await ProfileMode.save(_initialProfile!);
    }
  }

  Future<void> handleUnauthorized(AppProfile source) async {
    // O APK contem dois clientes internos. Uma resposta atrasada do modulo
    // inativo nunca pode apagar a sessao nova do perfil escolhido.
    if (await ProfileMode.load() != source) return;
    await Future.wait([
      driver_api.Api.logout(),
      parent_api.Api.logout(),
      ProfileMode.clear(),
    ]);
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ProfileSelectorScreen()),
      (_) => false,
    );
  }

  driver_http.ApiHttp.onUnauthorized =
      () => handleUnauthorized(AppProfile.driver);
  parent_http.ApiHttp.onUnauthorized =
      () => handleUnauthorized(AppProfile.parent);
  parent_host.HostActions.switchProfile = () async {
    await Future.wait([
      driver_api.Api.logout(),
      parent_api.Api.logout(),
      ProfileMode.clear(),
    ]);
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ProfileSelectorScreen()),
      (_) => false,
    );
  };
  _initPushInBackground(_initialProfile);
  runApp(const VaiEscolarApp());
}

void _initPushInBackground(AppProfile? profile) async {
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(
        driver_push.firebaseMessagingBackgroundHandler);

    parent_push.PushService.onTap = (data) {
      if (data['type'] == 'chat') {
        navigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => const parent_chat.ChatScreen()),
        );
        return;
      }
      final tripId = data['tripId'] as String?;
      if (tripId != null) {
        navigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) => parent_map.ParentMap(
              token: parent_api.Api.token ?? '',
              tripId: tripId,
            ),
          ),
        );
      }
    };
    parent_push.PushService.onForeground = _showForegroundNotification;
    driver_push.PushService.onTap = (data) {
      if (data['type'] == 'chat') {
        navigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => const ChatThreadsScreen()),
        );
      }
    };
    driver_push.PushService.onForeground = _showForegroundNotification;

    if (profile == AppProfile.parent) {
      if (parent_api.Api.token != null) await parent_push.PushService.init();
    } else {
      if (driver_api.Api.token != null) await driver_push.PushService.init();
    }
  } catch (error) {
    if (kDebugMode) print('Firebase nao configurado - push desativado: $error');
  }
}

void _showForegroundNotification(
    String title, String body, Map<String, dynamic> data) {
  if (data['type'] == 'trip_started' ||
      data['type'] == 'trip_event' ||
      data['type'] == 'approaching') {
    parent_refresh.AppRefreshSignal.notifyTripsChanged();
  }
  final context = navigatorKey.currentContext;
  if (context == null) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(body.isEmpty ? title : '$title\n$body'),
    ));
}

class VaiEscolarApp extends StatelessWidget {
  const VaiEscolarApp({super.key});

  Widget _home() {
    if (_initialProfile == AppProfile.driver && driver_api.Api.token != null) {
      return const driver_shell.AppShell();
    }
    if (_initialProfile == AppProfile.parent && parent_api.Api.token != null) {
      return const parent_shell.AppShell();
    }
    return const ProfileSelectorScreen();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, mode, _) => MaterialApp(
        navigatorKey: navigatorKey,
        title: 'VaiEscolar',
        debugShowCheckedModeBanner: false,
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
        home: _home(),
      ),
    );
  }
}
