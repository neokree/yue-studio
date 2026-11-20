// End to end: fresh data dir -> setup (fake manifest) -> Create -> Library shows "done".
// Run through tool/test.sh (Docker, Xvfb). Env: E2E_SHOTS_DIR (PNG output), E2E_SONG_JSON (default reference/song.json).
// Plus the YUE2_STUDIO_* overrides from engine/PROTOCOL.md section 6.
//
// TODO(M2): after "library done" add, in this order:
//   - tap the like button on the row, assert the liked state changes (and "liked only" filter keeps the row)
//   - rename the song (long press / menu -> dialog), assert the new title shows in the row
//   - tap play, assert the player bar appears and the position advances (audioplayers_linux + GStreamer)
//   - (M3) cover: upload a wav, transcribe in fake mode, generate, expect a second row
// Shared keys to add for those steps need to be agreed with the library track first.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yue2_studio/main.dart' as app;

final _shotsDir = Platform.environment['E2E_SHOTS_DIR'];

Future<void> shot(WidgetTester t, String name) async {
  final dir = _shotsDir;
  if (dir == null || dir.isEmpty) return;
  await t.pump(const Duration(milliseconds: 50));
  final el = find.byKey(const Key('app.screenshot')).evaluate().first;
  final boundary = el.renderObject! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: 1);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

/// Pump in short steps until [f] matches. No pumpAndSettle: spinners/animations loop forever.
Future<void> waitFor(WidgetTester t, Finder f, String what,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (f.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) {
      throw TestFailure('timeout (${timeout.inSeconds}s) waiting for: $what');
    }
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> pumpFor(WidgetTester t, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

final _row = find.byWidgetPredicate((w) {
  final k = w.key;
  return k is ValueKey<String> && k.value.startsWith('library.item.');
});

String _statusText(WidgetTester t) {
  final s = find.byKey(const Key('library.status'));
  if (s.evaluate().isEmpty) return '';
  final w = s.evaluate().first.widget;
  if (w is Text) return (w.data ?? w.textSpan?.toPlainText() ?? '').toLowerCase();
  final inner = find.descendant(of: s, matching: find.byType(Text));
  if (inner.evaluate().isEmpty) return '';
  return (t.widget<Text>(inner.first).data ?? '').toLowerCase();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('setup -> create -> library done', (t) async {
    final songPath = Platform.environment['E2E_SONG_JSON'] ?? 'reference/song.json';
    final song = jsonDecode(await File(songPath).readAsString()) as Map<String, dynamic>;

    try {
      await (app.main as dynamic)();
      await t.pump();

      // 1. setup screen
      await waitFor(t, find.byKey(const Key('setup.install')), 'setup.install button');
      await shot(t, '01-setup');

      // 2. install (fake manifest: uv installs Python 3.12, so this takes a while)
      await t.tap(find.byKey(const Key('setup.install')));
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, '02-install');
      await waitFor(t, find.byKey(const Key('nav.create')), 'shell (nav.create) after install',
          timeout: const Duration(seconds: 120));

      // 3. create
      await t.tap(find.byKey(const Key('nav.create')));
      await pumpFor(t, const Duration(milliseconds: 500));
      await t.enterText(find.byKey(const Key('create.style')), song['style'] as String);
      await t.enterText(find.byKey(const Key('create.lyrics')), song['lyrics'] as String);
      await pumpFor(t, const Duration(milliseconds: 300));
      await shot(t, '03-create-filled');

      // 4. generate
      await t.tap(find.byKey(const Key('create.generate')));
      await pumpFor(t, const Duration(milliseconds: 500));
      await shot(t, '04-generating');

      // 5. library
      await t.tap(find.byKey(const Key('nav.library')));
      await waitFor(t, _row, 'a library.item.<id> row');
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (!_statusText(t).contains('done')) {
        if (DateTime.now().isAfter(end)) {
          throw TestFailure('library.status never reached done, last: "${_statusText(t)}"');
        }
        await t.pump(const Duration(milliseconds: 200));
      }
      await pumpFor(t, const Duration(milliseconds: 500));
      await shot(t, '05-library-done');
      expect(_row, findsOneWidget);
    } catch (_) {
      try {
        await shot(t, '99-failure');
      } catch (_) {}
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
