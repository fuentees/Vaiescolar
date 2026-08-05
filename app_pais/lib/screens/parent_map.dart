import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geocoding/geocoding.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../services/api.dart';
import '../services/live_location.dart';
import '../services/van_icon.dart';
import '../theme.dart';
import 'timeline_screen.dart';

/// Mapa ao vivo. Busca a ultima posicao conhecida como fallback, conecta no
/// WebSocket e move o marcador (com interpolacao suave e rotacao pelo
/// heading). Um card flutuante sobre o mapa mostra o status atual, e um
/// botao abre a timeline de eventos do dia.
class ParentMap extends StatefulWidget {
  final String token;
  final String tripId;
  final Map<String, String> studentNames;
  final String? direction; // 'to_school' ou 'to_home'
  final String? routeName;
  final bool emergencyReturn;
  const ParentMap({
    super.key,
    required this.token,
    required this.tripId,
    this.studentNames = const {},
    this.direction,
    this.routeName,
    this.emergencyReturn = false,
  });

  @override
  State<ParentMap> createState() => _ParentMapState();
}

class _ParentMapState extends State<ParentMap> with WidgetsBindingObserver {
  LiveLocation _live = LiveLocation();
  GoogleMapController? _map;
  String? _mapStyle;
  BitmapDescriptor? _vanIcon;
  LatLng _pos = const LatLng(-23.55, -46.63); // fallback: Sao Paulo
  double _heading = 0;
  bool _hasPosition = false;
  Timer? _tween;
  Timer? _staleTicker;
  String? _statusText;
  DateTime? _statusAt;
  bool _tripFinished = false;
  bool _studentOnBoard = false;

  final Set<Marker> _extraMarkers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusText = widget.direction == 'to_home'
        ? 'Voltando para casa'
        : 'A caminho da escola';
    _studentOnBoard = widget.emergencyReturn;
    if (widget.emergencyReturn) {
      _statusText = 'Retorno de emergência para casa';
    }
    _loadMapStyle().then((style) {
      if (!mounted) return;
      setState(() => _mapStyle = style);
    });
    buildVanMarkerIcon().then((icon) {
      if (!mounted) return;
      setState(() => _vanIcon = icon);
    });
    _loadInitialState();
    _loadHomeAndSchoolMarkers();
    _connectLive();
    // Reavalia "GPS desatualizado" a cada 30s mesmo sem posicao nova chegando.
    _staleTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<String> _loadMapStyle() async {
    try {
      return await rootBundle
          .loadString('packages/app_pais/assets/map_style.json');
    } catch (_) {
      return rootBundle.loadString('assets/map_style.json');
    }
  }

  void _connectLive() {
    _live.connect(token: widget.token, tripId: widget.tripId);
    _live.stream.listen(_onNewPosition);
    _live.events.listen(_onEvent);
    _live.approaching.listen((alert) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Chegada para ${alert.studentName} em cerca de 5 min';
        _statusAt = alert.at;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('A van esta chegando para ${alert.studentName}.'),
      ));
    });
    _live.finished.listen((_) {
      if (mounted) setState(() => _tripFinished = true);
    });
  }

  // O WebSocket nao sobrevive a app ir para segundo plano (o SO throttla/mata
  // a conexao). Ao voltar ao 1o plano, reconecta e busca a ultima posicao
  // conhecida via HTTP como fallback (eventos que chegaram enquanto o app
  // estava em background nao sao "replayed" pelo hub, so a posicao mais
  // recente).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _live.dispose();
      _live = LiveLocation();
      _connectLive();
      _loadInitialState();
    }
  }

  // Busca a ultima posicao conhecida (fallback antes do WS) e o ultimo
  // evento ja registrado (para o card de status nao comecar generico numa
  // viagem que ja teve embarque/desembarque antes desta tela abrir).
  // Tambem confere se a viagem ainda esta ativa: o broadcast "trip_finished"
  // so chega se o WS estiver conectado no momento exato em que o motorista
  // finaliza -- se o app estava em segundo plano (WS cai sozinho), essa
  // checagem via REST e o unico jeito de descobrir que a viagem ja acabou.
  Future<void> _loadInitialState() async {
    final active = await Api.activeTrips();
    final stillActive = active.any((t) => t['trip_id'] == widget.tripId);
    final emergencyActive = active.any((t) =>
        t['trip_id'] == widget.tripId && t['emergency_return_active'] == true);
    final last = await Api.tripLocation(widget.tripId);
    final events = await Api.tripEvents(widget.tripId);
    if (!mounted) return;
    if (!stillActive) {
      setState(() => _tripFinished = true);
      return;
    }
    setState(() {
      if (emergencyActive) {
        _studentOnBoard = true;
        _statusText = 'Retorno de emergência para casa';
      }
      if (last != null) {
        _pos = LatLng(
            (last['lat'] as num).toDouble(), (last['lng'] as num).toDouble());
        _heading = (last['heading'] as num?)?.toDouble() ?? 0;
        _hasPosition = true;
        _statusAt =
            DateTime.tryParse(last['recorded_at'] as String? ?? '')?.toLocal();
      }
      if (events.isNotEmpty) {
        final lastEvent = events.last;
        _studentOnBoard = lastEvent['type'] == 'boarded';
        if (widget.emergencyReturn) {
          _studentOnBoard = true;
          _statusText = 'Retorno de emergência para casa';
        }
        final eventAt = DateTime.parse(lastEvent['at'] as String).toLocal();
        if (_statusAt == null || eventAt.isAfter(_statusAt!)) {
          final studentName = lastEvent['student_name'] as String;
          final action =
              lastEvent['type'] == 'boarded' ? 'embarcou' : 'chegou / desceu';
          _statusText = '$studentName $action';
          _statusAt = eventAt;
        }
      }
    });
    if (_hasPosition) {
      await _map?.animateCamera(
        CameraUpdate.newLatLngZoom(_pos, 17),
      );
    }
  }

  // Geocodifica o endereco de casa (do 1o filho desta viagem) e da escola,
  // uma vez, e cacheia como marcadores fixos no mapa. Usa GET
  // /api/students/mine (ja acessivel ao pai) em vez de um endpoint novo --
  // ele ja retorna home_address/school_address.
  Future<void> _loadHomeAndSchoolMarkers() async {
    final children = await Api.myChildren();
    final ids = widget.studentNames.keys.toSet();
    final mine = children
        .cast<Map<String, dynamic>>()
        .where((c) => ids.contains(c['id']));
    if (mine.isEmpty) return;
    final first = mine.first;
    final homeAddress = first['home_address'] as String?;
    final schoolAddress = first['school_address'] as String?;

    if (homeAddress != null && homeAddress.trim().isNotEmpty) {
      _geocode(homeAddress).then((pos) {
        if (pos == null || !mounted) return;
        setState(() {
          _extraMarkers.add(Marker(
            markerId: const MarkerId('home'),
            position: pos,
            icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueAzure),
            infoWindow: const InfoWindow(title: 'Casa'),
          ));
        });
      });
    }
    if (schoolAddress != null && schoolAddress.trim().isNotEmpty) {
      _geocode(schoolAddress).then((pos) {
        if (pos == null || !mounted) return;
        setState(() {
          _extraMarkers.add(Marker(
            markerId: const MarkerId('school'),
            position: pos,
            icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueGreen),
            infoWindow: const InfoWindow(title: 'Escola'),
          ));
        });
      });
    }
  }

  Future<LatLng?> _geocode(String address) async {
    try {
      final results = await Geocoding().locationFromAddress(address);
      if (results.isEmpty) return null;
      return LatLng(results.first.latitude, results.first.longitude);
    } catch (_) {
      return null; // endereco nao encontrado/sem internet -- so nao mostra o marcador
    }
  }

  void _onNewPosition(LivePosition p) {
    if (_tripFinished) return;
    final from = _pos;
    final to = LatLng(p.lat, p.lng);
    _tween?.cancel();
    setState(() {
      _heading = p.heading ?? _heading;
      _statusAt = DateTime.now();
    });
    if (!_hasPosition) {
      setState(() {
        _pos = to;
        _hasPosition = true;
      });
      _map?.animateCamera(CameraUpdate.newLatLngZoom(_pos, 17));
      return;
    }
    const steps = 20;
    var i = 0;
    _tween = Timer.periodic(const Duration(milliseconds: 50), (t) {
      i++;
      final f = i / steps;
      setState(() {
        _pos = LatLng(
          from.latitude + (to.latitude - from.latitude) * f,
          from.longitude + (to.longitude - from.longitude) * f,
        );
      });
      _map?.animateCamera(CameraUpdate.newLatLng(_pos));
      if (i >= steps) t.cancel();
    });
  }

  void _onEvent(TripEvent e) {
    if (widget.studentNames.isNotEmpty &&
        !widget.studentNames.containsKey(e.studentId)) {
      return;
    }
    final name = widget.studentNames[e.studentId] ?? 'Aluno';
    final action = e.type == 'emergency_return'
        ? 'retorno de emergência para casa'
        : e.type == 'boarded'
            ? 'embarcou'
            : 'chegou / desceu';
    setState(() {
      _statusText = '$name $action';
      _statusAt = DateTime.now();
      _studentOnBoard = e.type == 'boarded' || e.type == 'emergency_return';
      if (e.type == 'dropped') _tripFinished = true;
    });
  }

  String _timeLabel(DateTime? at) {
    if (at == null) return 'agora';
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return 'agora';
    if (diff.inMinutes < 60) return 'ha ${diff.inMinutes} min';
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return 'as $hh:$mm';
  }

  bool get _isStale {
    final at = _statusAt;
    if (at == null) return false;
    return DateTime.now().difference(at).inMinutes >= 5;
  }

  void _centerOnVan() {
    _map?.animateCamera(CameraUpdate.newLatLngZoom(_pos, 17));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tween?.cancel();
    _staleTicker?.cancel();
    _live.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final studentLabel = widget.studentNames.values.isEmpty
        ? 'Viagem'
        : widget.studentNames.values.join(', ');
    final direcaoLabel = widget.direction == 'to_home'
        ? 'Volta (para casa)'
        : 'Ida (para a escola)';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Onde esta a van'),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: _live.connected,
            builder: (context, connected, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                connected ? Icons.wifi : Icons.wifi_off,
                size: 20,
                color: connected ? AppColors.success : AppColors.error,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.timeline),
            tooltip: 'Timeline do dia',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => TimelineScreen(tripId: widget.tripId)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(target: _pos, zoom: 17),
                  style: _mapStyle,
                  onMapCreated: (c) {
                    _map = c;
                    if (_hasPosition) {
                      c.animateCamera(CameraUpdate.newLatLngZoom(_pos, 17));
                    }
                  },
                  markers: {
                    Marker(
                      markerId: const MarkerId('van'),
                      position: _pos,
                      rotation: _heading,
                      flat: true,
                      anchor: const Offset(0.5, 0.5),
                      icon: _vanIcon ??
                          BitmapDescriptor.defaultMarkerWithHue(
                              BitmapDescriptor.hueYellow),
                    ),
                    ..._extraMarkers,
                  },
                  myLocationEnabled: false,
                ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton.small(
                    heroTag: 'center',
                    onPressed: _centerOnVan,
                    child: const Icon(Icons.my_location),
                  ),
                ),
                if (_tripFinished)
                  const Positioned(
                    left: 16,
                    right: 16,
                    top: 16,
                    child: Card(
                      color: AppColors.success,
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('Acompanhamento encerrado — aluno chegou',
                            style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Card(
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                        color: AppColors.accent,
                        shape: BoxShape.circle,
                      ),
                      child:
                          const Icon(Icons.directions_bus, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(studentLabel,
                              style: Theme.of(context).textTheme.titleMedium),
                          if (!_studentOnBoard)
                            Text(
                              widget.routeName != null
                                  ? '${widget.routeName} · $direcaoLabel'
                                  : direcaoLabel,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          Text(
                            '$_statusText · atualizado ${_timeLabel(_statusAt)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (_isStale && !_tripFinished) ...[
                            const SizedBox(height: 4),
                            Row(children: [
                              const Icon(Icons.warning_amber,
                                  size: 14, color: AppColors.accent),
                              const SizedBox(width: 4),
                              Text(
                                'GPS desatualizado ha ${DateTime.now().difference(_statusAt!).inMinutes} min',
                                style: const TextStyle(
                                    color: AppColors.accent, fontSize: 12),
                              ),
                            ]),
                          ],
                          // Resumo textual do status, pra quem usa leitor de tela e nao
                          // consegue ler o mapa em si.
                          Semantics(
                            label:
                                'Status: $_statusText, atualizado ${_timeLabel(_statusAt)}'
                                '${_isStale ? ", GPS desatualizado" : ""}',
                            child: const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
