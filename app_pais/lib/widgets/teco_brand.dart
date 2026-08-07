import 'package:flutter/material.dart';

const tecoPrimary = Color(0xFF0F4C5C);
const tecoCyan = Color(0xFF2BB3C0);
const tecoYellow = Color(0xFFF4B942);

/// Exibe diretamente o arquivo oficial fornecido da marca TECO.
/// Nenhuma parte do simbolo e redesenhada pelo aplicativo.
class TecoBrandMark extends StatelessWidget {
  final double size;
  final bool dark;
  const TecoBrandMark({super.key, this.size = 78, this.dark = false});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: Image.asset(
          dark
              ? 'assets/branding/teco-icon-dark.png'
              : 'assets/branding/teco-icon-light.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          semanticLabel: 'TECO',
        ),
      );
}

/// Assinatura horizontal oficial fornecida, usada sem reconstruir o lettering.
class TecoBrandLockup extends StatelessWidget {
  final bool compact;
  final bool dark;
  const TecoBrandLockup({super.key, this.compact = false, this.dark = false});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: compact ? 142 : 286,
        height: compact ? 44 : 92,
        child: Image.asset(
          'assets/branding/teco-logo.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          semanticLabel: 'TECO',
        ),
      );
}

/// Identificacao discreta das telas internas, sem criar uma barra adicional.
class TecoBrandedTitle extends StatelessWidget {
  final String label;
  const TecoBrandedTitle(this.label, {super.key});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const TecoBrandMark(size: 30),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
}
