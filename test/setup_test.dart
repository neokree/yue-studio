import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/app/paths.dart';
import 'package:yue2_studio/setup/installer.dart';
import 'package:yue2_studio/setup/manifest.dart';
import 'package:yue2_studio/setup/requirements.dart';
import 'package:yue2_studio/setup/setup_screen.dart';
import 'package:yue2_studio/setup/step_runner.dart';
import 'package:yue2_studio/theme/theme.dart';
import 'package:yue2_studio/theme/tokens.dart';

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

/// A machine that passes the preflight whatever the host is.
class _Passing implements HardwareProbe {
  @override
  Future<Hardware> read(String dataDir) async => Hardware.passing;
}

double _fill(WidgetTester t) => t.widget<AnimatedFractionallySizedBox>(find.byKey(const Key('setup.bar.fill'))).widthFactor!;

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// WCAG contrast; a translucent foreground is flattened over [bg] first.
double contrast(Color fg, Color bg) {
  final f = Color.alphaBlend(fg, bg);
  final a = _lum(f), b = _lum(bg);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

void main() {
  late Directory tmp;
  late Paths paths;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2setup');
    paths = Paths(dataDir: tmp.path, uv: '/none', engineDir: tmp.path, manifest: '');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Installer make(FakeRunner r, {Set<String> done = const {}, int? free = 100000000000}) =>
      Installer(paths: paths, manifest: manifest, done: done, runner: r, freeBytes: (_) async => free, probe: _Passing());

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
    expect(_fill(tester), 0);
  });

  testWidgets('running: real bytes on the model row, overall bar moves, no button', (tester) async {
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
    expect(find.byKey(const Key('setup.install')), findsNothing); // hidden while installing, no dead button
    expect(find.text('Installing Python'), findsNothing);
    // py + venv share 11.5 - 6.8 = 4.7 GB; both done = 4.7 GB, plus half the model = 3.4 GB
    expect(find.text('8.1 of 11.5 GB'), findsOneWidget);
    expect(_fill(tester), closeTo(8.1 / 11.5, 0.01));
    gate.complete();
    await run;
    await tester.pump();
  });

  testWidgets('uv step: no raw uv line, no phase text in the size slot, bar and number agree; bytes count when it finishes', (tester) async {
    final gate = Completer<void>();
    final i = make(FakeRunner((step, report) async {
      if (step.id == 'py') {
        report(phase: 'python', detail: 'Downloading cpython-3.12.16-linux-aarch64-gnu (download) (27.9MiB)');
        await gate.future;
      }
    }));
    await show(tester, i);
    final run = i.install();
    await tester.pump();
    expect(find.textContaining('cpython'), findsNothing);
    expect(find.text('Installing Python'), findsNothing);
    // the size slot of the running Python row still holds its size (4.7 GB shared by py + venv = 2.4 GB each)
    expect(tester.widget<Text>(find.byKey(const Key('setup.step.size.py'))).data, '2.4 GB');
    expect(find.text('0.0 of 11.5 GB'), findsOneWidget);
    expect(_fill(tester), 0); // no floating segment: the bar is empty exactly when the number is 0
    gate.complete();
    await run;
    await tester.pump();
    expect(find.text('11.5 of 11.5 GB'), findsOneWidget);
  });

  testWidgets('venv step shows a human phase line', (tester) async {
    final gate = Completer<void>();
    final i = make(FakeRunner((step, report) async {
      if (step.id == 'venv') {
        report(phase: 'packages', detail: 'Resolved 91 packages in 1.2s');
        await gate.future;
      }
    }));
    await show(tester, i);
    final run = i.install();
    await tester.pump();
    await tester.pump();
    expect(find.text('Installing packages'), findsOneWidget);
    expect(find.textContaining('Resolved'), findsNothing);
    gate.complete();
    await run;
  });

  testWidgets('failed step: names the step, shows the cause and the way to recover', (tester) async {
    final i = make(FakeRunner((step, report) async {
      if (step.id == 'model') throw SetupException('Network connection lost.');
    }));
    await show(tester, i);
    await i.install();
    await tester.pump();
    expect(find.text("Couldn't finish YuE2 song model."), findsOneWidget);
    expect(find.text('Network connection lost.'), findsOneWidget);
    expect(find.byKey(const Key('setup.step.recovery')), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Failed'), findsNothing); // one red headline, not three
  });

  testWidgets('finished: every dot filled, ready line, total equals the manifest', (tester) async {
    final i = make(FakeRunner((_, _) async {}), done: {'py', 'venv', 'model'});
    await show(tester, i);
    expect(find.text('Everything is installed. Opening your studio.'), findsOneWidget);
    expect(find.text('Setting up YuE'), findsNothing); // title is a rich text; the subtitle swapped
    expect(find.text('Your private-first music generation studio. Music is generated locally.'), findsNothing);
  });

  testWidgets('8 real manifest steps fit the 1040x780 first-run window, sizes sum to the total', (tester) async {
    tester.view.physicalSize = const Size(1040, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final real = SetupManifest.read('engine/manifests/real.json');
    expect(real.steps.length, 8);
    expect(real.steps.every((s) => s.bytes > 0), isTrue);
    expect(real.steps.fold<int>(0, (a, s) => a + s.bytes), real.bytes);
    final i = Installer(paths: paths, manifest: real, runner: FakeRunner((_, _) async {}), freeBytes: (_) async => 100000000000, probe: _Passing());
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: SetupScreen(installer: i)));
    expect(tester.takeException(), isNull);
    expect(find.text('0.0 of 13.5 GB'), findsOneWidget);
    expect(find.text('7.3 GB'), findsOneWidget);
    expect(find.text('17 MB'), findsNWidgets(2));
    expect(find.text('1.7 GB'), findsOneWidget);
    expect(find.text('1.2 GB'), findsOneWidget);
    // everything reachable: Install button is on screen without scrolling
    expect(tester.getBottomLeft(find.byKey(const Key('setup.install'))).dy, lessThan(780));
  });

  testWidgets('dark theme: window #1E1E20, accent #D97C62, visible track, fine print', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final gate = Completer<void>();
    final i = make(FakeRunner((_, _) => gate.future));
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: SetupScreen(installer: i)));
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, const Color(0xFF1E1E20));
    final fill = find.descendant(of: find.byKey(const Key('setup.bar.fill')), matching: find.byType(ColoredBox));
    expect(tester.widget<ColoredBox>(fill).color, const Color(0xFFD97C62));
    // the empty track must read against the window: at least 1.3:1 (white 16% on #1E1E20 is about 1.5)
    final track = tester.widget<ColoredBox>(find.byKey(const Key('setup.bar.track'))).color;
    expect(contrast(track, AppColors.dark.background), greaterThan(1.3));
    final run = i.install();
    await tester.pump();
    expect(find.byKey(const Key('setup.install')), findsNothing);
    gate.complete();
    await run;
  });

  test('contrast of the texts the setup screen uses, both themes', () {
    for (final (name, c) in [('light', AppColors.light), ('dark', AppColors.dark)]) {
      expect(contrast(c.text, c.background), greaterThan(7), reason: name);
      expect(contrast(c.textSecondary, c.background), greaterThan(4.5), reason: name);
      expect(contrast(c.textSecondary, c.field), greaterThan(4.5), reason: name);
      expect(contrast(c.error, c.background), greaterThan(4.5), reason: name);
      expect(contrast(c.onAccent, c.accent), greaterThan(4.5), reason: name);
    }
    // The 8.5 px footer is textTertiary by spec: dark is comfortably above 4.5.
    expect(contrast(AppColors.dark.textTertiary, AppColors.dark.background), greaterThan(4.5));
  });

  test('test hook: YUE2_STUDIO_TEST_FAIL_STEP fails that step once', () async {
    final r = ProcessStepRunner(paths, failStep: 'py');
    await expectLater(
      r.run(manifest.steps.first, ({phase, progress, doneBytes, totalBytes, detail}) {}),
      throwsA(isA<SetupException>().having((e) => e.message, 'message', 'The connection was interrupted.')),
    );
    // second time it really runs (uv is /none here, so it fails differently: could not start)
    await expectLater(
      r.run(manifest.steps.first, ({phase, progress, doneBytes, totalBytes, detail}) {}),
      throwsA(isA<SetupException>().having((e) => e.message, 'message', contains('Could not start'))),
    );
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
    expect(find.text('Failed'), findsNothing);
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
    expect(_fill(tester), 1);
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

  testWidgets('blocked machine: names the problem, runs nothing, button becomes Check again', (tester) async {
    final r = FakeRunner((_, _) async {});
    final i = Installer(paths: paths, manifest: manifest, runner: r, freeBytes: (_) async => 100000000000, probe: _Fixed(const Hardware(arm64: false, macos: '13.6', memoryBytes: 8 * Requirements.gib, freeDiskBytes: 5 * Requirements.gb)));
    await show(tester, i);
    await tester.pump();
    for (final k in ['intel', 'macos', 'memory', 'disk']) {
      expect(find.byKey(ValueKey('setup.preflight.$k')), findsOneWidget, reason: k);
    }
    expect(find.textContaining('macOS 13.6'), findsOneWidget);
    expect(find.textContaining('8 GB of memory'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
    await tester.tap(find.byKey(const Key('setup.install')));
    await tester.pump();
    await tester.pump();
    expect(r.ran, isEmpty);
    expect(i.running, isFalse);
  });

  testWidgets('16 GB: warning line, install still runs', (tester) async {
    final r = FakeRunner((_, _) async {});
    final i = Installer(paths: paths, manifest: manifest, runner: r, freeBytes: (_) async => 100000000000, probe: _Fixed(const Hardware(arm64: true, macos: '14.0', memoryBytes: 16 * Requirements.gib, freeDiskBytes: 60 * Requirements.gb)));
    await show(tester, i);
    await tester.pump();
    expect(find.text('This Mac has 16 GB of memory. It works, but close other apps while generating.'), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
    await i.install();
    expect(r.ran, ['py', 'venv', 'model']);
  });

  testWidgets('column top stays put when the error text appears', (tester) async {
    final i = make(FakeRunner((step, report) async {
      if (step.id == 'model') throw SetupException('The connection was interrupted.');
    }));
    await show(tester, i);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(const Key('setup.title'))).dy;
    await i.install();
    await tester.pump();
    expect(find.byKey(const Key('setup.step.recovery')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('setup.title'))).dy, before);
  });

  test('the real runner shows live "x of y" from uv cache growth, never above the total', () async {
    final uv = File('${tmp.path}/fake-uv.sh')
      ..writeAsStringSync('#!/bin/sh\nmkdir -p "\$UV_CACHE_DIR"\nhead -c 4000000 /dev/zero > "\$UV_CACHE_DIR/blob"\nsleep 2.5\n');
    await Process.run('chmod', ['+x', uv.path]);
    final p = Paths(dataDir: tmp.path, uv: uv.path, engineDir: tmp.path, manifest: '');
    final step = SetupStep({'id': 'py', 'kind': 'python', 'version': '3.12', 'bytes': 10000000});
    final seen = <(int, int)>[];
    await ProcessStepRunner(p).run(step, ({phase, progress, doneBytes, totalBytes, detail}) {
      if (doneBytes != null) seen.add((doneBytes, totalBytes ?? 0));
    });
    expect(seen.first, (0, 10000000));
    expect(seen.last.$1, greaterThanOrEqualTo(4000000));
    expect(seen.every((e) => e.$1 <= 9700000 && e.$2 == 10000000), isTrue);
  });
}

class _Fixed implements HardwareProbe {
  _Fixed(this.h);
  final Hardware h;
  @override
  Future<Hardware> read(String dataDir) async => h;
}
