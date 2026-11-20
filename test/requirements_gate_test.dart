import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/app/paths.dart';
import 'package:yue2_studio/setup/installer.dart';
import 'package:yue2_studio/setup/manifest.dart';
import 'package:yue2_studio/setup/requirements.dart';
import 'package:yue2_studio/setup/requirements_gate.dart';
import 'package:yue2_studio/theme/theme.dart';

class _Probe implements HardwareProbe {
  _Probe(this.h);
  final Hardware h;
  @override
  Future<Hardware> read(String dataDir) async => h;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('yue2gate'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Installer installer(Hardware h) => Installer(
        paths: Paths(dataDir: '${tmp.path}/data', uv: '/none', engineDir: tmp.path, manifest: ''),
        manifest: SetupManifest.fromJson({
          'name': 't',
          'bytes': 1,
          'steps': [
            {'id': 'py', 'kind': 'python', 'label': 'Python', 'version': '3.12'}
          ],
        }),
        probe: _Probe(h),
      );

  Hardware mem(double? gb) => gb == null ? const Hardware() : Hardware(memoryBytes: (gb * Requirements.gib).round(), freeDiskBytes: 100 * Requirements.gb);

  Future<Installer> show(WidgetTester t, double? gb) async {
    final i = installer(mem(gb));
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: RequirementsGate(installer: i, child: const Text('SETUP', key: Key('the.setup')))));
    await t.pump();
    return i;
  }

  final page = find.byKey(const Key('requirements.statement'));
  final button = find.byKey(const Key('requirements.tryAnyway'));
  final setup = find.byKey(const Key('the.setup'));

  testWidgets('8 GB: page with the amount, no button, no way to setup', (t) async {
    await show(t, 8);
    expect(page, findsOneWidget);
    expect(tester(t, 'requirements.amount'), '8 GB');
    expect(button, findsNothing);
    expect(setup, findsNothing);
    expect(find.text('Your Mac has'), findsOneWidget);
  });

  testWidgets('16 GB: page, Try anyway opens setup and is remembered', (t) async {
    final i = await show(t, 16);
    expect(page, findsOneWidget);
    expect(tester(t, 'requirements.amount'), '16 GB');
    expect(button, findsOneWidget);
    expect(setup, findsNothing);
    await t.tap(button);
    await t.pump();
    expect(setup, findsOneWidget);
    expect(page, findsNothing);
    expect(ackFile(i.paths.dataDir).existsSync(), isTrue);
  });

  testWidgets('16 GB after an earlier Try anyway: page skipped, straight to setup', (t) async {
    ackFile('${tmp.path}/data')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"acknowledged":true}');
    await show(t, 16);
    expect(page, findsNothing);
    expect(setup, findsOneWidget);
  });

  testWidgets('under 16 GB the ack does not let you through', (t) async {
    ackFile('${tmp.path}/data')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"acknowledged":true}');
    await show(t, 8);
    expect(page, findsOneWidget);
    expect(setup, findsNothing);
  });

  testWidgets('23 GB: still the page with the button', (t) async {
    await show(t, 23);
    expect(page, findsOneWidget);
    expect(button, findsOneWidget);
  });

  testWidgets('24 GB: no page, setup', (t) async {
    await show(t, 24);
    expect(page, findsNothing);
    expect(setup, findsOneWidget);
  });

  testWidgets('unknown memory: no page, setup', (t) async {
    await show(t, null);
    expect(page, findsNothing);
    expect(setup, findsOneWidget);
  });

  testWidgets('the page says YuE with a superscript 2 and no stray "YuE2 Studio"', (t) async {
    await show(t, 8);
    expect(find.byKey(const Key('requirements.title')), findsOneWidget);
    expect(find.textContaining('YuE2 Studio', findRichText: true), findsNothing);
    expect(find.textContaining('needs at least 24 GB of RAM to work properly', findRichText: true), findsOneWidget);
    expect(find.textContaining('minimum requirements not met', findRichText: true), findsOneWidget);
  });
}

String? tester(WidgetTester t, String key) => t.widget<Text>(find.byKey(Key(key))).data;
