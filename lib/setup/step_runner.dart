import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../app/paths.dart';
import '../engine/process_engine.dart';
import 'manifest.dart';

/// A setup step failed; [message] is already fit to show to the user.
class SetupException implements Exception {
  SetupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What a running step can tell the UI. Only the given fields change.
/// [phase] is one of: connecting, python, venv, packages (the UI maps it to a label).
typedef StepReport = void Function({String? phase, double? progress, int? doneBytes, int? totalBytes, String? detail});

/// Runs one manifest step. The real one spawns uv / fetch.py; tests use a fake.
abstract class StepRunner {
  Future<void> run(SetupStep step, StepReport report);
}

final _ansi = RegExp(r'\x1B\[[0-9;?]*[A-Za-z]');

/// Executes steps as described in engine/PROTOCOL.md section 5, with the data-dir environment
/// (HF_HOME, UV_CACHE_DIR, UV_PYTHON_INSTALL_DIR, no HF_TOKEN).
class ProcessStepRunner implements StepRunner {
  ProcessStepRunner(this.paths, {String? failStep}) : _failStep = failStep ?? Platform.environment['YUE2_STUDIO_TEST_FAIL_STEP'];
  final Paths paths;

  /// Test hook (YUE2_STUDIO_TEST_FAIL_STEP=`step id`): that step fails once, for the e2e error screenshot.
  String? _failStep;

  @override
  Future<void> run(SetupStep step, StepReport report) async {
    final raw = step.raw;
    if (_failStep == step.id) {
      _failStep = null;
      throw SetupException('The connection was interrupted.');
    }
    // Hermetic: no user uv config, and no python launcher links outside the data dir (uv defaults to ~/.local/bin).
    final env = {...ProcessEngine.environmentFor(paths), 'UV_NO_CONFIG': '1', 'UV_PYTHON_BIN_DIR': p.join(paths.dataDir, 'bin')};
    switch (step.kind) {
      case 'python':
        report(phase: 'python');
        await _withGrowth(step, report, () => _exec(paths.uv, ['python', 'install', '--no-bin', raw['version'] as String], env, report));
      case 'venv':
        final venv = p.join(paths.dataDir, 'venvs', raw['name'] as String);
        report(phase: 'venv');
        await _withGrowth(step, report, () async {
          await _exec(paths.uv, ['venv', venv, '--python', raw['python'] as String, '--clear'], env, report);
          final packages = [...?(raw['packages'] as List?)?.cast<String>()];
          final req = raw['requirements'] as String?;
          if (packages.isEmpty && req == null) return;
          report(phase: 'packages', detail: '');
          await _exec(
            paths.uv,
            [
              'pip', 'install', '--python', p.join(venv, 'bin', 'python'),
              ...packages,
              if (req != null) ...['-r', p.join(paths.dataDir, req)],
            ],
            env,
            report,
          );
        });
      case 'hf':
        final local = raw['local_dir'] as String?;
        report(phase: 'connecting');
        await _exec(
          paths.venvPython(raw['venv'] as String),
          [
            paths.fetcher,
            '--repo', raw['repo'] as String,
            '--revision', raw['revision'] as String? ?? 'main',
            if (local != null) ...['--local-dir', p.join(paths.dataDir, local)],
          ],
          env,
          report,
          json: true,
        );
      case 'models':
        // Model-set migration (engine/modelset.py, PROTOCOL.md section 5): downloads/builds what the set needs, verifies,
        // switches atomically, then deletes models the set no longer uses. Same JSON progress lines as fetch.py.
        report(phase: 'connecting');
        await _exec(
          paths.venvPython(raw['venv'] as String),
          [
            paths.modelset,
            'migrate',
            '--data-dir', paths.dataDir,
            '--manifest', p.join(paths.engineDir, 'manifests', raw['manifest'] as String? ?? 'models.json'),
          ],
          env,
          report,
          json: true,
        );
      default:
        throw SetupException('Unknown setup step "${step.kind}".');
    }
  }

  /// uv prints no byte counts, so the row's "x of y" follows how much the uv cache and Python folders grew while the step ran,
  /// kept below the total until the step really ends (unpacking counts too).
  // ponytail: disk growth stands in for download progress; exact numbers would need uv to report them.
  Future<void> _withGrowth(SetupStep step, StepReport report, Future<void> Function() body) async {
    final total = step.bytes;
    if (total <= 0) return body();
    report(progress: 0, doneBytes: 0, totalBytes: total);
    final dirs = [p.join(paths.dataDir, 'uv-cache'), p.join(paths.dataDir, 'uv-python')];
    final base = await _size(dirs);
    var alive = true, busy = false, best = 0;
    final timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (busy) return;
      busy = true;
      try {
        final grown = ((await _size(dirs)) - base).clamp(best, (total * 0.97).floor());
        if (alive && grown > best) {
          best = grown;
          report(progress: grown / total, doneBytes: grown, totalBytes: total);
        }
      } finally {
        busy = false;
      }
    });
    try {
      await body();
    } finally {
      alive = false;
      timer.cancel();
    }
  }

  /// Bytes on disk under [dirs]: one `du -sk` for all of them (no Dart-side walk of the thousands of cache files).
  Future<int> _size(List<String> dirs) async {
    try {
      final r = await Process.run('du', ['-sk', ...dirs]);
      var kb = 0;
      // A folder that does not exist yet makes du exit 1 but it still prints the others.
      for (final l in const LineSplitter().convert(r.stdout as String)) {
        kb += int.tryParse(l.split(RegExp(r'\s'))[0]) ?? 0;
      }
      return kb * 1024;
    } on ProcessException {
      return 0;
    }
  }

  /// [json]: stdout lines are fetch.py events; everything else is shown as a detail line.
  Future<void> _exec(String exe, List<String> args, Map<String, String> env, StepReport report, {bool json = false}) async {
    final Process proc;
    try {
      proc = await Process.start(exe, args, environment: env, includeParentEnvironment: false);
    } on ProcessException catch (e) {
      throw SetupException('Could not start ${p.basename(exe)}: ${e.message}');
    }
    final tail = <String>[];
    Object? lineError;
    void handle(String raw) {
      final l = raw.replaceAll(_ansi, '').trim();
      if (l.isEmpty) return;
      tail.add(l);
      if (tail.length > 12) tail.removeAt(0);
      try {
        if (json && l.startsWith('{')) {
          _hfLine(l, report);
        } else {
          report(detail: l);
        }
      } catch (e) {
        lineError ??= e;
      }
    }

    final out = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(handle).asFuture<void>();
    final err = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(handle).asFuture<void>();
    final code = await proc.exitCode;
    await Future.wait([out, err]);
    if (lineError != null) throw lineError!;
    if (code != 0) throw SetupException('${p.basename(exe)} exited with code $code.\n${tail.reversed.take(3).toList().reversed.join('\n')}');
  }

  void _hfLine(String line, StepReport report) {
    final Object? j;
    try {
      j = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (j is! Map) return;
    if (j['type'] == 'progress') {
      final total = (j['total'] as num?)?.toInt() ?? 0;
      final done = (j['done'] as num?)?.toInt() ?? 0;
      report(progress: total > 0 ? (done / total).clamp(0.0, 1.0).toDouble() : null, doneBytes: done, totalBytes: total > 0 ? total : null);
    } else if (j['type'] == 'error') {
      throw SetupException(j['message'] as String? ?? 'Download failed.');
    }
  }
}