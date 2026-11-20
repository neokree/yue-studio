import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

// Song artwork, algorithm version 1. NEVER change what version 1 produces for a given seed:
// add a version 2 instead (DESIGN.md "Artwork"). Spec is stored in meta.json as {algorithm, seed}.

const _mask = 0xFFFFFFFF;

/// 32-bit FNV-1a, used to derive a seed for songs created before artwork existed.
int fnv1a32(String s) {
  var h = 0x811C9DC5;
  for (final u in s.codeUnits) {
    h = ((h ^ (u & 0xFF)) * 0x01000193) & _mask;
    if (u > 0xFF) h = ((h ^ (u >> 8)) * 0x01000193) & _mask;
  }
  return h;
}

int _imul(int a, int b) => (((a & 0xFFFF) * b) + ((((a >>> 16) * b) & 0xFFFF) << 16)) & _mask;

/// mulberry32 with explicit 32-bit masking (identical on every platform, never dart:math Random).
class Mulberry32 {
  Mulberry32(int seed) : _a = seed & _mask;
  int _a;

  int nextInt() {
    _a = (_a + 0x6D2B79F5) & _mask;
    var t = _a;
    t = _imul(t ^ (t >>> 15), t | 1);
    t = (t ^ ((t + _imul(t ^ (t >>> 7), t | 61)) & _mask)) & _mask;
    return (t ^ (t >>> 14)) & _mask;
  }

  /// [0, 1)
  double next() => nextInt() / 4294967296;
}

class ArtworkSpec {
  const ArtworkSpec({this.algorithm = 1, required this.seed});
  final int algorithm, seed;

  /// Songs without a stored spec get this one (and it is persisted by the store).
  factory ArtworkSpec.forId(String id) => ArtworkSpec(seed: fnv1a32(id));

  factory ArtworkSpec.fromJson(Map<String, dynamic> j) =>
      ArtworkSpec(algorithm: (j['algorithm'] as num?)?.toInt() ?? 1, seed: (j['seed'] as num).toInt());

  Map<String, dynamic> toJson() => {'algorithm': algorithm, 'seed': seed};

  @override
  bool operator ==(Object other) => other is ArtworkSpec && other.algorithm == algorithm && other.seed == seed;
  @override
  int get hashCode => Object.hash(algorithm, seed);
}

enum Motif { rings, stripes, dots, waves, rays }

class Blob {
  const Blob(this.x, this.y, this.radius, this.hue);
  final double x, y, radius, hue; // x,y,radius as fractions of the size, hue in degrees
}

/// Everything v1 draws, derived from the seed alone. Draw order of the PRNG is part of the version.
class ArtworkParams {
  ArtworkParams._(this.hue, this.hue2, this.lightA, this.lightB, this.blobs, this.motif, this.density, this.alpha,
      this.cx, this.cy, this.angle, this.phase, this.dotSizes);

  // Version 1 has never shipped, so it could still be tuned on 2026-11-20 (wider hue pairs, motif from the PRNG after a
  // warm-up so neighbouring seeds differ). From the first release on it is frozen.
  factory ArtworkParams.v1(int seed) {
    final r = Mulberry32(seed);
    for (var i = 0; i < 4; i++) {
      r.nextInt(); // warm-up: consecutive seeds start from unrelated states
    }
    final hue = r.next() * 360;
    final hue2 = (hue + 70 + r.next() * 160) % 360; // 70-230 degrees apart: clearly two colours
    final lightA = .40 + r.next() * .14;
    final lightB = .22 + r.next() * .14;
    final blobs = [
      for (var i = 0; i < 3; i++) Blob(r.next(), r.next(), .25 + r.next() * .45, (hue + 150 * r.next()) % 360),
    ];
    final motif = Motif.values[r.nextInt() % Motif.values.length];
    final density = 4 + (r.next() * 7).floor();
    final alpha = .34 + r.next() * .06;
    final cx = r.next();
    final cy = .6 + r.next() * .6;
    final angle = r.next() * math.pi;
    final phase = r.next() * math.pi * 2;
    final dots = [for (var i = 0; i < density * density; i++) r.next()];
    return ArtworkParams._(hue, hue2, lightA, lightB, blobs, motif, density, alpha, cx, cy, angle, phase, dots);
  }

  /// Unknown future versions fall back to the newest one this build knows.
  factory ArtworkParams.forSpec(ArtworkSpec s) => ArtworkParams.v1(s.seed);

  final double hue, hue2, lightA, lightB, alpha, cx, cy, angle, phase;
  final List<Blob> blobs;
  final Motif motif;
  final int density;
  final List<double> dotSizes;
}

class ArtworkPainter extends CustomPainter {
  ArtworkPainter(this.spec) : p = ArtworkParams.forSpec(spec);
  final ArtworkSpec spec;
  final ArtworkParams p;

  static Color _hsl(double h, double s, double l, [double a = 1]) => HSLColor.fromAHSL(a, h % 360, s, l).toColor();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(s, s), [_hsl(p.hue, .66, p.lightA), _hsl(p.hue2, .62, p.lightB)]));
    for (final b in p.blobs) {
      final c = Offset(b.x * s, b.y * s);
      canvas.drawRect(
          rect,
          Paint()
            ..shader = ui.Gradient.radial(c, b.radius * s, [_hsl(b.hue, .8, .68, .75), _hsl(b.hue, .8, .68, 0)]));
    }
    final white = const Color(0xFFFFFFFF).withValues(alpha: p.alpha);
    final stroke = Paint()
      ..color = white
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(s / 110, .75);
    final fill = Paint()..color = white;
    final n = p.density;
    final c = Offset(p.cx * s, p.cy * s);
    switch (p.motif) {
      case Motif.rings:
        // 40 px thumbnails need a real line weight, a hairline vanishes against the gradient.
        stroke.strokeWidth = math.max(s / 60, 1.5);
        for (var i = 1; i <= n; i++) {
          canvas.drawCircle(c, s * i / n * .9, stroke);
        }
      case Motif.stripes:
        canvas.save();
        canvas.translate(s / 2, s / 2);
        canvas.rotate(p.angle);
        stroke.strokeWidth = s / (n * 3);
        for (var i = -n; i <= n; i++) {
          canvas.drawLine(Offset(-s, i * s / n), Offset(s, i * s / n), stroke);
        }
        canvas.restore();
      case Motif.dots:
        for (var i = 0; i < n; i++) {
          for (var j = 0; j < n; j++) {
            canvas.drawCircle(Offset((i + .5) * s / n, (j + .5) * s / n), s / n * (.12 + .3 * p.dotSizes[i * n + j]), fill);
          }
        }
      case Motif.waves:
        stroke.strokeWidth = math.max(s / 50, 1.5);
        final freq = 1.5 + p.angle / math.pi * 2;
        final amp = s * .05;
        for (var i = 1; i <= n; i++) {
          final base = s * i / (n + 1);
          final path = Path();
          for (var k = 0; k <= 32; k++) {
            final x = s * k / 32;
            final y = base + math.sin(x / s * math.pi * 2 * freq + p.phase + i * .7) * amp;
            k == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
          }
          canvas.drawPath(path, stroke);
        }
      case Motif.rays:
        final k = n * 2;
        final step = math.pi * 2 / k;
        for (var i = 0; i < k; i++) {
          final a = p.angle + i * step;
          canvas.drawPath(
              Path()
                ..moveTo(c.dx, c.dy)
                ..lineTo(c.dx + math.cos(a) * s * 2, c.dy + math.sin(a) * s * 2)
                ..lineTo(c.dx + math.cos(a + step / 2) * s * 2, c.dy + math.sin(a + step / 2) * s * 2)
                ..close(),
              fill);
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ArtworkPainter old) => old.spec != spec;
}
