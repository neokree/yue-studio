import 'dart:convert';

import '../artwork/artwork.dart';
import '../engine/protocol.dart';

enum SongStatus { queued, generating, done, failed }

enum SongKind { song, cover }

/// meta.json (engine/PROTOCOL.md section 6).
class Song {
  const Song({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.status,
    required this.request,
    this.kind = SongKind.song,
    this.liked = false,
    this.audio,
    this.duration,
    this.error,
    this.artwork,
  });

  final String id, title;
  final DateTime createdAt;
  final SongStatus status;
  final SongKind kind;
  final bool liked;
  final SongRequest request;
  final String? audio, error;
  final double? duration;

  /// Stored artwork spec; null for songs from before artwork (the store assigns and persists one on load).
  final ArtworkSpec? artwork;

  ArtworkSpec get art => artwork ?? ArtworkSpec.forId(id);

  Song copyWith({
    String? title,
    SongStatus? status,
    bool? liked,
    SongRequest? request,
    String? audio,
    double? duration,
    String? error,
    ArtworkSpec? artwork,
    bool clearError = false,
  }) =>
      Song(
        id: id,
        createdAt: createdAt,
        kind: kind,
        title: title ?? this.title,
        status: status ?? this.status,
        liked: liked ?? this.liked,
        request: request ?? this.request,
        audio: audio ?? this.audio,
        duration: duration ?? this.duration,
        error: clearError ? null : (error ?? this.error),
        artwork: artwork ?? this.artwork,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'liked': liked,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'status': status.name,
        'kind': kind.name,
        'request': request.toJson(),
        'audio': audio,
        'duration': duration,
        'error': error,
        if (artwork != null) 'artwork': artwork!.toJson(),
      };

  factory Song.fromJson(Map<String, dynamic> j) => Song(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        liked: j['liked'] == true,
        createdAt: DateTime.parse(j['createdAt'] as String),
        status: SongStatus.values.firstWhere((s) => s.name == j['status'], orElse: () => SongStatus.failed),
        kind: SongKind.values.firstWhere((s) => s.name == j['kind'], orElse: () => SongKind.song),
        request: SongRequest.fromJson(Map<String, dynamic>.from(j['request'] as Map)),
        audio: j['audio'] as String?,
        duration: (j['duration'] as num?)?.toDouble(),
        error: j['error'] as String?,
        artwork: j['artwork'] is Map ? ArtworkSpec.fromJson(Map<String, dynamic>.from(j['artwork'] as Map)) : null,
      );

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

class SongRequest {
  const SongRequest({required this.style, required this.lyrics, required this.cot, required this.seed, this.abc});
  final String style, lyrics;
  final CotMode cot;
  final int seed;
  final String? abc;

  Map<String, dynamic> toJson() => {
        'style': style,
        'lyrics': lyrics,
        'cot': cot.name,
        'seed': seed,
        if (abc != null) 'abc': abc,
      };

  factory SongRequest.fromJson(Map<String, dynamic> j) => SongRequest(
        style: j['style'] as String? ?? '',
        lyrics: j['lyrics'] as String? ?? '',
        cot: CotMode.parse(j['cot'] as String?),
        seed: (j['seed'] as num?)?.toInt() ?? 0,
        abc: j['abc'] as String?,
      );
}
