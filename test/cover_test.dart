import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/cover/cover_screen.dart';
import 'package:yue2_studio/library/song.dart';
import 'package:yue2_studio/queue/job_queue.dart';

const _abc = 'X:1\nK:C\n"Am"A2 c2 | "F"A2 f2 |]\n';

class _FakeQueue extends Fake implements JobQueue {
  final transcribed = <(String, String)>[];
  final enqueued = <Map<String, Object?>>[];
  Object? failWith;

  @override
  Future<String> transcribe(String audioPath, String mode) async {
    transcribed.add((audioPath, mode));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (failWith != null) throw failWith!;
    return _abc;
  }

  @override
  String enqueueGenerate({
    required String style,
    required String lyrics,
    required String cot,
    int? seed,
    String? abc,
    String? title,
    SongKind kind = SongKind.song,
    double? sourceSeconds,
  }) {
    enqueued.add({'style': style, 'lyrics': lyrics, 'cot': cot, 'abc': abc, 'kind': kind, 'sourceSeconds': sourceSeconds, 'seed': seed});
    return 'id1';
  }
}

/// 2 s of silence, 8 kHz mono 16-bit.
File _wav(Directory d) {
  const rate = 8000, n = rate * 2;
  final b = BytesBuilder();
  void s(String x) => b.add(x.codeUnits);
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  s('RIFF'); u32(36 + n * 2); s('WAVE'); s('fmt '); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
  s('data'); u32(n * 2); b.add(Uint8List(n * 2));
  return File('${d.path}/take.wav')..writeAsBytesSync(b.toBytes());
}

void main() {
  test('helpers', () {
    expect(formatLength(72), '1:12');
    expect(formatLength(null), '—');
    expect(formatBytes(2 * 1024 * 1024 + 700 * 1024), '2.7 MB');
  });

  testWidgets('cover flow: pick, transcribe, mode clears score, validate, enqueue', (t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final tmp = Directory.systemTemp.createTempSync('yue2cover');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final wav = _wav(tmp);
    final q = _FakeQueue();

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CoverScreen(
          queue: q,
          estimate: ({required String lyrics, double? sourceSeconds}) => const Duration(seconds: 100),
          picker: () async => wav.path,
        ),
      ),
    ));
    expect(find.text('About 1 min 40 s on this Mac'), findsOneWidget);

    // missing file
    await t.tap(find.byKey(const Key('cover.generate')));
    await t.pump();
    expect(find.text('Choose a recording first.'), findsOneWidget);

    // pick: name, size, length
    await t.tap(find.byKey(const Key('cover.pick')));
    for (var i = 0; i < 20 && !t.widget<Text>(find.byKey(const Key('cover.filemeta'))).data!.contains(':'); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // real file I/O
      await t.pump();
    }
    expect(find.text('take.wav'), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const Key('cover.filemeta'))).data, contains('0:02'));

    // missing score
    await t.tap(find.byKey(const Key('cover.generate')));
    await t.pump();
    expect(find.text('Transcribe the recording or paste a score first.'), findsOneWidget);

    // transcribe (Free by default -> melody)
    await t.tap(find.byKey(const Key('cover.transcribe')));
    await t.pump();
    expect(find.text('Transcribing, this takes about a minute.'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 100));
    expect(t.widget<TextField>(find.byKey(const Key('cover.score'))).controller!.text, _abc);
    expect(q.transcribed.single, (wav.path, 'melody'));

    // changing the mode clears the score
    await t.tap(find.byKey(const Key('cover.mode.close')));
    await t.pump();
    expect(t.widget<TextField>(find.byKey(const Key('cover.score'))).controller!.text, isEmpty);

    // a failed transcription names the problem
    q.failWith = Exception('no melody found');
    await t.tap(find.byKey(const Key('cover.transcribe')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('no melody found'), findsOneWidget);
    q.failWith = null;

    // pasting your own score works, then style is required
    await t.enterText(find.byKey(const Key('cover.score')), _abc);
    await t.tap(find.byKey(const Key('cover.generate')));
    await t.pump();
    expect(find.text('Describe the new style first.'), findsOneWidget);

    await t.enterText(find.byKey(const Key('cover.style')), 'acoustic folk');
    await t.enterText(find.byKey(const Key('cover.lyrics')), '[Verse]\nHello');
    await t.enterText(find.byKey(const Key('cover.seed')), '42');
    await t.tap(find.byKey(const Key('cover.generate')));
    await t.pump();
    final call = q.enqueued.single;
    expect(call['kind'], SongKind.cover);
    expect(call['cot'], 'full');
    expect(call['abc'], _abc.trim());
    expect(call['style'], 'acoustic folk');
    expect(call['seed'], 42);
    expect(call['sourceSeconds'], closeTo(2, 0.01));
    expect(find.byKey(const Key('cover.queued')), findsOneWidget);
  });
}
