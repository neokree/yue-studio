import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../artwork/artwork.dart';
import 'song.dart';

/// Directory scan of the library folder (one meta.json per song), newest first. No database.
/// ponytail: sync file IO on tiny json files keeps widget tests deterministic; go async if lists get huge.
class LibraryStore extends ChangeNotifier {
  LibraryStore(this.root);

  final String root;
  List<Song> songs = [];

  /// Library filter shared by the sidebar (Liked) and the Library screen (All/Liked).
  bool likedOnly = false;

  void setLikedOnly(bool v) {
    if (v == likedOnly) return;
    likedOnly = v;
    notifyListeners();
  }

  int get count => songs.length;
  int get likedCount => songs.where((s) => s.liked).length;
  List<Song> get visible => likedOnly ? songs.where((s) => s.liked).toList() : songs;

  String dirOf(String id) => p.join(root, id);

  /// Scans the disk. Jobs left queued/generating by a previous run can never finish: mark them failed.
  void load() {
    final found = <Song>[];
    final dir = Directory(root);
    if (dir.existsSync()) {
      for (final d in dir.listSync().whereType<Directory>()) {
        final meta = File(p.join(d.path, 'meta.json'));
        if (!meta.existsSync()) continue;
        try {
          final raw = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
          var s = Song.fromJson(raw);
          final interrupted = s.status == SongStatus.queued || s.status == SongStatus.generating;
          if (interrupted) s = s.copyWith(status: SongStatus.failed, error: 'Interrupted');
          // Old songs get a stable artwork seed (FNV-1a of the id), persisted so it can never change.
          if (s.artwork == null) s = s.copyWith(artwork: ArtworkSpec.forId(s.id));
          if (interrupted || raw['artwork'] == null) _write(s);
          found.add(s);
        } catch (_) {} // unreadable meta: skip the folder
      }
    }
    songs = found..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    notifyListeners();
  }

  Song? byId(String id) => songs.where((s) => s.id == id).firstOrNull;

  Song create({
    String? title,
    required SongRequest request,
    SongKind kind = SongKind.song,
    DateTime? now,
  }) {
    final id = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 16).toRadixString(36)}';
    final s = Song(
      id: id,
      title: _titleOrDefault(title, request.lyrics, now ?? DateTime.now()),
      createdAt: now ?? DateTime.now(),
      status: SongStatus.queued,
      kind: kind,
      request: request,
      artwork: ArtworkSpec(seed: _freshSeed()),
    );
    _write(s);
    songs = [s, ...songs]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    notifyListeners();
    return s;
  }

  /// Blank title: first lyric line (section tags skipped), else "Untitled 2026-11-20" (instrumentals).
  static String _titleOrDefault(String? title, String lyrics, DateTime at) {
    final t = title?.trim() ?? '';
    if (t.isNotEmpty) return t;
    final line = lyrics.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty && !l.startsWith('['), orElse: () => '');
    if (line.isNotEmpty) return line.length > 60 ? line.substring(0, 60) : line;
    final d = at.toLocal();
    return 'Untitled ${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// Random seed whose motif and hue differ from the three newest songs, so neighbouring rows never look alike.
  /// Only picks the seed for a NEW song; stored artworks are never touched.
  int _freshSeed() {
    final rnd = Random();
    final recent = [for (final s in songs.take(3)) ArtworkParams.forSpec(s.art)];
    // ponytail: 4 motifs can't always differ from 3 neighbours plus hue; after 100 misses only the newest row counts.
    var tries = 0;
    bool distinct(ArtworkParams p) => (tries < 100 ? recent : recent.take(1)).every((r) {
          final d = (r.hue - p.hue).abs() % 360;
          return r.motif != p.motif && (d > 180 ? 360 - d : d) > 50;
        });
    var seed = rnd.nextInt(1 << 31);
    for (; tries < 400 && !distinct(ArtworkParams.v1(seed)); tries++) {
      seed = rnd.nextInt(1 << 31);
    }
    return seed;
  }

  void update(Song s) {
    _write(s);
    final i = songs.indexWhere((x) => x.id == s.id);
    if (i >= 0) songs = [...songs]..[i] = s;
    notifyListeners();
  }

  void rename(String id, String title) {
    final s = byId(id), t = title.trim();
    if (s != null && t.isNotEmpty && t != s.title) update(s.copyWith(title: t));
  }

  void toggleLike(String id) {
    final s = byId(id);
    if (s != null) update(s.copyWith(liked: !s.liked));
  }

  /// Removes the song folder (audio, score, meta). Callers must not delete a queued/generating song.
  void delete(String id) {
    final d = Directory(dirOf(id));
    if (d.existsSync()) d.deleteSync(recursive: true);
    songs = songs.where((s) => s.id != id).toList();
    notifyListeners();
  }

  /// Copies the song's audio file to [destPath].
  Future<void> exportAudio(Song song, String destPath) async {
    final a = song.audio;
    if (a == null) throw StateError('Song has no audio');
    await File(p.join(dirOf(song.id), a)).copy(destPath);
  }

  void _write(Song s) {
    final dir = Directory(dirOf(s.id))..createSync(recursive: true);
    final tmp = File(p.join(dir.path, 'meta.json.tmp'))..writeAsStringSync(s.encode());
    tmp.renameSync(p.join(dir.path, 'meta.json'));
  }
}
