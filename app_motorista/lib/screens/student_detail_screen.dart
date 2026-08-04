import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';
import 'invite_screen.dart';
import 'chat_screen.dart';

const _monthNames = [
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
  'Dez',
];

String _formatMonth(String isoDate) {
  final d = DateTime.parse(isoDate);
  return '${_monthNames[d.month - 1]}/${d.year}';
}

/// "Perfil do aluno": dados, escola, responsaveis e historico de pagamentos
/// num so lugar (antes so dava pra ver/editar via dialog na lista de alunos).
class StudentDetailScreen extends StatefulWidget {
  final String studentId;
  const StudentDetailScreen({super.key, required this.studentId});

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
    final data = await Api.studentDetail(widget.studentId);
    setState(() {
      _student = data;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _student;
    return Scaffold(
      appBar: AppBar(title: Text(s?['name'] as String? ?? 'Aluno')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : s == null
              ? const Center(child: Text('Nao foi possivel carregar o aluno.'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Card(
                        child: Column(
                          children: [
                            ListTile(
                              leading: const Icon(Icons.apartment_outlined),
                              title: const Text('Escola'),
                              subtitle: Text(
                                  (s['school_display_name'] as String?) ??
                                      'Nao informada'),
                            ),
                            if ((s['school_address'] as String?)?.isNotEmpty ==
                                true)
                              ListTile(
                                leading: const Icon(Icons.location_on_outlined),
                                title: const Text('Endereco da escola'),
                                subtitle: Text(s['school_address'] as String),
                              ),
                            ListTile(
                              leading: const Icon(Icons.home_outlined),
                              title: const Text('Endereco residencial'),
                              subtitle: Text(
                                  (s['home_address'] as String?)?.isNotEmpty ==
                                          true
                                      ? s['home_address'] as String
                                      : 'Nao informado'),
                            ),
                            ListTile(
                              leading: const Icon(Icons.payments_outlined),
                              title: const Text('Mensalidade'),
                              subtitle: Text(
                                s['monthly_fee'] != null
                                    ? 'R\$ ${s['monthly_fee']}'
                                    : 'Nao definida',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Responsaveis',
                              style: Theme.of(context).textTheme.titleMedium),
                          TextButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => InviteScreen(
                                    studentId: widget.studentId,
                                    studentName: s['name'] as String),
                              ),
                            ),
                            icon: const Icon(Icons.qr_code, size: 18),
                            label: const Text('Convidar'),
                          ),
                        ],
                      ),
                      if ((s['guardians'] as List).isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                              'Nenhum responsavel vinculado ainda. Gere um convite acima.'),
                        )
                      else
                        ...(s['guardians'] as List).map((g) => Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: ListTile(
                                leading: const CircleAvatar(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: Colors.white,
                                  child: Icon(Icons.family_restroom, size: 20),
                                ),
                                title: Text(g['name'] as String),
                                subtitle: Text([
                                  g['email'] as String,
                                  if ((g['phone'] as String?)?.isNotEmpty ==
                                      true)
                                    g['phone'] as String,
                                ].join(' · ')),
                                trailing: IconButton(
                                  tooltip: 'Conversar com responsável',
                                  icon: const Icon(Icons.chat_bubble_outline),
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => ChatScreen(
                                        parentUserId: g['id'] as String,
                                        parentName:
                                            '${g['name']} • ${s['name']}',
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            )),
                      const SizedBox(height: 20),
                      Text('Pagamentos',
                          style: Theme.of(context).textTheme.titleMedium),
                      if ((s['payments'] as List).isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                              'Nenhuma cobranca gerada ainda. Use a tela "Financeiro".'),
                        )
                      else
                        ...(s['payments'] as List).map((p) {
                          final paid = p['status'] == 'paid';
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              title: Text(
                                  _formatMonth(p['reference_month'] as String)),
                              subtitle: Text('R\$ ${p['amount']}'),
                              trailing: Chip(
                                label: Text(paid ? 'Pago' : 'Pendente'),
                                backgroundColor: (paid
                                        ? AppColors.success
                                        : AppColors.accent)
                                    .withValues(alpha: 0.15),
                                labelStyle: TextStyle(
                                    color: paid
                                        ? AppColors.success
                                        : AppColors.accent),
                              ),
                            ),
                          );
                        }),
                    ],
                  ),
                ),
    );
  }
}
