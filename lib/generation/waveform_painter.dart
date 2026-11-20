import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// Mutable state of the ring, owned by the view and advanced by its single Ticker.
/// Notifies once per frame; the painter repaints from this and nothing rebuilds.
class WaveFrame extends ChangeNotifier {
  /// Seconds of animation time (frozen at 0 under Reduce Motion).
  double time = 0;

  /// Real progress shown, 0..1.
  double progress = 0;

  /// 0..1: how far the ring has settled to an even length after completion.
  double settle = 0;

  void bump() => notifyListeners();
}

/// 120 radial bars around the mark (design/DESIGN.md, "Generation waveform").
/// Two drawRawPoints calls per frame, no Path, no per-frame allocation besides two list views.
class WaveformPainter extends CustomPainter {
  WaveformPainter(this.frame, {required this.accent, required this.idle, this.pulse = true}) : super(repaint: frame) {
    _on = Paint()
      ..color = accent
      ..strokeCap = StrokeCap.round;
    _off = Paint()
      ..color = idle.withValues(alpha: 0.45)
      ..strokeCap = StrokeCap.round;
  }

  final WaveFrame frame;
  final Color accent, idle;

  /// False under Reduce Motion: static ring, no beat.
  final bool pulse;

  static const bars = 120;
  static const beatHz = 0.35;

  static final Float64List _cos = Float64List.fromList(
      [for (var i = 0; i < bars; i++) math.cos(i / bars * 2 * math.pi - math.pi / 2)]);
  static final Float64List _sin = Float64List.fromList(
      [for (var i = 0; i < bars; i++) math.sin(i / bars * 2 * math.pi - math.pi / 2)]);

  // Spatial frequencies are whole turns around the ring, so the shape is seamless at 12 o'clock and has no
  // high-frequency term to make neighbouring bars jag.
  static const _k = [3.0, 5.0, 8.0];

  late final Paint _on, _off;
  final Float32List _buf = Float32List(bars * 4);

  /// Sharp attack, slow release, 0..1.
  static double beat(double t) {
    final ph = (t * beatHz) % 1.0;
    const attack = 0.06;
    if (ph < attack) return ph / attack;
    return math.pow(1 - (ph - attack) / (1 - attack), 2.4).toDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final d = math.min(size.width, size.height);
    final cx = size.width / 2, cy = size.height / 2;
    final w = d * 0.009;
    _on.strokeWidth = _off.strokeWidth = w;
    final r0 = d * 0.22;
    // The longest bar, round cap included, ends exactly on the ring's outer diameter.
    final minLen = d * 0.015, maxLen = d * 0.5 - w - r0;
    final t = frame.time, s = frame.settle.clamp(0.0, 1.0), p = frame.progress.clamp(0.0, 1.0);
    final reachedAmp = ui.lerpDouble(pulse ? 0.55 + 0.45 * beat(t) : 0.75, 0.8, s)!;
    final idleAmp = ui.lerpDouble(0.3, 0.8, s)!;
    final reached = (p * bars).ceil().clamp(0, bars);
    for (var i = 0; i < bars; i++) {
      final th = i / bars * 2 * math.pi;
      // Sum of three slow sines, 0..1.
      var v = 0.5 + 0.5 * (math.sin(th * _k[0] + t * 1.1) * .5 + math.sin(th * _k[1] - t * .8) * .3 + math.sin(th * _k[2] + t * 1.7) * .2);
      v = ((v - 0.2) / 0.6).clamp(0.0, 1.0); // sines rarely leave 0.2..0.8: stretch so peaks reach the ring edge
      v = v + (0.45 - v) * s;
      final len = math.min(maxLen, minLen + (maxLen - minLen) * v * (i < reached ? reachedAmp : idleAmp));
      final c = _cos[i], sn = _sin[i], o = i * 4;
      _buf[o] = (cx + c * r0);
      _buf[o + 1] = (cy + sn * r0);
      _buf[o + 2] = (cx + c * (r0 + len));
      _buf[o + 3] = (cy + sn * (r0 + len));
    }
    if (reached > 0) canvas.drawRawPoints(ui.PointMode.lines, Float32List.sublistView(_buf, 0, reached * 4), _on);
    if (reached < bars) canvas.drawRawPoints(ui.PointMode.lines, Float32List.sublistView(_buf, reached * 4), _off);
  }

  @override
  bool shouldRepaint(WaveformPainter old) => old.accent != accent || old.idle != idle || old.pulse != pulse || old.frame != frame;
}
