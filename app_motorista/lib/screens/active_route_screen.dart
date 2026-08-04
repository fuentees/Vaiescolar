import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api.dart';
import '../services/tracking_service.dart';
import '../theme.dart';
import 'invite_screen.dart';
import 'profile_screen.dart';

/// Aba "Rota" -- comeca mostrando o seletor de rota/direcao/veiculo e o
/// botao de iniciar; assim que uma viagem fica ativa, vira a tela
/// operacional (presenca dos alunos + finalizar), absorvendo o que antes era
/// TripStudentsScreen numa tela separada.
class ActiveRouteScreen extends StatefulWidget {
  const ActiveRouteScreen({super.key});
  @override
  State<ActiveRouteScreen> createState() => _ActiveRouteScreenState();
}

class _ActiveRouteScreenState extends State<ActiveRouteScreen> {
  List<dynamic> _routes = [];
  List<dynamic> _vehicles = [];
  String? _routeId;
  String? _vehicleId;
  String _direction = 'to_school';
  String? _activeTripId;
  DateTime? _activeTripStartedAt;
  bool _busy = false;
  String? _error;

  List<dynamic> _students = [];
  bool _loadingStudents = false;
  final Set<String> _busyStudentIds = {};

  Timer? _clockTimer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    TrackingService.init();
    _load();
    Api.vehicles().then((v) {
      if (mounted) setState(() => _vehicles = v);
    });
    _checkActiveTrip();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  void _startClock() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  void _stopClock() {
    _clockTimer?.cancel();
    _clockTimer = null;
  }

  String _formatElapsed(DateTime since) {
    final d = _now.difference(since);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}min';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatSinceShort(DateTime at) {
    final diff = _now.difference(at);
    if (diff.inSeconds < 5) return 'agora mesmo';
    if (diff.inMinutes < 1) return 'ha ${diff.inSeconds}s';
    return 'ha ${diff.inMinutes}min';
  }

  Future<void> _navigateTo(String address) async {
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _call(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    await launchUrl(Uri.parse('tel:$digits'),
        mode: LaunchMode.externalApplication);
  }

  Future<void> _load() async {
    final r = await Api.routes();
    if (!mounted) return;
    setState(() {
      _routes = r;
      if (_routeId == null && r.isNotEmpty) {
        _routeId = r.first['id'];
        _vehicleId = r.first['vehicle_id'] as String?;
      }
    });
  }

  void _onRouteChanged(String? routeId) {
    final route =
        _routes.firstWhere((r) => r['id'] == routeId, orElse: () => null);
    setState(() {
      _routeId = routeId;
      _vehicleId = route?['vehicle_id'] as String?;
    });
  }

  /// Restaura o estado "rota em andamento" apos o processo ser morto pelo
  /// Android -- _activeTripId (memoria) e perdido, mas a viagem continua
  /// aberta no servidor. Confirma com o backend antes de decidir o que fazer.
  Future<void> _checkActiveTrip() async {
    final backendTrip = await Api.myActiveTrip();
    if (backendTrip == null) {
      await TrackingService.clearPersistedTripId();
      return;
    }
    if (_activeTripId == backendTrip['trip_id']) return; // ja consistente

    if (!mounted) return;
    final tripId = backendTrip['trip_id'] as String;
    final startedAt =
        DateTime.tryParse(backendTrip['started_at'] as String)?.toLocal();
    final routeName = backendTrip['route_name'] as String? ?? 'rota';
    final horario = startedAt != null
        ? '${startedAt.hour.toString().padLeft(2, '0')}:${startedAt.minute.toString().padLeft(2, '0')}'
        : '--:--';

    final continuar = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Viagem em aberto'),
        content: Text(
          'Você tem uma viagem em "$routeName" aberta desde $horario (de uma sessão anterior). '
          'Quer continuar o rastreamento ou finalizar essa viagem agora?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Finalizar viagem'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continuar rastreamento'),
          ),
        ],
      ),
    );

    if (continuar == true) {
      final started = await TrackingService.startTracking(
        tripId,
        direction: backendTrip['direction'] as String? ?? _direction,
      );
      if (!mounted) return;
      setState(() {
        _activeTripId = tripId;
        _activeTripStartedAt = startedAt;
        _routeId = backendTrip['route_id'] as String?;
        _vehicleId = backendTrip['vehicle_id'] as String?;
        _direction = backendTrip['direction'] as String? ?? _direction;
        if (!started) {
          _error =
              'Permissao de localizacao negada. O rastreamento nao foi retomado.';
        }
      });
      _startClock();
      _loadStudents();
    } else {
      await Api.finishTrip(tripId);
      await TrackingService.clearPersistedTripId();
    }
  }

  Future<void> _start() async {
    if (_routeId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final linkedStudents = await Api.routeStudents(_routeId!);
    if (!mounted) return;
    if (linkedStudents.isEmpty) {
      setState(() {
        _busy = false;
        _error =
            'Esta rota nao tem nenhum aluno vinculado. Adicione alunos em Gestao > Rotas antes de iniciar.';
      });
      return;
    }
    final tripId =
        await Api.startTrip(_routeId!, _direction, vehicleId: _vehicleId);
    if (!mounted) return;
    if (tripId != null) {
      final started = await TrackingService.startTracking(
        tripId,
        direction: _direction,
      );
      if (!mounted) return;
      if (started) {
        setState(() {
          _activeTripId = tripId;
          _activeTripStartedAt = DateTime.now();
        });
        _startClock();
        _loadStudents();
      } else {
        await Api.finishTrip(tripId);
        if (!mounted) return;
        setState(() => _error = TrackingService.startFailureReason ??
            'Não foi possível ativar a localização. Verifique o GPS e as permissões do app.');
      }
    } else {
      // Pode ter sido uma segunda tentativa concorrente. O backend devolve
      // conflito e esta consulta recupera a viagem que ja esta em andamento.
      await _checkActiveTrip();
      if (!mounted) return;
      if (_activeTripId == null) {
        setState(
            () => _error = 'Nao foi possivel iniciar a rota. Tente novamente.');
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _confirmFinish() async {
    if (_activeTripId == null || _busy) return;
    final route =
        _routes.firstWhere((r) => r['id'] == _routeId, orElse: () => null);
    final routeName = route?['name'] as String? ?? 'rota';
    final startedAt = _activeTripStartedAt;
    final horario = startedAt != null
        ? '${startedAt.hour.toString().padLeft(2, '0')}:${startedAt.minute.toString().padLeft(2, '0')}'
        : '--:--';
    final direcao =
        _direction == 'to_school' ? 'ida (para a escola)' : 'volta (para casa)';
    final pendentes = _students
        .where((student) =>
            student['absent'] != true && student['last_status'] != 'dropped')
        .length;
    final avisoPendencias = pendentes > 0
        ? '\n\nAtenção: $pendentes ${pendentes == 1 ? 'aluno ainda não teve o desembarque confirmado' : 'alunos ainda não tiveram o desembarque confirmado'}.'
        : '';

    final confirmado = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Finalizar rota?'),
        content: Text(
          '"$routeName" — $direcao, iniciada às $horario. '
          'O rastreamento será encerrado e não pode ser desfeito.'
          '$avisoPendencias',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Finalizar'),
          ),
        ],
      ),
    );
    if (confirmado != true) return;
    await _finish();
  }

  Future<void> _finish() async {
    if (_activeTripId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await Api.finishTrip(_activeTripId!);
    if (!mounted) return;
    if (ok) {
      // O rastreamento só pode parar depois que o servidor confirmar o fim.
      // Em uma falha de internet, a viagem continua ativa e o responsável
      // não fica sem localização enquanto o motorista tenta novamente.
      await TrackingService.stopTracking();
      if (!mounted) return;
      _stopClock();
      setState(() {
        _activeTripId = null;
        _activeTripStartedAt = null;
        _busy = false;
        _students = [];
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Rota finalizada')));
    } else {
      // Nao zera _activeTripId numa falha -- a viagem continua "ativa" ate
      // finalizar com sucesso, permitindo tentar de novo.
      setState(() {
        _busy = false;
        _error = 'Não foi possível finalizar. Confirme o desembarque de todos os alunos e tente novamente.';
      });
    }
  }

  Future<void> _loadStudents() async {
    if (_activeTripId == null) return;
    setState(() => _loadingStudents = true);
    final students = await Api.tripStudents(_activeTripId!);
    if (!mounted) return;
    setState(() {
      _students = students;
      _loadingStudents = false;
    });
  }

  Future<void> _mark(
      String studentId, String name, String type, String? currentStatus) async {
    String? receivedBy;
    // So confirma no caso de pular etapa (desembarque sem embarque
    // registrado) -- embarque normal na primeira marcacao nao precisa.
    if (type == 'dropped' && currentStatus != 'boarded') {
      final confirmado = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Confirmar desembarque'),
          content: Text(
              '$name ainda nao tem embarque registrado nesta viagem. Confirmar desembarque mesmo assim?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Confirmar')),
          ],
        ),
      );
      if (confirmado != true) return;
      if (!mounted) return;
    }
    if (type == 'dropped') {
      final controller = TextEditingController();
      receivedBy = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Quem recebeu $name?'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Nome da pessoa ou instituição',
              hintText: 'Ex.: Maria Silva ou Escola Municipal',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.length >= 2) Navigator.pop(dialogContext, value);
              },
              child: const Text('Confirmar desembarque'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (receivedBy == null) return;
    }
    setState(() => _busyStudentIds.add(studentId));
    final ok = await Api.registerEvent(
        tripId: _activeTripId!,
        studentId: studentId,
        type: type,
        receivedBy: receivedBy);
    if (ok) {
      await _loadStudents();
      await TrackingService.refreshProximityStops();
    }
    if (!mounted) return;
    setState(() => _busyStudentIds.remove(studentId));
  }

  @override
  Widget build(BuildContext context) {
    final tracking = _activeTripId != null;
    return PopScope(
      canPop: !tracking,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final sair = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Sair do app?'),
            content: const Text(
              'A rota continua ativa e o rastreamento continua enviando '
              'localizacao em segundo plano.',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancelar')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Sair')),
            ],
          ),
        );
        if (sair == true) SystemNavigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Rota do dia'),
          actions: [
            IconButton(
              icon: const Icon(Icons.person_outline),
              tooltip: 'Minha conta',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              ),
            ),
          ],
        ),
        body: tracking ? _buildActiveBody(context) : _buildSetupBody(context),
      ),
    );
  }

  Widget _buildSetupBody(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Rota do dia',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    DropdownButton<String>(
                      value: _routeId,
                      hint: const Text('Selecione a rota'),
                      isExpanded: true,
                      items: _routes
                          .map<DropdownMenuItem<String>>(
                              (r) => DropdownMenuItem(
                                    value: r['id'] as String,
                                    child: Text(r['name'] as String),
                                  ))
                          .toList(),
                      onChanged: _onRouteChanged,
                    ),
                    DropdownButton<String>(
                      value: _direction,
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(
                            value: 'to_school',
                            child: Text('Ida (para a escola)')),
                        DropdownMenuItem(
                            value: 'to_home', child: Text('Volta (para casa)')),
                      ],
                      onChanged: (v) => setState(() => _direction = v!),
                    ),
                    if (_vehicles.isNotEmpty)
                      DropdownButton<String>(
                        value: _vehicles.any((v) => v['id'] == _vehicleId)
                            ? _vehicleId
                            : null,
                        hint: const Text('Veiculo (opcional)'),
                        isExpanded: true,
                        items: _vehicles
                            .map<DropdownMenuItem<String>>(
                                (v) => DropdownMenuItem(
                                      value: v['id'] as String,
                                      child: Text(v['plate'] as String),
                                    ))
                            .toList(),
                        onChanged: (v) => setState(() => _vehicleId = v),
                      ),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(_error!,
                            style: const TextStyle(color: AppColors.error)),
                      ),
                    ElevatedButton(
                      onPressed: _busy || _routeId == null ? null : _start,
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.success,
                          foregroundColor: Colors.white),
                      child: const Text('INICIAR ROTA'),
                    ),
                  ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveBody(BuildContext context) {
    final boarded = _students
        .where((s) =>
            s['last_status'] == 'boarded' || s['last_status'] == 'dropped')
        .length;
    final startedAt = _activeTripStartedAt;
    final lastSentAt = TrackingService.lastSentAt.value;
    final gpsOnline = TrackingService.gpsOnline.value;
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          color: AppColors.success.withValues(alpha: 0.12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(
                  child: Text('Rastreamento ATIVO — enviando localizacao')),
              if (startedAt != null)
                Text(_formatElapsed(startedAt),
                    style: Theme.of(context).textTheme.titleSmall),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.auto_awesome,
                  size: 14, color: AppColors.primary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  TrackingService.proximityStatus.value,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Icon(
                gpsOnline ? Icons.gps_fixed : Icons.gps_off,
                size: 14,
                color: gpsOnline ? AppColors.success : AppColors.error,
              ),
              const SizedBox(width: 4),
              Text(
                lastSentAt == null
                    ? (gpsOnline
                        ? 'Aguardando primeiro envio de GPS'
                        : 'Sem sinal de GPS ainda')
                    : 'Ultimo envio: ${_formatSinceShort(lastSentAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
            if (_students.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('$boarded de ${_students.length} alunos',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: AppColors.error)),
            ],
          ]),
        ),
        Expanded(
          child: _loadingStudents && _students.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _loadStudents,
                  child: ListView.builder(
                    itemCount: _students.length,
                    itemBuilder: (context, i) {
                      final s = _students[i];
                      final id = s['id'] as String;
                      final name = s['name'] as String;
                      final status = s['last_status'] as String?;
                      final absent = s['absent'] == true;
                      final address = s['home_address'] as String?;
                      final emergencyPhone =
                          s['emergency_contact_phone'] as String?;
                      final busy = _busyStudentIds.contains(id);
                      final statusLabel = status == 'boarded'
                          ? 'Embarcou'
                          : status == 'dropped'
                              ? 'Desceu'
                              : 'Aguardando';

                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(name,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium),
                                            if (absent) ...[
                                              const SizedBox(width: 8),
                                              Chip(
                                                label: const Text('Ausente'),
                                                backgroundColor: AppColors
                                                    .accent
                                                    .withValues(alpha: 0.15),
                                                labelStyle: const TextStyle(
                                                    color: AppColors.accent,
                                                    fontSize: 12),
                                                visualDensity:
                                                    VisualDensity.compact,
                                                materialTapTargetSize:
                                                    MaterialTapTargetSize
                                                        .shrinkWrap,
                                              ),
                                            ],
                                          ],
                                        ),
                                        Text(statusLabel,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall),
                                      ],
                                    ),
                                  ),
                                  if (emergencyPhone != null &&
                                      emergencyPhone.trim().isNotEmpty)
                                    IconButton(
                                      icon: const Icon(Icons.phone_outlined),
                                      tooltip:
                                          'Ligar para o contato de emergencia',
                                      onPressed: () => _call(emergencyPhone),
                                    ),
                                  if (address != null &&
                                      address.trim().isNotEmpty)
                                    IconButton(
                                      icon:
                                          const Icon(Icons.directions_outlined),
                                      tooltip: 'Navegar ate o endereco',
                                      onPressed: () => _navigateTo(address),
                                    ),
                                  IconButton(
                                    icon: const Icon(Icons.person_add_alt),
                                    tooltip: 'Convidar responsavel',
                                    onPressed: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => InviteScreen(
                                            studentId: id, studentName: name),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              if (busy)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 8),
                                  child: Center(
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    ),
                                  ),
                                )
                              else
                                Row(children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: status == 'boarded'
                                          ? null
                                          : () => _mark(
                                              id, name, 'boarded', status),
                                      child: const Text('Embarcou'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: status == 'dropped'
                                          ? null
                                          : () => _mark(
                                              id, name, 'dropped', status),
                                      child: const Text('Desceu'),
                                    ),
                                  ),
                                ]),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton(
              onPressed: _busy ? null : _confirmFinish,
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white),
              child: const Text('FINALIZAR ROTA'),
            ),
          ),
        ),
      ],
    );
  }
}
