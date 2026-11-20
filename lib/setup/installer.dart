import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app/paths.dart';
import '../engine/process_engine.dart';
import 'manifest.dart';

enum StepStatus { pending, running, done, failed }

class SetupStepState {
  StepStatus status = StepStatus.pending;

  /// 0..1 when known, null = indeterminate.
  double? progress;
  String? error;
}

/// Runs the manifest steps with uv (PROTOCOL.md section 5) and remembers finished ones.
class Installer extends ChangeNotifier {
  Installer({required this.paths, required this.manifest, Set<String> done = const {}}) {
    for (final s in manifest.steps) {
      states[s.id] = SetupStepState()..status = done.contains(s.id) ? StepStatus.done : StepStatus.pending;
    }
  }

  final Paths paths;
  final SetupManifest manifest;
  final Map<String, SetupStepState> states = {};
  bool running = false;

  /// Set when the free-disk check fails (not tied to a step).
  ({int need, int free})? diskShort;

  static Future<Installer> load(Paths paths) async {
    final done = <String>{};
    final f = File(paths.setupState);
    if (f.existsSync()) {
      try {
        done.addAll(((jsonDecode(f.readAsStringSync()) as Map)['done'] as List).cast<String>());
      } catch (_) {} // corrupt state file: start over
    }
    return Installer(paths: paths, manifest: SetupManifest.read(paths.manifest), done: done);
  }

  bool get complete => states.values.every((s) => s.status == StepStatus.done);
  bool get started => states.values.any((s) => s.status != StepStatus.pending);
  bool get failed => diskShort != null || states.values.any((s) => s.status == StepStatus.failed);

  Future<void> install() async {
    if (running) return;
    running = true;
    diskShort = null;
    notifyListeners();
    try {
      await Directory(paths.dataDir).create(recursive: true);
      final free = await _freeBytes();
      final remaining = manifest.steps.where((s) => states[s.id]!.status != StepStatus.done).fold<int>(0, (a, s) => a + s.bytes);
      final need = (remaining * 1.1).round();
      if (free != null && free < need) {
        diskShort = (need: need, free: free);
        return;
      }
      for (final step in manifest.steps) {
        final st = states[step.id]!;
        if (st.status == StepStatus.done) continue;
        st
          ..status = StepStatus.running
          ..progress = null
          ..error = null;
        notifyListeners();
        try {
          await _run(step, st);
        } catch (e) {
          st
            ..status = StepStatus.failed
            ..error = e.toString();
          return;
        } finally {
          notifyListeners();
        }
        st
          ..status = StepStatus.done
          ..progress = 1;
        _saveState();
        notifyListeners();
      }
    } finally {
      running = false;
      notifyListeners();
    }
  }

  void _saveState() {
    final done = [for (final s in manifest.steps) if (states[s.id]!.status == StepStatus.done) s.id];
    File(paths.setupState).writeAsStringSync(jsonEncode({'done': done}));
  }

  Future<int?> _freeBytes() async {
    try {
      final r = await Process.run('df', ['-k', paths.dataDir]);
      final cols = (r.stdout as String).trim().split('\n').last.split(RegExp(r'\s+'));
      return int.parse(cols[3]) * 1024;
    } catch (_) {
      return null; // can't tell: don't block
    }
  }

  Future<void> _run(SetupStep step, SetupStepState st) async {
    final raw = step.raw;
    final env = ProcessEngine.environmentFor(paths);
    switch (step.kind) {
      case 'python':
        await _exec(paths.uv, ['python', 'install', raw['version'] as String], env);
      case 'venv':
        final venv = p.join(paths.dataDir, 'venvs', raw['name'] as String);
        await _exec(paths.uv, ['venv', venv, '--python', raw['python'] as String, '--clear'], env);
        final packages = [...?(raw['packages'] as List?)?.cast<String>()];
        final req = raw['requirements'] as String?;
        if (packages.isNotEmpty || req != null) {
          await _exec(
            paths.uv,
            [
              'pip', 'install', '--python', p.join(venv, 'bin', 'python'),
              ...packages,
              if (req != null) ...['-r', p.join(paths.dataDir, req)],
            ],
            env,
          );
        }
      case 'hf':
        final local = raw['local_dir'] as String?;
        await _exec(
          paths.venvPython(raw['venv'] as String),
          [
            paths.fetcher,
            '--repo', raw['repo'] as String,
            '--revision', raw['revision'] as String? ?? 'main',
            if (local != null) ...['--local-dir', p.join(paths.dataDir, local)],
          ],
          env,
          onLine: (line) => _hfLine(line, st),
        );
      default:
        throw StateError('unknown step kind "${step.kind}"');
    }
  }

  void _hfLine(String line, SetupStepState st) {
    try {
      final j = jsonDecode(line);
      if (j is! Map) return;
      if (j['type'] == 'progress') {
        final total = (j['total'] as num?) ?? 0;
        st.progress = total > 0 ? ((j['done'] as num) / total).clamp(0.0, 1.0).toDouble() : null;
        notifyListeners();
      } else if (j['type'] == 'error') {
        throw StateError(j['message'] as String? ?? 'download failed');
      }
    } on FormatException {
      // not a JSON line: ignore
    }
  }

  Future<void> _exec(String exe, List<String> args, Map<String, String> env, {void Function(String)? onLine}) async {
    final proc = await Process.start(exe, args, environment: env, includeParentEnvironment: false);
    final tail = <String>[];
    Object? lineError;
    void handle(String l) {
      tail.add(l);
      if (tail.length > 20) tail.removeAt(0);
      try {
        onLine?.call(l);
      } catch (e) {
        lineError ??= e;
      }
    }

    final out = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(handle).asFuture<void>();
    final err = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(handle).asFuture<void>();
    final code = await proc.exitCode;
    await Future.wait([out, err]);
    if (lineError != null) throw lineError!;
    if (code != 0) throw StateError('${p.basename(exe)} exited with $code\n${tail.join('\n')}');
  }
}
