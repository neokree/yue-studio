// Paints the app icon with the in-app logo painter and writes the AppIcon.appiconset PNGs.
// Run: tool/make_icon.sh   (= fvm flutter test tool/make_icon/make_icon_test.dart)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/brand/yue_logo.dart';

const _accent = Color(0xFFA4503A);
const _out = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';

/// Everything is laid out on the 1024 Big Sur grid, then scaled: each size is rasterised natively.
Future<ui.Image> _render(int size) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.scale(size / 1024);
  const body = Rect.fromLTWH(100, 100, 824, 824);
  final shape = RSuperellipse.fromRectAndRadius(body, const Radius.circular(185));
  // soft drop shadow: ~10 px blur, 12% black, 8 px down
  c.drawRSuperellipse(
    shape.shift(const Offset(0, 8)),
    Paint()
      ..color = const Color(0x1F000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
  );
  c.drawRSuperellipse(
    shape,
    Paint()
      ..shader = ui.Gradient.linear(body.topCenter, body.bottomCenter, const [Color(0xFFF6F4F1), Color(0xFFEDE8E3)]),
  );
  // mark: 62% of the body, centred. The painter has a fixed stroke, so at small sizes the mark is
  // drawn a few times with sub-pixel offsets to thicken it (keeps 16/32 px crisp).
  final mark = 824 * (size <= 16 ? .72 : .62); // 62% of the body; a bit larger at 16 px
  final thick = size <= 64 ? (size <= 16 ? 5.0 : size <= 32 ? 6.0 : 4.0) : 0.0; // in 1024-grid px
  final offsets = thick == 0
      ? const [Offset.zero]
      : [for (final dx in [-thick, 0.0, thick]) for (final dy in [-thick, 0.0, thick]) Offset(dx, dy)];
  for (final o in offsets) {
    c.save();
    c.translate(512 - mark / 2 + o.dx, 512 - mark / 2 + o.dy);
    const YueLogoPainter(_accent).paint(c, Size.square(mark));
    c.restore();
  }
  return rec.endRecording().toImage(size, size);
}

void main() {
  testWidgets('write app icon PNGs', (tester) async {
    await tester.runAsync(() async {
      for (final s in [16, 32, 64, 128, 256, 512, 1024]) {
        final img = await _render(s);
        final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$_out/app_icon_$s.png').writeAsBytes(bytes.buffer.asUint8List());
      }
    });
    expect(File('$_out/app_icon_1024.png').existsSync(), isTrue);
  });
}
