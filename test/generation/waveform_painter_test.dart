import 'dart:ui' as ui;


import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/generation/waveform_painter.dart';

void main() {
  test('paints at every progress, settle and reduced-motion setting without throwing; beat has a sharp attack', () {
    final frame = WaveFrame();
    for (final pulse in [true, false]) {
      final painter = WaveformPainter(frame, accent: const Color(0xFFA4503A), idle: const Color(0xFF77777C), pulse: pulse);
      for (final (p, s) in [(0.0, 0.0), (0.004, 0.0), (0.5, 0.0), (1.0, 0.0), (1.0, 0.5), (1.0, 1.0), (1.5, 2.0), (-1.0, 0.0)]) {
        frame
          ..time = p * 7
          ..progress = p
          ..settle = s;
        painter.paint(ui.Canvas(ui.PictureRecorder()), const Size(340, 340));
      }
    }
    expect(WaveformPainter.beat(0), 0);
    expect(WaveformPainter.beat(0.06 / WaveformPainter.beatHz), closeTo(1, 1e-9));
    expect(WaveformPainter.beat(0.5 / WaveformPainter.beatHz), lessThan(0.25));
  });

  test('no bar, round cap included, leaves the ring outer diameter', () async {
    const d = 300;
    final frame = WaveFrame();
    final painter = WaveformPainter(frame, accent: const Color(0xFFA4503A), idle: const Color(0xFF77777C));
    for (final (t, p, s) in [(0.0, 0.5, 0.0), (0.06 / WaveformPainter.beatHz, 0.5, 0.0), (3.3, 1.0, 0.0), (1.0, 1.0, 1.0)]) {
      frame
        ..time = t
        ..progress = p
        ..settle = s;
      final rec = ui.PictureRecorder();
      painter.paint(ui.Canvas(rec), Size(d.toDouble(), d.toDouble()));
      final img = await rec.endRecording().toImage(d, d);
      final px = (await img.toByteData())!;
      var outside = 0;
      for (var y = 0; y < d; y++) {
        for (var x = 0; x < d; x++) {
          final dx = x + .5 - d / 2, dy = y + .5 - d / 2;
          if (dx * dx + dy * dy > (d / 2) * (d / 2) && px.getUint8((y * d + x) * 4 + 3) > 40) outside++;
        }
      }
      expect(outside, 0, reason: 't=$t p=$p s=$s');
    }
  });

  test('paint is cheap', () {
    final frame = WaveFrame()..progress = 0.5;
    final painter = WaveformPainter(frame, accent: const Color(0xFFA4503A), idle: const Color(0xFF77777C));
    final canvas = ui.Canvas(ui.PictureRecorder());
    for (var i = 0; i < 200; i++) {
      frame.time = i / 60;
      painter.paint(canvas, const Size(340, 340)); // warm up
    }
    final sw = Stopwatch()..start();
    const n = 2000;
    for (var i = 0; i < n; i++) {
      frame.time = i / 60;
      painter.paint(canvas, const Size(340, 340));
    }
    final us = sw.elapsedMicroseconds / n;
    // ignore: avoid_print
    print('WaveformPainter.paint: ${us.toStringAsFixed(1)} us per frame (debug/JIT, recording canvas)');
    expect(us, lessThan(1000), reason: 'a frame is 16000 us; the ring must stay far below that');
  });
}
