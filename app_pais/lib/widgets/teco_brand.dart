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
        padding: EdgeInsets.all(size * .09),
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
    final sx = size.width / 100;
    final sy = size.height / 100;
    canvas.scale(sx, sy);
    final primary = Paint()
      ..color = dark ? Colors.white : tecoPrimary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final pin = Path()
      ..moveTo(50, 69)
      ..cubicTo(38, 54, 27, 42, 27, 28)
      ..cubicTo(27, 10, 40, 2, 52, 2)
      ..cubicTo(67, 2, 77, 13, 77, 28)
      ..cubicTo(77, 42, 65, 56, 50, 69);
    canvas.drawPath(pin, primary);

    final road = Path()
      ..moveTo(7, 97)
      ..cubicTo(22, 75, 38, 69, 61, 72)
      ..cubicTo(75, 74, 84, 69, 93, 60);
    canvas.drawPath(
        road,
        Paint()
          ..color = dark ? Colors.white : tecoPrimary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 12
          ..strokeCap = StrokeCap.round);
    final connection = Path()
      ..moveTo(64, 80)
      ..cubicTo(77, 82, 85, 76, 92, 69);
    canvas.drawPath(
        connection,
        Paint()
          ..color = tecoCyan
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(const Offset(94, 67), 4.5, Paint()..color = tecoCyan);
    canvas.drawCircle(const Offset(94, 67), 2,
        Paint()..color = dark ? tecoPrimary : Colors.white);

    final bus = RRect.fromRectAndRadius(
        const Rect.fromLTWH(38, 18, 28, 30), const Radius.circular(5));
    canvas.drawRRect(bus, Paint()..color = tecoYellow);
    canvas.drawRRect(const RRect.fromLTRBXY(42, 22, 62, 31, 2, 2),
        Paint()..color = tecoPrimary);
    canvas.drawRect(
        const Rect.fromLTWH(42, 35, 20, 4), Paint()..color = Colors.white);
    canvas.drawCircle(const Offset(43, 48), 3, Paint()..color = tecoPrimary);
    canvas.drawCircle(const Offset(61, 48), 3, Paint()..color = tecoPrimary);
  }

  @override
  bool shouldRepaint(covariant _TecoMarkPainter oldDelegate) =>
      oldDelegate.dark != dark;
}
