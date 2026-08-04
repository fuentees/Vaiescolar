import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'offline_queue.dart';

const _activeTripIdKey = 'active_trip_id';
const _geocodeCacheKey = 'proximity_geocode_cache_v1';

@visibleForTesting
bool isInsideApproachingWindow({
  required double distanceMeters,
  required double speedMetersPerSecond,
  required double accuracyMeters,
}) {
  if (accuracyMeters > 100 || distanceMeters > 2500) return false;
  final effectiveSpeed =
      speedMetersPerSecond >= 2 ? speedMetersPerSecond.clamp(4.2, 16.7) : 6.9;
  return distanceMeters / effectiveSpeed <= 330;
}

class _ProximityStop {
  final String studentId;
  final String name;
  final double lat;
  final double lng;
  final String? status;
  bool alertSent;

  _ProximityStop(
      {required this.studentId,
      required this.name,
      required this.lat,
      required this.lng,
      required this.status,
      required this.alertSent});
}

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_TrackingTaskHandler());
}

/// TaskHandler minimo: sua unica funcao e manter o processo Android vivo via
/// servico de 1o plano (com notificacao persistente). O stream de GPS em si
/// roda no isolate principal (ver TrackingService abaixo) -- isso e
/// suficiente porque o SO nao mata o processo enquanto o foreground service
/// estiver ativo, e evita duplicar estado entre isolates.
class _TrackingTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

/// Rastreamento em 1o plano com stack 100% gratuita (sem licenca paga):
///  - flutter_foreground_task: notificacao persistente + mantem o app vivo
///    enquanto a rota esta ativa (liga/desliga com o motorista, nunca 24/7).
///  - geolocator: stream de posicoes com GPS puro (bestForNavigation) e
///    filtro de distancia de 20m.
///  - offline_queue (sqflite): todo ping e gravado localmente primeiro; um
///    timer tenta reenviar em lote a cada 15s. Sucesso remove da fila;
///    falha/sem rede mantem para a proxima tentativa -- nada se perde numa
///    area sem sinal.
class TrackingService {
  static StreamSubscription<Position>? _positionSub;
  static Timer? _flushTimer;
  static String? _tripId;
  static String? _direction;
  static bool _initialized = false;
  static bool _evaluatingProximity = false;
  static String? startFailureReason;
  static List<_ProximityStop> _stops = [];

  /// Estado do ultimo envio de GPS -- consumido pela tela de rota ativa pra
  /// mostrar "ultimo envio: ha Ns" e um indicador online/offline. `null` em
  /// `lastSentAt` significa "ainda nao enviou nada nesta sessao".
  static final ValueNotifier<DateTime?> lastSentAt = ValueNotifier(null);
  static final ValueNotifier<bool> gpsOnline = ValueNotifier(true);
  static final ValueNotifier<String> proximityStatus =
      ValueNotifier('Preparando alertas automaticos');

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'vaiescolar_tracking',
        channelName: 'Rastreamento VaiEscolar',
        channelDescription: 'Notificacao enquanto a rota esta ativa',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWifiLock: true,
      ),
    );
  }

  static Future<bool> _ensurePermissions() async {
    startFailureReason = null;
    if (!await Geolocator.isLocationServiceEnabled()) {
      startFailureReason =
          'O GPS do celular está desligado. Ative a Localização e tente novamente.';
      gpsOnline.value = false;
      return false;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      startFailureReason = permission == LocationPermission.deniedForever
          ? 'A localização foi bloqueada. Abra Configurações > Apps > VaiEscolar > Permissões e permita a localização.'
          : 'Permissão de localização negada. Permita o acesso para iniciar a rota.';
      gpsOnline.value = false;
      return false;
    }

    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    final notifPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notifPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    return true;
  }

  /// Trip id salvo localmente (sobrevive a um kill do processo) -- usado no
  /// boot do app pra saber se *deveria* haver uma viagem rodando, antes de
  /// confirmar com o backend (ver ActiveRouteScreen.initState).
  static Future<String?> persistedTripId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeTripIdKey);
  }

  static Future<void> clearPersistedTripId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeTripIdKey);
  }

  /// Inicia o rastreamento apontando os pings para a viagem informada.
  /// Retorna false se as permissoes de localizacao nao foram concedidas.
  static Future<bool> startTracking(String tripId,
      {required String direction}) async {
    if (!await _ensurePermissions()) return false;
    _tripId = tripId;
    _direction = direction;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeTripIdKey, tripId);

    await FlutterForegroundTask.startService(
      notificationTitle: 'VaiEscolar',
      notificationText: 'Rota em andamento — enviando localizacao',
      callback: _startCallback,
    );
    unawaited(refreshProximityStops());

    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 20,
    );
    _positionSub =
        Geolocator.getPositionStream(locationSettings: settings).listen((pos) {
      gpsOnline.value = true;
      OfflineQueue.enqueue({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'speed': pos.speed,
        'heading': pos.heading,
        'accuracy': pos.accuracy,
        'recorded_at': pos.timestamp.toIso8601String(),
      });
      _flush();
      _evaluateProximity(pos);
    }, onError: (_) {
      gpsOnline.value = false;
      proximityStatus.value = 'GPS sem sinal — verificando novamente';
    });

    _flushTimer = Timer.periodic(const Duration(seconds: 15), (_) => _flush());
    return true;
  }

  static Future<void> refreshProximityStops() async {
    final tripId = _tripId;
    if (tripId == null) return;
    proximityStatus.value = 'Preparando alertas automaticos';
    final students = await Api.tripStudents(tripId);
    final prefs = await SharedPreferences.getInstance();
    final rawCache = prefs.getString(_geocodeCacheKey);
    final cache = rawCache == null
        ? <String, dynamic>{}
        : jsonDecode(rawCache) as Map<String, dynamic>;
    final resolved = <_ProximityStop>[];

    for (final item in students) {
      if (item['absent'] == true) continue;
      final address = (item['home_address'] as String?)?.trim();
      if (address == null || address.isEmpty) continue;
      double? lat;
      double? lng;
      lat = (item['home_lat'] as num?)?.toDouble();
      lng = (item['home_lng'] as num?)?.toDouble();
      final cached = cache[address];
      if ((lat == null || lng == null) && cached is Map) {
        lat = (cached['lat'] as num?)?.toDouble();
        lng = (cached['lng'] as num?)?.toDouble();
      }
      if (lat == null || lng == null) {
        try {
          final locations = await Geocoding().locationFromAddress(address);
          if (locations.isNotEmpty) {
            lat = locations.first.latitude;
            lng = locations.first.longitude;
            cache[address] = {'lat': lat, 'lng': lng};
          }
        } catch (_) {
          // Um endereco invalido nao pode interromper o rastreamento.
        }
      }
      if (lat != null && lng != null) {
        resolved.add(_ProximityStop(
          studentId: item['id'] as String,
          name: item['name'] as String,
          lat: lat,
          lng: lng,
          status: item['last_status'] as String?,
          alertSent: item['approaching_alert_sent'] == true,
        ));
      }
    }
    await prefs.setString(_geocodeCacheKey, jsonEncode(cache));
    if (_tripId != tripId) return;
    _stops = resolved;
    proximityStatus.value = resolved.isEmpty
        ? 'Alertas indisponiveis: cadastre os enderecos das paradas'
        : 'Alertas automaticos ativos';
  }

  static Future<void> _evaluateProximity(Position pos) async {
    if (_evaluatingProximity || _stops.isEmpty || pos.accuracy > 100) return;
    final next = _stops.cast<_ProximityStop?>().firstWhere(
          (stop) => _direction == 'to_home'
              ? stop!.status != 'dropped'
              : stop!.status != 'boarded' && stop.status != 'dropped',
          orElse: () => null,
        );
    if (next == null || next.alertSent) return;

    final distance = Geolocator.distanceBetween(
      pos.latitude,
      pos.longitude,
      next.lat,
      next.lng,
    );
    if (!isInsideApproachingWindow(
      distanceMeters: distance,
      speedMetersPerSecond: pos.speed,
      accuracyMeters: pos.accuracy,
    )) {
      return;
    }

    _evaluatingProximity = true;
    try {
      final tripId = _tripId;
      if (tripId == null) return;
      final ok = await Api.sendApproachingAlert(tripId, next.studentId);
      if (ok) {
        next.alertSent = true;
        proximityStatus.value =
            '${next.name}: responsaveis avisados automaticamente';
      }
    } finally {
      _evaluatingProximity = false;
    }
  }

  static Future<void> _flush() async {
    final tripId = _tripId;
    if (tripId == null) return;
    final pending = await OfflineQueue.pending();
    if (pending.isEmpty) return;
    final ok =
        await Api.sendLocations(tripId, pending.map((p) => p.data).toList());
    gpsOnline.value = ok;
    if (ok) {
      await OfflineQueue.remove(pending.map((p) => p.id).toList());
      lastSentAt.value = DateTime.now();
    }
  }

  static Future<void> stopTracking() async {
    await _flush();
    await _positionSub?.cancel();
    _positionSub = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    await FlutterForegroundTask.stopService();
    _tripId = null;
    _direction = null;
    _stops = [];
    await clearPersistedTripId();
    lastSentAt.value = null;
    gpsOnline.value = true;
    proximityStatus.value = 'Preparando alertas automaticos';
  }
}
