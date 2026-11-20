import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/app/paths.dart';
import 'package:yue2_studio/setup/installer.dart';
import 'package:yue2_studio/setup/manifest.dart';
import 'package:yue2_studio/setup/setup_screen.dart';
import 'package:yue2_studio/setup/step_runner.dart';
import 'package:yue2_studio/theme/theme.dart';

/// Records the steps it ran; [onRun] decides what each one does.
class FakeRunner implements StepRunner {
  FakeRunner(this.onRun);
  final Future<void> Function(SetupStep step, StepReport report) onRun;
  final ran = <String>[];

  @override
  Future<void> run(SetupStep step, StepReport report) {
    ran.add(step.id);
    return onRun(step, report);
  }
}

final manifest = SetupManifest.fromJson({
  'name': 't',
  'bytes': 11500000000,
  'steps': [
    {'id': 'py', 'kind': 'python', 'label': 'Python 3.12', 'version': '3.12'},
    {'id': 'venv', 'kind': 'venv', 'label': 'Engine environment', 'name': 'yue2', 'python': '3.12', 'packages': []},
    {'id': 'model', 'kind': 'hf', 'label': 'YuE2 song model', 'repo': 'x/y', 'bytes': 6800000000, 'venv': 'yue2'},
  ],
});

void main() {
  late Directory tmp;
  late Paths paths;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2setup');
    paths = Paths(dataDir: tmp.path, uv: '/none', engineDir: tmp.path, manifest: '');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Installer make(FakeRunner r, {Set<String> done = const {}, int? free = 100000000000}) =>
      Installer(paths: paths, manifest: manifest, done: done, runner: r, freeBytes: (_) async => free);

  Future<void> show(WidgetTester tester, Installer i) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: SetupScreen(installer: i)));
  }

  testWidgets('fresh: every step waiting, total 0 of 11.5 GB, fine print, Install button', (tester) async {
    await show(tester, make(FakeRunner((_, _) async {})));
    expect(find.byKey(const Key('setup.install')), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
    expect(find.text('Python 3.12'), findsOneWidget);
    expect(find.text('6.8 GB'), findsOneWidget);
    expect(find.text('0.0 of 11.5 GB'), findsOneWidget);
    expect(find.text('Unofficial client, not affiliated with the YuE2 authors.'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byKey(const Key('setup.bar'))).value, 0);
  });

  testWidgets('running: real bytes on the model row, overall bar moves, button disabled', (tester) async {
    final gate = Completer<void>();
    final i = make(FakeRunner((step, report) async {
      if (step.id != 'model') return;
      report(phase: 'connecting');
      report(progress: 0.5, doneBytes: 3400000000, totalBytes: 6800000000);
      await gate.future;
    }));
    await show(tester, i);
    final run = i.install();
    await tester.pump();
    await tester.pump();
    expect(find.text('3.4 of 6.8 GB'), findsOneWidget);
    expect(find.text('Installing...'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('setup.install'))).onPressed, isNull);
    // py + venv share 11.5 - 6.8 = 4.7 GB; both done = 4.7 GB, plus half the model = 3.4 GB
    expect(find.text('8.1 of 11.5 GB'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byKey(const Key('setup.bar'))).value, closeTo(8.1 / 11.5, 0.01));
    gate.complete();
    await run;
    await tester.pump();
  });

  testWidgets('indeterminate step shows its phase and last output line', (tester) async {
    final gate = Completer<void>();
    final i = make(FakeRunner((step, report) async {
      if (step.id == 'py') {
        report(phase: 'python', detail: 'Downloading cpython-3.12');
        await gate.future;
      }
    }));
    await show(tester, i);
    final run = i.install();
    await tester.pump();
    expect(find.text('Installing Python'), findsOneWidget);
    expect(find.text('Downloading cpython-3.12'), findsOneWidget);
    gate.complete();
    await run;
  });

  testWidgets('failed step shows its message, Retry resumes from it and skips finished steps', (tester) async {
    var fail = true;
    final r = FakeRunner((step, report) async {
      if (step.id == 'venv' && fail) throw SetupException('pip exited with code 1.\nno matching distribution');
    });
    final i = make(r);
    await show(tester, i);
    await i.install();
    await tester.pump();
    expect(r.ran, ['py', 'venv']);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.textContaining('no matching distribution'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(File(paths.setupState).readAsStringSync(), contains('py'));

    fail = false;
    await tester.tap(find.byKey(const Key('setup.install')));
    await tester.pump();
    await tester.pump();
    expect(r.ran, ['py', 'venv', 'venv', 'model']);
    expect(i.complete, isTrue);
    await tester.pump();
    expect(find.byKey(const Key('setup.install')), findsNothing);
  });

  testWidgets('done: bar full, total equals the manifest, no button', (tester) async {
    final i = make(FakeRunner((_, _) async {}), done: {'py', 'venv', 'model'});
    await show(tester, i);
    expect(i.complete, isTrue);
    expect(find.text('11.5 of 11.5 GB'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byKey(const Key('setup.bar'))).value, 1);
    expect(find.byKey(const Key('setup.install')), findsNothing);
  });

  testWidgets('disk full: names how much is needed and never starts', (tester) async {
    final r = FakeRunner((_, _) async {});
    final i = make(r, free: 4100000000);
    await show(tester, i);
    await i.install();
    await tester.pump();
    expect(r.ran, isEmpty);
    // 11.5 GB + 2 GB margin = 13.5 GB needed
    expect(find.textContaining('13.5 GB'), findsOneWidget);
    expect(find.textContaining('4.1 GB'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  test('disk check counts only what is left, resume after finished steps', () async {
    final r = FakeRunner((_, _) async {});
    // py + venv done: remaining is the 6.8 GB model + 2 GB margin = 8.8 GB
    final i = make(r, done: {'py', 'venv'}, free: 8700000000);
    await i.install();
    expect(i.diskShort?.need, 8800000000);
    expect(r.ran, isEmpty);
  });
}
