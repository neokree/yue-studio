import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../theme/tokens.dart';

/// The YuE2 mark (circle with hanging notes), redrawn from reference/yue2-logo.webp on a 100 x 100 grid.
class YueLogo extends StatelessWidget {
  const YueLogo({super.key, this.size = 26, this.color});
  final double size;

  /// Defaults to the accent colour.
  final Color? color;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'YuE2',
        image: true,
        child: CustomPaint(
          size: Size.square(size),
          painter: YueLogoPainter(color ?? AppColors.of(context).accent),
        ),
      );
}

class YueLogoPainter extends CustomPainter {
  const YueLogoPainter(this.color);
  final Color color;

  /// Stroke 4 on the 100 grid: round caps and joins, as in the reference.
  static Path get _line => Path()
    // the flag-and-beam
    ..moveTo(58, 7)
    ..relativeLineTo(0, 16)
    ..relativeCubicTo(0, 8, -3, 10, -10, 10)
    ..lineTo(31, 33)
    ..arcToPoint(const Offset(31, 47), radius: const Radius.circular(5), clockwise: false)
    ..relativeLineTo(44, 0)
    // three stems
    ..moveTo(38, 47)
    ..relativeLineTo(0, 28)
    ..moveTo(53, 47)
    ..relativeLineTo(0, 31)
    ..moveTo(68, 47)
    ..relativeLineTo(0, 28);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 100, size.height / 100);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(50, 50), 45, stroke);
    canvas.drawPath(_line, stroke);
    final fill = Paint()..color = color;
    canvas.drawCircle(const Offset(33, 76), 5, fill);
    canvas.drawCircle(const Offset(63, 76), 5, fill);
  }

  @override
  bool shouldRepaint(YueLogoPainter old) => old.color != color;
}

/// "YuE² Studio": the 2 is a superscript at about 62%, bold, in the accent colour.
class YueWordmark extends StatelessWidget {
  const YueWordmark({super.key, this.fontSize = TypeSize.brand});
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final base = TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600, color: c.text, height: 1.1);
    return Semantics(
      label: '${t.shell.brand.main}${t.shell.brand.sup} ${t.shell.brand.studio}',
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(style: base, children: [
          TextSpan(text: t.shell.brand.main),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Transform.translate(
              offset: Offset(0.5, -fontSize * .38),
              child: Text(
                t.shell.brand.sup,
                style: TextStyle(fontSize: fontSize * .62, fontWeight: FontWeight.w700, color: c.accent, height: 1),
              ),
            ),
          ),
          TextSpan(text: ' ${t.shell.brand.studio}'),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
