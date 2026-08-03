import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Escaneia o QR gerado pelo app do motorista (codifica o mesmo codigo de 6
/// caracteres do convite) e devolve o valor lido via Navigator.pop.
class QrScanScreen extends StatelessWidget {
  const QrScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Escanear codigo')),
      body: MobileScanner(
        onDetect: (capture) {
          for (final barcode in capture.barcodes) {
            final value = barcode.rawValue;
            if (value != null && value.isNotEmpty) {
              Navigator.of(context).pop(value);
              return;
            }
          }
        },
      ),
    );
  }
}
