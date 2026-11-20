import 'package:flutter/material.dart';

/// The mock's 16 x 16 line icons, drawn in code.
enum NavGlyph { create, cover, library, heart }

class NavIcon extends StatelessWidget {
  const NavIcon(this.glyph, {super.key, required this.color, this.size = 16});
  final NavGlyph glyph;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GlyphPainter(glyph, color));
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);
  final NavGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 16, size.height / 16);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (glyph) {
      case NavGlyph.create:
        canvas.drawPath(Path()..moveTo(8, 2)..lineTo(8, 14)..moveTo(2, 8)..lineTo(14, 8), line);
      case NavGlyph.cover:
        canvas.drawPath(
            Path()..moveTo(6, 12)..lineTo(6, 3)..lineTo(13, 1.5)..lineTo(13, 10), line);
        canvas.drawCircle(const Offset(4, 12), 2, line);
        canvas.drawCircle(const Offset(11, 10.5), 2, line);
      case NavGlyph.library:
        canvas.drawPath(
            Path()
              ..moveTo(3, 2.5)..lineTo(3, 13.5)
              ..moveTo(6.5, 2.5)..lineTo(6.5, 13.5)
              ..moveTo(10, 3)..lineTo(13, 13),
            line);
      case NavGlyph.heart:
        canvas.drawPath(
            Path()
              ..moveTo(8, 14)
              ..cubicTo(8, 14, 2, 10.2, 2, 6.2)
              ..cubicTo(2, 4.2, 3.6, 3, 5.2, 3)
              ..cubicTo(6.4, 3, 7.5, 3.6, 8, 4.6)
              ..cubicTo(8.5, 3.6, 9.6, 3, 10.8, 3)
              ..cubicTo(12.4, 3, 14, 4.2, 14, 6.2)
              ..cubicTo(14, 10.2, 8, 14, 8, 14)
              ..close(),
            Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color;
}
