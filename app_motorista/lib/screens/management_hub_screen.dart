import 'package:flutter/material.dart';
import 'audit_screen.dart';
import 'finance_screen.dart';
import 'profile_screen.dart';
import 'reports_screen.dart';
import 'routes_screen.dart';
import 'schools_screen.dart';
import 'students_screen.dart';
import 'users_screen.dart';
import 'vehicles_screen.dart';
import 'contracts_screen.dart';

class _HubItem {
  final IconData icon;
  final String label;
  final WidgetBuilder builder;
  const _HubItem(this.icon, this.label, this.builder);
}

const _items = [
  _HubItem(Icons.school, 'Alunos', _studentsBuilder),
  _HubItem(Icons.apartment_outlined, 'Escolas', _schoolsBuilder),
  _HubItem(Icons.alt_route, 'Rotas', _routesBuilder),
  _HubItem(Icons.local_shipping_outlined, 'Veiculos', _vehiclesBuilder),
  _HubItem(Icons.group_outlined, 'Equipe e responsaveis', _usersBuilder),
  _HubItem(Icons.payments_outlined, 'Financeiro', _financeBuilder),
  _HubItem(Icons.description_outlined, 'Contratos', _contractsBuilder),
  _HubItem(Icons.bar_chart_outlined, 'Relatorios', _reportsBuilder),
  _HubItem(Icons.receipt_long_outlined, 'Auditoria', _auditBuilder),
];

Widget _studentsBuilder(BuildContext _) => const StudentsScreen();
Widget _schoolsBuilder(BuildContext _) => const SchoolsScreen();
Widget _routesBuilder(BuildContext _) => const RoutesScreen();
Widget _vehiclesBuilder(BuildContext _) => const VehiclesScreen();
Widget _usersBuilder(BuildContext _) => const UsersScreen();
Widget _financeBuilder(BuildContext _) => const FinanceScreen();
Widget _contractsBuilder(BuildContext _) => const ContractsScreen();
Widget _reportsBuilder(BuildContext _) => const ReportsScreen();
Widget _auditBuilder(BuildContext _) => const AuditScreen();

/// Aba "Gestao" -- reune os cadastros que antes ficavam soltos no drawer.
/// So visivel/com conteudo pro admin do tenant (motorista comum nao tem essa
/// aba na bottom nav).
class ManagementHubScreen extends StatelessWidget {
  const ManagementHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestao'),
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
      body: ListView.builder(
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final item = _items[i];
          return ListTile(
            leading: Icon(item.icon),
            title: Text(item.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: item.builder)),
          );
        },
      ),
    );
  }
}
