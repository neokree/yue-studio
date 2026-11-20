// Real engine, headless, macOS only. Run through tool/real_engine.sh (it sets the env).
// Real setup (engine/manifests/real.json, bundled uv) -> one real generation (reference/song.json, via ProcessEngine)
// -> one real Free transcription of that audio -> one cover generation from that ABC. Downloads about 11 GB.
// Env: REAL_ENGINE_DATA (data dir), REAL_ENGINE_LOG (log file).
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

/// Sends [req], returns the result event for [job]; logs progress (one line per stage change or 20 s).
Future<ResultEvent> runJob(
  ProcessEngine engine,
  EngineRequest req,
  String job, {
  Duration timeout = const Duration(minutes: 40),
}) async {
  final done = Completer<ResultEvent>();
  var lastStage = '';
  var lastLog = DateTime.fromMillisecondsSinceEpoch(0);
  final sub = engine.events.listen((e) {
    switch (e) {
      case ProgressEvent() when e.job == job:
        if (e.stage != lastStage ||
            DateTime.now().difference(lastLog) > const Duration(seconds: 20)) {
          say(
            '   $job ${e.stage} ${e.done}${e.total == null ? '' : '/${e.total}'}',
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
    return await done.future.timeout(timeout);
  } finally {
    await sub.cancel();
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

    // 2. one real generation (it also loads the model: stage "load")
    final song =
        jsonDecode(
              File(p.join(_root, 'reference', 'song.json')).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final gen = await timed(
      'generate (reference/song.json, cot=${song['cot']})',
      () => runJob(
        engine,
        GenerateRequest(
          job: 'real-song',
          out: p.join(out, 'real-song'),
          style: song['style'] as String,
          lyrics: song['lyrics'] as String,
          cot: CotMode.parse(song['cot'] as String?),
          seed: (song['seed'] as num).toInt(),
        ),
        'real-song',
      ),
    );
    final audio = p.join(gen.dir, gen.audio ?? 'audio.flac');
    expect(File(audio).existsSync(), isTrue, reason: 'no audio at $audio');
    expect(File(audio).lengthSync(), greaterThan(10000));
    say(
      '   song: $audio (${gen.duration?.toStringAsFixed(1)} s audio, seed ${gen.seed})',
    );

    // 3. one real transcription, Free mode (melody only)
    final tr = await timed(
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
    final abcFile = File(p.join(tr.dir, 'score.abc'));
    expect(abcFile.existsSync(), isTrue, reason: 'no score.abc in ${tr.dir}');
    final abc = abcFile.readAsStringSync();
    expect(abc, contains('X:'));
    say('   score: ${abcFile.path} (${abc.length} chars)');

    // 4. one cover generation from that ABC
    final cover = await timed(
      'cover generate (abc from step 3, cot=melody)',
      () => runJob(
        engine,
        GenerateRequest(
          job: 'real-cover',
          out: p.join(out, 'real-cover'),
          style: song['style'] as String,
          lyrics: song['lyrics'] as String,
          cot: CotMode.melody,
          seed: (song['seed'] as num).toInt(),
          abc: abc,
        ),
        'real-cover',
      ),
    );
    final coverAudio = p.join(cover.dir, cover.audio ?? 'audio.flac');
    expect(
      File(coverAudio).existsSync(),
      isTrue,
      reason: 'no cover audio at $coverAudio',
    );
    say(
      '   cover: $coverAudio (${cover.duration?.toStringAsFixed(1)} s audio)',
    );

    say('=== SUMMARY (data dir $dataDir)');
    for (final e in stepTimes.entries) {
      say('  setup step ${e.key.padRight(20)} ${e.value.inSeconds} s');
    }
    for (final e in _timings.entries) {
      say('  ${e.key.padRight(48)} ${e.value.inSeconds} s');
    }
    say('  song:   $audio');
    say('  score:  ${abcFile.path}');
    say('  cover:  $coverAudio');
  }, timeout: Timeout.none);
}
