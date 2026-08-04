import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/api.dart';
import '../theme.dart';

/// Gera e mostra o codigo de convite de um aluno (texto grande + QR) para o
/// motorista compartilhar com o responsavel. O pai usa esse codigo na tela
/// "Tenho um codigo" do app dele para se auto-cadastrar.
class InviteScreen extends StatefulWidget {
  final String studentId;
  final String studentName;
  const InviteScreen(
      {super.key, required this.studentId, required this.studentName});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  String? _code;
  DateTime? _expiresAt;
  bool _loading = true;
  String? _error;
  String _relationship = 'Responsavel legal';

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await Api.generateInvite(widget.studentId, _relationship);
    if (result == null) {
      setState(() {
        _loading = false;
        _error = 'Nao foi possivel gerar o convite.';
      });
      return;
    }
    setState(() {
      _code = result['code'] as String;
      _expiresAt = DateTime.tryParse(result['expires_at'] as String);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          AppBar(title: Text('Convidar responsavel — ${widget.studentName}')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Text(_error!,
                        style: const TextStyle(color: AppColors.error)))
                : SingleChildScrollView(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Peca para o responsavel abrir o app dos pais, tocar em '
                          '"Tenho um codigo" e digitar:',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: _relationship,
                          decoration: const InputDecoration(
                            labelText: 'Parentesco com o aluno',
                          ),
                          items: const [
                            'Mae',
                            'Pai',
                            'Avo',
                            'Tio ou tia',
                            'Responsavel legal',
                            'Outro',
                          ]
                              .map((value) => DropdownMenuItem(
                                    value: value,
                                    child: Text(value),
                                  ))
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _relationship = value);
                            }
                          },
                        ),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 16),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            _code ?? '',
                            style: const TextStyle(
                              fontSize: 40,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 8,
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                        if (_code != null)
                          QrImageView(
                              data: _code!,
                              size: 200,
                              backgroundColor: Colors.white),
                        const SizedBox(height: 24),
                        if (_expiresAt != null)
                          Text(
                            'Valido ate ${_expiresAt!.day.toString().padLeft(2, '0')}/'
                            '${_expiresAt!.month.toString().padLeft(2, '0')}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        const SizedBox(height: 24),
                        OutlinedButton(
                            onPressed: _generate,
                            child: const Text('Gerar novo codigo')),
                      ],
                    ),
                  ),
      ),
    );
  }
}
