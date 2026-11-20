// End to end: fresh data dir -> setup (fake manifest) -> Create -> generating -> Library done -> like -> rename
// -> play -> Liked filter -> Cover (Free, fake transcribe) -> cover done -> dark theme pass.
// Run through tool/test.sh (Docker, Xvfb). Env: E2E_SHOTS_DIR (PNG output), E2E_SONG_JSON (default reference/song.json),
// YUE2_STUDIO_DATA_DIR (read back meta.json from disk), YUE2_STUDIO_TEST_PICK_FILE (read by the app: Key('cover.pick') uses it).
// Plus the YUE2_STUDIO_* overrides from engine/PROTOCOL.md section 6.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yue2_studio/main.dart' as app;

final _shotsDir = Platform.environment['E2E_SHOTS_DIR'];
final _dataDir = Platform.environment['YUE2_STUDIO_DATA_DIR'];

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

/// Pump in short steps until [cond] holds. No pumpAndSettle: spinners/animations loop forever.
Future<void> waitUntil(
  WidgetTester t,
  bool Function() cond,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) {
      throw TestFailure('timeout (${timeout.inSeconds}s) waiting for: $what');
    }
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> waitFor(
  WidgetTester t,
  Finder f,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) => waitUntil(t, () => f.evaluate().isNotEmpty, what, timeout: timeout);

Future<void> pumpFor(WidgetTester t, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> tapKey(WidgetTester t, String key, {Finder? within}) async {
  final f = within == null
      ? find.byKey(Key(key))
      : find.descendant(of: within, matching: find.byKey(Key(key)));
  await waitFor(t, f, key);
  await t.tap(f.first);
  await t.pump(const Duration(milliseconds: 200));
}

final _row = find.byWidgetPredicate((w) {
  final k = w.key;
  return k is ValueKey<String> && k.value.startsWith('library.item.');
});

List<String> _rowIds() => [
  for (final e in _row.evaluate())
    (e.widget.key! as ValueKey<String>).value.substring('library.item.'.length),
];

Finder _rowOf(String id) => find.byKey(ValueKey('library.item.$id'));

String _textOf(Finder f) {
  if (f.evaluate().isEmpty) return '';
  final w = f.evaluate().first.widget;
  if (w is Text) return w.data ?? w.textSpan?.toPlainText() ?? '';
  return '';
}

/// Lower-cased text of the row's Key('library.status') (the key may sit on the Text or on a wrapper).
String _statusOf(Finder row) {
  final s = find.descendant(
    of: row,
    matching: find.byKey(const Key('library.status')),
  );
  if (s.evaluate().isEmpty) return '';
  final direct = _textOf(s);
  if (direct.isNotEmpty) return direct.toLowerCase();
  final inner = find.descendant(of: s, matching: find.byType(Text));
  return inner.evaluate().isEmpty ? '' : _textOf(inner.first).toLowerCase();
}

bool _allDone(int count) {
  final ids = _rowIds();
  return ids.length == count &&
      ids.every((id) => _statusOf(_rowOf(id)).contains('done'));
}

/// Text in the field behind [key] (TextField, EditableText, or a wrapper around one).
String _fieldText(Finder key) {
  if (key.evaluate().isEmpty) return '';
  final w = key.evaluate().first.widget;
  if (w is TextField) return w.controller?.text ?? '';
  if (w is EditableText) return w.controller.text;
  final inner = find.descendant(of: key, matching: find.byType(EditableText));
  return inner.evaluate().isEmpty
      ? ''
      : (inner.evaluate().first.widget as EditableText).controller.text;
}

Map<String, dynamic>? _meta(String id) {
  final d = _dataDir;
  if (d == null) return null;
  final f = File('$d/library/$id/meta.json');
  return f.existsSync()
      ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
      : null;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'setup -> create -> like/rename/play -> cover -> dark',
    (t) async {
      final songPath =
          Platform.environment['E2E_SONG_JSON'] ?? 'reference/song.json';
      final song =
          jsonDecode(await File(songPath).readAsString())
              as Map<String, dynamic>;
      final style = song['style'] as String, lyrics = song['lyrics'] as String;
      const renamed = 'Neon Rain Renamed';
      addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
      t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

      Future<void> fillCreate() async {
        await t.enterText(find.byKey(const Key('create.style')), style);
        await t.enterText(find.byKey(const Key('create.lyrics')), lyrics);
        await pumpFor(t, const Duration(milliseconds: 300));
      }

      /// Add to Queue, wait for the generation view, let the animation run, then capture mid-run.
      Future<void> generateAndShoot(String name) async {
        await t.tap(find.byKey(const Key('create.generate')));
        await waitFor(
          t,
          find.byKey(const Key('generation.view')),
          'generation.view after Add to Queue',
        );
        await pumpFor(
          t,
          const Duration(milliseconds: 1200),
        ); // YUE2_FAKE_STEP_SECONDS=0.8 in test.sh: job lasts 2+ s
        await shot(t, name);
      }

      try {
        await (app.main as dynamic)();
        await t.pump();

        // 1-2. setup
        await waitFor(
          t,
          find.byKey(const Key('setup.install')),
          'setup.install button',
        );
        await shot(t, '01-setup');
        await t.tap(find.byKey(const Key('setup.install')));
        await pumpFor(t, const Duration(seconds: 2));
        await shot(t, '02-setup-installing');
        await waitFor(
          t,
          find.byKey(const Key('nav.create')),
          'shell (nav.create) after install',
          timeout: const Duration(seconds: 120),
        );

        // 3-4. create -> generating
        await tapKey(t, 'nav.create');
        await pumpFor(t, const Duration(milliseconds: 500));
        await fillCreate();
        await shot(t, '03-create');
        await generateAndShoot('04-generating');

        // 5. library done
        await tapKey(t, 'nav.library');
        await waitFor(t, _row, 'a library.item.<id> row');
        await waitUntil(
          t,
          () => _allDone(1),
          'the song row to reach done',
          timeout: const Duration(seconds: 60),
        );
        await pumpFor(t, const Duration(milliseconds: 500));
        await shot(t, '05-library');
        final id = _rowIds().single;

        // like (state verified in meta.json)
        await tapKey(t, 'library.like', within: _rowOf(id));
        await waitUntil(
          t,
          () => _meta(id)?['liked'] != false,
          'meta.json liked=true',
          timeout: const Duration(seconds: 5),
        );
        if (_meta(id) != null) expect(_meta(id)!['liked'], true);

        // rename: double-tap the title, type, Enter
        final title = find.descendant(
          of: _rowOf(id),
          matching: find.byKey(const Key('library.title')),
        );
        await t.tap(title);
        await t.pump(const Duration(milliseconds: 60));
        await t.tap(title);
        await t.pump(const Duration(milliseconds: 100));
        final field = find.byKey(const Key('library.rename.field'));
        await waitFor(
          t,
          field,
          'library.rename.field after double-tap on the title',
        );
        await t.enterText(field, renamed);
        await t.pump();
        await t.testTextInput.receiveAction(TextInputAction.done);
        await t.pump(const Duration(milliseconds: 200));
        if (field.evaluate().isNotEmpty) {
          await t.sendKeyEvent(
            LogicalKeyboardKey.enter,
          ); // field wired to the key, not to the input action
          await t.pump(const Duration(milliseconds: 200));
        }
        await waitUntil(
          t,
          () => field.evaluate().isEmpty && _textOf(title) == renamed,
          'row title "$renamed"',
          timeout: const Duration(seconds: 5),
        );
        if (_meta(id) != null) expect(_meta(id)!['title'], renamed);
        await shot(t, '06-library-liked-renamed');

        // play: the player bar shows the title; toggle pauses then resumes
        await tapKey(t, 'library.play', within: _rowOf(id));
        await waitFor(t, find.byKey(const Key('player.bar')), 'player.bar');
        await pumpFor(t, const Duration(milliseconds: 600));
        expect(_textOf(find.byKey(const Key('player.title'))), renamed);
        await shot(t, '07-player');
        await tapKey(t, 'player.toggle');
        await tapKey(t, 'player.toggle');
        expect(find.byKey(const Key('player.bar')), findsOneWidget);

        // Liked filter shows the song
        await tapKey(t, 'nav.liked');
        await waitFor(t, _rowOf(id), 'the liked song under nav.liked');
        expect(_row, findsOneWidget);

        // Cover: pick (env path) -> Free -> transcribe (fake) -> style/lyrics -> Add to Queue
        await tapKey(t, 'nav.cover');
        await tapKey(t, 'cover.pick');
        await tapKey(t, 'cover.mode.free');
        await tapKey(t, 'cover.transcribe');
        final score = find.byKey(const Key('cover.score'));
        await waitUntil(
          t,
          () => _fieldText(score).trim().isNotEmpty,
          'cover.score filled by the fake transcription',
        );
        expect(_fieldText(score), contains('X:'));
        await t.enterText(find.byKey(const Key('cover.style')), style);
        await t.enterText(find.byKey(const Key('cover.lyrics')), lyrics);
        await pumpFor(t, const Duration(milliseconds: 300));
        await shot(t, '08-cover-filled');
        await t.tap(find.byKey(const Key('cover.generate')));
        await pumpFor(t, const Duration(milliseconds: 500));

        // the cover lands in the library as a second row, done
        await tapKey(t, 'nav.library');
        await waitUntil(
          t,
          () => _rowIds().length == 2,
          'two library rows (song + cover)',
          timeout: const Duration(seconds: 20),
        );
        await waitUntil(
          t,
          () => _allDone(2),
          'song and cover rows done',
          timeout: const Duration(seconds: 60),
        );
        await pumpFor(t, const Duration(milliseconds: 500));
        await shot(t, '09-library-with-cover');
        final coverId = _rowIds().firstWhere((x) => x != id);
        if (_meta(coverId) != null) expect(_meta(coverId)!['kind'], 'cover');

        // dark theme: Create, generating, Library
        t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await pumpFor(t, const Duration(milliseconds: 600));
        await tapKey(t, 'nav.create');
        await pumpFor(t, const Duration(milliseconds: 500));
        await fillCreate();
        await shot(t, '10-create-dark');
        await generateAndShoot('11-generating-dark');
        await tapKey(t, 'nav.library');
        await waitUntil(
          t,
          () => _allDone(3),
          'three library rows done',
          timeout: const Duration(seconds: 60),
        );
        await pumpFor(t, const Duration(milliseconds: 500));
        await shot(t, '12-library-dark');
      } catch (_) {
        try {
          await shot(t, '99-failure');
        } catch (_) {}
        rethrow;
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
