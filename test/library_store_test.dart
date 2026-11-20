import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/artwork/artwork.dart';
import 'package:yue2_studio/engine/protocol.dart';
import 'package:yue2_studio/library/library_store.dart';
import 'package:yue2_studio/library/song.dart';

const _req = SongRequest(style: 's', lyrics: 'l', cot: CotMode.full, seed: 1);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('yue2lib'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('create, update, reload newest first', () {
    final lib = LibraryStore(tmp.path);
    final a = lib.create(title: 'old', request: _req, now: DateTime.utc(2026, 1, 1));
    final b = lib.create(title: 'new', request: _req, now: DateTime.utc(2026, 2, 1));
    expect(lib.songs.map((s) => s.id), [b.id, a.id]);
    lib.update(a.copyWith(status: SongStatus.done, audio: 'audio.wav', duration: 2, liked: true));

    final again = LibraryStore(tmp.path)..load();
    expect(again.songs.map((s) => s.title), ['new', 'old']);
    final old = again.byId(a.id)!;
    expect((old.status, old.audio, old.duration, old.liked), (SongStatus.done, 'audio.wav', 2.0, true));
    expect(old.request.cot, CotMode.full);
  });

  test('blank title falls back to the first lyric line, then to Untitled + date', () {
    final lib = LibraryStore(tmp.path);
    SongRequest req(String lyrics) => SongRequest(style: 's', lyrics: lyrics, cot: CotMode.full, seed: 1);
    final at = DateTime(2026, 11, 20, 12);
    expect(lib.create(request: req('[verse]\n\nSalt and lemon\nsecond'), now: at).title, 'Salt and lemon');
    expect(lib.create(title: '  ', request: req('[inst]'), now: at).title, 'Untitled 2026-11-20');
    expect(lib.create(title: 'Mine', request: req('x'), now: at).title, 'Mine');
  });

  test('new songs get artwork whose motif and hue differ from the three newest', () {
    final lib = LibraryStore(tmp.path);
    for (var i = 0; i < 12; i++) {
      final s = lib.create(title: 't$i', request: _req, now: DateTime.utc(2026, 1, 1 + i));
      expect(s.artwork?.algorithm, 1);
    }
    final p = [for (final s in lib.songs) ArtworkParams.forSpec(s.art)]; // newest first
    for (var i = 0; i + 1 < p.length; i++) {
      expect(p[i].motif, isNot(p[i + 1].motif));
    }
  });

  test('queued/generating left by a dead run become failed', () {
    final lib = LibraryStore(tmp.path);
    final s = lib.create(title: 't', request: _req);
    final again = LibraryStore(tmp.path)..load();
    expect(again.byId(s.id)!.status, SongStatus.failed);
    expect(again.byId(s.id)!.error, isNotNull);
  });
}
