import 'package:flutter/material.dart';

/// Cabecalho persistente das areas autenticadas.
/// Usa diretamente a assinatura oficial fornecida da marca TECO.
class AuthenticatedBrandBar extends StatelessWidget {
  const AuthenticatedBrandBar({super.key});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).dividerColor.withValues(alpha: .35),
            ),
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            width: double.infinity,
            height: 54,
            child: Center(
              child: Image.asset(
                'assets/branding/teco-logo.png',
                width: 174,
                height: 50,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                semanticLabel: 'TECO',
              ),
            ),
          ),
        ),
      );
}
