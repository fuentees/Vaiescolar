import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config.dart';
import '../services/api.dart';
import '../services/api_result.dart';
import '../services/app_refresh_signal.dart';
import '../theme.dart';
import 'link_child_screen.dart';
import 'maintenance_screen.dart';
import 'notifications_screen.dart';
import 'parent_map.dart';
import 'student_detail_screen.dart';
import 'contract_screen.dart';

String _formatDate(String iso) {
  final d = DateTime.parse(iso);
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
}

class _ActiveTrip {
  final String tripId;
  final String routeName;
  final String direction;
  final String? lastEventType;
  final DateTime? lastEventAt;
  final DateTime? locationAt;
  final double? currentLat;
  final double? currentLng;
  final double? speedMetersPerSecond;
  final double? targetLat;
  final double? targetLng;
  final bool emergencyReturnActive;
  final String? vehiclePlate;
  final String? vehicleModel;
  final String? vehicleColor;

  _ActiveTrip({
    required this.tripId,
    required this.routeName,
    required this.direction,
    this.lastEventType,
    this.lastEventAt,
    this.locationAt,
    this.currentLat,
    this.currentLng,
    this.speedMetersPerSecond,
    this.targetLat,
    this.targetLng,
    this.emergencyReturnActive = false,
    this.vehiclePlate,
    this.vehicleModel,
    this.vehicleColor,
  });

  String get status {
    if (emergencyReturnActive) return 'Retorno de emergência para casa';
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

  int? get etaMinutes {
    if (lastEventType == 'dropped' ||
        locationAt == null ||
        currentLat == null ||
        currentLng == null ||
        targetLat == null ||
        targetLng == null) {
      return null;
    }
    if (DateTime.now().toUtc().difference(locationAt!.toUtc()).inMinutes >= 5) {
      return null;
    }
    double radians(double degrees) => degrees * math.pi / 180;
    final dLat = radians(targetLat! - currentLat!);
    final dLng = radians(targetLng! - currentLng!);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(radians(currentLat!)) *
            math.cos(radians(targetLat!)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final directKm = 6371 * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    if (directKm < .05) return 1;
    final measuredKmh = (speedMetersPerSecond ?? 0) * 3.6;
    // Em parada/semaforo, usa uma media urbana conservadora; em movimento,
    // respeita a velocidade real. O fator 1,25 aproxima a distancia viaria
    // porque Haversine mede uma linha reta.
    final effectiveKmh = measuredKmh >= 5 ? measuredKmh.clamp(8, 55) : 22.0;
    return ((directKm * 1.25 / effectiveKmh) * 60).ceil().clamp(1, 180).toInt();
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
  final Map<String, Map<String, dynamic>> _paymentStatusByStudent = {};
  final Map<String, Map<String, dynamic>> _nextAbsenceByStudent = {};
  String _firstName = '';
  int _newAlerts = 0;
  bool _loading = true;
  bool _maintenance = false;
  Timer? _liveRefreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    AppRefreshSignal.trips.addListener(_onTripsChanged);
    _liveRefreshTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _refreshTrips());
  }

  @override
  void dispose() {
    AppRefreshSignal.trips.removeListener(_onTripsChanged);
    _liveRefreshTimer?.cancel();
    super.dispose();
  }

  void _onTripsChanged() {
    _refreshTrips();
  }

  void _setActiveTrips(List<dynamic> rows) {
    _activeByStudent.clear();
    for (final dynamic item in rows) {
      final row = item as Map<String, dynamic>;
      double? number(String key) => (row[key] as num?)?.toDouble();
      _activeByStudent[row['student_id'] as String] = _ActiveTrip(
        tripId: row['trip_id'] as String,
        routeName: row['route_name'] as String? ?? 'Rota',
        direction: row['direction'] as String,
        lastEventType: row['last_event_type'] as String?,
        lastEventAt: DateTime.tryParse(row['last_event_at'] as String? ?? ''),
        locationAt:
            DateTime.tryParse(row['location_recorded_at'] as String? ?? ''),
        currentLat: number('current_lat'),
        currentLng: number('current_lng'),
        speedMetersPerSecond: number('current_speed'),
        targetLat: number('target_lat'),
        targetLng: number('target_lng'),
        emergencyReturnActive: row['emergency_return_active'] == true,
        vehiclePlate: row['vehicle_plate'] as String?,
        vehicleModel: row['vehicle_model'] as String?,
        vehicleColor: row['vehicle_color'] as String?,
      );
    }
  }

  Future<void> _refreshTrips() async {
    if (!mounted || _loading) return;
    final rows = await Api.activeTrips();
    if (!mounted) return;
    setState(() => _setActiveTrips(rows));
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

    _setActiveTrips(results[0] as List<dynamic>);
    _paymentStatusByStudent.clear();
    for (final dynamic item in results[1] as List<dynamic>) {
      final p = item as Map<String, dynamic>;
      _paymentStatusByStudent[p['student_id'] as String] = p;
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
    if (!mounted) return;
    final direction = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Em qual trajeto?'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'all'),
            child: const ListTile(
                leading: Icon(Icons.event_busy),
                title: Text('Dia todo'),
                subtitle: Text('Não fará ida nem volta')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'to_school'),
            child: const ListTile(
                leading: Icon(Icons.school_outlined),
                title: Text('Somente ida'),
                subtitle: Text('Não irá para a escola com a van')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'to_home'),
            child: const ListTile(
                leading: Icon(Icons.home_outlined),
                title: Text('Somente volta'),
                subtitle: Text('Não voltará para casa com a van')),
          ),
        ],
      ),
    );
    if (direction == null) return;
    final date =
        '${chosen.year}-${chosen.month.toString().padLeft(2, '0')}-${chosen.day.toString().padLeft(2, '0')}';
    if (await Api.markAbsence(studentId, date, direction: direction)) {
      await _load();
    }
  }

  Future<void> _cancelAbsence(String absenceId) async {
    if (await Api.cancelAbsence(absenceId)) {
      await _load();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(Api.lastError ?? 'Nao foi possivel cancelar a falta.'),
      ));
    }
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
          emergencyReturn: trip.emergencyReturnActive,
        ),
      ),
    );
  }

  void _openContract(String id, String name) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ContractScreen(studentId: id, studentName: name),
    ));
  }

  Future<void> _openPayment(Map<String, dynamic> payment) async {
    final checkoutUrl = payment['checkout_url'] as String?;
    if (checkoutUrl != null && checkoutUrl.isNotEmpty) {
      await launchUrl(Uri.parse(checkoutUrl),
          mode: LaunchMode.externalApplication);
      return;
    }
    final pixKey = payment['pix_key'] as String?;
    if (pixKey != null && pixKey.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: pixKey));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chave PIX copiada')),
        );
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Solicite os dados de pagamento ao transportador.')),
      );
    }
  }

  Widget _sectionTitle(
      String title, String subtitle, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 21),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _attentionTile({
    required Color color,
    required IconData icon,
    required String eyebrow,
    required String title,
    required String subtitle,
    required String actionLabel,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 5, 16, 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: .22)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .14),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(eyebrow.toUpperCase(),
                style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5)),
            const SizedBox(height: 2),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(subtitle),
        ),
        trailing: Semantics(
          button: true,
          label: actionLabel,
          child: Icon(Icons.chevron_right_rounded, color: color),
        ),
        onTap: onTap,
      ),
    );
  }

  List<Widget> _attentionItems() {
    final items = <Widget>[];
    for (final dynamic value in _children) {
      final child = value as Map<String, dynamic>;
      final id = child['id'] as String;
      final name = child['name'] as String;
      if (child['contract_status'] == 'pending') {
        items.add(_attentionTile(
          color: const Color(0xFF7551C2),
          icon: Icons.assignment_outlined,
          eyebrow: 'Contrato',
          title: '$name aguarda assinatura',
          subtitle: 'Leia e assine o documento para regularizar o cadastro.',
          actionLabel: 'Abrir contrato',
          onTap: () => _openContract(id, name),
        ));
      }
      final payment = _paymentStatusByStudent[id];
      if (payment != null && payment['status'] != 'paid') {
        final canPay =
            payment['checkout_url'] != null || payment['pix_key'] != null;
        items.add(_attentionTile(
          color: const Color(0xFFE07A1F),
          icon: Icons.account_balance_wallet_outlined,
          eyebrow: 'Financeiro',
          title: 'Mensalidade de $name pendente',
          subtitle: canPay
              ? 'Toque para consultar e realizar o pagamento.'
              : 'Consulte o transportador para regularizar o pagamento.',
          actionLabel: canPay ? 'Pagar mensalidade' : 'Ver pendência',
          onTap: () => _openPayment(payment),
        ));
      }
      final absence = _nextAbsenceByStudent[id];
      if (absence != null) {
        items.add(_attentionTile(
          color: const Color(0xFFD19A13),
          icon: Icons.event_busy_outlined,
          eyebrow: 'Falta programada',
          title: '$name não irá em ${_formatDate(absence['date'] as String)}',
          subtitle: switch (absence['direction']) {
            'to_school' => 'Somente no trajeto de ida para a escola.',
            'to_home' => 'Somente no trajeto de volta para casa.',
            _ => 'Ausência registrada para o dia todo.',
          },
          actionLabel: 'Cancelar falta',
          onTap: () => _cancelAbsence(absence['id'] as String),
        ));
      }
    }
    return items;
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
    final etaMinutes = trip.etaMinutes;
    final arrival = etaMinutes == null
        ? null
        : DateTime.now().add(Duration(minutes: etaMinutes));
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
          if (trip.lastEventType != 'boarded') ...[
            Text(trip.routeName,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 3),
          ],
          Text(_updatedLabel(trip.locationAt),
              style: const TextStyle(color: Colors.white, fontSize: 13)),
          if (trip.vehiclePlate != null) ...[
            const SizedBox(height: 5),
            Text(
              'Van ${trip.vehiclePlate}${trip.vehicleModel == null ? '' : ' • ${trip.vehicleModel}'}${trip.vehicleColor == null ? '' : ' • ${trip.vehicleColor}'}',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
          if (trip.lastEventType != 'boarded') ...[
            const SizedBox(height: 5),
            Text(
              arrival == null
                  ? 'Previsão indisponível até receber um GPS recente'
                  : 'Previsão em tempo real: ${arrival.hour.toString().padLeft(2, '0')}:${arrival.minute.toString().padLeft(2, '0')} (aprox. $etaMinutes min)',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700),
            ),
          ],
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
    final name = child['name'] as String;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
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
                    } else if (value == 'contract') {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            ContractScreen(studentId: id, studentName: name),
                      ));
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'details', child: Text('Detalhes')),
                    PopupMenuItem(
                        value: 'absence', child: Text('Marcar falta')),
                    PopupMenuItem(value: 'contract', child: Text('Contrato')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            StudentDetailScreen(studentId: id, name: name),
                      ),
                    ),
                    icon: const Icon(Icons.person_outline, size: 18),
                    label: const Text('Detalhes'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _markAbsence(id),
                    icon: const Icon(Icons.event_busy_outlined, size: 18),
                    label: const Text('Avisar falta'),
                  ),
                ),
              ],
            ),
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
    final attentionItems = _attentionItems();
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
                      if (activeEntries.isNotEmpty)
                        _sectionTitle(
                          'Agora',
                          'Acompanhe o transporte em tempo real.',
                          Icons.route_rounded,
                          const Color(0xFF147A83),
                        )
                      else
                        Container(
                          margin: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.success.withValues(alpha: .08),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.check_circle_outline,
                                  color: AppColors.success),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Nenhuma viagem em andamento agora.',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ),
                        ),
                      for (final child in activeEntries)
                        _activeTripCard(child, _activeByStudent[child['id']]!),
                      if (attentionItems.isNotEmpty) ...[
                        _sectionTitle(
                          'Precisa de atenção',
                          '${attentionItems.length} ${attentionItems.length == 1 ? 'item para resolver' : 'itens para resolver'}.',
                          Icons.notifications_active_outlined,
                          const Color(0xFFE07A1F),
                        ),
                        ...attentionItems,
                      ],
                      _sectionTitle(
                        'Meus filhos',
                        'Dados e ações rápidas de cada aluno.',
                        Icons.family_restroom_rounded,
                        AppColors.primary,
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: TextButton.icon(
                            onPressed: _addChild,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Adicionar filho'),
                          ),
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
