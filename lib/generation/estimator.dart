import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// What the estimator knows about the machine. Cached in <data>/estimator.json.
class Hardware {
  const Hardware({required this.mac, this.chip = '', this.memBytes = 0, this.perfCores = 0, this.gpuCores = 0});
  final bool mac;
  final String chip;
  final int memBytes, perfCores, gpuCores;

  Map<String, dynamic> toJson() =>
      {'mac': mac, 'chip': chip, 'memBytes': memBytes, 'perfCores': perfCores, 'gpuCores': gpuCores};
  factory Hardware.fromJson(Map<String, dynamic> j) => Hardware(
        mac: j['mac'] == true,
        chip: j['chip'] as String? ?? '',
        memBytes: (j['memBytes'] as num?)?.toInt() ?? 0,
        perfCores: (j['perfCores'] as num?)?.toInt() ?? 0,
        gpuCores: (j['gpuCores'] as num?)?.toInt() ?? 0,
      );

  /// Reference measurement: M4 Pro, 20 GPU cores, 48 GB.
  static const reference =
      Hardware(mac: true, chip: 'Apple M4 Pro', memBytes: 51539607552, perfCores: 10, gpuCores: 20);
}

typedef HardwareProbe = Future<Hardware> Function();

Future<Hardware> probeHardware() async {
  if (!Platform.isMacOS) return const Hardware(mac: false, chip: 'generic');
  Future<String> sysctl(String k) async {
    try {
      return ((await Process.run('sysctl', ['-n', k])).stdout as String).trim();
    } catch (_) {
      return '';
    }
  }

  var gpu = 0;
  try {
    final r = await Process.run('system_profiler', ['SPDisplaysDataType', '-json']);
    final list = (jsonDecode(r.stdout as String) as Map)['SPDisplaysDataType'] as List;
    gpu = int.tryParse('${(list.first as Map)['sppci_cores']}') ?? 0;
  } catch (_) {}
  return Hardware(
    mac: true,
    chip: await sysctl('machdep.cpu.brand_string'),
    memBytes: int.tryParse(await sysctl('hw.memsize')) ?? 0,
    perfCores: int.tryParse(await sysctl('hw.perflevel0.physicalcpu')) ?? 0,
    gpuCores: gpu,
  );
}

/// Seconds of work per second of audio for [hw], scaled from the reference M4 Pro 48 GB (2.3).
/// ponytail: GPU core count, chip generation and RAM only; memory bandwidth is not modelled.
/// The first real run replaces this prior, so it only has to be in the right ballpark.
double priorWorkPerAudioSecond(Hardware hw) {
  if (!hw.mac) return 4.0; // generic Linux box, no idea about its GPU
  final gen = int.tryParse(RegExp(r'M(\d+)').firstMatch(hw.chip)?.group(1) ?? '');
  final genFactor = switch (gen) { 1 => 0.75, 2 => 0.85, 3 => 0.95, _ => 1.0 };
  final cores = hw.gpuCores > 0 ? hw.gpuCores : hw.perfCores * 2;
  var rel = (cores == 0 ? 20 : cores) / 20 * genFactor;
  const gib = 1 << 30;
  if (hw.memBytes > 0 && hw.memBytes < 20 * gib) rel *= 0.7;
  if (hw.memBytes > 0 && hw.memBytes < 12 * gib) rel *= 0.6;
  return (refWork / rel).clamp(1.0, 15.0);
}

const refWork = 2.3;

/// Stage cost model on the reference Mac (M4 Pro 48 GB), cot=full: seconds = coef x L^exp for L seconds of audio.
/// Fitted through two measured runs (70 s: abc 17, semantic 56, nar ~80, vae ~4; 174.3 s: abc 92.4, semantic 262.4,
/// nar 482.5, vae 18). abc: p = ln(92.4/17)/ln(174.3/70) = 1.856; semantic: q = 1.693 (per-token speed drops as the
/// sequence grows, 32 -> 16.6 tok/s); nar is attention over the whole song, so 2 (0.016 x L^2 = 78 s at 70, 486 s at 174);
/// vae is chunked, so 1.
const stageExp = {'abc': 1.856, 'semantic': 1.693, 'nar': 2.0, 'vae': 1.0};
const stageCoef = {'abc': 0.0064, 'semantic': 0.0421, 'nar': 0.016, 'vae': 0.075};

/// Expected token count of the token stages = coef x L^exp. abc tokens ~ 20 tok/s x abc time (340 at 70 s, 1847 at 174 s);
/// semantic is linear, 25 tokens per second of audio (1750 at 70 s, 4359 at 174 s).
const tokenExp = {'abc': 1.856, 'semantic': 1.0};
const tokenCoefPrior = {'abc': 0.128, 'semantic': 25.0};

/// Song length model: affine in the number of sung lines through (8 lines, 70 s) and (33 lines, 174.3 s). Section tags ignored.
const _lenA = 36.6, _lenB = 4.17, _instrumentalSeconds = 120.0;

/// Expected generation time and progress (design/DESIGN.md, "Time estimate").
///
/// Time is not linear in the length L: each stage is coef x L^exp (see [stageExp]), the coefficients start from the
/// reference Mac scaled by the hardware prior and are replaced by the user's own runs (the exponents stay).
class GenerationEstimator {
  GenerationEstimator(this.dataDir, {HardwareProbe? probe}) : _probe = probe ?? probeHardware;

  final String dataDir;
  final HardwareProbe _probe;

  /// Per-stage coefficient c of seconds = c x L^exp (this machine: prior x hardware scale, then calibrated).
  Map<String, double> coef = {...stageCoef};

  /// Per-stage coefficient of the expected token count (abc, semantic).
  Map<String, double> tokenCoef = {...tokenCoefPrior};

  /// Seconds of work per audio second at the 70 s reference length, per stage (what a typical song costs).
  Map<String, double> get speeds => {for (final k in coef.keys) k: _secs(k, 70) / 70};

  double _secs(String stage, double audio) => coef[stage]! * math.pow(audio, stageExp[stage]!);

  double loadSeconds = 20;
  double transcribePerSecond = 0.9; // 63 s for a ~70 s source
  int runs = 0;
  Hardware hardware = Hardware.reference;

  /// True once the model has been loaded in this app session: the next job skips the load step.
  bool modelLoaded = false;

  /// True when the engine runs in fake mode (ready.fake, or YUE2_STUDIO_FAKE=1): its timings say nothing about the
  /// machine, so [record] ignores them and a test run never pollutes the user's calibration.
  bool fake = Platform.environment['YUE2_STUDIO_FAKE'] == '1';

  File get _file => File(p.join(dataDir, 'estimator.json'));

  Future<void> load() async {
    Map<String, dynamic> j = {};
    try {
      j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    if (j['hw'] is Map) {
      hardware = Hardware.fromJson((j['hw'] as Map).cast());
    } else {
      hardware = await _probe();
    }
    runs = (j['runs'] as num?)?.toInt() ?? 0;
    final scale = priorWorkPerAudioSecond(hardware) / refWork;
    coef = {for (final e in stageCoef.entries) e.key: e.value * scale};
    tokenCoef = {...tokenCoefPrior};
    if (j['coef'] is Map) {
      for (final e in (j['coef'] as Map).entries) {
        if (coef.containsKey(e.key) && e.value is num && e.value > 0) coef[e.key as String] = (e.value as num).toDouble();
      }
    }
    if (j['tokenCoef'] is Map) {
      for (final e in (j['tokenCoef'] as Map).entries) {
        if (tokenCoef.containsKey(e.key) && e.value is num && e.value > 0) tokenCoef[e.key as String] = (e.value as num).toDouble();
      }
    }
    loadSeconds = (j['loadSeconds'] as num?)?.toDouble() ?? loadSeconds;
    await _save();
  }

  Future<void> _save() async {
    try {
      await Directory(dataDir).create(recursive: true);
      await _file.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'hw': hardware.toJson(),
        'runs': runs,
        'coef': coef,
        'tokenCoef': tokenCoef,
        'loadSeconds': loadSeconds,
      }));
    } catch (_) {} // the estimate is a nicety, never fail a job over it
  }

  /// Expected song length in seconds. Covers use the source length.
  /// Lyrics: 36.6 + 4.17 s per sung line, section tags ignored (8 lines -> 70 s, 33 lines -> 174 s), clamped to 30..300 s.
  /// No lyrics (instrumental): 120 s.
  /// [scoreSeconds]: the length the engine read from the finished score (progress.audio); it wins once known.
  double expectedSeconds({String lyrics = '', double? sourceSeconds, double? scoreSeconds}) {
    if (scoreSeconds != null && scoreSeconds > 0) return scoreSeconds;
    if (sourceSeconds != null && sourceSeconds > 0) return sourceSeconds;
    final lines = lyrics.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !RegExp(r'^\[.*\]$').hasMatch(l)).length;
    if (lines == 0) return _instrumentalSeconds;
    return (_lenA + _lenB * lines).clamp(30.0, 300.0);
  }

  /// Ordered (stage, seconds of work) for a job. A cover (sourceSeconds given) arrives with its score, so no abc stage.
  List<(String, double)> _steps(double audio, {required bool plan, required bool cover, String? current}) => [
        if (!modelLoaded || current == 'load') ('load', loadSeconds),
        if (plan && !cover) ('abc', _secs('abc', audio)),
        ('semantic', _secs('semantic', audio)),
        ('nar', _secs('nar', audio)),
        ('vae', _secs('vae', audio)),
      ];

  Duration estimate({required String lyrics, double? sourceSeconds, bool plan = true}) {
    final a = expectedSeconds(lyrics: lyrics, sourceSeconds: sourceSeconds);
    final s = _steps(a, plan: plan, cover: sourceSeconds != null).fold<double>(0, (x, e) => x + e.$2);
    return Duration(milliseconds: (s * 1000).round());
  }

  /// Time for the transcription of a source file of [seconds].
  Duration estimateTranscribe(double seconds) => Duration(milliseconds: (seconds * transcribePerSecond * 1000).round());

  /// Expected total token count of a token-counted stage.
  double _expectedTokens(String stage, double audio) => tokenCoef[stage]! * math.pow(audio, tokenExp[stage]!);

  /// Fraction (0..1) of the current stage, never reaching 1 for stages with unknown totals.
  double _fraction(String stage, int done, int? total, Duration elapsed, double audio, double stageSeconds) {
    switch (stage) {
      case 'nar' || 'vae':
        return total != null && total > 0 ? (done / total).clamp(0.0, 1.0) : 0;
      case 'abc' || 'semantic':
        final exp = _expectedTokens(stage, audio);
        // If the guess was too low, stretch it so the stage plateaus at 85% instead of overshooting its share.
        return done / math.max(exp, done / 0.85);
      default: // load, transcribe: time against the expected duration
        return math.min(0.95, elapsed.inMilliseconds / 1000 / math.max(stageSeconds, 1));
    }
  }

  /// 0..1 progress inside [stage] alone (what the status line shows as a percentage); stays below 1 for token stages.
  double stageFractionFor({
    required String stage,
    required int done,
    int? total,
    Duration elapsedInStage = Duration.zero,
    required String lyrics,
    double? sourceSeconds,
    bool plan = true,
  }) {
    final audio = expectedSeconds(lyrics: lyrics, sourceSeconds: sourceSeconds);
    final sec = _steps(audio, plan: plan, cover: sourceSeconds != null, current: stage).where((e) => e.$1 == stage);
    return _fraction(stage, done, total, elapsedInStage, audio, sec.isEmpty ? 1 : sec.first.$2);
  }

  /// 0..1 overall progress, stages weighted by their share of time. Not monotonic by itself: the queue keeps the max.
  double progressFor({
    required String stage,
    required int done,
    int? total,
    required Duration elapsedInStage,
    required String lyrics,
    double? sourceSeconds,
    double? scoreSeconds,
    bool plan = true,
  }) {
    final audio = expectedSeconds(lyrics: lyrics, sourceSeconds: sourceSeconds, scoreSeconds: scoreSeconds);
    if (stage == 'transcribe') return _fraction(stage, done, total, elapsedInStage, audio, audio * transcribePerSecond);
    final steps = _steps(audio, plan: plan, cover: sourceSeconds != null, current: stage);
    final all = steps.fold<double>(0, (x, e) => x + e.$2);
    var before = 0.0;
    for (final (s, sec) in steps) {
      if (s == stage) return ((before + _fraction(s, done, total, elapsedInStage, audio, sec) * sec) / all).clamp(0.0, 1.0);
      before += sec;
    }
    return 0;
  }

  /// Time left, recomputed from the live speed of the current stage.
  Duration remainingFor({
    required String stage,
    required int done,
    int? total,
    required Duration elapsedInStage,
    required String lyrics,
    double? sourceSeconds,
    double? scoreSeconds,
    bool plan = true,
  }) {
    final audio = expectedSeconds(lyrics: lyrics, sourceSeconds: sourceSeconds, scoreSeconds: scoreSeconds);
    final el = elapsedInStage.inMilliseconds / 1000;
    if (stage == 'transcribe') {
      return Duration(milliseconds: (math.max(0, audio * transcribePerSecond - el) * 1000).round());
    }
    final steps = _steps(audio, plan: plan, cover: sourceSeconds != null, current: stage);
    final i = steps.indexWhere((e) => e.$1 == stage);
    if (i < 0) return Duration(milliseconds: (steps.fold<double>(0, (x, e) => x + e.$2) * 1000).round());
    final sec = steps[i].$2;
    final f = _fraction(stage, done, total, elapsedInStage, audio, sec);
    // Observed length of the current stage, from the live rate once there is enough to go on.
    var observed = sec;
    var left = sec * (1 - f);
    if ((stage == 'abc' || stage == 'semantic') && done >= 25 && el > 1) {
      final exp = _expectedTokens(stage, audio);
      observed = exp / (done / el);
      left = math.max(0, exp - done) / (done / el);
    } else if ((stage == 'nar' || stage == 'vae') && f >= 0.05 && el >= 2) {
      observed = el / f;
      left = observed * (1 - f);
    }
    final pace = stage == 'load' ? 1.0 : (observed / sec).clamp(0.25, 4.0);
    final later = steps.skip(i + 1).fold<double>(0, (x, e) => x + e.$2);
    return Duration(milliseconds: ((left + later * pace) * 1000).round());
  }

  /// Folds a finished run into the stored coefficients c = seconds / L^exp (moving average; the first run replaces the
  /// prior; the exponents stay, so a short run still scales up to a long song).
  /// [stageSeconds] keys: load, abc, semantic, nar, vae. [tokens] (optional): final token count of abc / semantic.
  Future<void> record({
    required Map<String, double> stageSeconds,
    required double audioSeconds,
    Map<String, int>? tokens,
  }) async {
    if (fake || audioSeconds <= 0) return;
    final a = runs == 0 ? 1.0 : math.max(0.3, 1 / (runs + 1));
    double mix(double old, double obs) => old + (obs - old) * a;
    for (final e in stageSeconds.entries) {
      if (e.value <= 0) continue;
      if (e.key == 'load') {
        loadSeconds = mix(loadSeconds, e.value);
      } else if (coef.containsKey(e.key)) {
        coef[e.key] = mix(coef[e.key]!, e.value / math.pow(audioSeconds, stageExp[e.key]!));
      }
    }
    for (final e in (tokens ?? const <String, int>{}).entries) {
      if (e.value > 0 && tokenCoef.containsKey(e.key)) {
        tokenCoef[e.key] = mix(tokenCoef[e.key]!, e.value / math.pow(audioSeconds, tokenExp[e.key]!));
      }
    }
    runs++;
    modelLoaded = true;
    await _save();
  }
}
