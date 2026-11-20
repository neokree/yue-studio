import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/artwork/artwork.dart';

void main() {
  test('mulberry32 is the reference algorithm (golden values)', () {
    final r = Mulberry32(1);
    expect([r.next(), r.next(), r.next()], [0.6270739405881613, 0.002735721180215478, 0.5274470399599522]);
  });

  test('fnv1a32 reference vector', () => expect(fnv1a32('abc'), 440920331));

  test('artwork v1: fixed seed -> fixed parameters (never change, add v2 instead)', () {
    // Re-recorded once on 2026-11-20 (version 1 had never shipped); frozen from the first release.
    final p = ArtworkParams.v1(42);
    expect((p.motif, p.density), (Motif.rings, 4));
    expect(p.hue, closeTo(62.933003548532724, 1e-9));
    expect(p.hue2, closeTo(217.1878102980554, 1e-9));
    expect(p.alpha, closeTo(0.375539439432323, 1e-12));
    expect(p.cx, closeTo(0.03153795562684536, 1e-12));
    expect(p.cy, closeTo(0.7601735921110957, 1e-12));
    expect(p.blobs[0].x, closeTo(0.8654746483080089, 1e-12));
    expect(p.blobs[2].hue, closeTo(133.55029210913926, 1e-9));
    final q = ArtworkParams.v1(1);
    expect((q.motif, q.density), (Motif.rays, 5));
    expect(q.angle, closeTo(2.509140464388938, 1e-12));
  });

  test('same seed always gives the same parameters', () {
    final a = ArtworkParams.v1(123456), b = ArtworkParams.v1(123456);
    expect((a.hue, a.motif, a.density), (b.hue, b.motif, b.density));
    expect(a.dotSizes, b.dotSizes);
  });

  test('ranges: density 4-10, alpha 34-40%, all five motifs appear, 12 seeds are not one motif', () {
    final seen = <Motif>{};
    for (var s = 0; s < 500; s++) {
      final p = ArtworkParams.v1(s);
      expect(p.density, inInclusiveRange(4, 10));
      expect(p.alpha, inInclusiveRange(.34, .40));
      seen.add(p.motif);
    }
    expect(seen, Motif.values.toSet());
    expect({for (var s = 100; s < 112; s++) ArtworkParams.v1(s).motif}.length, greaterThan(1));
  });

  test('variety: motifs evenly spread, hue pairs cover the wheel and are far apart, neighbours rarely repeat', () {
    final motifs = <Motif, int>{}, hueBuckets = <int>{};
    var sameAsPrev = 0;
    for (var s = 0; s < 1000; s++) {
      final p = ArtworkParams.v1(s);
      motifs[p.motif] = (motifs[p.motif] ?? 0) + 1;
      hueBuckets.add((p.hue / 30).floor());
      hueBuckets.add(12 + (p.hue2 / 30).floor());
      final d = (p.hue2 - p.hue).abs() % 360;
      expect(d > 180 ? 360 - d : d, greaterThanOrEqualTo(69)); // two clearly different hues
      if (s > 0 && ArtworkParams.v1(s - 1).motif == p.motif) sameAsPrev++;
    }
    expect(motifs.values, everyElement(inInclusiveRange(150, 250))); // ~20% each
    expect(hueBuckets.length, 24); // every 30 degree slice used for both hues
    expect(sameAsPrev, lessThan(260)); // chance is ~200; seed % 5 correlation would be 1000 or 0
  });

  test('spec json round trip; song without spec derives seed from id', () {
    final s = ArtworkSpec.fromJson(const ArtworkSpec(seed: 99).toJson());
    expect((s.algorithm, s.seed), (1, 99));
    expect(ArtworkSpec.forId('abc'), ArtworkSpec.forId('abc'));
    expect(ArtworkSpec.forId('abc').seed, fnv1a32('abc'));
  });
}
