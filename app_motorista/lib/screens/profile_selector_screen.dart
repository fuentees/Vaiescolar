import 'package:app_pais/screens/login_screen.dart' as parent;
import 'package:flutter/material.dart';
import '../services/profile_mode.dart';
import '../theme.dart';
import 'package:app_pais/widgets/teco_brand.dart';
import 'login_screen.dart' as driver;

class ProfileSelectorScreen extends StatelessWidget {
  const ProfileSelectorScreen({super.key});

  Future<void> _open(BuildContext context, AppProfile profile) async {
    await ProfileMode.save(profile);
    if (!context.mounted) return;
    final screen = profile == AppProfile.driver
        ? const driver.LoginScreen()
        : const parent.LoginScreen();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                children: [
                  const TecoBrandLockup(),
                  const SizedBox(height: 24),
                  Text('Verificação de Usuário',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 10),
                  Text(
                    'Para garantir a melhor experiência, confirme seu perfil:',
                    style: Theme.of(context).textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  _ProfileCard(
                    icon: Icons.directions_bus_rounded,
                    title: 'Sou Motorista/Transportador',
                    subtitle: 'Sou motorista de transporte escolar',
                    color: AppColors.primary,
                    onTap: () => _open(context, AppProfile.driver),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Expanded(child: Divider()),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text('ou',
                            style: Theme.of(context).textTheme.bodyMedium),
                      ),
                      const Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _ProfileCard(
                    icon: Icons.family_restroom_rounded,
                    title: 'Sou Passageiro/Responsável',
                    subtitle: 'Quero rastrear o transporte escolar',
                    color: AppColors.cyan,
                    onTap: () => _open(context, AppProfile.parent),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'O tipo da sua conta será confirmado com segurança após o login.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ProfileCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .13),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 3),
                      Text(subtitle,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      );
}
