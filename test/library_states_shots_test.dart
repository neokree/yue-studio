// Captures the Library and player states a reviewer needs (running + queued rows, Liked filter, both empty states,
// player bar light/dark, artwork variety). Only runs with D_SHOTS_DIR=<dir>; Roboto stands in for the system font.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/artwork/artwork.dart';
import 'package:yue2_studio/engine/fake_engine.dart';
import 'package:yue2_studio/engine/protocol.dart';
import 'package:yue2_studio/library/library_screen.dart';
import 'package:yue2_studio/library/library_store.dart';
import 'package:yue2_studio/library/song.dart';
import 'package:yue2_studio/player/player_bar.dart';
import 'package:yue2_studio/player/player_controller.dart';
import 'package:yue2_studio/queue/job_queue.dart';
import 'package:yue2_studio/theme/theme.dart';

import 'player_controller_test.dart' show FakeBackend;

final _dir = Platform.environment['D_SHOTS_DIR'];

void main() {
  late Directory tmp;
  late LibraryStore lib;
  late FakeBackend fake;
  late PlayerController player;
  late JobQueue queue;
  final key = GlobalKey();

  // One seed per motif (first found) plus one more, so every motif and hue pair shows up.
  List<int> seeds() {
    final byMotif = <Motif, int>{};
    for (var s = 0; byMotif.length < Motif.values.length; s++) {
      byMotif.putIfAbsent(ArtworkParams.v1(s).motif, () => s);
    }
    return [...byMotif.values, 977, 31337, 2026];
  }

  Future<void> shot(WidgetTester t, String name) async {
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 2);
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
      File('$_dir/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes.buffer.asUint8List());
    });
  }

  Future<void> pump(WidgetTester t, Brightness b, {bool bar = true}) async {
    t.view.physicalSize = const Size(1000, 560);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.platformBrightnessTestValue = b;
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    final base = buildTheme(b);
    await t.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'Roboto')),
        home: Scaffold(
          body: Column(children: [
            Expanded(child: LibraryScreen(library: lib, queue: queue, player: player)),
            if (bar) PlayerBar(player: player, library: lib),
          ]),
        ),
      ),
    ));
  }

  setUpAll(() async {
    // Real glyphs instead of the Ahem boxes flutter_test draws by default (fonts from the fvm SDK cache).
    final dir = '${Platform.environment['HOME']}/.fvm/versions/3.44.3/bin/cache/artifacts/material_fonts';
    Future<ByteData> load(String f) async => ByteData.sublistView(await File('$dir/$f').readAsBytes());
    for (final (family, files) in [('Roboto', ['Roboto-Regular.ttf']), ('MaterialIcons', ['MaterialIcons-Regular.otf'])]) {
      final l = FontLoader(family);
      for (final f in files) {
        l.addFont(load(f));
      }
      await l.load();
    }
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2shots');
    lib = LibraryStore(tmp.path);
    fake = FakeBackend();
    player = PlayerController(backend: fake, library: lib);
    queue = JobQueue(engine: FakeEngine(auto: false), library: lib);
  });
  tearDown(() {
    player.dispose();
    queue.dispose();
    tmp.deleteSync(recursive: true);
  });

  Song mk(String title, String style, int seed, int day, SongStatus st, {double? dur, bool liked = false}) {
    final s = lib.create(title: title, request: SongRequest(style: style, lyrics: 'la', cot: CotMode.full, seed: seed), now: DateTime.utc(2026, 11, day));
    lib.update(s.copyWith(status: st, audio: st == SongStatus.done ? 'a.wav' : null, duration: dur, liked: liked, artwork: ArtworkSpec(seed: seed)));
    if (st == SongStatus.done) File('${lib.dirOf(s.id)}/a.wav').writeAsStringSync('x');
    return lib.byId(s.id)!;
  }

  void fill() {
    final sd = seeds();
    mk('Queued: city lights', 'synthwave, female vocal, 110 bpm, nostalgic, neon', sd[0], 19, SongStatus.queued);
    mk('Generating: harbour', 'folk, acoustic guitar, male vocal, calm', sd[1], 18, SongStatus.generating);
    final names = ['Warm piano pop', 'Rainy tram', 'Paper moons', 'Salt and lemon', 'Night shift', 'Second light'];
    final styles = [
      'English, warm piano pop, expressive vocal, 80 bpm, reverb, intimate',
      'indie rock, male vocal, driving drums',
      'ambient, instrumental, pads',
      'italian pop, female vocal, upbeat',
      'jazz, trio, brushed drums, late night',
      'electronic, dreamy, vocal chops'
    ];
    for (var i = 0; i < 6; i++) {
      mk(names[i], styles[i], sd[2 + i], 17 - i, SongStatus.done, dur: 64.0 + i * 31, liked: i == 0 || i == 3);
    }
  }

  final skip = _dir == null ? 'set D_SHOTS_DIR to capture' : null;

  testWidgets('library light, running + queued on top, nothing playing', (t) async {
    fill();
    await pump(t, Brightness.light);
    await shot(t, 'library-light-idle');
  }, skip: skip != null);

  testWidgets('library dark with player, Liked filter, empty states', (t) async {
    fill();
    await pump(t, Brightness.dark);
    final done = lib.songs.firstWhere((s) => s.status == SongStatus.done);
    await player.play(done);
    fake.dur.add(const Duration(seconds: 64));
    fake.pos.add(const Duration(seconds: 24));
    await shot(t, 'library-dark-playing');
    lib.setLikedOnly(true);
    await shot(t, 'library-dark-liked');
    await pump(t, Brightness.light);
    await player.stop();
    await shot(t, 'library-light-liked-idle');
    for (final s in [...lib.songs]) {
      s.status == SongStatus.done ? lib.toggleLike(s.id) : null;
    }
    lib.setLikedOnly(true);
    for (final s in [...lib.songs]) {
      if (s.liked) lib.toggleLike(s.id);
    }
    await shot(t, 'library-light-empty-liked');
    for (final s in [...lib.songs]) {
      lib.delete(s.id);
    }
    lib.setLikedOnly(false);
    await shot(t, 'library-light-empty');
  }, skip: skip != null);

  testWidgets('player bar light and dark, playing at 38%', (t) async {
    fill();
    final done = lib.songs.firstWhere((s) => s.status == SongStatus.done);
    for (final b in Brightness.values) {
      await pump(t, b);
      await player.play(done);
      fake.dur.add(const Duration(seconds: 64));
      fake.pos.add(const Duration(milliseconds: 24300));
      await shot(t, 'player-${b.name}');
    }
  }, skip: skip != null);
}
