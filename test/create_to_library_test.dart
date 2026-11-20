import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/app/app.dart';
import 'package:yue2_studio/app/paths.dart';
import 'package:yue2_studio/app/services.dart';
import 'package:yue2_studio/engine/fake_engine.dart';
import 'package:yue2_studio/library/library_store.dart';
import 'package:yue2_studio/queue/job_queue.dart';
import 'package:yue2_studio/setup/installer.dart';
import 'package:yue2_studio/setup/manifest.dart';

void main() {
  testWidgets('Create -> Library shows the song as done', (t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final tmp = Directory.systemTemp.createTempSync('yue2w');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final paths = Paths(dataDir: tmp.path, uv: 'uv', engineDir: tmp.path, manifest: '', copyAssets: false);
    final engine = FakeEngine();
    final library = LibraryStore(paths.libraryDir);
    final services = Services(
      installer: Installer(paths: paths, manifest: SetupManifest(name: 'empty', bytes: 0, steps: [])),
      library: library,
      queue: JobQueue(engine: engine, library: library),
      engine: engine,
    );

    await t.pumpWidget(StudioApp(services: services));
    await t.enterText(find.byKey(const Key('create.style')), 'warm piano pop');
    await t.enterText(find.byKey(const Key('create.lyrics')), '[Verse]\nNeon fades along the lane');
    await t.pump();
    await t.tap(find.byKey(const Key('create.generate')));
    await t.pump();
    await t.pump();

    await t.tap(find.byKey(const Key('nav.library')));
    await t.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('library.item.')), findsOneWidget);
    expect(find.text('Neon fades along the lane'), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const Key('library.status'))).data, 'Done');
  });
}
