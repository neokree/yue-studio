import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/engine/protocol.dart';
import 'package:yue2_studio/library/library_store.dart';
import 'package:yue2_studio/library/song.dart';
import 'package:yue2_studio/player/player_controller.dart';

class FakeBackend implements PlayerBackend {
  final pos = StreamController<Duration>.broadcast(sync: true);
  final dur = StreamController<Duration>.broadcast(sync: true);
  final done = StreamController<void>.broadcast(sync: true);
  final log = <String>[];
  @override
  Stream<Duration> get position => pos.stream;
  @override
  Stream<Duration> get duration => dur.stream;
  @override
  Stream<void> get completed => done.stream;
  @override
  Future<void> play(String path) async => log.add('play ${path.split('/').last}');
  @override
  Future<void> pause() async => log.add('pause');
  @override
  Future<void> resume() async => log.add('resume');
  @override
  Future<void> seek(Duration to) async => log.add('seek ${to.inSeconds}');
  @override
  Future<void> stop() async => log.add('stop');
  @override
  Future<void> dispose() async {}
}

const _req = SongRequest(style: 's', lyrics: 'l', cot: CotMode.full, seed: 1);

void main() {
  late Directory tmp;
  late LibraryStore lib;
  late FakeBackend fake;
  late PlayerController pl;
  late List<Song> songs; // newest first: c, b, a

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2pl');
    lib = LibraryStore(tmp.path);
    fake = FakeBackend();
    pl = PlayerController(backend: fake, library: lib);
    songs = [];
    for (var i = 1; i <= 3; i++) {
      final s = lib.create(title: 't$i', request: _req, now: DateTime.utc(2026, 1, i));
      lib.update(s.copyWith(status: SongStatus.done, audio: 'audio$i.wav', duration: 10));
      songs.add(lib.byId(s.id)!);
    }
  });
  tearDown(() {
    pl.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('play, toggle, seek, position and duration from the backend', () async {
    await pl.play(songs[0]); // t1, the oldest = last in the list
    expect((pl.current!.title, pl.playing), ('t1', true));
    expect(fake.log.single, 'play audio1.wav');
    fake.pos.add(const Duration(seconds: 3));
    fake.dur.add(const Duration(seconds: 12));
    expect((pl.position.inSeconds, pl.duration.inSeconds), (3, 12));
    await pl.toggle();
    expect(pl.playing, false);
    await pl.toggle();
    expect(pl.playing, true);
    await pl.seek(const Duration(seconds: 5));
    expect(fake.log.skip(1), ['pause', 'resume', 'seek 5']);
  });

  test('next/previous walk library.visible; completion advances; liked filter respected', () async {
    final newest = lib.visible.first; // t3
    await pl.play(newest);
    await pl.next();
    expect(pl.current!.title, 't2');
    fake.done.add(null); // finished -> next
    await Future<void>.delayed(Duration.zero);
    expect(pl.current!.title, 't1');
    expect(pl.hasNext, false);
    fake.done.add(null); // last song finished: stops advancing
    expect((pl.current!.title, pl.playing), ('t1', false));
    await pl.previous(); // position past 3 s? no, at the end -> restart then
    expect(fake.log.last, startsWith('seek'));
    pl.position = Duration.zero;
    await pl.previous();
    expect(pl.current!.title, 't2');

    lib.toggleLike(songs[1].id); // only t2 liked
    lib.setLikedOnly(true);
    await pl.play(lib.visible.single);
    await pl.next();
    expect(pl.current!.title, 't2');
  });

  test('deleting the playing song stops the player; renaming updates it', () async {
    await pl.play(songs[0]);
    lib.rename(songs[0].id, 'new name');
    expect(pl.current!.title, 'new name');
    lib.delete(songs[0].id);
    expect((pl.current, pl.playing), (null, false));
    expect(fake.log.last, 'stop');
  });

  test('a song without audio is ignored', () async {
    final q = lib.create(title: 'q', request: _req);
    await pl.play(q);
    expect(pl.current, null);
  });
}
