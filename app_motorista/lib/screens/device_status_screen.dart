import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../services/push_service.dart';
import '../theme.dart';

/// Diagnostico rapido do dispositivo: GPS ligado, permissao de localizacao
/// (incluindo "sempre", necessaria pro rastreamento em 1o plano continuar
/// funcionando), conexao com a internet e push registrado -- util quando o
/// motorista relata "o app nao esta enviando minha posicao".
class DeviceStatusScreen extends StatefulWidget {
  const DeviceStatusScreen({super.key});
  @override
  State<DeviceStatusScreen> createState() => _DeviceStatusScreenState();
}

class _DeviceStatusScreenState extends State<DeviceStatusScreen> {
  bool _loading = true;
  bool _gpsEnabled = false;
  LocationPermission _locationPermission = LocationPermission.denied;
  List<ConnectivityResult> _connectivity = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      Geolocator.isLocationServiceEnabled(),
      Geolocator.checkPermission(),
      Connectivity().checkConnectivity(),
    ]);
    if (!mounted) return;
    setState(() {
      _gpsEnabled = results[0] as bool;
      _locationPermission = results[1] as LocationPermission;
      _connectivity = results[2] as List<ConnectivityResult>;
      _loading = false;
    });
  }

  bool get _online =>
      _connectivity.isNotEmpty &&
      !_connectivity.contains(ConnectivityResult.none);

  String get _connectivityLabel {
    if (_connectivity.contains(ConnectivityResult.wifi)) return 'Wi-Fi';
    if (_connectivity.contains(ConnectivityResult.mobile)) {
      return 'Dados moveis';
    }
    if (_connectivity.contains(ConnectivityResult.ethernet)) return 'Ethernet';
    return 'Sem conexao';
  }

  String get _permissionLabel {
    switch (_locationPermission) {
      case LocationPermission.always:
        return 'Sempre (ideal para rastreamento em 1o plano)';
      case LocationPermission.whileInUse:
        return 'So com o app aberto (pode interromper o rastreamento)';
      case LocationPermission.denied:
        return 'Negada';
      case LocationPermission.deniedForever:
        return 'Negada permanentemente -- ajuste nas configuracoes do Android';
      case LocationPermission.unableToDetermine:
        return 'Nao foi possivel verificar';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Status do dispositivo')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _StatusTile(
                    icon: Icons.gps_fixed,
                    title: 'GPS do aparelho',
                    subtitle: _gpsEnabled
                        ? 'Ligado'
                        : 'Desligado -- ative para rastrear a rota',
                    ok: _gpsEnabled,
                  ),
                  _StatusTile(
                    icon: Icons.my_location,
                    title: 'Permissao de localizacao',
                    subtitle: _permissionLabel,
                    ok: _locationPermission == LocationPermission.always ||
                        _locationPermission == LocationPermission.whileInUse,
                  ),
                  _StatusTile(
                    icon: Icons.wifi,
                    title: 'Conexao com a internet',
                    subtitle: _online
                        ? _connectivityLabel
                        : 'Offline -- pings de GPS ficam na fila local',
                    ok: _online,
                  ),
                  _StatusTile(
                    icon: Icons.notifications_active_outlined,
                    title: 'Notificacoes push',
                    subtitle: PushService.isInitialized
                        ? 'Registrado'
                        : 'Nao registrado nesta sessao',
                    ok: PushService.isInitialized,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Se algo aparecer com problema, resolva no proprio Android '
                    '(Configurações > Apps > TECO) e puxe para atualizar esta tela.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool ok;
  const _StatusTile(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.ok});

  @override
  Widget build(BuildContext context) {
    final color = ok ? AppColors.success : AppColors.error;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          foregroundColor: color,
          child: Icon(icon, size: 20),
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing:
            Icon(ok ? Icons.check_circle : Icons.error_outline, color: color),
      ),
    );
  }
}
