import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
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

String _formatTime(String? value) {
  if (value == null || value.length < 5) return '';
  return value.substring(0, 5);
}

class _ActiveTrip {
  final String tripId;
  final String routeName;
  final String direction;
  final String? lastEventType;
  final DateTime? lastEventAt;
  final DateTime? locationAt;

  _ActiveTrip({
    required this.tripId,
    required this.routeName,
    required this.direction,
    this.lastEventType,
    this.lastEventAt,
    this.locationAt,
  });

  String get status {
    if (lastEventType == 'boarded') {
      return direction == 'to_school'
          ? 'Na van · indo para a escola'
          : 'Na van · voltando para casa';
    }
    if (lastEventType == 'dropped') {
      return direction == 'to_school' ? 'Chegou à escola' : 'Chegou em casa';
    }
    return 'Aguardando embarque';
  }

  IconData get icon {
    if (lastEventType == 'boarded') return Icons.directions_bus_rounded;
    if (lastEventType == 'dropped') return Icons.check_circle_rounded;
    return Icons.schedule_rounded;
  }
}

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
  String _firstName = '';
  int _newAlerts = 0;
  bool _loading = true;
  bool _maintenance = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final childrenResult = await apiCall<List<dynamic>>(
      () => http.get(
        Uri.parse('${Config.apiBase}/api/students/mine'),
        headers: {'authorization': 'Bearer ${Api.token}'},
      ),
      (body) => body as List<dynamic>,
    );
    if (!mounted) return;
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
    final now = DateTime.now();
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final results = await Future.wait<dynamic>([
      Api.activeTrips(),
      Api.myPaymentsForMonth(month),
      Api.myAbsences(),
      Api.me(),
      Api.notifications(limit: 30),
    ]);
    if (!mounted) return;

    _activeByStudent.clear();
    for (final dynamic item in results[0] as List<dynamic>) {
      final row = item as Map<String, dynamic>;
      _activeByStudent[row['student_id'] as String] = _ActiveTrip(
        tripId: row['trip_id'] as String,
        routeName: row['route_name'] as String? ?? 'Rota',
        direction: row['direction'] as String,
        lastEventType: row['last_event_type'] as String?,
        lastEventAt: DateTime.tryParse(row['last_event_at'] as String? ?? ''),
        locationAt:
            DateTime.tryParse(row['location_recorded_at'] as String? ?? ''),
      );
    }
    _paymentStatusByStudent.clear();
    for (final dynamic item in results[1] as List<dynamic>) {
      final p = item as Map<String, dynamic>;
      _paymentStatusByStudent[p['student_id'] as String] =
          p['status'] as String;
    }
    _nextAbsenceByStudent.clear();
    for (final dynamic item in results[2] as List<dynamic>) {
      final absence = item as Map<String, dynamic>;
      _nextAbsenceByStudent.putIfAbsent(
          absence['student_id'] as String, () => absence);
    }
    final me = results[3] as Map<String, dynamic>?;
    final fullName = me?['name'] as String? ?? '';
    final prefs = await SharedPreferences.getInstance();
    final lastSeen =
        DateTime.tryParse(prefs.getString('notifications_last_seen_at') ?? '');
    final notifications = results[4] as List<dynamic>;
    final newAlerts = notifications.where((item) {
      final createdAt = DateTime.tryParse(
          (item as Map<String, dynamic>)['created_at'] as String? ?? '');
      return createdAt != null &&
          (lastSeen == null || createdAt.isAfter(lastSeen));
    }).length;

    setState(() {
      _maintenance = false;
      _children = children;
      _firstName = fullName.trim().split(' ').firstOrNull ?? '';
      _newAlerts = newAlerts;
      _loading = false;
    });
  }

  Future<void> _openNotifications() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NotificationsScreen()),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'notifications_last_seen_at', DateTime.now().toUtc().toIso8601String());
    if (mounted) setState(() => _newAlerts = 0);
  }

  Future<void> _markAbsence(String studentId) async {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final chosen = await showDatePicker(
      context: context,
      initialDate: tomorrow,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 60)),
      helpText: 'Aluno não vai neste dia',
    );
    if (chosen == null) return;
    final date =
        '${chosen.year}-${chosen.month.toString().padLeft(2, '0')}-${chosen.day.toString().padLeft(2, '0')}';
    if (await Api.markAbsence(studentId, date)) await _load();
  }

  Future<void> _cancelAbsence(String absenceId) async {
    if (await Api.cancelAbsence(absenceId)) await _load();
  }

  Future<void> _addChild() async {
    final linked = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LinkChildScreen()),
    );
    if (linked == true) _load();
  }

  void _openMap(Map<String, dynamic> child, _ActiveTrip trip) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ParentMap(
          token: Api.token!,
          tripId: trip.tripId,
          studentNames: {child['id'] as String: child['name'] as String},
          direction: trip.direction,
          routeName: trip.routeName,
        ),
      ),
    );
  }

  String _updatedLabel(DateTime? value) {
    if (value == null) return 'Aguardando sinal do GPS';
    final minutes = DateTime.now().toUtc().difference(value.toUtc()).inMinutes;
    if (minutes < 1) return 'GPS atualizado agora';
    if (minutes < 60) return 'GPS atualizado há $minutes min';
    return 'Última posição às ${value.toLocal().hour.toString().padLeft(2, '0')}:${value.toLocal().minute.toString().padLeft(2, '0')}';
  }

  Widget _skeleton() => ListView(
        padding: const EdgeInsets.all(16),
        children: List.generate(
          3,
          (index) => Container(
            height: index == 0 ? 190 : 130,
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: .55),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      );

  Widget _activeTripCard(Map<String, dynamic> child, _ActiveTrip trip) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0F6B6B), Color(0xFF084D50)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: .22),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(trip.icon, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(child['name'] as String,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600)),
                    Text(trip.status,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                    color: Color(0xFF6EE7A0), shape: BoxShape.circle),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(trip.routeName,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 3),
          Text(_updatedLabel(trip.locationAt),
              style: const TextStyle(color: Colors.white, fontSize: 13)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openMap(child, trip),
              icon: const Icon(Icons.near_me_rounded),
              label: const Text('Acompanhar van ao vivo'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _childCard(Map<String, dynamic> child) {
    final id = child['id'] as String;
    final trip = _activeByStudent[id];
    final payment = _paymentStatusByStudent[id];
    final absence = _nextAbsenceByStudent[id];
    final name = child['name'] as String;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final timeToSchool =
        _formatTime(child['planned_time_to_school'] as String?);
    final timeToHome = _formatTime(child['planned_time_to_home'] as String?);
    final plannedRoute = child['planned_route_name'] as String?;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 25,
                  backgroundColor: AppColors.primary.withValues(alpha: .12),
                  foregroundColor: AppColors.primary,
                  child: Text(initial,
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        child['school_name'] as String? ??
                            'Escola não informada',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Mais opções',
                  onSelected: (value) {
                    if (value == 'details') {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            StudentDetailScreen(studentId: id, name: name),
                      ));
                    } else if (value == 'absence') {
                      _markAbsence(id);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'details', child: Text('Detalhes')),
                    PopupMenuItem(
                        value: 'absence', child: Text('Marcar falta')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (trip != null ? AppColors.success : AppColors.primary)
                    .withValues(alpha: .08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(trip?.icon ?? Icons.home_rounded,
                      size: 20,
                      color:
                          trip != null ? AppColors.success : AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      trip?.status ?? 'Sem viagem ativa agora',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            if (absence != null) ...[
              const SizedBox(height: 10),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_busy_rounded,
                    color: AppColors.error),
                title: Text(
                    'Falta agendada para ${_formatDate(absence['date'] as String)}'),
                trailing: TextButton(
                  onPressed: () => _cancelAbsence(absence['id'] as String),
                  child: const Text('Cancelar'),
                ),
              ),
            ] else if (trip == null && plannedRoute != null) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.schedule_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      timeToSchool.isEmpty && timeToHome.isEmpty
                          ? '$plannedRoute · horários ainda não configurados'
                          : [
                              plannedRoute,
                              if (timeToSchool.isNotEmpty)
                                'Ida cadastrada: $timeToSchool',
                              if (timeToHome.isNotEmpty)
                                'Volta cadastrada: $timeToHome',
                            ].join('\n'),
                    ),
                  ),
                ],
              ),
            ],
            if (payment != null) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Icon(
                    payment == 'paid'
                        ? Icons.check_circle_outline
                        : Icons.receipt_long_outlined,
                    size: 18,
                    color: payment == 'paid'
                        ? AppColors.success
                        : AppColors.accent,
                  ),
                  const SizedBox(width: 8),
                  Text(payment == 'paid'
                      ? 'Mensalidade em dia'
                      : 'Mensalidade pendente'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyState() => ListView(
        padding: const EdgeInsets.all(28),
        children: [
          const SizedBox(height: 64),
          Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: .1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.family_restroom_rounded,
                size: 44, color: AppColors.primary),
          ),
          const SizedBox(height: 24),
          Text('Vamos adicionar seu filho?',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Use o código enviado pelo motorista para acompanhar viagens, avisos e pagamentos.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _addChild,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Adicionar filho'),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    if (_maintenance) return MaintenanceScreen(onRetry: _load);
    final activeEntries = _children
        .cast<Map<String, dynamic>>()
        .where((child) => _activeByStudent.containsKey(child['id']))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(_firstName.isEmpty ? 'Olá!' : 'Olá, $_firstName'),
        actions: [
          IconButton(
            tooltip: 'Notificações',
            onPressed: _openNotifications,
            icon: Badge(
              isLabelVisible: _newAlerts > 0,
              label: Text(_newAlerts > 99 ? '99+' : '$_newAlerts'),
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _loading
          ? _skeleton()
          : _children.isEmpty
              ? _emptyState()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: Text(
                          activeEntries.isEmpty
                              ? 'Tudo tranquilo por aqui'
                              : 'Acompanhamento em tempo real',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      for (final child in activeEntries)
                        _activeTripCard(child, _activeByStudent[child['id']]!),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text('Meus filhos',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                            ),
                            TextButton.icon(
                              onPressed: _addChild,
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('Adicionar'),
                            ),
                          ],
                        ),
                      ),
                      for (final dynamic child in _children)
                        _childCard(child as Map<String, dynamic>),
                    ],
                  ),
                ),
    );
  }
}
