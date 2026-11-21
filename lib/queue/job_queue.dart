import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../engine/engine.dart';
import '../engine/protocol.dart';
import '../generation/estimator.dart';
import '../i18n/strings.g.dart';
import '../library/library_store.dart';
import '../library/song.dart';

/// One engine job: a song to generate, or a side job (a recording to transcribe, a song to split into stems).
class _Job {
  _Job.generate(this.id, this.lyrics, this.sourceSeconds, this.plan)
      : transcribeAudio = null,
        transcribeMode = null,
        stemsOut = null,
        done = null;
  _Job.transcribe(this.id, this.transcribeAudio, this.transcribeMode)
      : lyrics = '',
        sourceSeconds = null,
        plan = true,
        stemsOut = null,
        done = Completer<String>();
  _Job.stems(this.id, this.transcribeAudio, this.stemsOut)
      : lyrics = '',
        sourceSeconds = null,
        plan = true,
        transcribeMode = null,
        done = Completer<String>();

  final String id, lyrics;
  final double? sourceSeconds;

  /// Song length read from the finished score (progress.audio): replaces the guess from the lyrics for the rest of the job.
  double? scoreSeconds;

  /// False when cot is off (no score stage).
  final bool plan;
  final String? transcribeAudio, transcribeMode, stemsOut;
  final Completer<String>? done;

  /// A side job (transcribe or stems): no song row, no estimate; [done] completes with its result.
  bool get isTranscribe => done != null;
  bool get isStems => stemsOut != null;
}

/// FIFO queue, one engine job at a time (engine/PROTOCOL.md section 1): the next request goes out only after the
/// previous job's result or error. Generation and transcription share the same line.
class JobQueue extends ChangeNotifier {
  JobQueue({required this.engine, required this.library, GenerationEstimator? estimator})
      : estimator = estimator ?? GenerationEstimator(library.root) {
    _sub = engine.events.listen(_onEvent);
  }

  final Engine engine;
  final LibraryStore library;
  final GenerationEstimator estimator;
  late final StreamSubscription<EngineEvent> _sub;

  final List<_Job> _pending = [];
  _Job? _running;
  int _transcribes = 0;

  String? _stage;
  int _stageDone = 0;
  int? _stageTotal;
  final _stageWatch = Stopwatch();
  final Map<String, double> _stageSeconds = {};
  final Map<String, int> _tokens = {};
  double _progress = 0;
  Duration? _remaining;
  String? _lastFinishedId;
  Timer? _ticker;

  // ---- what the UI reads -------------------------------------------------------------------------------------

  /// The song being generated (null when idle or when the running job is a transcription).
  Song? get running {
    final j = _running;
    return j == null || j.isTranscribe ? null : library.byId(j.id);
  }

  /// Older name of [running]'s id.
  String? get current => running?.id;

  /// True while any engine job runs, including a transcription.
  bool get busy => _running != null;
  bool get transcribing => _running?.isTranscribe ?? false;

  /// Stage of the running side job ('transcribe' or 'stems'), null when idle or generating.
  String? get sideStage => _running?.isTranscribe != true ? null : (_running!.isStems ? 'stems' : 'transcribe');

  /// Song ids whose stems are being made or are waiting their turn.
  Set<String> get stemming => {for (final j in [?_running, ..._pending]) if (j.isStems) j.id.substring(1)};

  /// Protocol stage of the running job (load, abc, semantic, nar, vae, transcribe), null before the first event.
  String? get stage => _stage;
  int get stageDone => _stageDone;
  int? get stageTotal => _stageTotal;

  /// 0..1, from the estimator, never goes backwards within a job.
  double get progress => _progress;

  /// Estimated time left for the running job, null when idle or transcribing.
  Duration? get remaining => _remaining;

  /// Jobs waiting behind the running one.
  int get queuedCount => _pending.length;

  /// Id of the last song that finished successfully.
  String? get lastFinishedId => _lastFinishedId;

  // ---- API -------------------------------------------------------------------------------------------------

  /// Creates the library entry (status queued) and puts it in line. Returns the song id.
  String enqueueGenerate({
    required String style,
    required String lyrics,
    required String cot,
    int? seed,
    String? abc,
    String? title,
    SongKind kind = SongKind.song,
    double? sourceSeconds,
  }) {
    final song = library.create(
      title: (title?.trim().isEmpty ?? true) ? _title(lyrics) : title!.trim(),
      kind: kind,
      request: SongRequest(
        style: style.trim(),
        lyrics: lyrics.trim(),
        cot: CotMode.parse(cot),
        seed: seed ?? Random().nextInt(1 << 31),
        abc: abc,
      ),
    );
    _pending.add(_Job.generate(song.id, song.request.lyrics, sourceSeconds, song.request.cot != CotMode.off));
    notifyListeners();
    _pump();
    return song.id;
  }

  /// Transcribes a recording to an ABC score; waits its turn behind generation jobs. Throws on engine error.
  Future<String> transcribe(String audioPath, String mode) {
    final id = 't${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_transcribes++}';
    final job = _Job.transcribe(id, audioPath, mode);
    _pending.add(job);
    notifyListeners();
    _pump();
    return job.done!.future;
  }

  /// Splits a finished song into stems in `<song dir>/stems`; waits its turn. Completes with that folder; throws on engine error.
  Future<String> stems(String songId) {
    final song = library.byId(songId)!;
    final job = _Job.stems('s$songId', p.join(library.dirOf(songId), song.audio!), p.join(library.dirOf(songId), 'stems'));
    _pending.add(job);
    notifyListeners();
    _pump();
    return job.done!.future;
  }

  /// Removes a queued song (marks it failed, "Cancelled") or asks the engine to stop the running one.
  void cancel(String songId) {
    final i = _pending.indexWhere((j) => j.id == songId && !j.isTranscribe);
    if (i >= 0) {
      _pending.removeAt(i);
      _markFailed(songId, t.shell.queue.cancelled);
      notifyListeners();
    } else if (_running?.id == songId) {
      engine.send(CancelRequest(songId));
    }
  }

  // ---- internals ---------------------------------------------------------------------------------------------

  Future<void> _pump() async {
    if (_running != null || _pending.isEmpty) return;
    final job = _running = _pending.removeAt(0);
    _stage = null;
    _stageDone = 0;
    _stageTotal = null;
    _stageSeconds.clear();
    _tokens.clear();
    _stageWatch
      ..reset()
      ..start();
    _progress = 0;
    _remaining = job.isTranscribe ? null : estimator.estimate(lyrics: job.lyrics, sourceSeconds: job.sourceSeconds, plan: job.plan);
    _ticker?.cancel();
    if (!job.isTranscribe) {
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _recompute());
      final s = library.byId(job.id);
      if (s != null) library.update(s.copyWith(status: SongStatus.generating, clearError: true));
    }
    notifyListeners();
    try {
      await engine.start();
      if (job.isStems && library.byId(job.id.substring(1)) == null) {
        return _finish(job, error: t.shell.queue.cancelled); // the song was deleted while its stems waited
      } else if (job.isStems) {
        engine.send(StemsRequest(job: job.id, audio: job.transcribeAudio!, out: job.stemsOut!));
      } else if (job.isTranscribe) {
        final out = p.join(library.root, '.transcribe', job.id);
        engine.send(TranscribeRequest(job: job.id, audio: job.transcribeAudio!, out: out, mode: job.transcribeMode!));
      } else {
        final r = library.byId(job.id)!.request;
        engine.send(GenerateRequest(
          job: job.id,
          out: library.dirOf(job.id),
          style: r.style,
          lyrics: r.lyrics,
          cot: r.cot,
          seed: r.seed,
          abc: r.abc,
        ));
      }
    } catch (e) {
      _finish(job, error: t.shell.queue.engineFailed(message: '$e'));
    }
  }

  void _onEvent(EngineEvent e) {
    if (e is ReadyEvent) estimator.fake = e.fake; // fake timings must not calibrate the estimate
    final job = _running;
    if (job == null) return;
    switch (e) {
      case ProgressEvent() when e.job == job.id:
        if (e.stage != _stage) {
          _closeStage();
          _stageWatch
            ..reset()
            ..start();
        }
        _stage = e.stage;
        _stageDone = e.done;
        _stageTotal = e.total;
        if (e.total == null) _tokens[e.stage] = e.done;
        job.scoreSeconds = e.audio ?? job.scoreSeconds;
        _recompute();
      case ResultEvent() when e.job == job.id:
        _onResult(job, e);
      case ErrorEvent() when e.job == job.id || e.job == null:
        _finish(job, error: e.cancelled ? t.shell.queue.cancelled : e.message);
      default:
    }
  }

  /// Adds the time spent in the current stage to the per-stage totals.
  void _closeStage() {
    final s = _stage;
    if (s != null) _stageSeconds[s] = (_stageSeconds[s] ?? 0) + _stageWatch.elapsedMicroseconds / 1e6;
  }

  void _onResult(_Job job, ResultEvent e) {
    if (job.isStems) {
      job.done!.complete(e.dir);
      return _finish(job, stemsDone: true);
    }
    if (job.isTranscribe) {
      String? abc;
      try {
        abc = File(p.join(e.dir, 'score.abc')).readAsStringSync();
      } catch (_) {}
      try {
        Directory(e.dir).deleteSync(recursive: true);
      } catch (_) {}
      return _finish(job, abc: abc, error: abc == null ? t.shell.queue.noScore : null);
    }
    _closeStage();
    final s = library.byId(job.id);
    if (s != null) {
      library.update(s.copyWith(
        status: SongStatus.done,
        audio: e.audio,
        duration: e.duration,
        request: e.seed == null
            ? null
            : SongRequest(style: s.request.style, lyrics: s.request.lyrics, cot: s.request.cot, seed: e.seed!, abc: s.request.abc),
        clearError: true,
      ));
    }
    final audio = e.duration;
    if (audio != null && audio > 0) {
      // Prefer the engine's own wall times (load is 0 when the model was already resident, and record skips zeros);
      // fall back to the times measured from progress events. Without engine timings, drop load: it is per session.
      final timings = e.timings ?? (Map<String, double>.of(_stageSeconds)..remove('load'));
      final tokens = {for (final k in ['abc', 'semantic']) if (_tokens[k] != null) k: _tokens[k]!};
      unawaited(estimator.record(stageSeconds: timings, audioSeconds: audio, tokens: tokens).catchError((_) {}));
    }
    _lastFinishedId = job.id;
    _finish(job);
  }

  /// Recomputes progress and remaining from the estimator; progress only moves forward.
  void _recompute() {
    final job = _running;
    if (job == null || job.isTranscribe) return;
    final stage = _stage ?? 'load';
    final elapsed = _stageWatch.elapsed;
    final prog = estimator.progressFor(
      stage: stage,
      done: _stageDone,
      total: _stageTotal,
      elapsedInStage: elapsed,
      lyrics: job.lyrics,
      sourceSeconds: job.sourceSeconds,
      scoreSeconds: job.scoreSeconds,
      plan: job.plan,
    );
    _progress = max(_progress, prog.clamp(0.0, 1.0));
    _remaining = estimator.remainingFor(
      stage: stage,
      done: _stageDone,
      total: _stageTotal,
      elapsedInStage: elapsed,
      lyrics: job.lyrics,
      sourceSeconds: job.sourceSeconds,
      scoreSeconds: job.scoreSeconds,
      plan: job.plan,
    );
    notifyListeners();
  }

  void _finish(_Job job, {String? error, String? abc, bool stemsDone = false}) {
    _ticker?.cancel();
    _ticker = null;
    if (stemsDone) {
      // completed in _onResult with the folder
    } else if (job.isTranscribe) {
      if (error != null) {
        job.done!.completeError(Exception(error));
      } else {
        job.done!.complete(abc ?? '');
      }
    } else if (error != null) {
      _markFailed(job.id, error);
    }
    _running = null;
    _stage = null;
    _stageDone = 0;
    _stageTotal = null;
    _progress = 0;
    _remaining = null;
    notifyListeners();
    _pump();
  }

  void _markFailed(String id, String message) {
    final s = library.byId(id);
    if (s != null) library.update(s.copyWith(status: SongStatus.failed, error: message));
  }

  /// Song name when the user gave none: the first lyric line with its section tag stripped, "Untitled" plus the date for
  /// instrumentals.
  static String _title(String lyrics) {
    for (final l in lyrics.split('\n')) {
      final s = l.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();
      if (s.isNotEmpty) return s.length > 48 ? s.substring(0, 48) : s;
    }
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.create.untitled} ${n.year}-${two(n.month)}-${two(n.day)}';
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub.cancel();
    super.dispose();
  }
}
