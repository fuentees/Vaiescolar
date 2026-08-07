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
            Semantics(
              label: 'TECO',
              image: true,
              child: ExcludeSemantics(
                child: SizedBox(
                  width: compact ? 90 : 190,
                  height: compact ? 25 : 51,
                  child: CustomPaint(
                    painter: _TecoWordmarkPainter(color: color),
                  ),
                ),
              ),
            ),
            if (!compact) ...[
              const SizedBox(height: 4),
              Text(
                'Transporte Escolar Conectado',
                style: TextStyle(
                  color: color.withValues(alpha: .88),
                  fontSize: 9,
                  letterSpacing: .15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _TecoWordmarkPainter extends CustomPainter {
  final Color color;
  const _TecoWordmarkPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 720, size.height / 180);
    final brand = Paint()..color = color;

    canvas.drawPath(
      Path()
        ..addRect(const Rect.fromLTWH(0, 0, 166, 42))
        ..addRect(const Rect.fromLTWH(59, 42, 48, 138)),
      brand,
    );
    final e = Path()
      ..moveTo(182, 0)
      ..lineTo(346, 0)
      ..lineTo(320, 42)
      ..lineTo(230, 42)
      ..lineTo(230, 66)
      ..lineTo(320, 66)
      ..lineTo(320, 107)
      ..lineTo(230, 107)
      ..lineTo(230, 138)
      ..lineTo(346, 138)
      ..lineTo(320, 180)
      ..lineTo(182, 180)
      ..close();
    canvas.drawPath(e, brand);

    final cOuter = Path()..addOval(const Rect.fromLTWH(354, 0, 174, 180));
    final cInner = Path()..addOval(const Rect.fromLTWH(400, 42, 92, 96));
    var c = Path.combine(PathOperation.difference, cOuter, cInner);
    c = Path.combine(
      PathOperation.difference,
      c,
      Path()..addRect(const Rect.fromLTWH(480, 52, 60, 76)),
    );
    canvas.drawPath(c, brand);

    final oOuter = Path()..addOval(const Rect.fromLTWH(536, 0, 174, 180));
    final oInner = Path()..addOval(const Rect.fromLTWH(582, 42, 82, 96));
    var o = Path.combine(PathOperation.difference, oOuter, oInner);
    o = Path.combine(
      PathOperation.difference,
      o,
      Path()..addRect(const Rect.fromLTWH(665, 57, 55, 66)),
    );
    canvas.drawPath(o, brand);

    final connection = Paint()
      ..color = tecoCyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(656, 78), const Offset(700, 78), connection);
    canvas.drawLine(const Offset(656, 102), const Offset(700, 102), connection);
    canvas.drawCircle(const Offset(705, 90), 15, Paint()..color = tecoCyan);
    canvas.drawCircle(const Offset(705, 90), 6, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _TecoWordmarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _TecoMarkPainter extends CustomPainter {
  final bool dark;
  const _TecoMarkPainter({required this.dark});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 512, size.height / 512);
    canvas.translate(31, 31);
    canvas.scale(.88);
    final markColor = dark ? Colors.white : tecoPrimary;
    final background = dark ? tecoPrimary : Colors.white;

    final outerPin = Path()
      ..moveTo(248, 57)
      ..cubicTo(156, 57, 88, 123, 88, 213)
      ..cubicTo(88, 280, 138, 346, 248, 448)
      ..cubicTo(358, 346, 408, 280, 408, 213)
      ..cubicTo(408, 123, 340, 57, 248, 57)
      ..close();
    canvas.drawPath(outerPin, Paint()..color = markColor);
    final pinCutout = Path()
      ..moveTo(248, 117)
      ..cubicTo(301, 117, 344, 156, 344, 213)
      ..cubicTo(344, 253, 315, 297, 248, 364)
      ..cubicTo(181, 297, 152, 253, 152, 213)
      ..cubicTo(152, 156, 195, 117, 248, 117)
      ..close();
    canvas.drawPath(pinCutout, Paint()..color = background);

    final mirror = dark ? tecoYellow : const Color(0xFF42474E);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(179, 151, 17, 47),
        const Radius.circular(7),
      ),
      Paint()..color = mirror,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(300, 151, 17, 47),
        const Radius.circular(7),
      ),
      Paint()..color = mirror,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(190, 126, 116, 139),
        const Radius.circular(18),
      ),
      Paint()..color = tecoYellow,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(222, 114, 52, 13),
        const Radius.circular(6.5),
      ),
      Paint()..color = dark ? tecoPrimary : const Color(0xFF1F2937),
    );
    final busDetail = dark ? tecoPrimary : Colors.white;
    canvas.drawCircle(const Offset(207, 142), 5, Paint()..color = busDetail);
    canvas.drawCircle(const Offset(289, 142), 5, Paint()..color = busDetail);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(207, 151, 82, 53),
        const Radius.circular(7),
      ),
      Paint()..color = busDetail,
    );
    canvas.drawCircle(const Offset(209, 226), 9, Paint()..color = busDetail);
    canvas.drawCircle(const Offset(287, 226), 9, Paint()..color = busDetail);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(226, 217, 44, 7),
        const Radius.circular(3.5),
      ),
      Paint()..color = busDetail,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(221, 232, 54, 7),
        const Radius.circular(3.5),
      ),
      Paint()..color = busDetail,
    );

    final road = Path()
      ..moveTo(32, 484)
      ..cubicTo(108, 363, 225, 303, 412, 310)
      ..lineTo(435, 358)
      ..cubicTo(277, 353, 178, 395, 109, 484)
      ..close();
    canvas.drawPath(road, Paint()..color = markColor);
    final lanePaint = Paint()
      ..color = background
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(130, 455), const Offset(160, 431), lanePaint);
    canvas.drawLine(const Offset(187, 414), const Offset(222, 397), lanePaint);
    canvas.drawLine(const Offset(251, 385), const Offset(289, 374), lanePaint);
    canvas.drawLine(const Offset(321, 367), const Offset(360, 362), lanePaint);

    final cyanRoad = Path()
      ..moveTo(150, 484)
      ..cubicTo(222, 405, 311, 371, 432, 379)
      ..lineTo(441, 412)
      ..cubicTo(335, 405, 257, 427, 197, 484)
      ..close();
    canvas.drawPath(cyanRoad, Paint()..color = tecoCyan);
    canvas.drawCircle(const Offset(443, 394), 22, Paint()..color = tecoCyan);
    canvas.drawCircle(const Offset(443, 394), 10, Paint()..color = background);
  }

  @override
  bool shouldRepaint(covariant _TecoMarkPainter oldDelegate) =>
      oldDelegate.dark != dark;
}
