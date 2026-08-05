import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:geolocator/geolocator.dart';
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
  List<dynamic> _plannedStops = [];
  bool _loadingStudents = false;
  final Set<String> _busyStudentIds = {};

  Timer? _clockTimer;
  Timer? _studentsRefreshTimer;
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
    _studentsRefreshTimer?.cancel();
    super.dispose();
  }

  void _startClock() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _studentsRefreshTimer?.cancel();
    _studentsRefreshTimer = Timer.periodic(
        const Duration(seconds: 10), (_) => _loadStudents(silent: true));
  }

  void _stopClock() {
    _clockTimer?.cancel();
    _clockTimer = null;
    _studentsRefreshTimer?.cancel();
    _studentsRefreshTimer = null;
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

  Future<void> _openWhatsApp(String phone) async {
    var digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 10 || digits.length == 11) digits = '55$digits';
    await launchUrl(Uri.parse('https://wa.me/$digits'),
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
    final gpsEnabled = await Geolocator.isLocationServiceEnabled();
    final connections = await Connectivity().checkConnectivity();
    final online = !connections.contains(ConnectivityResult.none);
    if (!mounted) return;
    if (!gpsEnabled || !online) {
      setState(() {
        _busy = false;
        _error = !gpsEnabled
            ? 'O GPS está desligado. Ative a Localização antes de iniciar.'
            : 'Sem conexão com a internet. Conecte-se antes de iniciar a rota.';
      });
      return;
    }
    final route =
        _routes.firstWhere((r) => r['id'] == _routeId, orElse: () => null);
    final vehicle =
        _vehicles.firstWhere((v) => v['id'] == _vehicleId, orElse: () => null);
    final vehicleCapacity = vehicle?['capacity'] as int?;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Checklist antes da saída'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(
              leading: Icon(Icons.gps_fixed, color: AppColors.success),
              title: Text('GPS ativado')),
          const ListTile(
              leading: Icon(Icons.wifi, color: AppColors.success),
              title: Text('Internet conectada')),
          ListTile(
              leading: const Icon(Icons.route),
              title: Text(route?['name'] as String? ?? 'Rota selecionada')),
          ListTile(
              leading: const Icon(Icons.directions_bus),
              title: Text(
                  vehicle?['plate'] as String? ?? 'Veículo padrão da rota')),
          ListTile(
              leading: const Icon(Icons.groups),
              title: Text('${linkedStudents.length} alunos na rota'),
              subtitle: vehicleCapacity != null && vehicleCapacity > 0
                  ? Text('Capacidade do veículo: $vehicleCapacity lugares')
                  : const Text('Capacidade do veículo não informada')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Revisar')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Iniciar rota')),
        ],
      ),
    );
    if (confirmed != true) {
      if (mounted) setState(() => _busy = false);
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
        setState(() => _error = Api.lastError ??
            'Nao foi possivel iniciar a rota. Tente novamente.');
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
            student['absent'] != true &&
            student['last_status'] != 'dropped' &&
            student['last_status'] != 'not_found')
        .length;
    final avisoPendencias = pendentes > 0
        ? '\n\nAtenção: $pendentes ${pendentes == 1 ? 'aluno ainda não teve o desembarque confirmado' : 'alunos ainda não tiveram o desembarque confirmado'}.'
        : '';

    var vanChecked = false;
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setDialogState) => AlertDialog(
          title: const Text('Finalizar rota?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              '"$routeName" — $direcao, iniciada às $horario. '
              'O rastreamento será encerrado e não pode ser desfeito.'
              '$avisoPendencias',
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: vanChecked,
              contentPadding: EdgeInsets.zero,
              title: const Text('Conferi todos os bancos'),
              subtitle: const Text(
                  'Confirmo que nenhum aluno permaneceu dentro da van.'),
              onChanged: (value) =>
                  setDialogState(() => vanChecked = value == true),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white),
              onPressed:
                  vanChecked ? () => Navigator.pop(dialogContext, true) : null,
              child: const Text('Finalizar'),
            ),
          ],
        ),
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
        _error =
            'Não foi possível finalizar. Confirme o desembarque de todos os alunos e tente novamente.';
      });
    }
  }

  Future<void> _loadStudents({bool silent = false}) async {
    if (_activeTripId == null) return;
    if (!silent && mounted) setState(() => _loadingStudents = true);
    final results = await Future.wait([
      Api.tripStudents(_activeTripId!),
      Api.tripStops(_activeTripId!),
    ]);
    final students = results[0] as List<dynamic>;
    students.sort((a, b) {
      final absentA = a['absent'] == true ? 1 : 0;
      final absentB = b['absent'] == true ? 1 : 0;
      return absentA.compareTo(absentB);
    });
    final plan = results[1] as Map<String, dynamic>?;
    if (!mounted) return;
    setState(() {
      _students = students;
      _plannedStops = plan?['stops'] as List<dynamic>? ?? [];
      _loadingStudents = false;
    });
  }

  Future<void> _showPlannedStops() async {
    if (_plannedStops.isEmpty) await _loadStudents();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: .78,
          child: Column(children: [
            const ListTile(
              leading: Icon(Icons.route),
              title: Text('Paradas da rota'),
              subtitle: Text('Ordem manual preparada para várias escolas'),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _plannedStops.length,
                itemBuilder: (_, index) {
                  final stop = _plannedStops[index] as Map<String, dynamic>;
                  final school = stop['type'] == 'school';
                  final students = stop['students'] as List<dynamic>? ?? [];
                  final address = stop['address'] as String?;
                  return ListTile(
                    leading: CircleAvatar(child: Text('${index + 1}')),
                    title: Text(stop['name'] as String? ?? 'Parada'),
                    subtitle: Text([
                      if (school)
                        '${students.length} aluno${students.length == 1 ? '' : 's'}',
                      if (address != null && address.isNotEmpty) address,
                    ].join(' • ')),
                    trailing: Wrap(children: [
                      if (address != null && address.isNotEmpty)
                        IconButton(
                          tooltip: 'Navegar até esta parada',
                          icon: const Icon(Icons.navigation_outlined),
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _navigateTo(address);
                          },
                        ),
                      if (school)
                        IconButton(
                          tooltip: 'Confirmar alunos desta escola',
                          icon: const Icon(Icons.how_to_reg_outlined),
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _confirmSchoolDrop(stop);
                          },
                        ),
                    ]),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _confirmSchoolDrop(Map<String, dynamic> stop) async {
    final schoolId = stop['school_id'] as String?;
    final schoolName = stop['name'] as String? ?? 'esta escola';
    final boarded = _students
        .where((student) =>
            (schoolId != null
                ? student['school_id'] == schoolId
                : student['school_name'] == schoolName) &&
            student['last_status'] == 'boarded' &&
            student['emergency_return_active'] != true)
        .toList();
    if (boarded.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nenhum aluno embarcado pendente nesta escola.')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Confirmar chegada em $schoolName?'),
        content: Text(
          '${boarded.length} aluno${boarded.length == 1 ? '' : 's'} será${boarded.length == 1 ? '' : 'ão'} marcado${boarded.length == 1 ? '' : 's'} como entregue${boarded.length == 1 ? '' : 's'} nesta escola.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Voltar')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Confirmar todos')),
        ],
      ),
    );
    if (confirmed != true || _activeTripId == null) return;
    setState(() => _busy = true);
    var success = 0;
    for (final student in boarded) {
      final ok = await Api.registerEvent(
        tripId: _activeTripId!,
        studentId: student['id'] as String,
        type: 'dropped',
      );
      if (ok) success++;
    }
    await _loadStudents();
    await TrackingService.refreshProximityStops();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          '$success de ${boarded.length} alunos confirmados em $schoolName'),
    ));
  }

  Future<void> _mark(
      String studentId, String name, String type, String? currentStatus) async {
    final activeTripId = _activeTripId;
    if (activeTripId == null) return;
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
    setState(() => _busyStudentIds.add(studentId));
    final ok = await Api.registerEvent(
        tripId: activeTripId, studentId: studentId, type: type);
    if (ok) {
      HapticFeedback.mediumImpact();
      SystemSound.play(SystemSoundType.click);
      await _loadStudents();
      await TrackingService.refreshProximityStops();
    }
    if (!mounted) return;
    setState(() => _busyStudentIds.remove(studentId));
  }

  Future<void> _markNotFound(
      String studentId, String name, String? status) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Aluno não localizado?'),
        content: Text(
          'O responsável por $name será avisado de que o aluno não estava no ponto. Se ele aparecer depois, ainda será possível marcar o embarque.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Voltar')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Avisar responsável')),
        ],
      ),
    );
    if (confirmed == true) {
      await _mark(studentId, name, 'not_found', status);
    }
  }

  Future<void> _undo(String studentId) async {
    final tripId = _activeTripId;
    if (tripId == null) return;
    setState(() => _busyStudentIds.add(studentId));
    final undone = await Api.undoLastEvent(tripId, studentId);
    if (undone) {
      HapticFeedback.selectionClick();
      await _loadStudents();
      await TrackingService.refreshProximityStops();
    }
    if (mounted) setState(() => _busyStudentIds.remove(studentId));
  }

  Future<void> _startEmergencyReturn(String studentId, String name) async {
    final tripId = _activeTripId;
    if (tripId == null) return;
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Retorno de emergência — $name'),
        content: TextField(
          controller: reasonController,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Motivo (opcional)',
            hintText: 'Ex.: aluno passou mal',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Iniciar retorno')),
        ],
      ),
    );
    final reason = reasonController.text.trim();
    reasonController.dispose();
    if (confirmed != true) return;
    setState(() => _busyStudentIds.add(studentId));
    final ok = await Api.startEmergencyReturn(
        tripId, studentId, reason.isEmpty ? null : reason);
    if (ok) {
      HapticFeedback.mediumImpact();
      await _loadStudents();
      await TrackingService.refreshProximityStops();
    }
    if (mounted) setState(() => _busyStudentIds.remove(studentId));
  }

  Future<void> _reportIncident() async {
    final tripId = _activeTripId;
    if (tripId == null) return;
    String type = 'delay';
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Avisar ocorrência'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Tipo'),
              items: const [
                DropdownMenuItem(value: 'delay', child: Text('Atraso')),
                DropdownMenuItem(
                    value: 'breakdown', child: Text('Pane ou problema na van')),
                DropdownMenuItem(
                    value: 'accident', child: Text('Acidente / urgência')),
                DropdownMenuItem(
                    value: 'student_missing',
                    child: Text('Aluno não localizado')),
                DropdownMenuItem(
                    value: 'school_closed', child: Text('Escola fechada')),
                DropdownMenuItem(value: 'other', child: Text('Outro aviso')),
              ],
              onChanged: (value) => setDialogState(() => type = value!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLength: 500,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'O que aconteceu?',
                  hintText: 'Mensagem enviada aos responsáveis'),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Voltar')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Enviar aviso')),
          ],
        ),
      ),
    );
    final description = controller.text.trim();
    controller.dispose();
    if (confirmed != true || description.length < 3) return;
    setState(() => _busy = true);
    final ok = await Api.reportIncident(tripId, type, description);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          ok ? 'Responsáveis avisados' : 'Não foi possível enviar o aviso'),
    ));
  }

  Future<void> _sendSos() async {
    final tripId = _activeTripId;
    if (tripId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.sos, color: AppColors.error, size: 42),
        title: const Text('Enviar alerta SOS?'),
        content: const Text(
          'Todos os responsáveis desta rota receberão agora um alerta urgente com som. Use somente em uma emergência real.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Voltar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('ENVIAR SOS'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await Api.reportIncident(
      tripId,
      'sos',
      'O motorista acionou o SOS. Aguarde novas informações e mantenha o telefone disponível.',
    );
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'SOS enviado aos responsáveis'
          : 'Falha ao enviar SOS. Ligue para o serviço de emergência.'),
      backgroundColor: AppColors.error,
    ));
  }

  Future<void> _changeVehicle() async {
    final tripId = _activeTripId;
    if (tripId == null || _vehicles.isEmpty) return;
    String? selected = _vehicleId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Trocar veículo da rota'),
          content: DropdownButtonFormField<String>(
            initialValue:
                _vehicles.any((v) => v['id'] == selected) ? selected : null,
            decoration: const InputDecoration(labelText: 'Novo veículo'),
            items: _vehicles
                .where((v) => v['status'] != 'maintenance')
                .map<DropdownMenuItem<String>>((v) => DropdownMenuItem(
                    value: v['id'] as String,
                    child: Text(
                        '${v['plate']}${v['model'] == null ? '' : ' - ${v['model']}'}')))
                .toList(),
            onChanged: (value) => setDialogState(() => selected = value),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Voltar')),
            FilledButton(
                onPressed: selected == null
                    ? null
                    : () => Navigator.pop(dialogContext, true),
                child: const Text('Confirmar troca')),
          ],
        ),
      ),
    );
    if (confirmed != true || selected == null) return;
    final ok = await Api.changeTripVehicle(tripId, selected!);
    if (!mounted) return;
    if (ok) setState(() => _vehicleId = selected);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Veículo alterado e responsáveis avisados'
            : 'Não foi possível trocar o veículo')));
  }

  Future<void> _cancelTrip() async {
    final tripId = _activeTripId;
    if (tripId == null) return;
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancelar rota em andamento?'),
        content: TextField(
          controller: controller,
          maxLength: 500,
          maxLines: 3,
          decoration: const InputDecoration(
              labelText: 'Motivo obrigatório',
              hintText: 'Ex.: van apresentou uma pane'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Voltar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Cancelar rota'),
          ),
        ],
      ),
    );
    final reason = controller.text.trim();
    controller.dispose();
    if (confirmed != true || reason.length < 3) return;
    setState(() => _busy = true);
    final ok = await Api.cancelTrip(tripId, reason);
    if (!mounted) return;
    if (ok) {
      await TrackingService.stopTracking();
      if (!mounted) return;
      _stopClock();
      setState(() {
        _activeTripId = null;
        _activeTripStartedAt = null;
        _students = [];
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Rota cancelada e responsáveis avisados')));
    } else {
      setState(() {
        _busy = false;
        _error = 'Não foi possível cancelar a rota.';
      });
    }
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
            if (tracking)
              PopupMenuButton<String>(
                tooltip: 'Ocorrências e emergência',
                icon: const Icon(Icons.warning_amber_rounded),
                onSelected: (value) {
                  if (value == 'sos') _sendSos();
                  if (value == 'incident') _reportIncident();
                  if (value == 'vehicle') _changeVehicle();
                  if (value == 'cancel') _cancelTrip();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'sos',
                      child: ListTile(
                          leading: Icon(Icons.sos, color: AppColors.error),
                          title: Text('Enviar SOS'))),
                  PopupMenuItem(
                      value: 'incident',
                      child: ListTile(
                          leading: Icon(Icons.campaign_outlined),
                          title: Text('Avisar ocorrência'))),
                  PopupMenuItem(
                      value: 'vehicle',
                      child: ListTile(
                          leading: Icon(Icons.swap_horiz),
                          title: Text('Trocar veículo'))),
                  PopupMenuDivider(),
                  PopupMenuItem(
                      value: 'cancel',
                      child: ListTile(
                          leading: Icon(Icons.cancel_outlined,
                              color: AppColors.error),
                          title: Text('Cancelar rota'))),
                ],
              ),
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
    final gpsStale =
        lastSentAt != null && _now.difference(lastSentAt).inMinutes >= 2;
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
            if (gpsStale) ...[
              const SizedBox(height: 8),
              const Row(children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: AppColors.error),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'GPS sem atualização há mais de 2 minutos. Verifique sinal, internet e economia de bateria.',
                    style: TextStyle(
                        color: AppColors.error, fontWeight: FontWeight.w700),
                  ),
                ),
              ]),
            ],
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
              TextButton.icon(
                onPressed: _showPlannedStops,
                icon: const Icon(Icons.alt_route, size: 18),
                label: const Text('Ver todas as paradas'),
              ),
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
                      final emergencyReturn =
                          s['emergency_return_active'] == true;
                      final absent = s['absent'] == true;
                      final address = s['home_address'] as String?;
                      final schoolName = s['school_name'] as String?;
                      final schoolAddress = s['school_address'] as String?;
                      final navigationAddress =
                          _direction == 'to_school' && status == 'boarded'
                              ? schoolAddress
                              : address;
                      final emergencyPhone =
                          s['emergency_contact_phone'] as String?;
                      final busy = _busyStudentIds.contains(id);
                      final statusLabel = emergencyReturn
                          ? 'Retorno de emergência para casa'
                          : status == 'boarded'
                              ? 'Embarcou'
                              : status == 'dropped'
                                  ? 'Desceu'
                                  : status == 'not_found'
                                      ? 'Não localizado no ponto'
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
                                        if (schoolName != null &&
                                            schoolName.isNotEmpty)
                                          Text('Escola: $schoolName',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall),
                                      ],
                                    ),
                                  ),
                                  if (emergencyPhone != null &&
                                      emergencyPhone.trim().isNotEmpty)
                                    PopupMenuButton<String>(
                                      tooltip: 'Contatar responsável',
                                      icon: const Icon(
                                          Icons.contact_phone_outlined),
                                      onSelected: (value) {
                                        if (value == 'call') {
                                          _call(emergencyPhone);
                                        }
                                        if (value == 'whatsapp') {
                                          _openWhatsApp(emergencyPhone);
                                        }
                                      },
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                            value: 'call',
                                            child: Text('Ligar')),
                                        PopupMenuItem(
                                            value: 'whatsapp',
                                            child: Text('Abrir WhatsApp')),
                                      ],
                                    ),
                                  if (!absent &&
                                      navigationAddress != null &&
                                      navigationAddress.trim().isNotEmpty)
                                    IconButton(
                                      icon:
                                          const Icon(Icons.directions_outlined),
                                      tooltip: 'Navegar ate o endereco',
                                      onPressed: () =>
                                          _navigateTo(navigationAddress),
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
                              if (absent)
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color:
                                        AppColors.accent.withValues(alpha: .10),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Text(
                                    'Fora das paradas de hoje. Se a falta for cancelada, o aluno volta automaticamente para a rota.',
                                  ),
                                )
                              else if (busy)
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
                              else if (emergencyReturn)
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    onPressed: () =>
                                        _mark(id, name, 'dropped', status),
                                    icon: const Icon(Icons.home_rounded),
                                    label: const Text('Chegou em casa'),
                                  ),
                                )
                              else if (status == 'dropped')
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                        backgroundColor: AppColors.error),
                                    onPressed: () =>
                                        _startEmergencyReturn(id, name),
                                    icon: const Icon(Icons.emergency_rounded),
                                    label: const Text('Retorno de emergência'),
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
                              if (!absent &&
                                  !busy &&
                                  status != 'boarded' &&
                                  status != 'dropped')
                                SizedBox(
                                  width: double.infinity,
                                  child: TextButton.icon(
                                    onPressed: status == 'not_found'
                                        ? null
                                        : () => _markNotFound(id, name, status),
                                    icon: const Icon(Icons.person_off_outlined),
                                    label: const Text('Aluno não localizado'),
                                  ),
                                ),
                              if (!absent &&
                                  !busy &&
                                  status != null &&
                                  !emergencyReturn)
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton.icon(
                                    onPressed: () => _undo(id),
                                    icon: const Icon(Icons.undo, size: 18),
                                    label:
                                        const Text('Corrigir última marcação'),
                                  ),
                                ),
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
