import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../theme.dart';

/// Desenha a "van amarela estilizada" do marcador em tempo de execucao
/// (Canvas -> PNG) em vez de depender de um asset PNG externo -- assim o
/// icone customizado do design system funciona sem precisar gerar/incluir
/// uma imagem binaria no repositorio.
Future<BitmapDescriptor> buildVanMarkerIcon(
    {double devicePixelRatio = 3.0}) async {
  const double w = 64;
  const double h = 44;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder,
      Rect.fromLTWH(0, 0, w * devicePixelRatio, h * devicePixelRatio));
  canvas.scale(devicePixelRatio);

  final bodyPaint = Paint()..color = AppColors.accent;
  final outlinePaint = Paint()
    ..color = Colors.black.withValues(alpha: 0.15)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  final windowPaint = Paint()..color = Colors.white;
  final wheelPaint = Paint()..color = const Color(0xFF1C2B2B);

  final bodyRect = RRect.fromRectAndRadius(
    const Rect.fromLTWH(2, 6, w - 4, h - 18),
    const Radius.circular(8),
  );
  canvas.drawRRect(bodyRect, bodyPaint);
  canvas.drawRRect(bodyRect, outlinePaint);

  canvas.drawRRect(
    RRect.fromRectAndRadius(
        const Rect.fromLTWH(8, 10, 16, 10), const Radius.circular(3)),
    windowPaint,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(
        const Rect.fromLTWH(28, 10, 16, 10), const Radius.circular(3)),
    windowPaint,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(
        const Rect.fromLTWH(w - 20, 10, 12, 10), const Radius.circular(3)),
    windowPaint,
  );

  canvas.drawCircle(const Offset(14, h - 8), 6, wheelPaint);
  canvas.drawCircle(const Offset(w - 14, h - 8), 6, wheelPaint);

  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (w * devicePixelRatio).round(),
    (h * devicePixelRatio).round(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
}
