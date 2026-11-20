import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/app/app.dart';
import 'package:yue2_studio/app/paths.dart';
import 'package:yue2_studio/app/services.dart';
import 'package:yue2_studio/engine/fake_engine.dart';
import 'package:yue2_studio/engine/protocol.dart';
import 'package:yue2_studio/generation/estimator.dart';
import 'package:yue2_studio/library/library_store.dart';
import 'package:yue2_studio/queue/job_queue.dart';
import 'package:yue2_studio/setup/installer.dart';
import 'package:yue2_studio/setup/manifest.dart';

void main() {
  late Directory tmp;
  late FakeEngine engine;
  late Services s;

  Future<void> boot(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    tmp = Directory.systemTemp.createTempSync('yue2sc');
    final paths = Paths(dataDir: tmp.path, uv: 'uv', engineDir: tmp.path, manifest: '', copyAssets: false);
    engine = FakeEngine(auto: false);
    final library = LibraryStore(paths.libraryDir);
    final estimator = GenerationEstimator(tmp.path);
    s = Services(
      installer: Installer(paths: paths, manifest: SetupManifest(name: 'empty', bytes: 0, steps: [])),
      library: library,
      queue: JobQueue(engine: engine, library: library, estimator: estimator),
      engine: engine,
      estimator: estimator,
    );
    await t.pumpWidget(StudioApp(services: s));
    await t.pumpAndSettle();
  }

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // temp dir
    }
  });

  testWidgets('Add to Queue shows the generation, sidebar follows the job, Create returns to the form', (t) async {
    await boot(t);
    final add = find.byKey(const Key('create.generate'));
    expect(t.widget<FilledButton>(add).onPressed, isNull, reason: 'needs style and lyrics');
    expect(find.textContaining('~ '), findsOneWidget, reason: 'estimate, never a static string');

    await t.enterText(find.byKey(const Key('create.style')), 'warm piano pop');
    await t.enterText(find.byKey(const Key('create.lyrics')), '[Verse]\nNeon fades along the lane');
    await t.enterText(find.byKey(const Key('create.seed')), '42');
    await t.pump();
    await t.tap(add);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));

    final job = engine.sent.whereType<GenerateRequest>().single;
    expect((job.style, job.cot, job.seed), ('warm piano pop', CotMode.full, 42));
    expect(find.byKey(const Key('generation.view')), findsOneWidget);
    expect(s.queue.running?.title, 'Neon fades along the lane');

    engine.emit(ProgressEvent(job: job.job, stage: 'nar', done: 15, total: 32));
    await t.pump();
    expect(find.textContaining('step 15 of 32'), findsWidgets, reason: 'sidebar and generation view');
    expect(find.text('Neon fades along the lane'), findsWidgets);

    await t.tap(find.byKey(const Key('nav.create')));
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('generation.view')), findsNothing);
    expect(find.byKey(const Key('create.generate')), findsOneWidget);
    expect(s.createDraft.style.text, 'warm piano pop', reason: 'the form keeps its content to queue variants');

    engine.emit(ResultEvent(job: job.job, dir: job.out, audio: 'audio.wav', seed: 42, duration: 2));
    await t.pump(const Duration(seconds: 5));
    expect(find.text('Nothing in the queue'), findsOneWidget);
  });

  testWidgets('queue panel reopens the generation view from Library, inert when idle', (t) async {
    await boot(t);
    expect(find.byKey(const Key('queue.open')), findsNothing, reason: 'idle: not clickable');
    s.queue.enqueueGenerate(style: 'pop', lyrics: '[Verse] Neon fades', cot: 'full');
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.byKey(const Key('nav.library')));
    await t.pump(const Duration(milliseconds: 600)); // a running job never settles
    expect(find.byKey(const Key('generation.view')), findsNothing);

    await t.tap(find.byKey(const Key('queue.open')));
    await t.pump(const Duration(milliseconds: 600));
    expect(s.nav.value, Section.create);
    expect(find.byKey(const Key('generation.view')), findsOneWidget);
    expect(find.bySemanticsLabel('Show generation progress'), findsOneWidget);

    final job = engine.sent.whereType<GenerateRequest>().single;
    engine.emit(ResultEvent(job: job.job, dir: job.out, audio: 'audio.wav', seed: 1, duration: 2));
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('Title field names the song; empty falls back to the first lyric line without its tag, then to Untitled', (t) async {
    await boot(t);
    expect(find.byKey(const Key('create.title')), findsOneWidget);
    await t.enterText(find.byKey(const Key('create.title')), '  City Lights ');
    await t.enterText(find.byKey(const Key('create.style')), 'pop');
    await t.enterText(find.byKey(const Key('create.lyrics')), '[Verse] Neon fades');
    await t.pump();
    await t.tap(find.byKey(const Key('create.generate')));
    await t.pump();
    expect(s.library.songs.single.title, 'City Lights');

    s.queue.enqueueGenerate(style: 'pop', lyrics: '[Verse] Neon fades\nline two', cot: 'full');
    s.queue.enqueueGenerate(style: 'ambient', lyrics: '', cot: 'off');
    final titles = s.library.songs.map((x) => x.title).toList();
    expect(titles, contains('Neon fades'));
    expect(titles.where((x) => x.startsWith('Untitled ')), hasLength(1));
    for (var i = 1; i <= 3; i++) {
      await t.pump(const Duration(milliseconds: 500));
      final job = engine.sent.whereType<GenerateRequest>().elementAt(i - 1);
      engine.emit(ResultEvent(job: job.job, dir: job.out, audio: 'audio.wav', seed: 1, duration: 2));
    }
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('sidebar: Liked is Library filtered, prefill switches to Create', (t) async {
    await boot(t);
    await t.tap(find.byKey(const Key('nav.liked')));
    await t.pumpAndSettle();
    expect((s.nav.value, s.library.likedOnly), (Section.library, true));
    await t.tap(find.byKey(const Key('nav.library')));
    await t.pumpAndSettle();
    expect((s.nav.value, s.library.likedOnly), (Section.library, false));

    s.createDraft.prefill(style: 'jazz', lyrics: 'la la', cot: 'melody');
    await t.pumpAndSettle();
    expect(s.nav.value, Section.create);
    expect(s.createDraft.cot, CotMode.melody);
    expect(find.text('jazz'), findsOneWidget);
  });
}
