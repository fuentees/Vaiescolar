import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api.dart';
import '../services/push_service.dart';
import '../services/remembered_login.dart';
import '../theme.dart';
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
    setState(() {
      _loading = true;
      _error = null;
    });
    final ok = await Api.login(_email.text.trim(), _pass.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (ok) {
      if (_remember) {
        await RememberedLogin.save(_email.text.trim(), _pass.text);
      } else {
        await RememberedLogin.clear();
      }
      if (!mounted) return;
      Navigator.of(context)
          .pushReplacement(MaterialPageRoute(builder: (_) => const AppShell()));
      unawaited(_initPush());
    } else {
      setState(() => _error = 'E-mail ou senha incorretos.');
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
            const _BrandMark(icon: Icons.directions_bus_rounded),
            const SizedBox(height: 24),
            Text('VaiEscolar',
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
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
              subtitle: const Text('Protegidos pelo armazenamento seguro do celular'),
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

class _BrandMark extends StatelessWidget {
  final IconData icon;
  const _BrandMark({required this.icon});
  @override
  Widget build(BuildContext context) => Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [AppColors.primary, Color(0xFF18A3A3)]),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
                color: AppColors.primary.withValues(alpha: .28),
                blurRadius: 28,
                offset: const Offset(0, 12))
          ],
        ),
        child: Icon(icon, color: Colors.white, size: 38),
      );
}
