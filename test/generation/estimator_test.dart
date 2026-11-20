import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/generation/estimator.dart';

void main() {
  late Directory tmp;
  late String songLyrics;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2est');
    songLyrics = (jsonDecode(File('reference/song.json').readAsStringSync()) as Map)['lyrics'] as String;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  GenerationEstimator ref() => GenerationEstimator(tmp.path, probe: () async => Hardware.reference);

  Duration none = Duration.zero;
  double prog(GenerationEstimator e, String s, int d, int? t, {Duration? el}) =>
      e.progressFor(stage: s, done: d, total: t, elapsedInStage: el ?? none, lyrics: songLyrics);

  test('reference lyrics are a 70 s song', () async {
    final e = ref();
    expect(e.expectedSeconds(lyrics: songLyrics), 70);
    expect(e.expectedSeconds(lyrics: ''), 15);
    expect(e.expectedSeconds(lyrics: 'a\nb', sourceSeconds: 95), 95, reason: 'covers use the source length');
  });

  test('reference Mac: 2.3 s per audio second plus 20 s model load on the first job', () async {
    final e = ref();
    await e.load();
    expect(e.estimate(lyrics: songLyrics).inSeconds, 181);
    expect(e.speeds['nar']! / e.speeds.values.reduce((a, b) => a + b), closeTo(0.51, 1e-9));
    e.modelLoaded = true;
    expect(e.estimate(lyrics: songLyrics).inSeconds, 161);
    expect(e.estimate(lyrics: songLyrics, plan: false).inSeconds, lessThan(161 - 17));
    expect(e.estimate(lyrics: '', sourceSeconds: 70).inSeconds, lessThan(161), reason: 'a cover brings its own score');
  });

  test('hardware prior scales with GPU cores, generation and memory', () {
    const m1 = Hardware(mac: true, chip: 'Apple M1', memBytes: 16 << 30, perfCores: 4, gpuCores: 8);
    const m4max = Hardware(mac: true, chip: 'Apple M4 Max', memBytes: 64 << 30, perfCores: 12, gpuCores: 40);
    expect(priorWorkPerAudioSecond(Hardware.reference), closeTo(2.3, 1e-9));
    expect(priorWorkPerAudioSecond(m1), greaterThan(10));
    expect(priorWorkPerAudioSecond(m4max), lessThan(2.3));
    expect(priorWorkPerAudioSecond(const Hardware(mac: false)), 4.0);
  });

  test('hardware is probed once and cached in estimator.json', () async {
    var probes = 0;
    Future<Hardware> probe() async {
      probes++;
      return Hardware.reference;
    }

    await GenerationEstimator(tmp.path, probe: probe).load();
    await GenerationEstimator(tmp.path, probe: probe).load();
    expect(probes, 1);
    expect(File('${tmp.path}/estimator.json').existsSync(), isTrue);
  });

  test('progress is weighted by stage time and monotonic through a run', () async {
    final e = ref();
    await e.load();
    // 181 s total: load 20, abc 17.71, semantic 56.35, nar 82.11, vae 4.83
    expect(prog(e, 'load', 0, null), 0);
    expect(prog(e, 'abc', 0, null), closeTo(20 / 181, 1e-3));
    expect(prog(e, 'semantic', 0, null), closeTo(37.71 / 181, 1e-3));
    expect(prog(e, 'nar', 0, 32), closeTo(94.06 / 181, 1e-3));
    expect(prog(e, 'nar', 16, 32), closeTo((94.06 + 41.055) / 181, 1e-3));
    expect(prog(e, 'vae', 0, 4), closeTo(176.17 / 181, 1e-3));
    expect(prog(e, 'vae', 4, 4), closeTo(1.0, 1e-9));
    final events = [
      ('load', 0, null, 0), ('load', 0, null, 19), ('abc', 25, null, 1), ('abc', 200, null, 8), ('abc', 340, null, 17),
      ('semantic', 25, null, 1), ('semantic', 1500, null, 30), ('semantic', 3500, null, 56),
      ('nar', 1, 32, 1), ('nar', 15, 32, 40), ('nar', 32, 32, 82), ('vae', 1, 4, 1), ('vae', 4, 4, 4),
    ];
    var last = -1.0;
    for (final (s, d, t, el) in events) {
      final p = prog(e, s, d, t, el: Duration(seconds: el));
      expect(p, greaterThanOrEqualTo(last), reason: '$s $d');
      last = p;
    }
  });

  test('token stages never exceed their own share, even if the token guess is far too low', () async {
    final e = ref();
    await e.load();
    final startSemantic = prog(e, 'semantic', 0, null);
    expect(prog(e, 'abc', 1000000, null), lessThan(startSemantic));
    final startNar = prog(e, 'nar', 0, 32);
    expect(prog(e, 'semantic', 1000000, null), lessThan(startNar));
    expect(prog(e, 'load', 0, null, el: const Duration(minutes: 5)), lessThan(prog(e, 'abc', 0, null)));
  });

  test('remaining time follows the live speed of the stage', () async {
    final e = ref();
    await e.load();
    e.modelLoaded = true;
    Duration rem(String s, int d, int? t, int el) =>
        e.remainingFor(stage: s, done: d, total: t, elapsedInStage: Duration(seconds: el), lyrics: songLyrics);
    expect(rem('abc', 0, null, 0).inSeconds, 161);
    // nar half done in 41 s (as predicted): 41 + vae 4.8 left
    expect(rem('nar', 16, 32, 41).inSeconds, closeTo(41 + 4.83, 1));
    // twice as slow as predicted: half the stage took 82 s, so 82 + 2 * 4.83 left
    expect(rem('nar', 16, 32, 82).inSeconds, closeTo(82 + 9.66, 1));
    // semantic at the 1500th token after 20 s: 75 tok/s, 2000 left
    expect(rem('semantic', 1500, null, 20).inSeconds, greaterThan(26));
    expect(rem('vae', 4, 4, 5).inSeconds, 0);
  });

  test('fake engine runs never calibrate; estimate is deterministic', () async {
    final e = ref();
    await e.load();
    final before = e.estimate(lyrics: songLyrics);
    expect(e.estimate(lyrics: songLyrics), before);
    e.fake = true;
    await e.record(stageSeconds: {'load': 1, 'abc': 1, 'semantic': 1, 'nar': 1, 'vae': 1}, audioSeconds: 70);
    expect(e.runs, 0);
    expect(e.modelLoaded, isFalse);
    expect(e.estimate(lyrics: songLyrics), before);
    expect(GenerationEstimator(tmp.path, probe: () async => Hardware.reference).runs, 0);
  });

  test('stage fraction is the share of the current stage', () async {
    final e = ref();
    await e.load();
    expect(e.stageFractionFor(stage: 'semantic', done: 1750, lyrics: songLyrics), closeTo(0.5, 1e-9)); // 50 tok/s * 70 s
    expect(e.stageFractionFor(stage: 'nar', done: 8, total: 32, lyrics: songLyrics), 0.25);
  });

  test('record: first run replaces the prior, later runs average, state survives a restart', () async {
    final e = ref();
    await e.load();
    await e.record(
      stageSeconds: {'load': 22, 'abc': 17, 'semantic': 55, 'nar': 80, 'vae': 4},
      audioSeconds: 70,
      tokens: {'abc': 340, 'semantic': 3500},
    );
    expect(e.speeds['abc'], closeTo(17 / 70, 1e-9));
    expect(e.speeds['nar'], closeTo(80 / 70, 1e-9));
    expect(e.loadSeconds, 22);
    expect(e.tokensPerSecond['semantic'], 50);
    expect(e.modelLoaded, isTrue);
    expect(e.estimate(lyrics: songLyrics).inSeconds, 156, reason: '17+55+80+4, no load now');

    await e.record(stageSeconds: {'nar': 100}, audioSeconds: 70); // second run: halfway
    expect(e.speeds['nar'], closeTo((80 / 70 + 100 / 70) / 2, 1e-9));
    expect(e.speeds['abc'], closeTo(17 / 70, 1e-9), reason: 'untouched stage keeps its speed');

    final again = GenerationEstimator(tmp.path, probe: () async => throw StateError('should be cached'));
    await again.load();
    expect(again.runs, 2);
    expect(again.speeds['nar'], closeTo(e.speeds['nar']!, 1e-9));
  });
}
