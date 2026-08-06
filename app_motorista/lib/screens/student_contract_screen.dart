import 'package:flutter/material.dart';
import '../services/api.dart';

class StudentContractScreen extends StatefulWidget {
  final String studentId;
  final String studentName;
  const StudentContractScreen(
      {super.key, required this.studentId, required this.studentName});
  @override
  State<StudentContractScreen> createState() => _StudentContractScreenState();
}

class _StudentContractScreenState extends State<StudentContractScreen> {
  List<dynamic> _contracts = [];
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await Api.studentContracts(widget.studentId);
    if (mounted) {
      setState(() {
        _contracts = data;
        _loading = false;
      });
    }
  }

  Future<void> _issue() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Emitir contrato individual?'),
              content: Text(
                  'Sera criada uma versao para ${widget.studentName}. O texto ficara congelado e aguardara a assinatura do responsavel.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancelar')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Emitir'))
              ],
            ));
    if (confirmed != true) return;
    final error = await Api.issueStudentContract(widget.studentId);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error ?? 'Contrato emitido.')));
    if (error == null) await _load();
  }

  Future<void> _revoke(Map<String, dynamic> contract) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Revogar contrato'),
              content: TextField(
                  controller: controller,
                  maxLength: 500,
                  decoration:
                      const InputDecoration(labelText: 'Motivo obrigatorio')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar')),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, controller.text.trim()),
                    child: const Text('Revogar'))
              ],
            ));
    controller.dispose();
    if (reason == null || reason.length < 5) return;
    final error = await Api.revokeContract(contract['id'] as String, reason);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error ??
            'Contrato revogado. Agora voce pode emitir uma nova versao.')));
    if (error == null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final active = _contracts
        .where((c) => c['status'] == 'pending' || c['status'] == 'signed')
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Contrato do aluno')),
      floatingActionButton: active == null
          ? FloatingActionButton.extended(
              onPressed: _issue,
              icon: const Icon(Icons.add),
              label: const Text('Emitir contrato'))
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _contracts.isEmpty
              ? const Center(
                  child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                          'Nenhum contrato emitido. Use o botao abaixo para criar o contrato individual deste aluno.',
                          textAlign: TextAlign.center)))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: _contracts.map((item) {
                    final signed = item['status'] == 'signed';
                    final revoked = item['status'] == 'revoked';
                    return Card(
                        child: ExpansionTile(
                      leading: Icon(
                          signed
                              ? Icons.verified
                              : revoked
                                  ? Icons.block
                                  : Icons.schedule,
                          color: signed
                              ? Colors.green
                              : revoked
                                  ? Colors.red
                                  : Colors.orange),
                      title: Text(
                          'Versao ${item['version']} · ${signed ? 'Assinado' : revoked ? 'Revogado' : 'Aguardando assinatura'}'),
                      subtitle:
                          signed ? Text('Por ${item['signer_name']}') : null,
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [
                        SelectableText(item['contract_text'] as String,
                            style: const TextStyle(height: 1.45)),
                        const SizedBox(height: 12),
                        SelectableText('Hash: ${item['contract_hash']}',
                            style: Theme.of(context).textTheme.bodySmall),
                        if (signed) ...[
                          const SizedBox(height: 8),
                          SelectableText(
                              'Evidencia: ${item['evidence_hash']}\nIP: ${item['signer_ip']}\nDispositivo: ${item['signer_user_agent']}',
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                        if (!revoked)
                          Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                  onPressed: () =>
                                      _revoke(item as Map<String, dynamic>),
                                  icon: const Icon(Icons.block),
                                  label: const Text('Revogar'))),
                      ],
                    ));
                  }).toList()),
    );
  }
}
