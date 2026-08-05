import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../services/api.dart';
import '../theme.dart';

class InviteScreen extends StatefulWidget {
  final String studentId;
  final String studentName;
  const InviteScreen(
      {super.key, required this.studentId, required this.studentName});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  List<dynamic> _invites = [];
  Map<String, dynamic>? _selected;
  bool _loading = true;
  String _relationship = 'Responsavel legal';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({String? selectCode}) async {
    final invites = await Api.studentInvites(widget.studentId);
    if (!mounted) return;
    final pending =
        invites.where((item) => item['status'] == 'pending').toList();
    Map<String, dynamic>? selected;
    for (final item in pending) {
      if (selectCode == null || item['code'] == selectCode) {
        selected = item as Map<String, dynamic>;
        break;
      }
    }
    setState(() {
      _invites = invites;
      _selected = selected;
      _loading = false;
    });
  }

  Future<void> _generate() async {
    setState(() => _loading = true);
    final result = await Api.generateInvite(widget.studentId, _relationship);
    if (!mounted) return;
    if (result == null) {
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nao foi possivel gerar o convite.')),
      );
      return;
    }
    await _load(selectCode: result['code'] as String?);
  }

  String _date(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return '-';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  void _share(Map<String, dynamic> invite) {
    Share.share(
      'Ola! Voce foi convidado para acompanhar ${widget.studentName} no VaiEscolar.\n\n'
      'Abra o app, escolha Responsavel e toque em "Criar conta com codigo de convite".\n'
      'Codigo: ${invite['code']}\n\n'
      'O codigo vale ate ${_date(invite['expires_at'])} e so pode ser usado uma vez. '
      'Se voce ja possui conta, informe seu e-mail e sua senha atual para adicionar este aluno.',
    );
  }

  Future<void> _cancel(Map<String, dynamic> invite) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancelar convite?'),
        content: Text('O codigo ${invite['code']} deixara de funcionar.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Voltar')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Cancelar convite')),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await Api.cancelInvite(widget.studentId, invite['id'] as String);
    if (!mounted) return;
    if (ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final pending =
        _invites.where((item) => item['status'] == 'pending').toList();
    return Scaffold(
      appBar:
          AppBar(title: Text('Convidar responsavel - ${widget.studentName}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                    'Crie um codigo para o responsavel abrir a propria conta. Cada codigo vale 7 dias e pode ser usado uma unica vez.',
                    style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _relationship,
                  decoration: const InputDecoration(
                      labelText: 'Parentesco com o aluno'),
                  items: const [
                    'Mae',
                    'Pai',
                    'Avo',
                    'Tio ou tia',
                    'Responsavel legal',
                    'Outro'
                  ]
                      .map((value) =>
                          DropdownMenuItem(value: value, child: Text(value)))
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _relationship = value ?? _relationship),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                    onPressed: _generate,
                    icon: const Icon(Icons.add),
                    label: const Text('Gerar convite')),
                if (_selected != null) ...[
                  const SizedBox(height: 24),
                  Center(
                      child: Text(_selected!['code'] as String,
                          style: const TextStyle(
                              fontSize: 38,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 7))),
                  const SizedBox(height: 16),
                  Center(
                      child: QrImageView(
                          data: _selected!['code'] as String,
                          size: 180,
                          backgroundColor: Colors.white)),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                      onPressed: () => _share(_selected!),
                      icon: const Icon(Icons.share),
                      label: const Text('Compartilhar instrucoes')),
                ],
                const SizedBox(height: 28),
                Text('Convites pendentes (${pending.length})',
                    style: Theme.of(context).textTheme.titleMedium),
                if (pending.isEmpty)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('Nenhum convite aguardando uso.'))
                else
                  ...pending.map((raw) {
                    final invite = raw as Map<String, dynamic>;
                    return Card(
                        child: ListTile(
                      onTap: () => setState(() => _selected = invite),
                      leading:
                          const CircleAvatar(child: Icon(Icons.mail_outline)),
                      title: Text(invite['code'] as String,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, letterSpacing: 2)),
                      subtitle: Text(
                          '${invite['relationship']} - valido ate ${_date(invite['expires_at'])}'),
                      trailing: Wrap(children: [
                        IconButton(
                            tooltip: 'Compartilhar',
                            onPressed: () => _share(invite),
                            icon: const Icon(Icons.share_outlined)),
                        IconButton(
                            tooltip: 'Cancelar',
                            color: AppColors.error,
                            onPressed: () => _cancel(invite),
                            icon: const Icon(Icons.cancel_outlined)),
                      ]),
                    ));
                  }),
                if (_invites.any((item) => item['status'] != 'pending')) ...[
                  const SizedBox(height: 20),
                  Text('Historico',
                      style: Theme.of(context).textTheme.titleMedium),
                  ..._invites
                      .where((item) => item['status'] != 'pending')
                      .take(8)
                      .map((item) {
                    const labels = {
                      'used': 'Utilizado',
                      'expired': 'Expirado',
                      'cancelled': 'Cancelado'
                    };
                    return ListTile(
                        dense: true,
                        title: Text(item['code'] as String),
                        subtitle: Text(
                            '${item['relationship']} - ${labels[item['status']] ?? item['status']}'));
                  }),
                ],
              ],
            ),
    );
  }
}
