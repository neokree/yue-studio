import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app/paths.dart';
import 'manifest.dart';
import 'requirements.dart';
import 'step_runner.dart';

enum StepStatus { pending, running, done, failed }

class SetupStepState {
  StepStatus status = StepStatus.pending;

  /// 0..1 when known.
  double? progress;
  int? doneBytes, totalBytes;

  /// Indeterminate steps: what is happening (connecting, python, venv, packages) and the last tool output line.
  String? phase, detail;
  String? error;
}

/// Margin kept free on top of what is still to download (PROTOCOL.md / CONTRACT: manifest bytes + 2 GB).
const diskMarginBytes = 2000000000;

/// Runs the manifest steps in order (PROTOCOL.md section 5) and remembers finished ones in setup-state.json.
class Installer extends ChangeNotifier {
  Installer({
    required this.paths,
    required this.manifest,
    Set<String> done = const {},
    StepRunner? runner,
    FreeBytes freeBytes = dfFreeBytes,
    HardwareProbe? probe,
  })  : runner = runner ?? ProcessStepRunner(paths),
        // ignore: prefer_initializing_formals
        _freeBytes = freeBytes,
        probe = probe ?? SystemProbe(freeBytes: freeBytes) {
    for (final s in manifest.steps) {
      states[s.id] = SetupStepState()..status = done.contains(s.id) ? StepStatus.done : StepStatus.pending;
    }
    // Steps without a size (uv python/venv) share what the manifest total has beyond the sized steps.
    final sized = manifest.steps.fold<int>(0, (a, s) => a + s.bytes);
    final unsized = manifest.steps.where((s) => s.bytes == 0).length;
    final share = unsized == 0 ? 0 : ((manifest.bytes - sized).clamp(0, manifest.bytes) / unsized).round();
    for (final s in manifest.steps) {
      _weight[s.id] = s.bytes > 0 ? s.bytes : share;
    }
  }

  final Paths paths;
  final SetupManifest manifest;
  final StepRunner runner;
  final FreeBytes _freeBytes;
  final HardwareProbe probe;
  final Map<String, SetupStepState> states = {};
  final Map<String, int> _weight = {};
  bool running = false;

  /// Result of the preflight (null until it has run). Blocking problems stop [install] before any download.
  Preflight? preflight;
  bool get blocked => preflight != null && !preflight!.ok;

  Future<bool> runPreflight() async {
    preflight = checkRequirements(await probe.read(paths.dataDir));
    notifyListeners();
    return preflight!.ok;
  }

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

  /// Bytes the step counts for in the totals (its own size, or its share of the unsized remainder).
  int weightOf(SetupStep s) => _weight[s.id] ?? 0;

  int get totalBytes => _weight.values.fold(0, (a, b) => a + b);

  int get downloadedBytes {
    var sum = 0.0;
    for (final s in manifest.steps) {
      final st = states[s.id]!;
      final w = weightOf(s);
      sum += switch (st.status) { StepStatus.done => w.toDouble(), StepStatus.running => w * (st.progress ?? 0), _ => 0 };
    }
    return sum.round();
  }

  /// 0..1 for the one overall bar.
  double get overall => totalBytes == 0 ? (complete ? 1 : 0) : (downloadedBytes / totalBytes).clamp(0.0, 1.0);

  Future<void> install() async {
    if (running) return;
    running = true;
    diskShort = null;
    notifyListeners();
    try {
      if (!await runPreflight()) return;
      Directory(paths.dataDir).createSync(recursive: true);
      final remaining = manifest.steps.where((s) => states[s.id]!.status != StepStatus.done).fold<int>(0, (a, s) => a + weightOf(s));
      final need = remaining + diskMarginBytes;
      final free = await _freeBytes(paths.dataDir);
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
          ..doneBytes = null
          ..totalBytes = null
          ..phase = null
          ..detail = null
          ..error = null;
        notifyListeners();
        try {
          await runner.run(step, ({phase, progress, doneBytes, totalBytes, detail}) {
            if (phase != null) st.phase = phase;
            if (progress != null) st.progress = progress;
            if (doneBytes != null) st.doneBytes = doneBytes;
            if (totalBytes != null) st.totalBytes = totalBytes;
            if (detail != null) st.detail = detail.isEmpty ? null : detail;
            notifyListeners();
          });
        } catch (e) {
          st
            ..status = StepStatus.failed
            ..error = e is SetupException ? e.message : e.toString();
          notifyListeners();
          return; // Retry resumes here: finished steps are skipped
        }
        st
          ..status = StepStatus.done
          ..progress = 1
          ..phase = null
          ..detail = null;
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
}
