import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';
import 'trip_history_screen.dart';

String _formatMonth(String iso) {
  const names = [
    'Jan',
    'Fev',
    'Mar',
    'Abr',
    'Mai',
    'Jun',
    'Jul',
    'Ago',
    'Set',
    'Out',
    'Nov',
    'Dez'
  ];
  final d = DateTime.parse(iso);
  return '${names[d.month - 1]}/${d.year}';
}

/// Detalhes completos do filho: escola, endereco, contato de emergencia,
/// pessoas autorizadas a buscar, responsaveis vinculados e ultimos
/// pagamentos -- tudo que o app dos pais so mostrava em pedacos espalhados.
class StudentDetailScreen extends StatefulWidget {
  final String studentId;
  final String name;
  const StudentDetailScreen(
      {super.key, required this.studentId, required this.name});

  @override
  State<StudentDetailScreen> createState() => _StudentDetailScreenState();
}

class _StudentDetailScreenState extends State<StudentDetailScreen> {
  Map<String, dynamic>? _student;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final s = await Api.studentDetail(widget.studentId);
    setState(() {
      _student = s;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _student == null
              ? const Center(child: Text('Nao foi possivel carregar os dados.'))
              : _buildBody(context, _student!),
    );
  }

  Widget _buildBody(BuildContext context, Map<String, dynamic> s) {
    final guardians = (s['guardians'] as List<dynamic>? ?? []);
    final payments = (s['payments'] as List<dynamic>? ?? []);
    final schoolName =
        s['school_display_name'] as String? ?? s['school_name'] as String?;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoRow(
                      icon: Icons.school_outlined,
                      label: 'Escola',
                      value: schoolName?.isNotEmpty == true
                          ? schoolName!
                          : 'Nao informada'),
                  if ((s['class_period'] as String?)?.isNotEmpty == true)
                    _InfoRow(
                        icon: Icons.schedule,
                        label: 'Turma/periodo',
                        value: s['class_period'] as String),
                  if ((s['home_address'] as String?)?.isNotEmpty == true)
                    _InfoRow(
                        icon: Icons.home_outlined,
                        label: 'Endereco',
                        value: s['home_address'] as String),
                  if ((s['birth_date'] as String?)?.isNotEmpty == true)
                    _InfoRow(
                        icon: Icons.cake_outlined,
                        label: 'Nascimento',
                        value: (s['birth_date'] as String).split('T').first),
                ],
              ),
            ),
          ),
          if ((s['emergency_contact_name'] as String?)?.isNotEmpty == true ||
              (s['authorized_pickup'] as String?)?.isNotEmpty == true ||
              (s['medical_notes'] as String?)?.isNotEmpty == true) ...[
            const SizedBox(height: 16),
            Text('Emergencia e cuidados',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ((s['emergency_contact_name'] as String?)?.isNotEmpty ==
                        true)
                      _InfoRow(
                        icon: Icons.emergency_outlined,
                        label: 'Contato de emergencia',
                        value:
                            '${s['emergency_contact_name']}${(s['emergency_contact_phone'] as String?)?.isNotEmpty == true ? ' · ${s['emergency_contact_phone']}' : ''}',
                      ),
                    if ((s['authorized_pickup'] as String?)?.isNotEmpty == true)
                      _InfoRow(
                          icon: Icons.how_to_reg_outlined,
                          label: 'Autorizados a buscar',
                          value: s['authorized_pickup'] as String),
                    if ((s['medical_notes'] as String?)?.isNotEmpty == true)
                      _InfoRow(
                          icon: Icons.medical_information_outlined,
                          label: 'Observacoes medicas',
                          value: s['medical_notes'] as String),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Responsaveis',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          if (guardians.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Nenhum responsavel vinculado ainda.'))
          else
            ...guardians.map((g) => Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(g['name'] as String),
                    subtitle: Text([g['email'], g['phone']]
                        .where((v) => v != null && (v as String).isNotEmpty)
                        .join(' · ')),
                  ),
                )),
          const SizedBox(height: 16),
          Text('Ultimos pagamentos',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (payments.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Nenhuma cobranca gerada ainda.'))
          else
            ...payments.map((p) {
              final paid = p['status'] == 'paid';
              return ListTile(
                dense: true,
                leading: Icon(
                    paid ? Icons.check_circle_outline : Icons.schedule,
                    color: paid ? AppColors.success : AppColors.accent),
                title: Text(_formatMonth(p['reference_month'] as String)),
                trailing: Text(paid ? 'Pago' : 'Pendente',
                    style: TextStyle(
                        color: paid ? AppColors.success : AppColors.accent)),
              );
            }),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => TripHistoryScreen(
                      studentId: widget.studentId, name: widget.name)),
            ),
            icon: const Icon(Icons.history),
            label: const Text('Historico de viagens'),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.grey.shade600)),
                Text(value, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
