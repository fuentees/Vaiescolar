import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../services/api.dart';
import '../services/api_result.dart';
import '../theme.dart';
import 'finance_screen.dart';
import 'maintenance_screen.dart';
import 'notifications_screen.dart';
import 'profile_screen.dart';
import 'routes_screen.dart';
import 'students_screen.dart';
import 'vehicles_screen.dart';

/// Aba "Inicio" -- dashboard do admin (saudacao + estatisticas do tenant).
/// Motorista comum tambem passa por essa aba, mas ela abre com foco na aba
/// "Rota" por padrao (ver AppShell) -- aqui so mostra a saudacao pra ele.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic>? _summary;
  Map<String, dynamic>? _today;
  String? _myName;

  List<String> _absentToday = [];
  List<String> _routesWithoutVehicle = [];
  List<String> _routesWithoutStudents = [];
  List<String> _routesOverCapacity = [];
  bool _loadingAlerts = false;
  bool _maintenance = false;

  @override
  void initState() {
    super.initState();
    if (Api.isAdmin) {
      _loadDashboard();
      _loadAlerts();
    }
    _loadToday();
    Api.me().then((me) {
      if (mounted) setState(() => _myName = me?['name'] as String?);
    });
  }

  Future<void> _loadToday() async {
    final data = await Api.dashboardToday();
    if (mounted) setState(() => _today = data);
  }

  // Chamada critica de boot pro admin: se falhar por rede/servidor, mostra a
  // tela de manutencao em vez do dashboard vazio/quebrado.
  Future<void> _loadDashboard() async {
    final result = await apiCall<Map<String, dynamic>>(
      () => http.get(
        Uri.parse('${Config.apiBase}/api/dashboard/summary'),
        headers: {'authorization': 'Bearer ${Api.token}'},
      ),
      (body) => body as Map<String, dynamic>,
    );
    if (!mounted) return;
    if (result is ApiOffline<Map<String, dynamic>> ||
        result is ApiServerError<Map<String, dynamic>>) {
      setState(() => _maintenance = true);
      return;
    }
    setState(() {
      _maintenance = false;
      _summary = switch (result) {
        ApiData<Map<String, dynamic>>(:final data) => data,
        _ => null,
      };
    });
  }

  /// Avisos do dia: faltas de hoje, rota sem veiculo escolhido, rota sem
  /// nenhum aluno vinculado, rota com mais alunos que a capacidade do
  /// veiculo -- coisas que o admin provavelmente quer saber sem precisar
  /// entrar em Gestao pra descobrir.
  Future<void> _loadAlerts() async {
    setState(() => _loadingAlerts = true);
    final now = DateTime.now();
    final todayStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final absences = await Api.absencesForDate(todayStr);
    final routes = await Api.routes();
    final vehicles = await Api.vehicles();
    final studentCounts = await Future.wait(
        routes.map((r) => Api.routeStudents(r['id'] as String)));
    final capacityByVehicle = {
      for (final v in vehicles) v['id'] as String: v['capacity'] as int?
    };

    final noVehicle = <String>[];
    final noStudents = <String>[];
    final overCapacity = <String>[];
    for (var i = 0; i < routes.length; i++) {
      final r = routes[i];
      final vehicleId = r['vehicle_id'] as String?;
      if (vehicleId == null) {
        noVehicle.add(r['name'] as String);
      } else {
        final capacity = capacityByVehicle[vehicleId];
        if (capacity != null && (studentCounts[i]).length > capacity) {
          overCapacity.add(r['name'] as String);
        }
      }
      if ((studentCounts[i]).isEmpty) noStudents.add(r['name'] as String);
    }

    if (!mounted) return;
    setState(() {
      _absentToday =
          absences.map((a) => a['student_name'] as String? ?? 'Aluno').toList();
      _routesWithoutVehicle = noVehicle;
      _routesWithoutStudents = noStudents;
      _routesOverCapacity = overCapacity;
      _loadingAlerts = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (Api.isAdmin && _maintenance) {
      return MaintenanceScreen(onRetry: _loadDashboard);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('VaiEscolar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            tooltip: 'Notificacoes',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationsScreen()),
            ),
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
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadToday();
          if (Api.isAdmin) {
            await _loadDashboard();
            await _loadAlerts();
          }
        },
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              _myName != null ? 'Ola, $_myName' : 'Ola!',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text('Aqui esta o resumo de hoje.',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            _TodaySection(data: _today, isAdmin: Api.isAdmin),
            const SizedBox(height: 20),
            if (Api.isAdmin && !_loadingAlerts) ...[
              _AlertsSection(
                absentToday: _absentToday,
                routesWithoutVehicle: _routesWithoutVehicle,
                routesWithoutStudents: _routesWithoutStudents,
                routesOverCapacity: _routesOverCapacity,
                onRoutesTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RoutesScreen())),
              ),
              const SizedBox(height: 20),
            ],
            if (Api.isAdmin)
              _DashboardGrid(
                summary: _summary,
                onStudentsTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const StudentsScreen())),
                onVehiclesTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const VehiclesScreen())),
                onFinanceTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FinanceScreen())),
              ),
          ],
        ),
      ),
    );
  }
}

class _TodaySection extends StatelessWidget {
  final Map<String, dynamic>? data;
  final bool isAdmin;
  const _TodaySection({required this.data, required this.isAdmin});

  String _direction(dynamic value) =>
      value == 'to_home' ? 'Volta para casa' : 'Ida para a escola';

  @override
  Widget build(BuildContext context) {
    if (data == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final routes = data!['routes'] as List<dynamic>? ?? [];
    final absences = data!['absences'] as List<dynamic>? ?? [];
    final active = data!['activeTrip'] as Map<String, dynamic>?;
    final completed = data!['completedTripsToday'] ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Operacao de hoje',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (active != null)
          Card(
            color: AppColors.success.withValues(alpha: .10),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: AppColors.success,
                foregroundColor: Colors.white,
                child: Icon(Icons.navigation_rounded),
              ),
              title: Text('${active['route_name']} em andamento'),
              subtitle: Text('${_direction(active['direction'])} - '
                  '${active['vehicle_plate'] ?? 'veiculo nao informado'}\n'
                  '${active['boarded_count'] ?? 0} embarcados - ${active['completed_count'] ?? 0} concluidos'),
              isThreeLine: true,
              trailing: const Chip(label: Text('ATIVA')),
            ),
          )
        else
          Card(
            child: ListTile(
              leading:
                  const Icon(Icons.route_outlined, color: AppColors.primary),
              title: const Text('Nenhuma rota em andamento'),
              subtitle: Text(routes.isEmpty
                  ? (isAdmin
                      ? 'Cadastre e atribua uma rota para comecar.'
                      : 'Nenhuma rota foi atribuida a voce.')
                  : 'Confira abaixo os horarios e inicie pela aba Rota.'),
            ),
          ),
        Row(children: [
          Expanded(
              child: _MiniTodayCard(
                  icon: Icons.route,
                  value: '${routes.length}',
                  label: isAdmin ? 'rotas ativas' : 'minhas rotas')),
          const SizedBox(width: 8),
          Expanded(
              child: _MiniTodayCard(
                  icon: Icons.event_busy,
                  value: '${absences.length}',
                  label: 'faltas hoje',
                  color: AppColors.accent)),
          const SizedBox(width: 8),
          Expanded(
              child: _MiniTodayCard(
                  icon: Icons.check_circle_outline,
                  value: '$completed',
                  label: 'viagens feitas',
                  color: AppColors.success)),
        ]),
        if (routes.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(isAdmin ? 'Rotas programadas' : 'Suas rotas',
              style: Theme.of(context).textTheme.titleSmall),
          ...routes.map((route) => Card(
                child: ListTile(
                  leading: const Icon(Icons.directions_bus_outlined),
                  title: Text(route['name'] as String),
                  subtitle: Text([
                    if (isAdmin && route['driver_name'] != null)
                      route['driver_name'],
                    route['vehicle_plate'] ?? 'Sem veiculo',
                    '${route['student_count'] ?? 0} alunos',
                    if (route['planned_time_to_school'] != null)
                      'Ida ${route['planned_time_to_school']}',
                    if (route['planned_time_to_home'] != null)
                      'Volta ${route['planned_time_to_home']}',
                  ].join(' - ')),
                ),
              )),
        ],
        if (absences.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Nao buscar hoje',
              style: Theme.of(context).textTheme.titleSmall),
          ...absences.map((absence) => ListTile(
                dense: true,
                leading: const Icon(Icons.person_off_outlined,
                    color: AppColors.accent),
                title: Text(absence['student_name'] as String),
                subtitle: Text(
                    '${absence['route_name']} - ${switch (absence['direction']) {
                  'to_school' => 'somente ida',
                  'to_home' => 'somente volta',
                  _ => 'ida e volta'
                }}'),
              )),
        ],
      ],
    );
  }
}

class _MiniTodayCard extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;
  const _MiniTodayCard(
      {required this.icon,
      required this.value,
      required this.label,
      this.color = AppColors.primary});
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Column(children: [
            Icon(icon, color: color),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            Text(label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2),
          ]),
        ),
      );
}

/// Avisos do dia (so admin, e so aparece se houver algo pra avisar).
class _AlertsSection extends StatelessWidget {
  final List<String> absentToday;
  final List<String> routesWithoutVehicle;
  final List<String> routesWithoutStudents;
  final List<String> routesOverCapacity;
  final VoidCallback onRoutesTap;

  const _AlertsSection({
    required this.absentToday,
    required this.routesWithoutVehicle,
    required this.routesWithoutStudents,
    required this.routesOverCapacity,
    required this.onRoutesTap,
  });

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    if (absentToday.isNotEmpty) {
      items.add(_AlertTile(
        icon: Icons.event_busy,
        color: AppColors.accent,
        text: absentToday.length == 1
            ? '${absentToday.first} vai faltar hoje'
            : '${absentToday.length} alunos vao faltar hoje',
        onTap: () => showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Faltas de hoje'),
            content: Text(absentToday.join('\n')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Fechar'))
            ],
          ),
        ),
      ));
    }
    if (routesWithoutVehicle.isNotEmpty) {
      items.add(_AlertTile(
        icon: Icons.local_shipping_outlined,
        color: AppColors.error,
        text: routesWithoutVehicle.length == 1
            ? 'Rota "${routesWithoutVehicle.first}" sem veiculo escolhido'
            : '${routesWithoutVehicle.length} rotas sem veiculo escolhido',
        onTap: onRoutesTap,
      ));
    }
    if (routesWithoutStudents.isNotEmpty) {
      items.add(_AlertTile(
        icon: Icons.person_off_outlined,
        color: AppColors.error,
        text: routesWithoutStudents.length == 1
            ? 'Rota "${routesWithoutStudents.first}" sem alunos vinculados'
            : '${routesWithoutStudents.length} rotas sem alunos vinculados',
        onTap: onRoutesTap,
      ));
    }
    if (routesOverCapacity.isNotEmpty) {
      items.add(_AlertTile(
        icon: Icons.groups_outlined,
        color: AppColors.error,
        text: routesOverCapacity.length == 1
            ? 'Rota "${routesOverCapacity.first}" com mais alunos que a capacidade do veiculo'
            : '${routesOverCapacity.length} rotas com mais alunos que a capacidade do veiculo',
        onTap: onRoutesTap,
      ));
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Alertas do dia', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...items,
      ],
    );
  }
}

class _AlertTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback onTap;
  const _AlertTile(
      {required this.icon,
      required this.color,
      required this.text,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(text),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Grade de estatisticas da home (so admin). Cada card navega pra tela
/// correspondente, exceto "Rotas ativas" que e so informativo.
class _DashboardGrid extends StatelessWidget {
  final Map<String, dynamic>? summary;
  final VoidCallback onStudentsTap;
  final VoidCallback onVehiclesTap;
  final VoidCallback onFinanceTap;

  const _DashboardGrid({
    required this.summary,
    required this.onStudentsTap,
    required this.onVehiclesTap,
    required this.onFinanceTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.0,
      children: [
        _StatCard(
          icon: Icons.school,
          label: 'Alunos',
          value: s == null ? '--' : '${s['totalStudents']}',
          color: AppColors.primary,
          onTap: onStudentsTap,
        ),
        _StatCard(
          icon: Icons.local_shipping_outlined,
          label: 'Veiculos',
          value: s == null ? '--' : '${s['totalVehicles']}',
          color: AppColors.accent,
          onTap: onVehiclesTap,
        ),
        _StatCard(
          icon: Icons.directions_bus_filled,
          label: 'Rotas ativas hoje',
          value: s == null ? '--' : '${s['activeTripsToday']}',
          color: AppColors.success,
          onTap: null,
        ),
        _StatCard(
          icon: Icons.payments_outlined,
          label: 'Pendencias financeiras',
          value: s == null ? '--' : '${s['pendingPayments']}',
          color: AppColors.error,
          onTap: onFinanceTap,
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final VoidCallback? onTap;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(height: 4),
              Text(value,
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
