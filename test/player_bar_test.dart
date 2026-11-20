import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/engine/protocol.dart';
import 'package:yue2_studio/library/library_store.dart';
import 'package:yue2_studio/library/song.dart';
import 'package:yue2_studio/player/player_bar.dart';
import 'package:yue2_studio/player/player_controller.dart';
import 'package:yue2_studio/theme/theme.dart';
import 'package:yue2_studio/theme/tokens.dart';

import 'player_controller_test.dart' show FakeBackend;

void main() {
  late Directory tmp;
  late LibraryStore lib;
  late FakeBackend fake;
  late PlayerController pl;
  late Song song;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2bar');
    lib = LibraryStore(tmp.path);
    fake = FakeBackend();
    pl = PlayerController(backend: fake, library: lib);
    final s = lib.create(
      title: 'Warm piano',
      request: const SongRequest(style: 'English, warm piano pop, expressive vocal, 80 bpm', lyrics: 'la', cot: CotMode.full, seed: 1),
    );
    lib.update(s.copyWith(status: SongStatus.done, audio: 'a.wav', duration: 2));
    song = lib.byId(s.id)!;
  });
  tearDown(() {
    pl.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester t, Brightness b) async {
    t.view.physicalSize = const Size(1000, 200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.platformBrightnessTestValue = b;
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(b),
      home: Scaffold(body: Column(children: [const Spacer(), PlayerBar(player: pl, library: lib)])),
    ));
  }

  testWidgets('nothing playing: neutral placeholder, transport and scrubber disabled', (t) async {
    await pump(t, Brightness.light);
    expect(find.text('Nothing playing'), findsOneWidget);
    expect(t.widget<IconButton>(find.byKey(const Key('player.toggle'))).onPressed, isNull);
    expect(t.widget<Slider>(find.byKey(const Key('player.scrubber'))).onChanged, isNull);
    expect(t.widget<Text>(find.byKey(const Key('player.elapsed'))).data, '–:––');
  });

  testWidgets('elapsed label and thumb share one position; subtitle is short style + length', (t) async {
    await pump(t, Brightness.light);
    await pl.play(song);
    fake.dur.add(const Duration(seconds: 2));
    fake.pos.add(const Duration(milliseconds: 760)); // 38% of 2 s
    await t.pump();
    expect(t.widget<Slider>(find.byKey(const Key('player.scrubber'))).value, closeTo(.38, 1e-9));
    expect(t.widget<Text>(find.byKey(const Key('player.elapsed'))).data, '0:01'); // 0.76 s rounds to 1, never "0:00" at 38%
    expect(t.widget<Text>(find.byKey(const Key('player.total'))).data, '0:02');
    expect(t.widget<Text>(find.byKey(const Key('player.subtitle'))).data, 'English, warm piano pop, expressive vocal · 0:02');
  });

  for (final b in Brightness.values) {
    testWidgets('scrubber fill and thumb use the accent, transport shares one vertical centre (${b.name})', (t) async {
      await pump(t, b);
      await pl.play(song);
      fake.dur.add(const Duration(seconds: 2));
      await t.pump();
      expect(t.widget<Slider>(find.byKey(const Key('player.scrubber'))).onChanged, isNotNull);
      final c = b == Brightness.dark ? AppColors.dark : AppColors.light;
      final theme = t.widget<SliderTheme>(find.descendant(of: find.byKey(const Key('player.bar')), matching: find.byType(SliderTheme)).first).data;
      expect(theme.activeTrackColor, c.accent);
      expect(theme.thumbColor, c.accent);
      final mid = [
        for (final f in [find.byTooltip('Previous'), find.byKey(const Key('player.toggle')), find.byTooltip('Next')]) t.getCenter(f).dy,
      ];
      expect(mid.toSet().length, 1);
      expect(t.getCenter(find.byKey(const Key('player.bar'))).dy, closeTo(mid.first, 1)); // 1 px top separator
    });
  }
}
