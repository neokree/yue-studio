import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yue2_studio/artwork/artwork.dart';
import 'package:yue2_studio/engine/protocol.dart';
import 'package:yue2_studio/library/library_store.dart';
import 'package:yue2_studio/library/song.dart';

const _req = SongRequest(style: 's', lyrics: 'l', cot: CotMode.full, seed: 1);

void main() {
  late Directory tmp;
  late LibraryStore lib;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2ops');
    lib = LibraryStore(tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('rename trims, ignores empty, persists', () {
    final s = lib.create(title: 'a', request: _req);
    lib.rename(s.id, '  Better  ');
    lib.rename(s.id, '   ');
    expect(lib.byId(s.id)!.title, 'Better');
    expect((LibraryStore(tmp.path)..load()).byId(s.id)!.title, 'Better');
  });

  test('like toggles, likedOnly filters visible, counts', () {
    final a = lib.create(title: 'a', request: _req, now: DateTime.utc(2026, 1, 1));
    final b = lib.create(title: 'b', request: _req, now: DateTime.utc(2026, 1, 2));
    lib.toggleLike(a.id);
    expect((lib.count, lib.likedCount), (2, 1));
    expect(lib.visible.map((s) => s.id), [b.id, a.id]);
    var notified = 0;
    lib.addListener(() => notified++);
    lib.setLikedOnly(true);
    lib.setLikedOnly(true);
    expect(notified, 1);
    expect(lib.visible.map((s) => s.id), [a.id]);
    lib.toggleLike(a.id);
    expect(lib.visible, isEmpty);
    expect((LibraryStore(tmp.path)..load()).byId(a.id)!.liked, false);
  });

  test('delete removes the folder and the row, other songs untouched', () {
    final a = lib.create(title: 'a', request: _req);
    final b = lib.create(title: 'b', request: _req);
    File(p.join(lib.dirOf(a.id), 'audio.wav')).writeAsStringSync('x');
    lib.delete(a.id);
    expect(Directory(lib.dirOf(a.id)).existsSync(), false);
    expect(lib.songs.map((s) => s.id), [b.id]);
    expect(Directory(lib.dirOf(b.id)).existsSync(), true);
  });

  test('exportAudio copies the file', () async {
    final a = lib.create(title: 'a', request: _req);
    File(p.join(lib.dirOf(a.id), 'audio.flac')).writeAsStringSync('sound');
    final done = a.copyWith(audio: 'audio.flac');
    lib.update(done);
    final dest = p.join(tmp.path, 'out.flac');
    await lib.exportAudio(done, dest);
    expect(File(dest).readAsStringSync(), 'sound');
    expect(() => lib.exportAudio(lib.create(title: 'n', request: _req), dest), throwsStateError);
  });

  test('create assigns artwork {algorithm 1, seed}; it survives reload, updates and other songs', () {
    final a = lib.create(title: 'a', request: _req);
    final spec = a.artwork!;
    expect(spec.algorithm, 1);
    final raw = jsonDecode(File(p.join(lib.dirOf(a.id), 'meta.json')).readAsStringSync()) as Map;
    expect(raw['artwork'], {'algorithm': 1, 'seed': spec.seed});
    lib.update(a.copyWith(status: SongStatus.done, title: 'renamed'));
    lib.create(title: 'b', request: _req);
    lib.delete(lib.songs.first.id);
    expect((LibraryStore(tmp.path)..load()).byId(a.id)!.artwork, spec);
  });

  test('song without artwork gets seed = FNV-1a of id, persisted on load', () {
    final a = lib.create(title: 'old', request: _req);
    final f = File(p.join(lib.dirOf(a.id), 'meta.json'));
    final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>..remove('artwork');
    f.writeAsStringSync(jsonEncode(m));
    final again = LibraryStore(tmp.path)..load();
    expect(again.byId(a.id)!.artwork, ArtworkSpec(seed: fnv1a32(a.id)));
    expect((jsonDecode(f.readAsStringSync()) as Map)['artwork'], {'algorithm': 1, 'seed': fnv1a32(a.id)});
  });
}
