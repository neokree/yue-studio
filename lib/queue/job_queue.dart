import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../engine/protocol.dart';
import '../library/library_store.dart';
import '../library/song.dart';

/// One job at a time: sends the next request only after the previous result or error (PROTOCOL.md section 1).
class JobQueue extends ChangeNotifier {
  JobQueue({required this.engine, required this.library}) {
    _sub = engine.events.listen(_onEvent);
  }

  final Engine engine;
  final LibraryStore library;
  late final StreamSubscription<EngineEvent> _sub;
  final List<String> _pending = [];

  /// Id of the song being generated, null when idle.
  String? current;

  /// Last progress event of [current].
  ProgressEvent? progress;

  List<String> get pending => List.unmodifiable(_pending);

  void enqueue(Song song) {
    _pending.add(song.id);
    notifyListeners();
    _pump();
  }

  /// Cancels a queued job directly, or asks the engine to stop the running one.
  void cancel(String id) {
    if (_pending.remove(id)) {
      _fail(id, 'Cancelled');
      notifyListeners();
    } else if (id == current) {
      engine.send(CancelRequest(id));
    }
  }

  Future<void> _pump() async {
    if (current != null || _pending.isEmpty) return;
    final id = _pending.removeAt(0);
    final song = library.byId(id);
    if (song == null) return _pump();
    current = id;
    progress = null;
    library.update(song.copyWith(status: SongStatus.generating, clearError: true));
    notifyListeners();
    try {
      await engine.start();
      final r = song.request;
      engine.send(GenerateRequest(
        job: id,
        out: library.dirOf(id),
        style: r.style,
        lyrics: r.lyrics,
        cot: r.cot,
        seed: r.seed,
        abc: r.abc,
      ));
    } catch (e) {
      _finish(id, error: 'Engine failed to start: $e');
    }
  }

  void _onEvent(EngineEvent e) {
    final id = current;
    if (id == null) return;
    switch (e) {
      case ProgressEvent() when e.job == id:
        progress = e;
        notifyListeners();
      case ResultEvent() when e.job == id:
        final s = library.byId(id);
        if (s != null) {
          library.update(s.copyWith(
            status: SongStatus.done,
            audio: e.audio,
            duration: e.duration,
            request: e.seed == null
                ? null
                : SongRequest(
                    style: s.request.style, lyrics: s.request.lyrics, cot: s.request.cot, seed: e.seed!, abc: s.request.abc),
            clearError: true,
          ));
        }
        _finish(id);
      case ErrorEvent() when e.job == id || e.job == null:
        _finish(id, error: e.cancelled ? 'Cancelled' : e.message);
      default:
    }
  }

  void _finish(String id, {String? error}) {
    if (error != null) _fail(id, error);
    current = null;
    progress = null;
    notifyListeners();
    _pump();
  }

  void _fail(String id, String message) {
    final s = library.byId(id);
    if (s != null) library.update(s.copyWith(status: SongStatus.failed, error: message));
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
