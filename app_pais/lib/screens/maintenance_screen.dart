import 'package:flutter/material.dart';
import '../theme.dart';

/// Tela cheia mostrada quando uma chamada critica de boot (ex.: carregar os
/// filhos logo apos login) falha por falta de conexao ou erro no servidor --
/// em vez de deixar a tela principal vazia/parecendo quebrada.
class MaintenanceScreen extends StatelessWidget {
  final VoidCallback onRetry;
  const MaintenanceScreen({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 64, color: AppColors.primary),
              const SizedBox(height: 20),
              Text(
                'Não foi possível conectar ao TECO',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Verifique sua internet e tente de novo. Se o problema continuar, '
                'o servidor pode estar temporariamente indisponivel.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Tentar novamente'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
