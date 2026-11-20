import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

const _req = SongRequest(style: 'warm piano pop', lyrics: 'la la', cot: CotMode.full, seed: 1);

void main() {
  late Directory tmp;
  late LibraryStore lib;
  late PlayerController player;
  late JobQueue queue;
  late Song done, queued, generating, failed;
  Song? reused;
  var wentCreate = 0;

  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Column(children: [
          Expanded(
            child: LibraryScreen(library: lib, queue: queue, player: player, onReuse: (s) => reused = s, onGoCreate: () => wentCreate++),
          ),
          PlayerBar(player: player, library: lib),
        ]),
      ),
    ));
  }

  Finder row(Song s) => find.byKey(ValueKey('library.item.${s.id}'));
  Finder inRow(Song s, Key k) => find.descendant(of: row(s), matching: find.byKey(k));
  String statusOf(WidgetTester t, Song s) => t.widget<Text>(inRow(s, const Key('library.status'))).data!;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2screen');
    lib = LibraryStore(tmp.path);
    Song mk(String title, DateTime at, SongStatus st, {String? audio, double? dur, String? err}) {
      final s = lib.create(title: title, request: _req, now: at);
      lib.update(s.copyWith(status: st, audio: audio, duration: dur, error: err));
      return lib.byId(s.id)!;
    }

    done = mk('Done song', DateTime.utc(2026, 1, 1), SongStatus.done, audio: 'audio.wav', dur: 64);
    failed = mk('Broken song', DateTime.utc(2026, 1, 2), SongStatus.failed, err: 'Out of memory');
    queued = mk('Queued song', DateTime.utc(2026, 1, 3), SongStatus.queued);
    generating = mk('Running song', DateTime.utc(2026, 1, 2, 12), SongStatus.generating);
    File('${lib.dirOf(done.id)}/audio.wav').writeAsStringSync('x');
    player = PlayerController(backend: FakeBackend(), library: lib);
    queue = JobQueue(engine: FakeEngine(auto: false), library: lib);
    reused = null;
    wentCreate = 0;
  });
  tearDown(() {
    player.dispose();
    queue.dispose();
    tmp.deleteSync(recursive: true);
  });

  testWidgets('rows: running and queued first with status, failed shows the error and offers delete', (t) async {
    await pump(t);
    final order = [for (final s in [generating, queued, failed, done]) t.getTopLeft(row(s)).dy];
    expect(order, [...order]..sort());
    expect(statusOf(t, generating), 'Generating');
    expect(statusOf(t, queued), 'Queued');
    expect(statusOf(t, done), 'Done');
    expect(statusOf(t, failed), 'Failed');
    expect(find.text('Out of memory'), findsOneWidget);
    expect(inRow(failed, const Key('library.delete')), findsOneWidget);
    expect(inRow(done, const Key('library.play')), findsOneWidget);
    expect(inRow(queued, const Key('library.play')), findsNothing);
    expect(find.text('1:04'), findsOneWidget);
    expect(find.text('warm piano pop'), findsNWidgets(3)); // the failed row shows its error instead
  });

  testWidgets('like toggles and the Liked filter hides the rest', (t) async {
    await pump(t);
    await t.tap(inRow(done, const Key('library.like')));
    await t.pump();
    expect(lib.byId(done.id)!.liked, true);
    await t.tap(find.byKey(const Key('library.filter.liked')));
    await t.pump();
    expect(row(done), findsOneWidget);
    expect(row(queued), findsNothing);
    await t.tap(find.byKey(const Key('library.filter.all')));
    await t.pump();
    expect(row(queued), findsOneWidget);
  });

  testWidgets('double tap title renames inline: Enter commits, Esc cancels', (t) async {
    await pump(t);
    await t.tap(inRow(done, const Key('library.title')));
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(inRow(done, const Key('library.title')));
    await t.pump();
    expect(find.byKey(const Key('library.rename.field')), findsOneWidget);
    await t.enterText(find.byKey(const Key('library.rename.field')), 'Cancelled name');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byKey(const Key('library.rename.field')), findsNothing);
    expect(lib.byId(done.id)!.title, 'Done song');

    await t.tap(inRow(done, const Key('library.title')));
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(inRow(done, const Key('library.title')));
    await t.pump();
    await t.enterText(find.byKey(const Key('library.rename.field')), 'Fresh title');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(lib.byId(done.id)!.title, 'Fresh title');
    expect(find.text('Fresh title'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 500)); // let the double-tap timers expire
  });

  testWidgets('menu: reuse calls back, delete asks first then removes the folder', (t) async {
    await pump(t);
    await t.tap(inRow(done, const Key('library.more')));
    await t.pumpAndSettle();
    await t.tap(find.text('Reuse Style and Lyrics'));
    await t.pumpAndSettle();
    expect(reused?.id, done.id);

    await t.tap(inRow(done, const Key('library.more')));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('library.delete.dialog')), findsOneWidget);
    expect(row(done), findsOneWidget); // nothing deleted before confirmation
    await t.tap(find.byKey(const Key('library.delete.confirm')));
    await t.pumpAndSettle();
    expect(row(done), findsNothing);
    expect(Directory(lib.dirOf(done.id)).existsSync(), false);
  });

  testWidgets('right click opens the context menu', (t) async {
    await pump(t);
    final g = await t.startGesture(t.getCenter(row(done)), kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await g.up();
    await t.pumpAndSettle();
    expect(find.text('Export Audio'), findsOneWidget);
    expect(find.text('Show Score'), findsOneWidget);
  });

  testWidgets('play shows the player bar with the song, toggle pauses', (t) async {
    await pump(t);
    expect(find.text('Nothing playing'), findsOneWidget);
    await t.tap(inRow(done, const Key('library.play')));
    await t.pump();
    expect(player.current?.id, done.id);
    expect(t.widget<Text>(find.byKey(const Key('player.title'))).data, 'Done song');
    await t.tap(find.byKey(const Key('player.toggle')));
    await t.pump();
    expect(player.playing, false);
  });

  testWidgets('empty library points to Create; empty Liked offers All', (t) async {
    for (final s in [...lib.songs]) {
      lib.delete(s.id);
    }
    await pump(t);
    expect(find.text('No songs yet. Create one.'), findsOneWidget);
    await t.tap(find.byKey(const Key('library.empty.create')));
    expect(wentCreate, 1);
    lib.setLikedOnly(true);
    await t.pump();
    expect(find.text('No liked songs yet'), findsOneWidget);
  });
}
