import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../services/api.dart';

class ContractScreen extends StatefulWidget {
  final String studentId;
  final String studentName;
  const ContractScreen(
      {super.key, required this.studentId, required this.studentName});

  @override
  State<ContractScreen> createState() => _ContractScreenState();
}

class _ContractScreenState extends State<ContractScreen> {
  final _name = TextEditingController();
  final _cpf = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  List<dynamic> _contracts = [];
  bool _loading = true;
  bool _accepted = false;
  bool _saving = false;
  bool _sendingCode = false;
  bool _codeSent = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _cpf.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final contracts = await Api.studentContracts(widget.studentId);
    if (mounted) {
      setState(() {
        _contracts = contracts;
        _loading = false;
      });
    }
  }

  Future<void> _sign(Map<String, dynamic> contract) async {
    if (!_accepted ||
        _name.text.trim().length < 3 ||
        _cpf.text.replaceAll(RegExp(r'\D'), '').length != 11 ||
        _password.text.isEmpty ||
        _code.text.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Confirme o aceite, nome, CPF, senha e codigo de 6 digitos.')));
      return;
    }
    setState(() => _saving = true);
    final error = await Api.signContract(contract['id'] as String,
        _name.text.trim(), _cpf.text, _password.text, _code.text);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contrato assinado com sucesso.')));
    await _load();
  }

  Future<void> _sendCode(Map<String, dynamic> contract) async {
    setState(() => _sendingCode = true);
    final error = await Api.requestContractCode(contract['id'] as String);
    if (!mounted) return;
    setState(() {
      _sendingCode = false;
      _codeSent = error == null;
    });
    if (Api.lastContractDevCode != null) _code.text = Api.lastContractDevCode!;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error ??
            'Codigo enviado por notificacao. Ele vence em 10 minutos.')));
  }

  Future<void> _sharePdf(Map<String, dynamic> contract) async {
    final bytes = await Api.contractPdf(contract['id'] as String);
    if (!mounted) return;
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nao foi possivel gerar o PDF.')));
      return;
    }
    await Share.shareXFiles([
      XFile.fromData(bytes,
          mimeType: 'application/pdf',
          name:
              'contrato-${widget.studentName.replaceAll(' ', '-').toLowerCase()}.pdf')
    ], subject: 'Contrato de transporte escolar - ${widget.studentName}');
    await _load();
  }

  Future<void> _verify(Map<String, dynamic> contract) async {
    final result = await Api.verifyContract(contract['id'] as String);
    if (!mounted) return;
    final valid = result?['contractValid'] == true &&
        (result?['evidenceValid'] == true || result?['evidenceValid'] == null);
    showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
              title: Text(
                  valid ? 'Integridade confirmada' : 'Falha na verificacao'),
              content: Text(valid
                  ? 'O texto e as evidencias correspondem aos hashes registrados no servidor.'
                  : 'O documento nao passou na verificacao. Entre em contato com o transportador.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Fechar'))
              ],
            ));
  }

  Future<void> _requestCancellation(Map<String, dynamic> contract) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Solicitar cancelamento'),
              content: TextField(
                  controller: controller,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 1000,
                  decoration: const InputDecoration(
                      labelText: 'Explique o motivo',
                      alignLabelWithHint: true)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Voltar')),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, controller.text.trim()),
                    child: const Text('Enviar solicitacao'))
              ],
            ));
    controller.dispose();
    if (reason == null || reason.length < 10) return;
    final error =
        await Api.requestContractCancellation(contract['id'] as String, reason);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error ?? 'Solicitacao enviada para analise.')));
  }

  String _date(dynamic value) {
    if (value == null) return '';
    final brasilia = DateTime.parse(value as String)
        .toUtc()
        .subtract(const Duration(hours: 3));
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(brasilia.day)}/${two(brasilia.month)}/${brasilia.year} '
        '${two(brasilia.hour)}:${two(brasilia.minute)} (Brasilia)';
  }

  @override
  Widget build(BuildContext context) {
    final current =
        _contracts.isEmpty ? null : _contracts.first as Map<String, dynamic>;
    final expired = current?['status'] == 'pending' &&
        DateTime.tryParse(current?['expires_at'] as String? ?? '')
                ?.isBefore(DateTime.now()) ==
            true;
    return Scaffold(
      appBar: AppBar(title: const Text('Contrato de transporte')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : current == null
              ? const Center(
                  child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                          'O transportador ainda nao emitiu o contrato deste aluno.',
                          textAlign: TextAlign.center)))
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Text(current['title'] as String,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text('${widget.studentName} · versao ${current['version']}'),
                  const SizedBox(height: 16),
                  Card(
                      child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: SelectableText(current['contract_text'] as String,
                        style: const TextStyle(height: 1.5)),
                  )),
                  const SizedBox(height: 12),
                  if (expired) ...[
                    const Card(
                        child: ListTile(
                      leading:
                          Icon(Icons.timer_off_outlined, color: Colors.red),
                      title: Text('Prazo de assinatura encerrado'),
                      subtitle:
                          Text('Solicite ao transportador uma nova emissao.'),
                    )),
                  ] else if (current['status'] == 'pending') ...[
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _accepted,
                      onChanged: (v) => setState(() => _accepted = v == true),
                      title: const Text(
                          'Li integralmente e concordo com o contrato'),
                      subtitle: const Text(
                          'O aceite registra data, hora, IP, dispositivo e hash de integridade.'),
                    ),
                    TextField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                          labelText: 'Nome completo de quem esta assinando',
                          prefixIcon: Icon(Icons.draw_outlined)),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _cpf,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'CPF de quem esta assinando',
                          prefixIcon: Icon(Icons.badge_outlined)),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                          labelText: 'Confirme sua senha',
                          prefixIcon: Icon(Icons.lock_outline)),
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _code,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          decoration: const InputDecoration(
                            labelText: 'Codigo de confirmacao',
                            counterText: '',
                            prefixIcon: Icon(Icons.password_outlined),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed:
                            _sendingCode ? null : () => _sendCode(current),
                        child: Text(_codeSent ? 'Reenviar' : 'Enviar codigo'),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _saving ? null : () => _sign(current),
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.verified_outlined),
                      label: const Text('Assinar eletronicamente'),
                    ),
                  ] else if (current['status'] == 'signed') ...[
                    Card(
                        color: Colors.green.withValues(alpha: .1),
                        child: ListTile(
                          leading:
                              const Icon(Icons.verified, color: Colors.green),
                          title: const Text('Contrato assinado'),
                          subtitle: Text(
                              '${current['signer_name']} · ${_date(current['signed_at'])}'),
                        )),
                    SelectableText(
                        'Hash do contrato: ${current['contract_hash']}\nHash da evidencia: ${current['evidence_hash']}',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => _sharePdf(current),
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('Baixar ou compartilhar PDF'),
                    ),
                    TextButton.icon(
                      onPressed: () => _verify(current),
                      icon: const Icon(Icons.verified_user_outlined),
                      label: const Text('Verificar integridade'),
                    ),
                    TextButton.icon(
                      onPressed: () => _requestCancellation(current),
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Solicitar cancelamento'),
                    ),
                  ] else
                    const ListTile(
                        leading: Icon(Icons.block),
                        title: Text('Contrato revogado')),
                  if (_contracts.length > 1) ...[
                    const SizedBox(height: 24),
                    Text('Historico',
                        style: Theme.of(context).textTheme.titleMedium),
                    ..._contracts.skip(1).map((item) => ListTile(
                          leading: const Icon(Icons.history),
                          title: Text(
                              'Versao ${item['version']} · ${item['status']}'),
                          subtitle: Text(item['signed_at'] == null
                              ? 'Nao assinado'
                              : 'Assinado em ${_date(item['signed_at'])}'),
                        )),
                  ]
                ]),
    );
  }
}
