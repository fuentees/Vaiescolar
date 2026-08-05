import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../services/push_service.dart';

class PermissionReminder extends StatefulWidget {
  const PermissionReminder({super.key});

  @override
  State<PermissionReminder> createState() => _PermissionReminderState();
}

class _PermissionReminderState extends State<PermissionReminder>
    with WidgetsBindingObserver {
  bool _allowed = true;
  bool _checking = true;
  bool _permanentlyDenied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    var allowed = true;
    var permanentlyDenied = false;
    try {
      allowed = await PushService.notificationsAllowed();
      permanentlyDenied =
          await PushService.notificationStatus() == AuthorizationStatus.denied;
    } catch (_) {
      // Nao exibe um falso aviso quando a consulta ao Firebase falha.
    }
    if (mounted) {
      setState(() {
        _allowed = allowed;
        _permanentlyDenied = permanentlyDenied;
        _checking = false;
      });
    }
  }

  Future<void> _request() async {
    try {
      await PushService.requestNotificationsPermission();
    } catch (_) {}
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    if (_checking || _allowed) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(children: [
            Icon(Icons.notifications_off_outlined,
                color: Theme.of(context).colorScheme.onErrorContainer),
            const SizedBox(width: 10),
            const Expanded(
                child: Text(
              'Ative as notificações para receber embarques, chegadas e avisos.',
            )),
            if (!_permanentlyDenied)
              TextButton(onPressed: _request, child: const Text('Permitir')),
            const IconButton(
              tooltip: 'Abrir configurações',
              onPressed: Geolocator.openAppSettings,
              icon: Icon(Icons.settings_outlined),
            ),
          ]),
        ),
      ),
    );
  }
}
