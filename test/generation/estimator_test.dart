import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

  // The PyTorch model, pinned: the reference Mac has 48 GB, so the engine guess would be MLX.
  GenerationEstimator ref() => GenerationEstimator(tmp.path, probe: () async => Hardware.reference, engine: 'torch');
  GenerationEstimator auto() => GenerationEstimator(tmp.path, probe: () async => Hardware.reference);

  Duration none = Duration.zero;
  double prog(GenerationEstimator e, String s, int d, int? t, {Duration? el}) =>
      e.progressFor(stage: s, done: d, total: t, elapsedInStage: el ?? none, lyrics: songLyrics);

  String lyricsOf(int lines) => '[verse]\n${List.generate(lines, (i) => 'line $i').join('\n')}\n[chorus]\n';

  test('length model: 8 lines -> 70 s, 33 lines -> ~174 s, instrumental -> 120 s, tags ignored', () async {
    final e = ref();
    expect(e.expectedSeconds(lyrics: songLyrics), closeTo(70, 0.5));
    expect(e.expectedSeconds(lyrics: lyricsOf(33)), closeTo(174.3, 1));
    expect(e.expectedSeconds(lyrics: ''), 120);
    expect(e.expectedSeconds(lyrics: '[verse]\n[chorus]'), 120);
    expect(e.expectedSeconds(lyrics: lyricsOf(200)), 300);
    expect(e.expectedSeconds(lyrics: 'a\nb', sourceSeconds: 95), 95, reason: 'covers use the source length');
  });

  test('reference Mac: 8 lines ~175 s with model load, ~155 s without; 33 lines ~875 s / ~855 s', () async {
    final e = ref();
    await e.load();
    expect(e.estimate(lyrics: songLyrics).inSeconds, inInclusiveRange(165, 185));
    expect(e.estimate(lyrics: lyricsOf(33)).inSeconds, inInclusiveRange(800, 900));
    final long = e.estimate(lyrics: lyricsOf(33)).inSeconds;
    e.modelLoaded = true;
    expect(e.estimate(lyrics: songLyrics).inSeconds, inInclusiveRange(145, 165));
    expect(e.estimate(lyrics: lyricsOf(33)).inSeconds, long - 20);
    expect(e.estimate(lyrics: songLyrics, plan: false).inSeconds, lessThan(e.estimate(lyrics: songLyrics).inSeconds - 15));
    expect(e.estimate(lyrics: '', sourceSeconds: 70).inSeconds, lessThan(e.estimate(lyrics: songLyrics).inSeconds), reason: 'a cover brings its own score');
  });

  test('stage curves are superlinear and match the two measured runs', () async {
    final e = ref();
    await e.load();
    double sec(String s, double l) => e.coef[s]! * math.pow(l, stageExp[s]!);
    expect(sec('abc', 70), closeTo(17, 0.5));
    expect(sec('abc', 174.3), closeTo(92.4, 2));
    expect(sec('semantic', 70), closeTo(56, 1));
    expect(sec('semantic', 174.3), closeTo(262.4, 3));
    expect(sec('nar', 70), closeTo(80, 4));
    expect(sec('nar', 174.3), closeTo(482.5, 10));
    expect(e.speeds['nar']!, closeTo(sec('nar', 70) / 70, 1e-9));
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
    final s = {for (final k in ['abc', 'semantic', 'nar', 'vae']) k: e.coef[k]! * math.pow(70, stageExp[k]!)};
    final total = 20 + s.values.reduce((a, b) => a + b);
    expect(prog(e, 'load', 0, null), 0);
    expect(prog(e, 'abc', 0, null), closeTo(20 / total, 1e-3));
    expect(prog(e, 'semantic', 0, null), closeTo((20 + s['abc']!) / total, 1e-3));
    expect(prog(e, 'nar', 0, 32), closeTo((20 + s['abc']! + s['semantic']!) / total, 1e-3));
    expect(prog(e, 'nar', 16, 32), closeTo((20 + s['abc']! + s['semantic']! + s['nar']! / 2) / total, 1e-3));
    expect(prog(e, 'vae', 0, 4), closeTo((total - s['vae']!) / total, 1e-3));
    expect(prog(e, 'vae', 4, 4), closeTo(1.0, 1e-9));
    final events = [
      ('load', 0, null, 0), ('load', 0, null, 19), ('abc', 25, null, 1), ('abc', 200, null, 8), ('abc', 340, null, 17),
      ('semantic', 25, null, 1), ('semantic', 900, null, 30), ('semantic', 1750, null, 56),
      ('nar', 1, 32, 1), ('nar', 15, 32, 40), ('nar', 32, 32, 82), ('vae', 1, 4, 1), ('vae', 4, 4, 4),
    ];
    var last = -1.0;
    for (final (st, d, t, el) in events) {
      final p = prog(e, st, d, t, el: Duration(seconds: el));
      expect(p, greaterThanOrEqualTo(last), reason: '$st $d');
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
    final nar = e.coef['nar']! * 4900, vae = e.coef['vae']! * 70;
    expect(rem('abc', 0, null, 0), e.estimate(lyrics: songLyrics));
    // nar half done in half its predicted time: half of it + vae left
    expect(rem('nar', 16, 32, (nar / 2).round()).inSeconds, closeTo(nar / 2 + vae, 1.5));
    // twice as slow as predicted: the rest of nar, and vae, take twice as long
    expect(rem('nar', 16, 32, nar.round()).inSeconds, closeTo(nar + 2 * vae, 1.5));
    // semantic at 1750 * 0.4 tokens after 20 s: 35 tok/s, 1050 left
    expect(rem('semantic', 700, null, 20).inSeconds, greaterThan(30));
    expect(rem('vae', 4, 4, 5).inSeconds, 0);
  });

  test('the length read from the score replaces the guess from the lyrics', () async {
    final e = ref();
    await e.load();
    e.modelLoaded = true;
    Duration rem(double? score) => e.remainingFor(
        stage: 'semantic', done: 0, elapsedInStage: Duration.zero, lyrics: songLyrics, scoreSeconds: score);
    expect(e.expectedSeconds(lyrics: songLyrics, sourceSeconds: 95, scoreSeconds: 48), 48);
    expect(rem(70).inSeconds, closeTo(rem(null).inSeconds, 2), reason: 'lyrics guess is 70 s');
    expect(rem(48), lessThan(rem(null) * 0.6), reason: 'a 48 s song is much quicker than the 70 s guess');
  });

  test('MLX cost model: the five measured runs, within 15%', () async {
    final e = auto();
    await e.load();
    e.modelLoaded = true;
    expect(e.engine, 'mlx', reason: '48 GB Apple Silicon: auto selection picks MLX');
    // (audio s, abc + semantic + nar + vae measured s)
    for (final (audio, measured) in [(69.6, 104.1), (145.0, 259.1), (179.7, 333.1), (216.3, 491.0)]) {
      final est = e.exp.keys.fold<double>(0, (a, k) => a + e.coef[k]! * math.pow(audio, e.exp[k]!));
      expect(est / measured, closeTo(1, 0.15), reason: '$audio s');
    }
    // far from the PyTorch model, which said about 2.4x too much for the 216 s song
    final torch = ref();
    await torch.load();
    final t = stageExp.keys.fold<double>(0, (a, k) => a + torch.coef[k]! * math.pow(216.3, stageExp[k]!));
    expect(t / 491, greaterThan(2));
  });

  test('a calibration belongs to one engine: old files and a change of engine start from the prior', () async {
    // estimator.json written before 0.2.0: no "engine", calibrated by PyTorch
    File('${tmp.path}/estimator.json').writeAsStringSync(jsonEncode({
      'hw': Hardware.reference.toJson(), 'runs': 4, 'coef': {'nar': 0.0159, 'semantic': 0.0326},
    }));
    final e = auto();
    await e.load();
    expect((e.engine, e.runs, e.coef['nar']), ('mlx', 0, mlxStageCoef['nar']));
    await e.record(stageSeconds: {'nar': 359.3}, audioSeconds: 216.3, engine: 'mlx');
    expect(e.coef['nar'], closeTo(359.3 / math.pow(216.3, 1.449), 1e-9), reason: 'first run replaces the prior');
    // the user switches to PyTorch (YUE2_STUDIO_ENGINE=torch): the result says so, the model follows
    await e.record(stageSeconds: {'nar': 480}, audioSeconds: 174, engine: 'torch');
    expect((e.engine, e.runs), ('torch', 1));
    expect(e.coef['nar'], closeTo(480 / (174 * 174), 1e-9));
    expect(e.coef['semantic'], stageCoef['semantic'], reason: 'stages the run did not report are the PyTorch prior');
    final again = auto();
    await again.load();
    expect((again.engine, again.runs), ('torch', 1), reason: 'the stored engine wins over the hardware guess');
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

  test('stage fraction is the share of the current stage; token stages use the expected token count for L', () async {
    final e = ref();
    await e.load();
    expect(e.stageFractionFor(stage: 'semantic', done: 875, lyrics: songLyrics), closeTo(0.5, 0.01)); // 25 tok/s of audio * 70 s
    expect(e.stageFractionFor(stage: 'semantic', done: 2180, lyrics: lyricsOf(33)), closeTo(0.5, 0.01)); // 4359 tokens at 174 s
    expect(e.stageFractionFor(stage: 'abc', done: 170, lyrics: songLyrics), closeTo(0.5, 0.02)); // 340 tokens at 70 s
    expect(e.stageFractionFor(stage: 'abc', done: 920, lyrics: lyricsOf(33)), closeTo(0.5, 0.02)); // 1847 tokens at 174 s
    expect(e.stageFractionFor(stage: 'nar', done: 8, total: 32, lyrics: songLyrics), 0.25);
  });

  test('record: first run replaces the prior, later runs average, state survives a restart', () async {
    final e = ref();
    await e.load();
    await e.record(
      stageSeconds: {'load': 22, 'abc': 17, 'semantic': 55, 'nar': 80, 'vae': 4},
      audioSeconds: 70,
      tokens: {'abc': 340, 'semantic': 1750},
    );
    expect(e.speeds['abc'], closeTo(17 / 70, 1e-9));
    expect(e.speeds['nar'], closeTo(80 / 70, 1e-9));
    expect(e.coef['nar'], closeTo(80 / 4900, 1e-12));
    expect(e.loadSeconds, 22);
    expect(e.tokenCoef['semantic'], closeTo(25, 1e-9));
    expect(e.modelLoaded, isTrue);
    expect(e.estimate(lyrics: songLyrics).inSeconds, closeTo(156, 1), reason: '17+55+80+4, no load now');

    await e.record(stageSeconds: {'nar': 100}, audioSeconds: 70); // second run: halfway
    expect(e.speeds['nar'], closeTo((80 / 70 + 100 / 70) / 2, 1e-9));
    expect(e.speeds['abc'], closeTo(17 / 70, 1e-9), reason: 'untouched stage keeps its speed');

    final again = GenerationEstimator(tmp.path, probe: () async => throw StateError('should be cached'));
    await again.load();
    expect(again.runs, 2);
    expect(again.coef['nar'], closeTo(e.coef['nar']!, 1e-9));
  });

  test('calibrating on a 70 s run still estimates a 174 s song within 20% of the measured 861 s', () async {
    final e = ref();
    await e.load();
    await e.record(stageSeconds: {'load': 20, 'abc': 17, 'semantic': 56, 'nar': 88, 'vae': 3}, audioSeconds: 70);
    final est = e.estimate(lyrics: lyricsOf(33)).inSeconds; // model already loaded: no load stage
    expect(est, inInclusiveRange(861 * 0.8, 861 * 1.2));
    // a purely linear model would have said 164 * 2.49 = 408 s
  });

  test('slower hardware scales every curve, a calibration replaces the scale', () async {
    const slow = Hardware(mac: true, chip: 'Apple M1', memBytes: 16 << 30, perfCores: 4, gpuCores: 8);
    final e = GenerationEstimator(Directory.systemTemp.createTempSync('yue2slow').path, probe: () async => slow);
    await e.load();
    final fast = ref();
    await fast.load();
    expect(e.coef['nar']! / fast.coef['nar']!, closeTo(priorWorkPerAudioSecond(slow) / refWork, 1e-9));
    expect(e.estimate(lyrics: lyricsOf(33)), greaterThan(fast.estimate(lyrics: lyricsOf(33)) * 3));
  });

}
