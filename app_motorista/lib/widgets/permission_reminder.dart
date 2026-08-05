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
  bool _notificationsAllowed = true;
  bool _locationAllowed = true;
  bool _gpsEnabled = true;
  bool _checking = true;
  bool _notificationPermanentlyDenied = false;
  bool _locationPermanentlyDenied = false;

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
    var notifications = true;
    var notificationPermanentlyDenied = false;
    try {
      notifications = await PushService.notificationsAllowed();
      notificationPermanentlyDenied =
          await PushService.notificationStatus() == AuthorizationStatus.denied;
    } catch (_) {
      // Uma falha temporaria do Firebase nao significa que o usuario negou
      // a permissao. Mantem o aviso oculto ate ser possivel confirmar.
    }
    final permission = await Geolocator.checkPermission();
    final gps = await Geolocator.isLocationServiceEnabled();
    if (!mounted) return;
    setState(() {
      _notificationsAllowed = notifications;
      _notificationPermanentlyDenied = notificationPermanentlyDenied;
      _locationAllowed = permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
      _locationPermanentlyDenied =
          permission == LocationPermission.deniedForever;
      _gpsEnabled = gps;
      _checking = false;
    });
  }

  Future<void> _request() async {
    if (!_notificationsAllowed) {
      try {
        await PushService.requestNotificationsPermission();
      } catch (_) {}
    }
    if (!_locationAllowed) await Geolocator.requestPermission();
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    if (_checking ||
        (_notificationsAllowed && _locationAllowed && _gpsEnabled)) {
      return const SizedBox.shrink();
    }
    final missing = <String>[
      if (!_notificationsAllowed) 'notificações',
      if (!_locationAllowed) 'localização',
      if (!_gpsEnabled) 'GPS',
    ].join(' e ');
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(children: [
            Icon(Icons.warning_amber_rounded,
                color: Theme.of(context).colorScheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
                child: Text(
              'Ative $missing para rastrear a rota e receber avisos.',
            )),
            if (!_notificationPermanentlyDenied && !_locationPermanentlyDenied)
              TextButton(onPressed: _request, child: const Text('Permitir')),
            IconButton(
              tooltip: 'Abrir configurações',
              onPressed: _gpsEnabled
                  ? Geolocator.openAppSettings
                  : Geolocator.openLocationSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
          ]),
        ),
      ),
    );
  }
}
