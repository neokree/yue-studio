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
      throw SetupException('Network connection lost (simulated by YUE2_STUDIO_TEST_FAIL_STEP).');
    }
    // Hermetic: no user uv config, and no python launcher links outside the data dir (uv defaults to ~/.local/bin).
    final env = {...ProcessEngine.environmentFor(paths), 'UV_NO_CONFIG': '1', 'UV_PYTHON_BIN_DIR': p.join(paths.dataDir, 'bin')};
    switch (step.kind) {
      case 'python':
        report(phase: 'python');
        await _exec(paths.uv, ['python', 'install', '--no-bin', raw['version'] as String], env, report);
      case 'venv':
        final venv = p.join(paths.dataDir, 'venvs', raw['name'] as String);
        report(phase: 'venv');
        await _exec(paths.uv, ['venv', venv, '--python', raw['python'] as String, '--clear'], env, report);
        final packages = [...?(raw['packages'] as List?)?.cast<String>()];
        final req = raw['requirements'] as String?;
        if (packages.isNotEmpty || req != null) {
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
        }
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
      default:
        throw SetupException('Unknown setup step "${step.kind}".');
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
