// Captures the setup states a reviewer needs: mid-install with finished (filled) steps, dark, error, low disk, requirements page.
// Only runs with B_SHOTS_DIR=<dir>; Roboto stands in for the system font.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/app/paths.dart';
import 'package:yue2_studio/setup/installer.dart';
import 'package:yue2_studio/setup/manifest.dart';
import 'package:yue2_studio/setup/requirements.dart';
import 'package:yue2_studio/setup/requirements_gate.dart';
import 'package:yue2_studio/setup/setup_screen.dart';
import 'package:yue2_studio/setup/step_runner.dart';
import 'package:yue2_studio/theme/theme.dart';

final _dir = Platform.environment['B_SHOTS_DIR'];

class _Runner implements StepRunner {
  _Runner(this.onRun);
  final Future<void> Function(SetupStep, StepReport) onRun;
  @override
  Future<void> run(SetupStep step, StepReport report) => onRun(step, report);
}

class _Probe implements HardwareProbe {
  _Probe(this.h);
  final Hardware h;
  @override
  Future<Hardware> read(String dataDir) async => h;
}

void main() {
  late Directory tmp;
  late Paths paths;
  final key = GlobalKey();

  setUpAll(() async {
    final dir = '${Platform.environment['HOME']}/.fvm/versions/3.44.3/bin/cache/artifacts/material_fonts';
    final l = FontLoader('Roboto')..addFont(File('$dir/Roboto-Regular.ttf').readAsBytes().then((b) => b.buffer.asByteData()));
    await l.load();
  });
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2setupshots');
    paths = Paths(dataDir: tmp.path, uv: '/none', engineDir: tmp.path, manifest: '');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> shot(WidgetTester t, String name) async {
    await t.pump(const Duration(milliseconds: 600));
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 2);
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
      File('$_dir/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes.buffer.asUint8List());
    });
  }

  Future<void> show(WidgetTester t, Installer i, Brightness b) async {
    t.view.physicalSize = const Size(1040, 780);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.platformBrightnessTestValue = b;
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    final base = buildTheme(b);
    await t.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'Roboto')),
        home: SetupScreen(installer: i),
      ),
    ));
    await t.pump();
  }

  Installer make(Future<void> Function(SetupStep, StepReport) onRun, {Hardware hw = Hardware.passing}) => Installer(
        paths: paths,
        manifest: SetupManifest.read('engine/manifests/real.json'),
        runner: _Runner(onRun),
        freeBytes: (_) async => 100000000000,
        probe: _Probe(hw),
      );

  for (final (name, b) in [('setup-installing', Brightness.light), ('setup-installing-dark', Brightness.dark)]) {
    testWidgets(name, (t) async {
      final gate = Completer<void>();
      final i = make((step, report) async {
        if (step.kind != 'hf') return; // Python and the environment finish at once, the first model download is caught half way
        report(progress: 0.43, doneBytes: (step.bytes * 0.43).round(), totalBytes: step.bytes);
        await gate.future;
      });
      await show(t, i, b);
      unawaited(i.install());
      await t.pump();
      await t.pump();
      await shot(t, name);
      gate.complete();
      await t.pump();
    }, skip: _dir == null);
  }

  testWidgets('setup-error', (t) async {
    final i = make((step, report) async {
      if (step.kind == 'hf') throw SetupException('The connection was interrupted.');
    });
    await show(t, i, Brightness.light);
    await i.install();
    await t.pump();
    await shot(t, 'setup-error');
  }, skip: _dir == null);

  testWidgets('setup-blocked: low disk', (t) async {
    final blocked = make((_, _) async {}, hw: const Hardware(memoryBytes: 32 * Requirements.gib, freeDiskBytes: 9 * Requirements.gb));
    await show(t, blocked, Brightness.light);
    await t.pump();
    await shot(t, 'setup-blocked');
  }, skip: _dir == null);

  // The requirements page (DESIGN.md screen 0): 8 GB has no button, 16 GB has "Try anyway".
  for (final gb in [8, 16]) {
    for (final b in [Brightness.light, Brightness.dark]) {
      testWidgets('requirements ${gb}gb ${b.name}', (t) async {
        t.view.physicalSize = const Size(1040, 780);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        t.platformDispatcher.platformBrightnessTestValue = b;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        final base = buildTheme(b);
        await t.pumpWidget(RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'Roboto')),
            home: RequirementsScreen(memoryGb: gb.toDouble(), onTryAnyway: gb >= Requirements.minMemoryGb ? () {} : null),
          ),
        ));
        await t.pump();
        await shot(t, 'requirements-${gb}gb-${b.name}');
      }, skip: _dir == null);
    }
  }
}
