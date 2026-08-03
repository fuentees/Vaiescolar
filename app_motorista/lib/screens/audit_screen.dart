import 'package:flutter/material.dart';
import '../services/api.dart';

const _entityLabels = {
  'user': 'Usuarios',
  'student': 'Alunos',
  'route': 'Rotas',
  'vehicle': 'Veiculos',
  'payment': 'Pagamentos',
};

const _actionLabels = {
  'criar_aluno': 'Aluno criado',
  'editar_aluno': 'Aluno editado',
  'excluir_aluno': 'Aluno excluido',
  'excluir_rota': 'Rota excluida',
  'excluir_veiculo': 'Veiculo excluido',
  'resetar_senha': 'Senha resetada',
  'desativar_usuario': 'Usuario desativado',
  'reativar_usuario': 'Usuario reativado',
  'marcar_pagamento_pago': 'Pagamento marcado como pago',
  'estornar_pagamento': 'Pagamento estornado',
};

String _formatDateTime(String iso) {
  final d = DateTime.parse(iso).toLocal();
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final min = d.minute.toString().padLeft(2, '0');
  return '$dd/$mm $hh:$min';
}

/// Auditoria administrativa: quem alterou o que (reset de senha, status de
/// pagamento, criar/editar/excluir aluno/rota/veiculo). So admin.
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});
  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  List<dynamic> _entries = [];
  String? _entityType;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final entries = await Api.auditLog(entityType: _entityType, limit: 100);
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Auditoria')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Todos'),
                  selected: _entityType == null,
                  onSelected: (_) {
                    setState(() => _entityType = null);
                    _load();
                  },
                ),
                ..._entityLabels.entries.map((e) => ChoiceChip(
                      label: Text(e.value),
                      selected: _entityType == e.key,
                      onSelected: (_) {
                        setState(() => _entityType = e.key);
                        _load();
                      },
                    )),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: _entries.isEmpty
                        ? ListView(children: const [
                            Padding(
                              padding: EdgeInsets.all(32),
                              child: Text('Nenhum registro de auditoria ainda.',
                                  textAlign: TextAlign.center),
                            ),
                          ])
                        : ListView.builder(
                            itemCount: _entries.length,
                            itemBuilder: (context, i) {
                              final e = _entries[i] as Map<String, dynamic>;
                              final action = e['action'] as String;
                              final detail =
                                  e['detail'] as Map<String, dynamic>?;
                              final detailLabel =
                                  detail?['name'] ?? detail?['plate'] ?? '';
                              return ListTile(
                                dense: true,
                                leading:
                                    const Icon(Icons.receipt_long_outlined),
                                title: Text(_actionLabels[action] ?? action),
                                subtitle: Text(
                                  '${e['actor_name'] ?? 'Sistema'}'
                                  '${detailLabel.toString().isNotEmpty ? ' · $detailLabel' : ''}',
                                ),
                                trailing: Text(
                                  _formatDateTime(e['created_at'] as String),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}
