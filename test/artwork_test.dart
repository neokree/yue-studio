import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/artwork/artwork.dart';

void main() {
  test('mulberry32 is the reference algorithm (golden values)', () {
    final r = Mulberry32(1);
    expect([r.next(), r.next(), r.next()], [0.6270739405881613, 0.002735721180215478, 0.5274470399599522]);
  });

  test('fnv1a32 reference vector', () => expect(fnv1a32('abc'), 440920331));

  test('artwork v1: fixed seed -> fixed parameters (never change, add v2 instead)', () {
    final p = ArtworkParams.v1(42);
    expect(p.motif, Motif.rings);
    expect(p.density, 7);
    expect(p.hue, closeTo(216.3973506912589, 1e-9));
    expect(p.hue2, closeTo(301.2264065910131, 1e-9));
    expect(p.alpha, closeTo(0.3811967210751027, 1e-12));
    expect(p.cx, closeTo(0.6106208984274417, 1e-12));
    expect(p.cy, closeTo(0.6023057711776346, 1e-12));
    expect(p.blobs[0].x, closeTo(0.8524657934904099, 1e-12));
    expect(p.blobs[2].hue, closeTo(262.4475777056068, 1e-9));
    final q = ArtworkParams.v1(1);
    expect((q.motif, q.density), (Motif.stripes, 5));
    expect(q.angle, closeTo(2.409940938867665, 1e-12));
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

  test('spec json round trip; song without spec derives seed from id', () {
    final s = ArtworkSpec.fromJson(const ArtworkSpec(seed: 99).toJson());
    expect((s.algorithm, s.seed), (1, 99));
    expect(ArtworkSpec.forId('abc'), ArtworkSpec.forId('abc'));
    expect(ArtworkSpec.forId('abc').seed, fnv1a32('abc'));
  });
}
