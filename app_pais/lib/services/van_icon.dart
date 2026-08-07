import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../theme.dart';

/// Marcador compacto visto de cima. A frente aponta para o norte (topo do
/// bitmap), que e a referencia de 0 graus usada pelo heading do GPS/Google
/// Maps. Assim `rotation: heading` faz a van acompanhar o sentido da rua.
Future<BitmapDescriptor> buildVanMarkerIcon(
    {double devicePixelRatio = 3.0}) async {
  const width = 22.0;
  const height = 38.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder,
      Rect.fromLTWH(0, 0, width * devicePixelRatio, height * devicePixelRatio));
  canvas.scale(devicePixelRatio);

  final shadow = Paint()
    ..color = Colors.black.withValues(alpha: .22)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2);
  canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(3, 2, 16, 34),
          const Radius.circular(6)),
      shadow);

  final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(2, 1, 18, 35), const Radius.circular(6));
  canvas.drawRRect(body, Paint()..color = AppColors.accent);
  canvas.drawRRect(
      body,
      Paint()
        ..color = const Color(0xFF9C6C00).withValues(alpha: .55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);

  // Para-brisa dianteiro (a frente e o topo do desenho).
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(4.5, 6, 13, 7), const Radius.circular(2.4)),
      Paint()..color = const Color(0xFF264A50));
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(5, 20, 12, 7), const Radius.circular(2)),
      Paint()..color = const Color(0xFF41666B));

  // Faixa central do teto ajuda a leitura de movimento sem aumentar o icone.
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(9, 14, 4, 5), const Radius.circular(1.5)),
      Paint()..color = const Color(0xFFFFD66D));

  final dark = Paint()..color = const Color(0xFF1B292B);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(.5, 8, 2.5, 7), const Radius.circular(1)),
      dark);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(19, 8, 2.5, 7), const Radius.circular(1)),
      dark);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(.5, 24, 2.5, 7), const Radius.circular(1)),
      dark);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(19, 24, 2.5, 7), const Radius.circular(1)),
      dark);

  final lights = Paint()..color = const Color(0xFFFFF4B0);
  canvas.drawCircle(const Offset(6, 3.5), 1.3, lights);
  canvas.drawCircle(const Offset(16, 3.5), 1.3, lights);
  final rearLights = Paint()..color = const Color(0xFFD94848);
  canvas.drawCircle(const Offset(6, 33.5), 1.1, rearLights);
  canvas.drawCircle(const Offset(16, 33.5), 1.1, rearLights);

  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (width * devicePixelRatio).round(),
    (height * devicePixelRatio).round(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
}
