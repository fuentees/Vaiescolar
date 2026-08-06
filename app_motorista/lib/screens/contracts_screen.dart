import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../services/api.dart';
import 'student_contract_screen.dart';

class ContractsScreen extends StatefulWidget {
  const ContractsScreen({super.key});
  @override
  State<ContractsScreen> createState() => _ContractsScreenState();
}

class _ContractsScreenState extends State<ContractsScreen> {
  List<dynamic> _items = [];
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await Api.contracts();
    if (mounted) {
      setState(() {
        _items = rows;
        _loading = false;
      });
    }
  }

  Future<void> _share(Map<String, dynamic> item) async {
    final bytes = await Api.contractPdf(item['id'] as String);
    if (bytes == null) return;
    await Share.shareXFiles([
      XFile.fromData(bytes,
          mimeType: 'application/pdf',
          name: 'contrato-${item['student_name']}.pdf')
    ]);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final pending =
        _items.where((e) => e['display_status'] == 'pending').length;
    final expired =
        _items.where((e) => e['display_status'] == 'expired').length;
    final signed = _items.where((e) => e['display_status'] == 'signed').length;
    return Scaffold(
        appBar: AppBar(title: const Text('Contratos'), actions: [
          IconButton(
              onPressed: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ContractSettingsScreen()));
                _load();
              },
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Modelo e regras')
        ]),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  Wrap(spacing: 8, children: [
                    Chip(label: Text('$pending pendentes')),
                    Chip(label: Text('$signed assinados')),
                    if (expired > 0) Chip(label: Text('$expired vencidos'))
                  ]),
                  const SizedBox(height: 12),
                  if (_items.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(30),
                        child: Text('Nenhum contrato emitido.',
                            textAlign: TextAlign.center)),
                  ..._items.map((raw) {
                    final item = raw as Map<String, dynamic>;
                    final status = item['display_status'];
                    return Card(
                        child: ListTile(
                      leading: Icon(
                          status == 'signed'
                              ? Icons.verified
                              : status == 'expired'
                                  ? Icons.timer_off
                                  : status == 'revoked'
                                      ? Icons.block
                                      : Icons.pending_actions,
                          color: status == 'signed'
                              ? Colors.green
                              : status == 'expired' || status == 'revoked'
                                  ? Colors.red
                                  : Colors.orange),
                      title: Text(item['student_name'] as String),
                      subtitle: Text(
                          'Versao ${item['version']} · ${status == 'signed' ? 'assinado' : status == 'expired' ? 'vencido' : status == 'revoked' ? 'revogado' : 'aguardando'}'),
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => StudentContractScreen(
                                  studentId: item['student_id'] as String,
                                  studentName:
                                      item['student_name'] as String))),
                      trailing: status == 'signed'
                          ? IconButton(
                              onPressed: () => _share(item),
                              icon: const Icon(Icons.picture_as_pdf_outlined),
                              tooltip: 'Compartilhar PDF')
                          : const Icon(Icons.chevron_right),
                    ));
                  })
                ])));
  }
}

class ContractSettingsScreen extends StatefulWidget {
  const ContractSettingsScreen({super.key});
  @override
  State<ContractSettingsScreen> createState() => _ContractSettingsScreenState();
}

class _ContractSettingsScreenState extends State<ContractSettingsScreen> {
  final _legalName = TextEditingController(),
      _taxId = TextEditingController(),
      _address = TextEditingController(),
      _title = TextEditingController(),
      _template = TextEditingController(),
      _days = TextEditingController(text: '15');
  bool _block = false, _loading = true, _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_legalName, _taxId, _address, _title, _template, _days]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final s = await Api.contractSettings();
    if (!mounted) return;
    _legalName.text = s?['legal_name'] ?? '';
    _taxId.text = s?['tax_id'] ?? '';
    _address.text = s?['legal_address'] ?? '';
    _title.text = s?['contract_title'] ?? '';
    _template.text = s?['contract_template'] ?? s?['default_template'] ?? '';
    _days.text = '${s?['contract_validity_days'] ?? 15}';
    setState(() {
      _block = s?['require_signed_contract'] == true;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final error = await Api.saveContractSettings({
      'legal_name': _legalName.text,
      'tax_id': _taxId.text,
      'legal_address': _address.text,
      'contract_title': _title.text,
      'contract_template': _template.text,
      'contract_validity_days': int.tryParse(_days.text) ?? 15,
      'require_signed_contract': _block
    });
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(error ?? 'Modelo salvo. Novos contratos usarao este texto.')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Modelo e regras')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              const Text('Dados do transportador'),
              TextField(
                  controller: _legalName,
                  decoration:
                      const InputDecoration(labelText: 'Nome ou razao social')),
              TextField(
                  controller: _taxId,
                  decoration: const InputDecoration(labelText: 'CPF ou CNPJ')),
              TextField(
                  controller: _address,
                  decoration:
                      const InputDecoration(labelText: 'Endereco completo')),
              const SizedBox(height: 16),
              TextField(
                  controller: _title,
                  decoration:
                      const InputDecoration(labelText: 'Titulo do contrato')),
              TextField(
                  controller: _days,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Prazo para assinatura (dias)')),
              const SizedBox(height: 12),
              TextField(
                  controller: _template,
                  minLines: 16,
                  maxLines: 30,
                  decoration: const InputDecoration(
                      labelText: 'Texto do modelo', alignLabelWithHint: true)),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _block,
                  onChanged: (v) => setState(() => _block = v),
                  title:
                      const Text('Exigir contrato assinado para iniciar rota'),
                  subtitle: const Text(
                      'Se ativado, a rota sera bloqueada enquanto algum aluno estiver sem contrato assinado.')),
              FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Salvar modelo e regras')),
            ]));
}
