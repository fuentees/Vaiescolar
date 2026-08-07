import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../theme.dart';

/// Marcador compacto visto de cima. A frente aponta para o norte (topo do
/// bitmap), que e a referencia de 0 graus usada pelo heading do GPS/Google
/// Maps. Assim `rotation: heading` faz a van acompanhar o sentido da rua.
Future<BitmapDescriptor> buildVanMarkerIcon(
    {double devicePixelRatio = 3.0}) async {
  const width = 24.0;
  const height = 36.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder,
      Rect.fromLTWH(0, 0, width * devicePixelRatio, height * devicePixelRatio));
  canvas.scale(devicePixelRatio);

  final shadow = Paint()
    ..color = Colors.black.withValues(alpha: .22)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(3, 2, 18, 32), const Radius.circular(6)),
      shadow);

  final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(2, 1, 20, 33), const Radius.circular(5));
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
          const Rect.fromLTWH(4.5, 6, 15, 7), const Radius.circular(2.4)),
      Paint()..color = const Color(0xFF264A50));
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(5, 20, 14, 7), const Radius.circular(2)),
      Paint()..color = const Color(0xFF41666B));

  // Faixa central do teto ajuda a leitura de movimento sem aumentar o icone.
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(10, 14, 4, 5), const Radius.circular(1.5)),
      Paint()..color = const Color(0xFFFFD66D));

  final dark = Paint()..color = const Color(0xFF1B292B);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(.5, 8, 2.5, 7), const Radius.circular(1)),
      dark);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(21, 8, 2.5, 7), const Radius.circular(1)),
      dark);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(.5, 24, 2.5, 7), const Radius.circular(1)),
      dark);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(21, 24, 2.5, 7), const Radius.circular(1)),
      dark);

  final lights = Paint()..color = const Color(0xFFFFF4B0);
  canvas.drawCircle(const Offset(6, 3.5), 1.3, lights);
  canvas.drawCircle(const Offset(18, 3.5), 1.3, lights);
  final rearLights = Paint()..color = const Color(0xFFD94848);
  canvas.drawCircle(const Offset(6, 33.5), 1.1, rearLights);
  canvas.drawCircle(const Offset(18, 31.5), 1.1, rearLights);

  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (width * devicePixelRatio).round(),
    (height * devicePixelRatio).round(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  // O PNG e produzido em alta resolucao para ficar nitido, mas o tamanho
  // visual e fixado em pontos logicos. Sem width/height, o Maps interpretava
  // os 72x108 pixels como tamanho do marcador e a van cobria varias ruas.
  return BitmapDescriptor.bytes(
    bytes!.buffer.asUint8List(),
    width: 18,
    height: 27,
  );
}
