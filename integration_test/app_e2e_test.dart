// End to end: fresh data dir -> setup (forced error, Retry) -> empty Library -> Create (title) -> generating -> like -> rename
// -> play -> Liked filter -> 3 queued jobs -> Cover (Free, fake transcribe) -> 6 songs -> dark theme pass.
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
final _clock = Stopwatch()..start();
void lap(String what) => print('LAP ${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s $what'); // ignore: avoid_print

Future<void> shot(WidgetTester t, String name) async {
  final dir = _shotsDir;
  if (dir == null || dir.isEmpty) return;
  lap(name);
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

/// One animation settle (AnimatedSwitcher / theme cross-fade are ~200-300 ms); the only fixed wait besides the generation capture.
Future<void> settle(WidgetTester t) => pumpFor(t, const Duration(milliseconds: 320));

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
  await t.pump(const Duration(milliseconds: 80));
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

/// All Key('library.status') texts of the visible rows, lower-cased.
List<String> _statuses() => [for (final id in _rowIds()) _statusOf(_rowOf(id))];

/// Label of the FilledButton behind Key('setup.install') ("Install", "Installing", "Retry") and whether it is enabled.
({String label, bool enabled}) _installButton() {
  final b = find.byKey(const Key('setup.install'));
  if (b.evaluate().isEmpty) return (label: '', enabled: false);
  final txt = find.descendant(of: b, matching: find.byType(Text));
  final label = txt.evaluate().isEmpty ? '' : _textOf(txt.first);
  final w = b.evaluate().first.widget;
  return (label: label, enabled: w is ButtonStyleButton && w.onPressed != null);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'setup (error, retry) -> create -> queue -> like/rename/play -> cover -> dark',
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

      Future<void> setDark(bool dark) async {
        t.platformDispatcher.platformBrightnessTestValue =
            dark ? Brightness.dark : Brightness.light;
        await settle(t);
      }

      /// Title field (C1 / E: Key('create.title') and Key('cover.title')); warns instead of failing while a track lags.
      Future<void> typeTitle(String key, String title) async {
        final f = find.byKey(Key(key));
        if (f.evaluate().isEmpty) {
          // ignore: avoid_print
          print('WARN: Key("$key") not found, title not typed');
          return;
        }
        await t.enterText(f, title);
      }

      Future<void> fillCreate(String title) async {
        await typeTitle('create.title', title);
        await t.enterText(find.byKey(const Key('create.style')), style);
        await t.enterText(find.byKey(const Key('create.lyrics')), lyrics);
        await t.pump(const Duration(milliseconds: 80));
      }

      /// Sidebar Create: Create clicked from the generation view returns to the form, so wait for the form's own fields.
      Future<void> openCreate() async {
        await tapKey(t, 'nav.create');
        await waitFor(t, find.byKey(const Key('create.style')), 'create form (create.style) after nav.create');
      }

      /// Add to Queue, wait for the generation view, let the animation run, then capture mid-run.
      Future<void> generateAndShoot(String name) async {
        await t.tap(find.byKey(const Key('create.generate')));
        await waitFor(
          t,
          find.byKey(const Key('generation.view')),
          'generation.view after Add to Queue',
        );
        await pumpFor(t, const Duration(milliseconds: 700)); // job lasts ~2 s at YUE2_FAKE_STEP_SECONDS=0.4: capture mid-run
        await shot(t, name);
      }

      try {
        await (app.main as dynamic)();
        await t.pump();

        // 1. setup: light, dark
        await waitFor(
          t,
          find.byKey(const Key('setup.install')),
          'setup.install button',
        );
        final installLabel = _installButton().label;
        await settle(t);
        await shot(t, '01-setup');
        await setDark(true);
        await shot(t, '01b-setup-dark');
        await setDark(false);

        // 2. first attempt fails at the first step (YUE2_STUDIO_TEST_FAIL_STEP), shoot the error, Retry (B's hook: the step fails only once)
        await t.tap(find.byKey(const Key('setup.install')));
        await waitUntil(
          t,
          () => _installButton().enabled && _installButton().label != installLabel,
          'setup error state (button back to Retry)',
          timeout: const Duration(seconds: 60),
        );
        await settle(t);
        await shot(t, '02b-setup-error');
        await t.tap(find.byKey(const Key('setup.install')));
        // Retry is running: the button is disabled while installing; capture right away .
        await waitUntil(t, () => !_installButton().enabled, 'setup installing state (button disabled)', timeout: const Duration(seconds: 10));
        lap('install running');
        await pumpFor(t, const Duration(milliseconds: 1200)); // python (instant) is done, the venv step sleeps 2.5 s in tool/e2e-uv.sh
        await shot(t, '02-setup-installing');
        await waitFor(
          t,
          find.byKey(const Key('nav.create')),
          'shell (nav.create) after install',
          timeout: const Duration(seconds: 120),
        );
        lap('shell visible');

        // 3. empty library
        await tapKey(t, 'nav.library');
        await settle(t);
        expect(_row, findsNothing);
        await shot(t, '00-library-empty');

        // 4. create (with a title) -> generating
        await openCreate();
        await settle(t);
        await fillCreate('Neon Rain');
        await shot(t, '03-create');
        await generateAndShoot('04-generating');

        // 5. first song done: like, rename, play
        await tapKey(t, 'nav.library');
        await waitFor(t, _row, 'a library.item.<id> row');
        await waitUntil(
          t,
          () => _allDone(1),
          'the song row to reach done',
          timeout: const Duration(seconds: 60),
        );
        await settle(t);
        final id = _rowIds().single;

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
          await t.sendKeyEvent(LogicalKeyboardKey.enter); // field wired to the key, not to the input action
          await t.pump(const Duration(milliseconds: 200));
        }
        await waitUntil(
          t,
          () => field.evaluate().isEmpty && _textOf(title) == renamed,
          'row title "$renamed"',
          timeout: const Duration(seconds: 5),
        );
        if (_meta(id) != null) expect(_meta(id)!['title'], renamed);

        // play: the player bar shows the title; light + dark shots, toggle pauses then resumes
        await tapKey(t, 'library.play', within: _rowOf(id));
        await waitFor(t, find.byKey(const Key('player.bar')), 'player.bar');
        await settle(t);
        expect(_textOf(find.byKey(const Key('player.title'))), renamed);
        await shot(t, '07-player');
        await setDark(true);
        await shot(t, '07b-player-dark');
        await setDark(false);
        await tapKey(t, 'player.toggle');
        await tapKey(t, 'player.toggle');
        expect(find.byKey(const Key('player.bar')), findsOneWidget);

        // Liked filter shows the (renamed) song
        await tapKey(t, 'nav.liked');
        await waitFor(t, _rowOf(id), 'the liked song under nav.liked');
        expect(_row, findsOneWidget);
        await settle(t);
        await shot(t, '06-library-liked');

        // 6. three jobs queued back to back: one runs, two wait
        for (var i = 1; i <= 3; i++) {
          await openCreate();
          await fillCreate('Night Drive $i');
          await t.tap(find.byKey(const Key('create.generate')));
          await waitFor(t, find.byKey(const Key('generation.view')), 'generation.view (queued job $i)');
        }
        await tapKey(t, 'nav.library');
        await waitUntil(
          t,
          () => _statuses().any((s) => s.contains('queued')) && _statuses().any((s) => s.contains('generating')),
          'library: one running, at least one queued',
          timeout: const Duration(seconds: 5),
        );
        final st = _statuses();
        // ignore: avoid_print
        print('statuses while queued: $st');
        await shot(t, '05-library-running-queued');
        await waitUntil(
          t,
          () => _allDone(4),
          'four rows done',
          timeout: const Duration(seconds: 90),
        );

        // 7. Cover: pick (env path) -> Free -> transcribe (fake) -> title/style/lyrics -> shots -> Add to Queue
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
        await typeTitle('cover.title', 'Neon Rain (cover)');
        await t.enterText(find.byKey(const Key('cover.style')), style);
        await t.enterText(find.byKey(const Key('cover.lyrics')), lyrics);
        await t.pump(const Duration(milliseconds: 80));
        await shot(t, '08-cover-filled');
        await setDark(true);
        await shot(t, '08b-cover-dark');
        await setDark(false);
        await t.tap(find.byKey(const Key('cover.generate')));
        await t.pump(const Duration(milliseconds: 80));

        // the cover lands in the library as a fifth row, done
        await tapKey(t, 'nav.library');
        await waitUntil(
          t,
          () => _rowIds().length == 5,
          'five library rows (4 songs + cover)',
          timeout: const Duration(seconds: 20),
        );
        await waitUntil(
          t,
          () => _allDone(5),
          'all five rows done',
          timeout: const Duration(seconds: 60),
        );
        await settle(t);
        await shot(t, '09-library-with-cover');
        if (_dataDir != null) {
          final kinds = [for (final x in _rowIds()) _meta(x)?['kind']];
          expect(kinds.where((k) => k == 'cover').length, 1, reason: 'one cover row: $kinds');
        }

        // 8. dark pass: Create, generating (sixth song), Library with six songs; then the same Library in light
        await setDark(true);
        await openCreate();
        await settle(t);
        await fillCreate('Glass Harbour');
        await shot(t, '10-create-dark');
        await generateAndShoot('11-generating-dark');
        await tapKey(t, 'nav.library');
        await waitUntil(
          t,
          () => _allDone(6),
          'six library rows done',
          timeout: const Duration(seconds: 60),
        );
        await settle(t);
        await shot(t, '12-library-dark');
        await setDark(false);
        await shot(t, '05b-library-artwork');
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