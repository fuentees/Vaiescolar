import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../services/api.dart';
import '../services/api_result.dart';
import '../theme.dart';
import 'link_child_screen.dart';
import 'maintenance_screen.dart';
import 'notifications_screen.dart';
import 'parent_map.dart';
import 'student_detail_screen.dart';

String _formatDate(String iso) {
  final d = DateTime.parse(iso);
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
}

class _ActiveTrip {
  final String tripId;
  final String routeName;
  final String direction;
  _ActiveTrip(this.tripId, this.routeName, this.direction);
}

/// Home do app dos pais: lista TODOS os filhos do pai logado (GET
/// /api/students/mine), nao so quem tem viagem ativa hoje. Cada card mostra
/// escola, status de pagamento do mes e -- so quando ha uma viagem rolando --
/// um atalho pro mapa ao vivo.
class ChildrenListScreen extends StatefulWidget {
  const ChildrenListScreen({super.key});
  @override
  State<ChildrenListScreen> createState() => _ChildrenListScreenState();
}

class _ChildrenListScreenState extends State<ChildrenListScreen> {
  List<dynamic> _children = [];
  final Map<String, _ActiveTrip> _activeByStudent = {};
  final Map<String, String> _paymentStatusByStudent = {};
  final Map<String, Map<String, dynamic>> _nextAbsenceByStudent = {};
  bool _loading = true;
  bool _maintenance = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    // Chamada critica de boot: se falhar por rede/servidor, mostra a tela de
    // manutencao em vez da lista vazia/quebrada -- as outras chamadas abaixo
    // (viagens ativas, pagamentos, faltas) sao complementares e ja toleram
    // falha silenciosa (caem pra lista vazia).
    final childrenResult = await apiCall<List<dynamic>>(
      () => http.get(
        Uri.parse('${Config.apiBase}/api/students/mine'),
        headers: {'authorization': 'Bearer ${Api.token}'},
      ),
      (body) => body as List<dynamic>,
    );
    if (childrenResult is ApiOffline<List<dynamic>> ||
        childrenResult is ApiServerError<List<dynamic>>) {
      setState(() {
        _maintenance = true;
        _loading = false;
      });
      return;
    }
    final children = switch (childrenResult) {
      ApiData<List<dynamic>>(:final data) => data,
      _ => <dynamic>[],
    };
    if (!mounted) return;
    setState(() => _maintenance = false);

    final now = DateTime.now();
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';

    final results = await Future.wait([
      Api.activeTrips(),
      Api.myPaymentsForMonth(month),
      Api.myAbsences(),
    ]);
    final activeRows = results[0];
    final payments = results[1];
    final absences = results[2];

    _activeByStudent.clear();
    for (final row in activeRows) {
      _activeByStudent[row['student_id'] as String] = _ActiveTrip(
        row['trip_id'] as String,
        row['route_name'] as String? ?? 'Rota',
        row['direction'] as String,
      );
    }
    _paymentStatusByStudent.clear();
    for (final p in payments) {
      _paymentStatusByStudent[p['student_id'] as String] =
          p['status'] as String;
    }
    // absences ja vem ordenado por data -- a primeira ocorrencia de cada
    // aluno e a proxima falta marcada.
    _nextAbsenceByStudent.clear();
    for (final a in absences) {
      final studentId = a['student_id'] as String;
      _nextAbsenceByStudent.putIfAbsent(
          studentId, () => a as Map<String, dynamic>);
    }

    setState(() {
      _children = children;
      _loading = false;
    });
  }

  Future<void> _markAbsence(String studentId) async {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final chosen = await showDatePicker(
      context: context,
      initialDate: tomorrow,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 60)),
      helpText: 'Aluno nao vai neste dia',
    );
    if (chosen == null) return;
    final dateStr =
        '${chosen.year}-${chosen.month.toString().padLeft(2, '0')}-${chosen.day.toString().padLeft(2, '0')}';
    await Api.markAbsence(studentId, dateStr);
    _load();
  }

  Future<void> _cancelAbsence(String absenceId) async {
    await Api.cancelAbsence(absenceId);
    _load();
  }

  Future<void> _addChild() async {
    final linked = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LinkChildScreen()),
    );
    if (linked == true) _load();
  }

  Widget _buildAddChildCard() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: const Icon(Icons.person_add_alt),
        title: const Text('Adicionar outro filho'),
        subtitle: const Text('Use um novo codigo de convite do motorista'),
        onTap: _addChild,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_maintenance) return MaintenanceScreen(onRetry: _load);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meus filhos'),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            tooltip: 'Notificacoes',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationsScreen()),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _children.isEmpty
                  ? ListView(children: [
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: [
                            const SizedBox(height: 48),
                            Text(
                              'Nenhum filho vinculado ainda',
                              style: Theme.of(context).textTheme.titleMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Use o codigo de convite do motorista pra se cadastrar.',
                              style: Theme.of(context).textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      _buildAddChildCard(),
                    ])
                  : ListView.builder(
                      itemCount: _children.length + 1,
                      itemBuilder: (context, i) {
                        if (i == _children.length) return _buildAddChildCard();
                        final c = _children[i] as Map<String, dynamic>;
                        final studentId = c['id'] as String;
                        final trip = _activeByStudent[studentId];
                        final paymentStatus =
                            _paymentStatusByStudent[studentId];
                        final schoolName = c['school_name'] as String?;
                        final nextAbsence = _nextAbsenceByStudent[studentId];

                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          child: Column(children: [
                            ListTile(
                              title: Text(c['name'] as String),
                              isThreeLine: trip != null,
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(schoolName?.isNotEmpty == true
                                      ? schoolName!
                                      : 'Escola nao informada'),
                                  if (trip != null)
                                    Text(
                                      trip.direction == 'to_school'
                                          ? 'Indo para a escola'
                                          : 'Voltando para casa',
                                      style: const TextStyle(
                                          color: AppColors.success,
                                          fontWeight: FontWeight.w600),
                                    ),
                                ],
                              ),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (paymentStatus != null)
                                    Chip(
                                      label: Text(paymentStatus == 'paid'
                                          ? 'Pago'
                                          : 'Pendente'),
                                      backgroundColor: (paymentStatus == 'paid'
                                              ? AppColors.success
                                              : AppColors.accent)
                                          .withValues(alpha: 0.15),
                                      labelStyle: TextStyle(
                                        color: paymentStatus == 'paid'
                                            ? AppColors.success
                                            : AppColors.accent,
                                        fontSize: 12,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                              child: Wrap(
                                alignment: WrapAlignment.end,
                                children: [
                                  TextButton.icon(
                                    onPressed: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => StudentDetailScreen(
                                            studentId: studentId,
                                            name: c['name'] as String),
                                      ),
                                    ),
                                    icon: const Icon(Icons.info_outline,
                                        size: 18),
                                    label: const Text('Detalhes'),
                                  ),
                                  if (trip != null)
                                    TextButton.icon(
                                      onPressed: () =>
                                          Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => ParentMap(
                                            token: Api.token!,
                                            tripId: trip.tripId,
                                            studentNames: {
                                              studentId: c['name'] as String
                                            },
                                            direction: trip.direction,
                                            routeName: trip.routeName,
                                          ),
                                        ),
                                      ),
                                      icon: const Icon(Icons.map_outlined,
                                          size: 18),
                                      label: const Text('Acompanhar no mapa'),
                                    ),
                                  nextAbsence == null
                                      ? TextButton.icon(
                                          onPressed: () =>
                                              _markAbsence(studentId),
                                          icon: const Icon(Icons.event_busy,
                                              size: 18),
                                          label: const Text('Marcar falta'),
                                        )
                                      : TextButton.icon(
                                          onPressed: () => _cancelAbsence(
                                              nextAbsence['id'] as String),
                                          icon:
                                              const Icon(Icons.close, size: 18),
                                          label: Text(
                                              'Falta em ${_formatDate(nextAbsence['date'] as String)}'),
                                          style: TextButton.styleFrom(
                                              foregroundColor: AppColors.error),
                                        ),
                                ],
                              ),
                            ),
                          ]),
                        );
                      },
                    ),
            ),
    );
  }
}
