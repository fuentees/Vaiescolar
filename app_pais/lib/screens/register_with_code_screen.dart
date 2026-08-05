import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api.dart';
import '../services/push_service.dart';
import '../theme.dart';
import 'app_shell.dart';
import 'privacy_screen.dart';
import 'qr_scan_screen.dart';

class _UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}

/// Cadastro do responsavel via codigo de convite (gerado pelo motorista para
/// um aluno especifico). E assim que o pai entra no sistema: sem o motorista
/// precisar digitar o cadastro de ninguem.
class RegisterWithCodeScreen extends StatefulWidget {
  const RegisterWithCodeScreen({super.key});
  @override
  State<RegisterWithCodeScreen> createState() => _RegisterWithCodeScreenState();
}

class _RegisterWithCodeScreenState extends State<RegisterWithCodeScreen> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _consent = false;
  bool _loading = false;
  String? _error;
  final _privacyTap = TapGestureRecognizer();

  @override
  void dispose() {
    _privacyTap.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result != null && mounted) {
      setState(() => _code.text = result.toUpperCase());
    }
  }

  Future<void> _submit() async {
    if (_code.text.trim().length != 6 ||
        _email.text.trim().isEmpty ||
        _pass.text.isEmpty) {
      setState(() => _error = 'Preencha o codigo, o e-mail e a senha.');
      return;
    }
    if (!_consent) {
      setState(
          () => _error = 'Aceite a politica de privacidade para continuar.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final error = await Api.registerWithCode(
      code: _code.text.trim(),
      name: _name.text.trim(),
      email: _email.text.trim(),
      password: _pass.text,
    );
    setState(() => _loading = false);
    if (error == null) {
      await PushService.init();
      if (mounted) {
        final student = Api.lastLinkedStudentName ?? 'Aluno';
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.check_circle,
                color: AppColors.success, size: 44),
            title: Text(Api.lastLinkUsedExistingAccount
                ? 'Aluno adicionado!'
                : 'Conta criada!'),
            content: Text(Api.lastLinkUsedExistingAccount
                ? 'Sua conta foi encontrada e $student foi adicionado com sucesso.'
                : 'Sua conta foi criada e $student foi adicionado com sucesso.'),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Continuar'))
            ],
          ),
        );
      }
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AppShell()),
        );
      }
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
      case 'conta existente: senha incorreta':
        return 'Ja existe uma conta com este e-mail. Informe a senha atual para adicionar o aluno.';
      case 'e-mail usado em outro perfil ou transportador':
        return 'Este e-mail pertence a outro perfil ou transportador.';
      default:
        return 'Nao foi possivel completar o cadastro. Tente novamente.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Criar conta com convite')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            'Digite o codigo de 6 caracteres enviado pelo transportador. Se voce ja possui conta, use o mesmo e-mail e a sua senha atual para adicionar outro filho.',
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
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Seu nome')),
          const SizedBox(height: 8),
          TextField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'E-mail')),
          const SizedBox(height: 8),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Senha',
              helperText: 'Conta existente? Digite sua senha atual.',
            ),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: _consent,
            onChanged: (v) => setState(() => _consent = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: RichText(
              text: TextSpan(
                style: DefaultTextStyle.of(context).style,
                children: [
                  const TextSpan(
                    text:
                        'Autorizo a coleta dos dados do meu filho para o acompanhamento '
                        'do transporte escolar, conforme a ',
                  ),
                  TextSpan(
                    text: 'Politica de Privacidade',
                    style: const TextStyle(
                        color: AppColors.primary,
                        decoration: TextDecoration.underline),
                    recognizer: _privacyTap
                      ..onTap = () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const PrivacyScreen()),
                          ),
                  ),
                  const TextSpan(text: '.'),
                ],
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child:
                  Text(_error!, style: const TextStyle(color: AppColors.error)),
            ),
          ElevatedButton(
            onPressed: _loading ? null : _submit,
            child: Text(_loading ? '...' : 'Continuar'),
          ),
        ]),
      ),
    );
  }
}
