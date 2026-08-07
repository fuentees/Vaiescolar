import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api.dart';
import '../services/push_service.dart';
import '../services/remembered_login.dart';
import '../theme.dart';
import 'package:app_pais/widgets/teco_brand.dart';
import 'app_shell.dart';
import 'register_tenant_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  bool _remember = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRememberedLogin();
  }

  Future<void> _loadRememberedLogin() async {
    final saved = await RememberedLogin.load();
    if (!mounted || saved == null) return;
    setState(() {
      _email.text = saved.email;
      _pass.text = saved.password;
      _remember = true;
    });
  }

  Future<void> _submit() async {
    final email = _email.text.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'Digite um e-mail válido.');
      return;
    }
    if (_pass.text.isEmpty) {
      setState(() => _error = 'Digite sua senha.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final ok = await Api.login(email, _pass.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (ok) {
      if (_remember) {
        await RememberedLogin.save(email, _pass.text);
      } else {
        await RememberedLogin.clear();
      }
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AppShell()),
        (_) => false,
      );
      unawaited(_initPush());
    } else {
      final message = Api.lastError ?? 'E-mail ou senha incorretos.';
      setState(() => _error = message);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _initPush() async {
    try {
      await PushService.init();
    } catch (_) {
      // Login e navegacao nao dependem do Firebase; ele tenta novamente na
      // proxima abertura caso o aparelho esteja momentaneamente sem servico.
    }
  }

  void _showForgotPasswordHint() {
    showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Esqueci minha senha'),
              content: const Text(
                  'Motoristas podem pedir a redefinicao ao administrador da empresa. Se voce e o administrador, entre em contato com o suporte.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Entendi'))
              ],
            ));
  }

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: SafeArea(
            child: Center(
                child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(children: [
            const TecoBrandLockup(),
            const SizedBox(height: 24),
            Text('Central do motorista',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 32),
            TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                    labelText: 'E-mail', prefixIcon: Icon(Icons.mail_outline))),
            const SizedBox(height: 12),
            TextField(
              controller: _pass,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) {
                if (!_loading) _submit();
              },
              decoration: InputDecoration(
                  labelText: 'Senha',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    tooltip: _obscure ? 'Mostrar senha' : 'Ocultar senha',
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(_obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                  )),
            ),
            CheckboxListTile(
              value: _remember,
              onChanged: (value) => setState(() => _remember = value ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Lembrar e-mail e senha'),
              subtitle:
                  const Text('Protegidos pelo armazenamento seguro do celular'),
            ),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!,
                      style: const TextStyle(color: AppColors.error))),
            const SizedBox(height: 20),
            ElevatedButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Entrar')),
            const SizedBox(height: 8),
            TextButton(
                onPressed: _showForgotPasswordHint,
                child: const Text('Esqueci minha senha')),
            TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const RegisterTenantScreen())),
                child: const Text('Criar conta para minha empresa')),
          ])),
    ))));
  }
}
