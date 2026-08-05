import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api.dart';
import '../theme.dart';
import 'qr_scan_screen.dart';

class _UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}

/// Vincula outro filho a conta ja logada, usando um segundo codigo de
/// convite. Diferente de "Tenho um codigo" (que cria uma conta nova), esta
/// tela e pra quem ja tem conta e so precisa adicionar mais um filho.
class LinkChildScreen extends StatefulWidget {
  const LinkChildScreen({super.key});
  @override
  State<LinkChildScreen> createState() => _LinkChildScreenState();
}

class _LinkChildScreenState extends State<LinkChildScreen> {
  final _code = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _scan() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result != null && mounted) {
      setState(() => _code.text = result.toUpperCase());
    }
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final error = await Api.linkChild(_code.text.trim());
    setState(() => _loading = false);
    if (error == null) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.check_circle,
                color: AppColors.success, size: 44),
            title: const Text('Filho adicionado!'),
            content: Text(
                '${Api.lastLinkedStudentName ?? 'O aluno'} foi vinculado a sua conta com sucesso.'),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Concluir'))
            ],
          ),
        );
      }
      if (mounted) Navigator.pop(context, true);
    } else {
      setState(() => _error = _friendlyError(error));
    }
  }

  String _friendlyError(String raw) {
    switch (raw) {
      case 'codigo invalido':
        return 'Codigo invalido. Confira com o motorista.';
      case 'codigo ja utilizado':
        return 'Esse codigo ja foi usado. Peca um novo ao motorista.';
      case 'codigo expirado':
        return 'Esse codigo expirou. Peca um novo ao motorista.';
      case 'codigo cancelado':
        return 'Esse convite foi cancelado. Peca um novo ao motorista.';
      default:
        return 'Nao foi possivel vincular. Tente novamente.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Adicionar outro filho')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            'Digite o codigo de 6 caracteres que o motorista compartilhou pra esse filho.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            textAlign: TextAlign.center,
            maxLength: 6,
            style: const TextStyle(
                fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 8),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
              _UpperCaseTextFormatter(),
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: const InputDecoration(counterText: ''),
          ),
          OutlinedButton.icon(
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Escanear QR'),
          ),
          const SizedBox(height: 24),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child:
                  Text(_error!, style: const TextStyle(color: AppColors.error)),
            ),
          ElevatedButton(
            onPressed: _loading ? null : _submit,
            child: Text(_loading ? '...' : 'Vincular filho'),
          ),
        ]),
      ),
    );
  }
}
