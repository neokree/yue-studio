import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/app/app.dart';
import 'package:yue2_studio/app/paths.dart';
import 'package:yue2_studio/app/services.dart';
import 'package:yue2_studio/engine/fake_engine.dart';
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

  testWidgets('bottom row does not overflow at the narrowest window and the ring follows focus', (t) async {
    await boot(t);
    t.view.physicalSize = const Size(900, 700);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    final rings = find.byWidgetPredicate(
        (w) => w is AnimatedContainer && ((w.decoration as BoxDecoration?)?.boxShadow?.any((s) => s.spreadRadius == 3) ?? false));
    expect(rings, findsNothing);
    await t.tap(find.byKey(const Key('create.lyrics')));
    await t.pump(const Duration(milliseconds: 300));
    expect(rings, findsOneWidget);
    await t.enterText(find.byKey(const Key('create.seed')), '42');
    expect(t.takeException(), isNull);
  });
}
