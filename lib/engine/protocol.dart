/// Mirrors engine/PROTOCOL.md sections 2 and 3. Change that file first.
library;

enum CotMode {
  full,
  melody,
  off;

  static CotMode parse(String? s) => values.firstWhere((m) => m.name == s, orElse: () => CotMode.full);
}

sealed class EngineRequest {
  const EngineRequest();
  Map<String, dynamic> toJson();
}

class GenerateRequest extends EngineRequest {
  const GenerateRequest({
    required this.job,
    required this.out,
    required this.style,
    required this.lyrics,
    required this.cot,
    required this.seed,
    this.abc,
  });
  final String job, out, style, lyrics;
  final CotMode cot;
  final int seed;
  final String? abc;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'generate',
        'job': job,
        'out': out,
        'style': style,
        'lyrics': lyrics,
        'cot': cot.name,
        'seed': seed,
        if (abc != null && abc!.isNotEmpty) 'abc': abc,
      };
}

class TranscribeRequest extends EngineRequest {
  const TranscribeRequest({required this.job, required this.audio, required this.out, required this.mode});
  final String job, audio, out;

  /// 'full' (Close: melody + chords) or 'melody' (Free: melody only).
  final String mode;

  @override
  Map<String, dynamic> toJson() => {'type': 'transcribe', 'job': job, 'audio': audio, 'out': out, 'mode': mode};
}

/// Splits [audio] into six stems (drums, bass, other, vocals, guitar, piano) written as `<name>.flac` into [out].
class StemsRequest extends EngineRequest {
  const StemsRequest({required this.job, required this.audio, required this.out});
  final String job, audio, out;

  @override
  Map<String, dynamic> toJson() => {'type': 'stems', 'job': job, 'audio': audio, 'out': out};
}

class CancelRequest extends EngineRequest {
  const CancelRequest(this.job);
  final String job;
  @override
  Map<String, dynamic> toJson() => {'type': 'cancel', 'job': job};
}

class ShutdownRequest extends EngineRequest {
  const ShutdownRequest();
  @override
  Map<String, dynamic> toJson() => {'type': 'shutdown'};
}

sealed class EngineEvent {
  const EngineEvent();

  /// Unknown types become [UnknownEvent]; unknown fields are ignored.
  factory EngineEvent.fromJson(Map<String, dynamic> j) {
    switch (j['type']) {
      case 'ready':
        return ReadyEvent(version: (j['version'] as num?)?.toInt() ?? 1, fake: j['fake'] == true);
      case 'progress':
        return ProgressEvent(
          job: j['job'] as String? ?? '',
          stage: j['stage'] as String? ?? '',
          done: (j['done'] as num?)?.toInt() ?? 0,
          total: (j['total'] as num?)?.toInt(),
          audio: (j['audio'] as num?)?.toDouble(),
        );
      case 'result':
        return ResultEvent(
          job: j['job'] as String? ?? '',
          dir: j['dir'] as String? ?? '',
          audio: j['audio'] as String?,
          seed: (j['seed'] as num?)?.toInt(),
          duration: (j['duration'] as num?)?.toDouble(),
          timings: (j['timings'] as Map?)?.map((k, v) => MapEntry('$k', (v as num).toDouble())),
          engine: switch (j['engine']) {
            {'ar': final String ar} => ar.startsWith('mlx') ? 'mlx' : 'torch',
            _ => null,
          },
        );
      case 'error':
        return ErrorEvent(
          job: j['job'] as String?,
          message: j['message'] as String? ?? 'unknown error',
          cancelled: j['cancelled'] == true,
        );
      default:
        return UnknownEvent(j);
    }
  }

  Map<String, dynamic> toJson();
}

class ReadyEvent extends EngineEvent {
  const ReadyEvent({this.version = 1, this.fake = false});
  final int version;
  final bool fake;
  @override
  Map<String, dynamic> toJson() => {'type': 'ready', 'version': version, 'fake': fake};
}

class ProgressEvent extends EngineEvent {
  const ProgressEvent({required this.job, required this.stage, required this.done, this.total, this.audio});
  final String job, stage;
  final int done;
  final int? total;

  /// Song length in seconds read from the finished score; only on the first `semantic` event of a planned song.
  final double? audio;
  @override
  Map<String, dynamic> toJson() =>
      {'type': 'progress', 'job': job, 'stage': stage, 'done': done, 'total': total, if (audio != null) 'audio': audio};
}

class ResultEvent extends EngineEvent {
  const ResultEvent({required this.job, required this.dir, this.audio, this.seed, this.duration, this.timings, this.engine});

  /// 'mlx' or 'torch': what ran the token loop (result.engine.ar), real generate only. The estimator keeps one cost
  /// model per engine.
  final String? engine;
  final String job, dir;
  final String? audio;
  final int? seed;
  final double? duration;

  /// Wall seconds per stage {load, abc, semantic, nar, vae}, generate only; null from older engines.
  final Map<String, double>? timings;
  @override
  Map<String, dynamic> toJson() => {
        'type': 'result',
        'job': job,
        'dir': dir,
        if (audio != null) 'audio': audio,
        if (seed != null) 'seed': seed,
        if (duration != null) 'duration': duration,
        if (timings != null) 'timings': timings,
        if (engine != null) 'engine': {'ar': engine},
      };
}

class ErrorEvent extends EngineEvent {
  const ErrorEvent({this.job, required this.message, this.cancelled = false});
  final String? job;
  final String message;
  final bool cancelled;
  @override
  Map<String, dynamic> toJson() => {'type': 'error', 'job': job, 'message': message, 'cancelled': cancelled};
}

class UnknownEvent extends EngineEvent {
  const UnknownEvent(this.raw);
  final Map<String, dynamic> raw;
  @override
  Map<String, dynamic> toJson() => raw;
}
