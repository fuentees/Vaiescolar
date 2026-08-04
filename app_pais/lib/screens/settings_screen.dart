import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/theme_controller.dart';
import '../services/update_service.dart';
import 'help_screen.dart';
import 'privacy_screen.dart';

/// Configuracoes: tema (persistido), atalhos pra ajuda/privacidade e versao
/// do app.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    final rawBuild = int.tryParse(info.buildNumber) ?? 0;
    final build = rawBuild >= 1000 ? rawBuild % 1000 : rawBuild;
    setState(() => _version = '${info.version} (build $build)');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configuracoes')),
      body: ListView(
        children: [
          const _SectionLabel('Aparencia'),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: ThemeController.mode,
            builder: (context, mode, _) => RadioGroup<ThemeMode>(
              groupValue: mode,
              onChanged: (v) => ThemeController.setMode(v!),
              child: const Column(
                children: [
                  RadioListTile<ThemeMode>(
                      title: Text('Automatico (sistema)'),
                      value: ThemeMode.system),
                  RadioListTile<ThemeMode>(
                      title: Text('Claro'), value: ThemeMode.light),
                  RadioListTile<ThemeMode>(
                      title: Text('Escuro'), value: ThemeMode.dark),
                ],
              ),
            ),
          ),
          const Divider(),
          const _SectionLabel('Sobre'),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('Central de ajuda'),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const HelpScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacidade e termos'),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const PrivacyScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('Verificar atualização'),
            onTap: () => UpdateService.check(context, showUpToDate: true),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Versao do app'),
            subtitle: Text(_version.isEmpty ? 'Carregando...' : _version),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
