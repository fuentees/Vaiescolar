import 'package:flutter/material.dart';
import '../services/api.dart';
import '../theme.dart';
import 'login_screen.dart';
import 'settings_screen.dart';

/// Mostra os dados da conta logada e permite trocar a propria senha.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _me;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final me = await Api.me();
    setState(() {
      _me = me;
      _loading = false;
    });
  }

  Future<void> _openChangePasswordDialog() async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    String? error;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Trocar senha'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: currentCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Senha atual'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: newCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Nova senha'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: AppColors.error)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            ElevatedButton(
              onPressed: () async {
                if (currentCtrl.text.isEmpty ||
                    newCtrl.text.trim().length < 6) {
                  setDialogState(() => error =
                      'Preencha a senha atual e uma nova com ao menos 6 caracteres.');
                  return;
                }
                final err = await Api.changePassword(
                    currentCtrl.text, newCtrl.text.trim());
                if (err != null) {
                  setDialogState(() => error = err);
                  return;
                }
                if (context.mounted) Navigator.pop(context);
                if (mounted) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(
                        content: Text('Senha atualizada com sucesso.')),
                  );
                }
              },
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sair da conta?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sair')),
        ],
      ),
    );
    if (confirmed != true) return;
    await Api.logout();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Minha conta')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: CircleAvatar(
                    radius: 40,
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    child: Text(
                      (_me?['name'] as String? ?? '?')
                          .substring(0, 1)
                          .toUpperCase(),
                      style: const TextStyle(
                          fontSize: 32, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: const Text('Nome'),
                        subtitle: Text(_me?['name'] as String? ?? '-'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.email_outlined),
                        title: const Text('E-mail'),
                        subtitle: Text(_me?['email'] as String? ?? '-'),
                      ),
                      if ((_me?['phone'] as String?)?.isNotEmpty == true)
                        ListTile(
                          leading: const Icon(Icons.phone_outlined),
                          title: const Text('Telefone'),
                          subtitle: Text(_me!['phone'] as String),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.settings_outlined),
                    title: const Text('Configuracoes'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _openChangePasswordDialog,
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('Trocar senha'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _logout,
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error),
                  icon: const Icon(Icons.logout),
                  label: const Text('Sair da conta'),
                ),
              ],
            ),
    );
  }
}
