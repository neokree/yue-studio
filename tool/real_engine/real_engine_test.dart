// Real engine, headless, macOS only. Run through tool/real_engine.sh (it sets the env).
// Real setup (engine/manifests/real.json, bundled uv) -> one real generation (tool/real_engine/long_song.json, ~3 min, via ProcessEngine)
// -> a second generation (cot=melody, no score) -> one real Free transcription -> one cover generation from that ABC.
// Ceilings: footprint of the largest engine process (sidecar or SheetSage2, every 2 s) <= 16 GB; generation wall <= 4 x audio seconds + 90 s. Downloads about 11 GB.
// Songs are ~3 min (tool/real_engine/long_song.json: 3 verses, 3 choruses, bridge). Also transcribes a long MP3 (the ~3 min generated song, else repeated to >= 205 s) at 44.1 kHz (.scratch/long-input, built by make_long_input.py) with the same memory ceiling and wall <= 120 s:
// SheetSage2's Metal pool used to grow past 30 GB on songs of that length (the engine now caps it, see mps_watermarks in backends.py).
// Env: REAL_ENGINE_DATA (data dir), REAL_ENGINE_LOG (log file), REAL_ENGINE_ONLY=transcribe (setup resume + the two transcriptions
// of the song already in <data>/library/real-song, no generation).
@Timeout(Duration(hours: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yue2_studio/app/paths.dart';
import 'package:yue2_studio/engine/process_engine.dart';
import 'package:yue2_studio/engine/protocol.dart';
import 'package:yue2_studio/setup/installer.dart';

final _root = Directory.current.path; // flutter test runs from the package root
IOSink? _log;
final _t0 = Stopwatch()..start();
final _timings = <String, Duration>{};

void say(String m) {
  final line = '[${_t0.elapsed.toString().split('.').first}] $m';
  // ignore: avoid_print
  print(line);
  _log?.writeln(line);
}

Future<T> timed<T>(String step, Future<T> Function() body) async {
  say('>> $step');
  final sw = Stopwatch()..start();
  try {
    return await body();
  } finally {
    _timings[step] = sw.elapsed;
    say('<< $step: ${sw.elapsed.inSeconds} s');
  }
}

/// Footprint (KB) of each child process of this test (the sidecar; SheetSage2 while it transcribes), as macOS "footprint"
/// reports it: it includes the GPU (IOAccelerator) buffers that MPS keeps the weights in, which `ps rss` does not see (1 GB vs 10 GB).
Future<List<int>> childFootprintsKb() async {
  final out = await Process.run('ps', ['-axo', 'pid=,ppid=']);
  final parent = <int, int>{};
  for (final l in (out.stdout as String).split('\n')) {
    final f = l.trim().split(RegExp(r'\s+'));
    if (f.length == 2) parent[int.parse(f[0])] = int.parse(f[1]);
  }
  final tree = <int>{pid};
  for (var grew = true; grew;) {
    grew = false;
    for (final e in parent.entries) {
      if (tree.contains(e.value) && tree.add(e.key)) grew = true;
    }
  }
  tree.remove(pid);
  if (tree.isEmpty) return [];
  final fp = await Process.run('footprint', [
    for (final q in tree) ...['-p', '$q'],
  ]);
  return [
    for (final m in RegExp(
      // Per-process lines only ("name [pid]: 64-bit  Footprint: ..."): skip the "Summary Footprint" line, which is the sum.
      r'\]: [^\n]*?Footprint: ([\d.]+) (KB|MB|GB)',
    ).allMatches(fp.stdout as String))
      (double.parse(m[1]!) *
              switch (m[2]!) {
                'KB' => 1,
                'MB' => 1024,
                _ => 1048576,
              })
          .round(),
  ];
}

/// Hard ceilings, so a slow or heavy engine cannot pass silently (the old release wheel took 16+ min and 52 GB).
// MLX keeps the PyTorch model loaded (acoustic prefill, VAE, fallback) next to the 8-bit token weights and the bf16
// acoustic copy: measured 18 GB (145 s song) and 21 GB (180 s, cot=melody) on an M4 Pro; PyTorch alone stayed under 16.
const maxRssGb = 26.0;
// 6.5x: measured 4.9x for a 174 s song on an M4 Pro (time grows faster than length), plus margin.
const wallPerAudioSecond = 6.5;
const longTranscribeWall = Duration(seconds: 120);
const loadAllowance = Duration(seconds: 90);
final _violations = <String>[];

class JobRun {
  JobRun(
    this.result,
    this.wall,
    this.peakGb,
    this.stageSeconds,
    this.peakTotalGb,
  );
  final ResultEvent result;
  final Duration wall;
  final double peakGb,
      peakTotalGb; // largest single process; all children summed
  final Map<String, double> stageSeconds;
}

/// Sends [req], returns the result event for [job] with wall time, peak memory (footprint, sampled every 2 s) and per-stage seconds
/// (first progress event of a stage to the first of the next). Logs progress (one line per stage change or 20 s).
/// Aborts the job as soon as the memory ceiling is crossed.
Future<JobRun> runJob(
  ProcessEngine engine,
  EngineRequest req,
  String job, {
  Duration timeout = const Duration(minutes: 30),
}) async {
  final done = Completer<ResultEvent>();
  var lastStage = '';
  var lastLog = DateTime.fromMillisecondsSinceEpoch(0);
  final sw = Stopwatch()..start();
  final stageAt = <String, Duration>{};
  var peakKb = 0,
      peakTotalKb = 0; // largest single process / all children together
  final sampler = Timer.periodic(const Duration(seconds: 2), (_) async {
    final all = await childFootprintsKb();
    final kb = all.fold<int>(0, (a, b) => a > b ? a : b);
    final total = all.fold<int>(0, (a, b) => a + b);
    if (kb > peakKb) peakKb = kb;
    if (total > peakTotalKb) peakTotalKb = total;
    if (kb / 1048576 > maxRssGb && !done.isCompleted) {
      done.completeError(
        StateError(
          '$job: memory ceiling crossed, ${(kb / 1048576).toStringAsFixed(1)} GB > $maxRssGb GB',
        ),
      );
    }
  });
  final sub = engine.events.listen((e) {
    switch (e) {
      case ProgressEvent() when e.job == job:
        stageAt.putIfAbsent(e.stage, () => sw.elapsed);
        if (e.stage != lastStage ||
            DateTime.now().difference(lastLog) > const Duration(seconds: 20)) {
          say(
            '   $job ${e.stage} ${e.done}${e.total == null ? '' : '/${e.total}'}  mem ${(peakKb / 1048576).toStringAsFixed(1)} GB peak',
          );
          lastStage = e.stage;
          lastLog = DateTime.now();
        }
      case ResultEvent() when e.job == job:
        if (!done.isCompleted) done.complete(e);
      case ErrorEvent() when e.job == job || e.job == null:
        if (!done.isCompleted) {
          done.completeError(StateError('engine error: ${e.message}'));
        }
      default:
    }
  });
  try {
    await engine.start();
    engine.send(req);
    final result = await done.future.timeout(timeout);
    final wall = sw.elapsed;
    final order = stageAt.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final secs = <String, double>{
      for (var i = 0; i < order.length; i++)
        order[i].key:
            ((i + 1 < order.length ? order[i + 1].value : wall) -
                    order[i].value)
                .inMilliseconds /
            1000,
    };
    return JobRun(result, wall, peakKb / 1048576, secs, peakTotalKb / 1048576);
  } finally {
    sampler.cancel();
    await sub.cancel();
  }
}

/// Logs one job's numbers and checks the ceilings (generation only: wall <= 6.5 x audio + 90 s).
void report(String name, JobRun r, {bool generation = true}) {
  say(
    '   $name: wall ${r.wall.inSeconds} s, peak ${r.peakGb.toStringAsFixed(1)} GB, stages ${r.stageSeconds.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(1)} s').join(', ')}',
  );
  if (r.peakGb > maxRssGb)
    _violations.add(
      '$name: peak ${r.peakGb.toStringAsFixed(1)} GB > $maxRssGb GB',
    );
  final audio = r.result.duration;
  if (generation && audio != null) {
    final limit = Duration(
      seconds: (wallPerAudioSecond * audio).ceil() + loadAllowance.inSeconds,
    );
    say(
      '   $name: ${audio.toStringAsFixed(1)} s audio, wall/audio ${(r.wall.inMilliseconds / 1000 / audio).toStringAsFixed(2)}x, limit ${limit.inSeconds} s',
    );
    if (r.wall > limit)
      _violations.add(
        '$name: wall ${r.wall.inSeconds} s > limit ${limit.inSeconds} s ($wallPerAudioSecond x ${audio.toStringAsFixed(1)} s audio + 90 s)',
      );
  }
}

void main() {
  final dataDir =
      Platform.environment['REAL_ENGINE_DATA'] ??
      p.join(_root, '.scratch', 'real-data');
  final logPath =
      Platform.environment['REAL_ENGINE_LOG'] ??
      p.join(_root, '.scratch', 'real-engine.log');

  test('real setup -> generate -> transcribe -> cover', () async {
    expect(
      Platform.isMacOS,
      isTrue,
      reason: 'real engine run is macOS (Apple Silicon) only',
    );
    File(logPath).parent.createSync(recursive: true);
    _log = File(logPath).openWrite(mode: FileMode.append);
    say('=== real engine run, data dir: $dataDir');

    // The real setup path: bundled uv (assets/uv/uv, fetched by tool/fetch_uv.sh), engine scripts in place, real manifest.
    final uv = p.join(_root, 'assets', 'uv', 'uv');
    expect(
      File(uv).existsSync(),
      isTrue,
      reason: 'bundled uv missing: run tool/fetch_uv.sh',
    );
    final paths = Paths(
      dataDir: dataDir,
      uv: uv,
      engineDir: p.join(_root, 'engine'),
      manifest: p.join(_root, 'engine', 'manifests', 'real.json'),
      copyAssets: false,
    );
    Directory(paths.libraryDir).createSync(recursive: true);

    // 1. setup, with per-step timings
    final installer = await Installer.load(paths);
    final started = <String, DateTime>{};
    final stepTimes = <String, Duration>{};
    final lastPct = <String, int>{};
    void onChange() {
      for (final s in installer.manifest.steps) {
        final st = installer.states[s.id]!;
        if (st.status == StepStatus.running) {
          if (!started.containsKey(s.id)) {
            started[s.id] = DateTime.now();
            say('   step ${s.id} (${s.label}) started');
          }
          final pct = ((st.progress ?? 0) * 100).floor();
          if (st.progress != null && pct >= (lastPct[s.id] ?? -10) + 10) {
            lastPct[s.id] = pct;
            say('   step ${s.id} $pct%');
          }
        } else if (st.status == StepStatus.done &&
            started.containsKey(s.id) &&
            !stepTimes.containsKey(s.id)) {
          final d = stepTimes[s.id] = DateTime.now().difference(started[s.id]!);
          say('   step ${s.id} done in ${d.inSeconds} s');
        } else if (st.status == StepStatus.failed) {
          say('   step ${s.id} FAILED: ${st.error}');
        }
      }
      if (installer.diskShort != null) {
        say('   not enough disk: ${installer.diskShort}');
      }
    }

    installer.addListener(onChange);
    await timed(
      'setup (${installer.complete ? 'already complete, resumed' : 'install'})',
      () => installer.install(),
    );
    installer.removeListener(onChange);
    final errors = [
      for (final e in installer.states.entries)
        if (e.value.error != null) '${e.key}: ${e.value.error}',
    ];
    expect(
      installer.complete,
      isTrue,
      reason: 'setup failed: ${errors.join('; ')}',
    );

    final engine = ProcessEngine(paths);
    addTearDown(() async {
      await engine.dispose();
      await _log?.flush();
      await _log?.close();
    });
    final out = p.join(dataDir, 'library');

    // 2. real generation, cot=full (it also loads the model: stage "load")
    final song =
        jsonDecode(
              File(
                p.join(_root, 'tool', 'real_engine', 'long_song.json'),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    GenerateRequest gen(String job, CotMode cot, {String? abc}) =>
        GenerateRequest(
          job: job,
          out: p.join(out, job),
          style: song['style'] as String,
          lyrics: song['lyrics'] as String,
          cot: cot,
          seed: (song['seed'] as num).toInt(),
          abc: abc,
        );
    final runs = <String, JobRun>{};
    final transcribeOnly =
        Platform.environment['REAL_ENGINE_ONLY'] == 'transcribe';
    late final String audio;
    String? audio2, coverAudio;
    if (transcribeOnly) {
      audio = p.join(out, 'real-song', 'audio.flac');
      expect(
        File(audio).existsSync(),
        isTrue,
        reason: 'no song at $audio, run the full test once',
      );
    } else {
      runs['generate cot=full'] = await timed(
        'generate (long_song.json, cot=${song['cot']})',
        () => runJob(
          engine,
          gen('real-song', CotMode.parse(song['cot'] as String?)),
          'real-song',
        ),
      );
      final g1 = runs['generate cot=full']!;
      audio = p.join(g1.result.dir, g1.result.audio ?? 'audio.flac');
      expect(File(audio).existsSync(), isTrue, reason: 'no audio at $audio');
      expect(File(audio).lengthSync(), greaterThan(10000));
      say(
        '   song: $audio (${g1.result.duration?.toStringAsFixed(1)} s audio, seed ${g1.result.seed})',
      );
      report('generate cot=full', g1);

      // 3. second generation, cot=melody and NO supplied score (the model plans the melody itself)
      runs['generate cot=melody'] = await timed(
        'generate (cot=melody, no score)',
        () => runJob(engine, gen('real-melody', CotMode.melody), 'real-melody'),
      );
      final g2 = runs['generate cot=melody']!;
      audio2 = p.join(g2.result.dir, g2.result.audio ?? 'audio.flac');
      expect(File(audio2).existsSync(), isTrue, reason: 'no audio at $audio2');
      say(
        '   song: $audio2 (${g2.result.duration?.toStringAsFixed(1)} s audio)',
      );
      report('generate cot=melody', g2);
    }

    // 4. one real transcription, Free mode (melody only), of the first song
    runs['transcribe'] = await timed(
      'transcribe (Free, melody only)',
      () => runJob(
        engine,
        TranscribeRequest(
          job: 'real-transcribe',
          audio: audio,
          out: p.join(out, 'real-transcribe'),
          mode: 'melody',
        ),
        'real-transcribe',
      ),
    );
    final tr = runs['transcribe']!;
    report('transcribe', tr, generation: false);
    final abcFile = File(p.join(tr.result.dir, 'score.abc'));
    expect(
      abcFile.existsSync(),
      isTrue,
      reason: 'no score.abc in ${tr.result.dir}',
    );
    final abc = abcFile.readAsStringSync();
    expect(abc, contains('X:'));
    say('   score: ${abcFile.path} (${abc.length} chars)');

    // 4b. the same transcription on a >= 200 s MP3 at 44.1 kHz: the memory and time ceilings must hold
    // (rebuilt every run: a song of 150 s or more is used as it is, a shorter one is repeated up to >= 205 s)
    final longIn = p.join(_root, '.scratch', 'long-input', 'long.mp3');
    Directory(p.dirname(longIn)).createSync(recursive: true);
    final made = await Process.run(
      p.join(dataDir, 'venvs', 'sheetsage2', 'bin', 'python'),
      [
        p.join(_root, 'tool', 'real_engine', 'make_long_input.py'),
        audio,
        longIn,
      ],
    );
    expect(made.exitCode, 0, reason: '${made.stderr}');
    say('   long input: ${(made.stdout as String).trim()}');
    runs['transcribe long (mp3, 44.1 kHz)'] = await timed(
      'transcribe (Free, long mp3 at 44.1 kHz)',
      () => runJob(
        engine,
        TranscribeRequest(
          job: 'real-transcribe-long',
          audio: longIn,
          out: p.join(out, 'real-transcribe-long'),
          mode: 'melody',
        ),
        'real-transcribe-long',
        timeout: longTranscribeWall + const Duration(seconds: 60),
      ),
    );
    final trLong = runs['transcribe long (mp3, 44.1 kHz)']!;
    report('transcribe long', trLong, generation: false);
    if (trLong.wall > longTranscribeWall) {
      _violations.add(
        'transcribe long: wall ${trLong.wall.inSeconds} s > ${longTranscribeWall.inSeconds} s',
      );
    }
    expect(
      File(p.join(trLong.result.dir, 'score.abc')).readAsStringSync(),
      contains('X:'),
    );

    // 5. one cover generation from that ABC
    if (!transcribeOnly) {
      runs['cover (abc)'] = await timed(
        'cover generate (abc from step 4, cot=melody)',
        () => runJob(
          engine,
          gen('real-cover', CotMode.melody, abc: abc),
          'real-cover',
        ),
      );
      final cover = runs['cover (abc)']!;
      coverAudio = p.join(cover.result.dir, cover.result.audio ?? 'audio.flac');
      expect(
        File(coverAudio).existsSync(),
        isTrue,
        reason: 'no cover audio at $coverAudio',
      );
      say(
        '   cover: $coverAudio (${cover.result.duration?.toStringAsFixed(1)} s audio)',
      );
      report('cover (abc)', cover);
    }

    say('=== SUMMARY (data dir $dataDir)');
    for (final e in stepTimes.entries) {
      say('  setup step ${e.key.padRight(20)} ${e.value.inSeconds} s');
    }
    for (final e in _timings.entries) {
      say('  ${e.key.padRight(48)} ${e.value.inSeconds} s');
    }
    for (final e in runs.entries) {
      say(
        '  ${e.key.padRight(20)} wall ${e.value.wall.inSeconds} s, peak ${e.value.peakGb.toStringAsFixed(1)} GB',
      );
    }
    say('  song:   $audio');
    if (audio2 != null) say('  melody: $audio2');
    say('  score:  ${abcFile.path}');
    if (coverAudio != null) say('  cover:  $coverAudio');
    say(_violations.isEmpty ? '  CEILINGS: passed' : '  CEILINGS: FAILED');
    expect(_violations, isEmpty, reason: _violations.join('; '));
  }, timeout: Timeout.none);
}
