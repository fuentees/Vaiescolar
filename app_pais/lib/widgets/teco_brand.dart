import 'package:flutter/material.dart';

const tecoPrimary = Color(0xFF0F4C5C);
const tecoCyan = Color(0xFF2BB3C0);
const tecoYellow = Color(0xFFF4B942);

class TecoBrandMark extends StatelessWidget {
  final double size;
  final bool dark;
  const TecoBrandMark({super.key, this.size = 78, this.dark = false});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: dark ? tecoPrimary : Colors.white,
          borderRadius: BorderRadius.circular(size * .25),
          boxShadow: [
            BoxShadow(
              color: tecoPrimary.withValues(alpha: .18),
              blurRadius: size * .28,
              offset: Offset(0, size * .12),
            ),
          ],
        ),
        child: CustomPaint(painter: _TecoMarkPainter(dark: dark)),
      );
}

class TecoBrandLockup extends StatelessWidget {
  final bool compact;
  final bool dark;
  const TecoBrandLockup({super.key, this.compact = false, this.dark = false});

  @override
  Widget build(BuildContext context) {
    final color = dark ? Colors.white : tecoPrimary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TecoBrandMark(size: compact ? 42 : 62, dark: dark),
        SizedBox(width: compact ? 9 : 13),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('TECO',
                style: TextStyle(
                  color: color,
                  fontSize: compact ? 24 : 38,
                  height: .9,
                  letterSpacing: compact ? 1 : 2,
                  fontWeight: FontWeight.w900,
                )),
            if (!compact) ...[
              const SizedBox(height: 6),
              Text('TRANSPORTE ESCOLAR CONECTADO',
                  style: TextStyle(
                    color: color.withValues(alpha: .82),
                    fontSize: 8.2,
                    letterSpacing: 1.05,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ],
        ),
      ],
    );
  }
}

class _TecoMarkPainter extends CustomPainter {
  final bool dark;
  const _TecoMarkPainter({required this.dark});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 512;
    final sy = size.height / 512;
    canvas.scale(sx, sy);
    canvas.translate(51, 51);
    canvas.scale(.8);
    final markColor = dark ? Colors.white : tecoPrimary;

    final outerPin = Path()
      ..moveTo(255, 48)
      ..cubicTo(159, 48, 86, 114, 86, 206)
      ..cubicTo(86, 274, 134, 341, 255, 456)
      ..cubicTo(376, 341, 424, 274, 424, 206)
      ..cubicTo(424, 114, 351, 48, 255, 48)
      ..close();
    canvas.drawPath(outerPin, Paint()..color = markColor);
    final pinCutout = Path()
      ..moveTo(255, 99)
      ..cubicTo(320, 99, 367, 142, 367, 205)
      ..cubicTo(367, 251, 336, 299, 255, 381)
      ..cubicTo(174, 299, 143, 251, 143, 205)
      ..cubicTo(143, 142, 190, 99, 255, 99)
      ..close();
    canvas.drawPath(
        pinCutout, Paint()..color = dark ? tecoPrimary : Colors.white);

    final mirrorPaint = Paint()..color = const Color(0xFF6B7280);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(171, 145, 30, 84), const Radius.circular(14)),
        dark ? (Paint()..color = tecoYellow) : mirrorPaint);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(309, 145, 30, 84), const Radius.circular(14)),
        dark ? (Paint()..color = tecoYellow) : mirrorPaint);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(193, 123, 124, 145), const Radius.circular(24)),
        Paint()..color = tecoYellow);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(215, 111, 80, 22), const Radius.circular(10)),
        Paint()..color = tecoYellow);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(210, 144, 90, 52), const Radius.circular(8)),
        Paint()..color = dark ? tecoPrimary : Colors.white);
    canvas.drawLine(
        const Offset(255, 145),
        const Offset(255, 195),
        Paint()
          ..color = const Color(0xFFD99B22)
          ..strokeWidth = 5);
    final detailColor = dark ? tecoPrimary : Colors.white;
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(211, 207, 88, 12), const Radius.circular(6)),
        Paint()..color = detailColor);
    canvas.drawCircle(const Offset(216, 238), 9, Paint()..color = detailColor);
    canvas.drawCircle(const Offset(294, 238), 9, Paint()..color = detailColor);

    final road = Path()
      ..moveTo(34, 489)
      ..cubicTo(79, 404, 141, 346, 217, 314)
      ..cubicTo(280, 287, 352, 279, 443, 288)
      ..lineTo(424, 341)
      ..cubicTo(348, 333, 288, 339, 236, 361)
      ..cubicTo(176, 386, 127, 429, 89, 489)
      ..close();
    canvas.drawPath(road, Paint()..color = markColor);
    final lane = Path()
      ..moveTo(103, 489)
      ..cubicTo(140, 434, 184, 395, 235, 372)
      ..cubicTo(280, 352, 331, 344, 393, 347);
    canvas.drawPath(
        lane,
        Paint()
          ..color = dark ? tecoPrimary : Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 12
          ..strokeCap = StrokeCap.round);
    final connection = Path()
      ..moveTo(204, 431)
      ..cubicTo(272, 386, 343, 364, 418, 367)
      ..cubicTo(439, 368, 456, 359, 468, 341);
    canvas.drawPath(
        connection,
        Paint()
          ..color = tecoCyan
          ..style = PaintingStyle.stroke
          ..strokeWidth = 11
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(const Offset(473, 333), 21, Paint()..color = tecoCyan);
    canvas.drawCircle(const Offset(473, 333), 9,
        Paint()..color = dark ? tecoPrimary : Colors.white);
  }

  @override
  bool shouldRepaint(covariant _TecoMarkPainter oldDelegate) =>
      oldDelegate.dark != dark;
}
