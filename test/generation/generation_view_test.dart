import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/engine/protocol.dart';
import 'package:yue2_studio/generation/estimator.dart';
import 'package:yue2_studio/generation/generation_view.dart';
import 'package:yue2_studio/library/library_store.dart';
import 'package:yue2_studio/generation/waveform_painter.dart';
import 'package:yue2_studio/library/song.dart';
import 'package:yue2_studio/queue/job_queue.dart';

class FakeQueue extends ChangeNotifier implements JobQueue {
  Song? song;
  String? cancelled;
  @override
  final estimator = GenerationEstimator('/nonexistent');
  @override
  String? stage;
  @override
  int stageDone = 0;
  @override
  int? stageTotal;
  @override
  double progress = 0;
  @override
  Duration? remaining;
  @override
  Song? get running => song;
  @override
  void cancel(String songId) => cancelled = songId;
  void update(VoidCallback f) {
    f();
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _req = SongRequest(style: 's', lyrics: 'l', cot: CotMode.full, seed: 1);

void main() {
  late Directory tmp;
  late LibraryStore lib;
  late FakeQueue q;
  late Song song;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2gen');
    lib = LibraryStore(tmp.path);
    song = lib.create(title: 'City Lights', request: _req);
    q = FakeQueue();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Widget app(Widget child, {bool reduce = false, bool ticking = true}) => MediaQuery(
        data: MediaQueryData(disableAnimations: reduce, size: const Size(900, 700)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: TickerMode(enabled: ticking, child: Theme(data: ThemeData(), child: child)),
        ),
      );

  testWidgets('follows the queue through the stages, then settles and hands off', (tester) async {
    var finished = 0;
    final view = GenerationView(queue: q, library: lib, onFinished: () => finished++);
    await tester.pumpWidget(app(view));
    expect(find.byKey(const Key('generation.view')), findsOneWidget); // idle placeholder
    expect(find.byKey(const Key('generation.cancel')), findsNothing);

    q.update(() {
      q.song = lib.byId(song.id);
      q.stage = 'load';
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Loading model'), findsOneWidget);
    expect(find.text('City Lights'), findsOneWidget);

    for (final (stage, done, total, p, text) in [
      ('abc', 37, null, 0.15, 'Planning score, 50%'), // 'l' is 15 s of audio: 74 abc tokens expected
      ('semantic', 375, null, 0.3, 'Composing melody, 50%'),
      ('nar', 15, 32, 0.7, 'Rendering sound, step 15 of 32'),
      ('vae', 1, 4, 0.97, 'Mastering, step 1 of 4'),
    ]) {
      q.update(() {
        q.stage = stage;
        q.stageDone = done;
        q.stageTotal = total;
        q.progress = p;
        q.remaining = const Duration(seconds: 70);
      });
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('$text · about 1 min 10 s left'), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('generation.cancel')));
    expect(q.cancelled, song.id);

    // completion
    lib.update(lib.byId(song.id)!.copyWith(status: SongStatus.done, audio: 'audio.wav', duration: 70));
    q.update(() => q.song = null);
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(finished, 0);
    await tester.pump(const Duration(seconds: 3));
    expect(finished, 1);
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.binding.transientCallbackCount, 0, reason: 'ring settled: the ticker has stopped');
  });

  testWidgets('ring is 280-320 px at a 1280x720 window, 32 px above the title; done stages carry a check', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    q.song = lib.byId(song.id);
    q.stage = 'nar';
    q.stageDone = 3;
    q.stageTotal = 32;
    q.remaining = const Duration(seconds: 3);
    // sidebar 216 + padding 28*2, header/player bar roughly 72 + 22*2 vertical
    await tester.pumpWidget(app(Padding(padding: const EdgeInsets.fromLTRB(0, 22, 0, 94), child: GenerationView(queue: q, library: lib))));
    await tester.pump(const Duration(milliseconds: 16));
    final ring = tester.getRect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is WaveformPainter));
    expect(ring.width, inInclusiveRange(280, 320));
    expect(tester.getTopLeft(find.text('City Lights')).dy - ring.bottom, closeTo(32, 6));
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(2), reason: 'Score and Melody are done');
    expect(find.text('Rendering sound, step 3 of 32 · a few seconds left'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a job that starts while the previous one wraps up is followed, not handed off', (tester) async {
    var finished = 0;
    await tester.pumpWidget(app(GenerationView(queue: q, library: lib, onFinished: () => finished++)));
    final b = lib.create(title: 'Second', request: _req);
    q.update(() => q.song = lib.byId(song.id));
    lib.update(lib.byId(song.id)!.copyWith(status: SongStatus.done));
    q.update(() => q.song = null);
    await tester.pump(const Duration(seconds: 1));
    q.update(() {
      q.song = lib.byId(b.id);
      q.stage = 'load';
    });
    await tester.pump(const Duration(seconds: 5));
    expect(finished, 0);
    expect(find.text('Second'), findsOneWidget);
    q.update(() => q.song = null); // clean up the pending timers
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('does not tick off-screen', (tester) async {
    q.song = lib.byId(song.id);
    q.stage = 'nar';
    await tester.pumpWidget(app(GenerationView(queue: q, library: lib), ticking: false));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(app(GenerationView(queue: q, library: lib), ticking: true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.transientCallbackCount, greaterThan(0), reason: 'and ticks again once visible');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Reduce Motion: static ring, no ticker, progress still shown', (tester) async {
    q.song = lib.byId(song.id);
    q.stage = 'nar';
    q.progress = 0.5;
    await tester.pumpWidget(app(GenerationView(queue: q, library: lib), reduce: true));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    q.update(() => q.progress = 0.8);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
