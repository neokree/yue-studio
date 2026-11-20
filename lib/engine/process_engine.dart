import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app/paths.dart';
import 'engine.dart';
import 'protocol.dart';

/// Spawns engine/sidecar.py from the "yue2" venv and speaks JSON lines (PROTOCOL.md section 1).
class ProcessEngine implements Engine {
  ProcessEngine(this.paths);

  final Paths paths;
  final _events = StreamController<EngineEvent>.broadcast();
  final List<String> stderrTail = []; // last 200 lines, for error reports
  Process? _proc;
  Future<void>? _starting;

  @override
  Stream<EngineEvent> get events => _events.stream;

  /// Environment shared with the installer (uv steps) and the sidecar.
  static Map<String, String> environmentFor(Paths paths) => {
        ...Platform.environment,
        'PYTORCH_ENABLE_MPS_FALLBACK': '1',
        'HF_HOME': '${paths.dataDir}/hf',
        'UV_CACHE_DIR': '${paths.dataDir}/uv-cache',
        'UV_PYTHON_INSTALL_DIR': '${paths.dataDir}/uv-python',
        'UV_PYTHON_PREFERENCE': 'only-managed',
        'PYTHONUNBUFFERED': '1',
      }
        ..remove('HF_TOKEN')
        ..remove('HUGGING_FACE_HUB_TOKEN');

  @override
  Future<void> start() => _starting ??= _spawn().whenComplete(() => _starting = null);

  Future<void> _spawn() async {
    if (_proc != null) return;
    final proc = await Process.start(
      paths.venvPython('yue2'),
      [paths.sidecar, '--data-dir', paths.dataDir, if (paths.fake) '--fake'],
      environment: environmentFor(paths),
      includeParentEnvironment: false,
    );
    _proc = proc;
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      stderrTail.add(l);
      if (stderrTail.length > 200) stderrTail.removeAt(0);
    });
    unawaited(proc.exitCode.then((code) {
      if (_proc == proc) _proc = null;
      if (!_events.isClosed) {
        _events.add(ErrorEvent(message: 'Engine exited (code $code)\n${stderrTail.join('\n')}'));
      }
    }));
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    try {
      final j = jsonDecode(line);
      if (j is Map<String, dynamic>) _events.add(EngineEvent.fromJson(j));
    } on FormatException {
      stderrTail.add('stdout: $line'); // not protocol; keep for the error report
    }
  }

  @override
  void send(EngineRequest r) {
    final proc = _proc;
    if (proc == null) throw StateError('engine not started');
    proc.stdin.writeln(jsonEncode(r.toJson()));
  }

  @override
  Future<void> dispose() async {
    final proc = _proc;
    _proc = null;
    if (proc != null) {
      try {
        proc.stdin.writeln(jsonEncode(const ShutdownRequest().toJson()));
        await proc.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        proc.kill();
      }
    }
    await _events.close();
  }
}
