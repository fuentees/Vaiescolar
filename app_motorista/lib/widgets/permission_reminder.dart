import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
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
    var notifications = false;
    try {
      notifications = await PushService.notificationsAllowed();
    } catch (_) {}
    final permission = await Geolocator.checkPermission();
    final gps = await Geolocator.isLocationServiceEnabled();
    if (!mounted) return;
    setState(() {
      _notificationsAllowed = notifications;
      _locationAllowed = permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
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
