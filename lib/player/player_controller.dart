import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library/library_store.dart';
import '../library/song.dart';

/// What the controller needs from an audio engine. Tests inject a fake: audioplayers is never touched there.
abstract class PlayerBackend {
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<void> get completed;
  Future<void> play(String path);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration to);
  Future<void> stop();
  Future<void> dispose();
}

/// The one AudioPlayer. Created lazily on first play.
class AudioplayersBackend implements PlayerBackend {
  final _p = AudioPlayer();
  @override
  Stream<Duration> get position => _p.onPositionChanged;
  @override
  Stream<Duration> get duration => _p.onDurationChanged;
  @override
  Stream<void> get completed => _p.onPlayerComplete;
  @override
  Future<void> play(String path) => _p.play(DeviceFileSource(path));
  @override
  Future<void> pause() => _p.pause();
  @override
  Future<void> resume() => _p.resume();
  @override
  Future<void> seek(Duration to) => _p.seek(to);
  @override
  Future<void> stop() => _p.stop();
  @override
  Future<void> dispose() => _p.dispose();
}

/// Single-player state for the whole app. next/previous walk `library.visible` (done songs only).
/// The library is attached by whichever widget gets it first (PlayerBar, LibraryScreen) so `PlayerController()` works bare.
class PlayerController extends ChangeNotifier {
  PlayerController({this._backend, LibraryStore? library}) {
    if (library != null) attach(library);
  }

  PlayerBackend? _backend;
  LibraryStore? _library;
  final _subs = <StreamSubscription<dynamic>>[];

  Song? current;
  bool playing = false;
  Duration position = Duration.zero;
  Duration? _reported;
  String? error;

  Duration get duration => _reported ?? Duration(milliseconds: ((current?.duration ?? 0) * 1000).round());

  void attach(LibraryStore library) {
    if (identical(_library, library)) return;
    _library?.removeListener(_onLibrary);
    _library = library..addListener(_onLibrary);
  }

  PlayerBackend get _b {
    final b = _backend ??= AudioplayersBackend();
    if (_subs.isEmpty) {
      _subs.addAll([
        b.position.listen((d) {
          position = d;
          notifyListeners();
        }),
        b.duration.listen((d) {
          _reported = d;
          notifyListeners();
        }),
        b.completed.listen((_) => _onComplete()),
      ]);
    }
    return b;
  }

  void _onLibrary() {
    final c = current;
    if (c == null) return;
    final s = _library?.byId(c.id);
    if (s == null) {
      stop();
    } else if (!identical(s, c)) {
      current = s; // rename / like show up in the bar
      notifyListeners();
    }
  }

  List<Song> get _queue => (_library?.visible ?? const <Song>[]).where((s) => s.status == SongStatus.done && s.audio != null).toList();

  int get _index => _queue.indexWhere((s) => s.id == current?.id);
  bool get hasNext => _index >= 0 && _index < _queue.length - 1;

  /// Symmetric with [hasNext]: a neighbour exists. (previous() still restarts the song after 3 s when there is one.)
  bool get hasPrevious => _index > 0;

  Future<void> play(Song song) async {
    final lib = _library, a = song.audio;
    if (lib == null || a == null) return;
    current = song;
    position = Duration.zero;
    _reported = null;
    playing = true;
    error = null;
    notifyListeners();
    try {
      await _b.play(p.join(lib.dirOf(song.id), a));
    } catch (e) {
      playing = false;
      error = '$e';
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    final c = current;
    if (c == null) return;
    if (playing) {
      playing = false;
      notifyListeners();
      await _b.pause();
    } else if (duration > Duration.zero && position >= duration) {
      await play(c); // finished: start over
    } else {
      playing = true;
      notifyListeners();
      await _b.resume();
    }
  }

  Future<void> next() async {
    final q = _queue, i = _index;
    if (i >= 0 && i < q.length - 1) await play(q[i + 1]);
  }

  Future<void> previous() async {
    final q = _queue, i = _index;
    if (current == null) return;
    if (position > const Duration(seconds: 3) || i <= 0) {
      await seek(Duration.zero);
    } else {
      await play(q[i - 1]);
    }
  }

  Future<void> seek(Duration to) async {
    if (current == null) return;
    position = to;
    notifyListeners();
    await _b.seek(to);
  }

  void _onComplete() {
    if (hasNext) {
      next();
    } else {
      playing = false;
      position = duration;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    current = null;
    playing = false;
    position = Duration.zero;
    _reported = null;
    notifyListeners();
    await _backend?.stop();
  }

  @override
  void dispose() {
    _library?.removeListener(_onLibrary);
    for (final s in _subs) {
      s.cancel();
    }
    _backend?.dispose();
    super.dispose();
  }
}
