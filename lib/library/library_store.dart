import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'song.dart';

/// Directory scan of the library folder (one meta.json per song), newest first. No database.
/// ponytail: sync file IO on tiny json files keeps widget tests deterministic; go async if lists get huge.
class LibraryStore extends ChangeNotifier {
  LibraryStore(this.root);

  final String root;
  List<Song> songs = [];

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
          var s = Song.fromJson(jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>);
          if (s.status == SongStatus.queued || s.status == SongStatus.generating) {
            s = s.copyWith(status: SongStatus.failed, error: 'Interrupted');
            _write(s);
          }
          found.add(s);
        } catch (_) {} // unreadable meta: skip the folder
      }
    }
    songs = found..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    notifyListeners();
  }

  Song? byId(String id) => songs.where((s) => s.id == id).firstOrNull;

  Song create({
    required String title,
    required SongRequest request,
    SongKind kind = SongKind.song,
    DateTime? now,
  }) {
    final id = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 16).toRadixString(36)}';
    final s = Song(
      id: id,
      title: title,
      createdAt: now ?? DateTime.now(),
      status: SongStatus.queued,
      kind: kind,
      request: request,
    );
    _write(s);
    songs = [s, ...songs]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    notifyListeners();
    return s;
  }

  void update(Song s) {
    _write(s);
    final i = songs.indexWhere((x) => x.id == s.id);
    if (i >= 0) songs = [...songs]..[i] = s;
    notifyListeners();
  }

  void _write(Song s) {
    final dir = Directory(dirOf(s.id))..createSync(recursive: true);
    final tmp = File(p.join(dir.path, 'meta.json.tmp'))..writeAsStringSync(s.encode());
    tmp.renameSync(p.join(dir.path, 'meta.json'));
  }
}
