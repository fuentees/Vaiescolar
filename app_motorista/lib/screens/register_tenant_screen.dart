import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';
import 'app_shell.dart';

/// Onboarding de uma empresa/motorista autonomo novo: cria o tenant e a
/// conta admin do dono. E a "porta de entrada" do produto -- sem essa tela,
/// so seria possivel cadastrar uma empresa nova via chamada direta a API.
class RegisterTenantScreen extends StatefulWidget {
  const RegisterTenantScreen({super.key});
  @override
  State<RegisterTenantScreen> createState() => _RegisterTenantScreenState();
}

class _RegisterTenantScreenState extends State<RegisterTenantScreen> {
  final _tenantNameCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    if (_tenantNameCtrl.text.trim().isEmpty ||
        _nameCtrl.text.trim().isEmpty ||
        _emailCtrl.text.trim().isEmpty ||
        _passCtrl.text.isEmpty) {
      setState(() => _error = 'Preencha todos os campos.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final error = await Api.registerTenant(
      tenantName: _tenantNameCtrl.text.trim(),
      name: _nameCtrl.text.trim(),
      email: _emailCtrl.text.trim(),
      password: _passCtrl.text,
    );
    setState(() => _loading = false);
    if (error == null) {
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AppShell()),
          (route) => false,
        );
      }
    } else {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Criar conta')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            'Cadastre sua empresa ou van escolar no VaiEscolar.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _tenantNameCtrl,
            decoration: const InputDecoration(
                labelText: 'Nome da empresa/van (ex.: Van do Ze)'),
          ),
          const SizedBox(height: 8),
          TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Seu nome')),
          const SizedBox(height: 8),
          TextField(
              controller: _emailCtrl,
              decoration: const InputDecoration(labelText: 'E-mail')),
          const SizedBox(height: 8),
          TextField(
            controller: _passCtrl,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Senha'),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child:
                  Text(_error!, style: const TextStyle(color: AppColors.error)),
            ),
          ElevatedButton(
            onPressed: _loading ? null : _submit,
            child: Text(_loading ? '...' : 'Criar conta'),
          ),
        ]),
      ),
    );
  }
}
