import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/engine/fake_engine.dart';
import 'package:yue2_studio/engine/protocol.dart';
import 'package:yue2_studio/generation/estimator.dart';
import 'package:yue2_studio/library/library_store.dart';
import 'package:yue2_studio/library/song.dart';
import 'package:yue2_studio/queue/job_queue.dart';

void main() {
  late Directory tmp;
  late LibraryStore lib;
  late FakeEngine engine;
  late JobQueue q;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2q');
    lib = LibraryStore('${tmp.path}/library');
    engine = FakeEngine(auto: false);
    q = JobQueue(engine: engine, library: lib, estimator: GenerationEstimator(tmp.path));
  });
  tearDown(() async {
    q.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20)); // estimator.record may still be writing
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // temp dir, cleaned by the OS
    }
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);
  String add(String name) => q.enqueueGenerate(style: 's', lyrics: name, cot: 'full', seed: 1);
  String statusOf(String id) => lib.byId(id)!.status.name;

  test('runs jobs one at a time, in order, and records the result', () async {
    final a = add('a'), b = add('b');
    await settle();
    expect(engine.sent.length, 1, reason: 'second job waits for the first');
    expect((engine.sent.single as GenerateRequest).job, a);
    expect((engine.sent.single as GenerateRequest).out, lib.dirOf(a));
    expect((statusOf(a), statusOf(b)), ('generating', 'queued'));
    expect((q.running?.id, q.queuedCount), (a, 1));

    engine.emit(ProgressEvent(job: a, stage: 'nar', done: 1, total: 4));
    expect((q.stage, q.stageDone, q.stageTotal), ('nar', 1, 4));
    engine.emit(ResultEvent(job: a, dir: lib.dirOf(a), audio: 'audio.wav', seed: 9, duration: 1.5));
    await settle();
    final done = lib.byId(a)!;
    expect((done.status, done.audio, done.duration, done.request.seed), (SongStatus.done, 'audio.wav', 1.5, 9));
    expect(q.lastFinishedId, a);
    expect((engine.sent.last as GenerateRequest).job, b, reason: 'FIFO: b starts after a');
    expect((q.running?.id, q.queuedCount), (b, 0));
  });

  test('cancel removes a queued song; cancel on the running one asks the engine', () async {
    final a = add('a'), b = add('b'), c = add('c');
    await settle();
    q.cancel(c);
    expect((statusOf(c), lib.byId(c)!.error), ('failed', 'Cancelled'));
    expect(q.queuedCount, 1);

    q.cancel(a); // running
    expect(engine.sent.last, isA<CancelRequest>());
    expect((engine.sent.last as CancelRequest).job, a);
    engine.emit(ErrorEvent(job: a, message: 'x', cancelled: true));
    await settle();
    expect(lib.byId(a)!.error, 'Cancelled');
    expect(q.running?.id, b, reason: 'the queue moves on');
    engine.emit(ErrorEvent(job: b, message: 'boom'));
    await settle();
    expect(lib.byId(b)!.error, 'boom');
    expect(q.busy, isFalse);
    expect(engine.sent.whereType<GenerateRequest>().map((r) => r.job), [a, b], reason: 'c never reached the engine');
  });

  test('transcribe shares the line with generation and returns the score', () async {
    final a = add('a');
    final score = q.transcribe('/tmp/in.wav', 'melody');
    final b = add('b');
    await settle();
    expect(engine.sent.length, 1, reason: 'transcribe waits for the running song');
    expect(q.queuedCount, 2);

    engine.emit(ResultEvent(job: a, dir: lib.dirOf(a), audio: 'audio.wav', seed: 1, duration: 1));
    await settle();
    final tr = engine.sent.last as TranscribeRequest;
    expect((tr.audio, tr.mode), ('/tmp/in.wav', 'melody'));
    expect(q.transcribing, isTrue);
    expect(q.running, isNull);
    expect(engine.sent.whereType<GenerateRequest>().length, 1, reason: 'b waits for the transcription');

    Directory(tr.out).createSync(recursive: true);
    File('${tr.out}/score.abc').writeAsStringSync('X:1\nK:C\nCDEF|');
    engine.emit(ResultEvent(job: tr.job, dir: tr.out));
    expect(await score, 'X:1\nK:C\nCDEF|');
    await settle();
    expect((engine.sent.last as GenerateRequest).job, b);
  });

  test('a failed transcription throws and the queue continues', () async {
    final score = q.transcribe('/tmp/in.wav', 'full');
    final b = add('b');
    final expectation = expectLater(score, throwsA(isA<Exception>()));
    await settle();
    final tr = engine.sent.single as TranscribeRequest;
    engine.emit(ErrorEvent(job: tr.job, message: 'no audio'));
    await expectation;
    await settle();
    expect((engine.sent.last as GenerateRequest).job, b);
  });

  test('progress follows the estimator and never goes backwards', () async {
    final a = add('[Verse]\nline one\nline two\n[Chorus]\nline three');
    await settle();
    final seen = <double>[];
    q.addListener(() => seen.add(q.progress));
    engine.emit(ProgressEvent(job: a, stage: 'semantic', done: 200));
    final p1 = q.progress;
    expect(p1, greaterThan(0));
    engine.emit(ProgressEvent(job: a, stage: 'nar', done: 2, total: 4));
    final p2 = q.progress;
    expect(p2, greaterThan(p1));
    engine.emit(ProgressEvent(job: a, stage: 'abc', done: 25)); // a stage that would be earlier
    expect(q.progress, p2, reason: 'max kept');
    engine.emit(ProgressEvent(job: a, stage: 'nar', done: 3, total: 4));
    expect(q.progress, greaterThanOrEqualTo(p2));
    expect(q.remaining, isNotNull);
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
    engine.emit(ResultEvent(job: a, dir: lib.dirOf(a), audio: 'audio.wav', seed: 1, duration: 60));
    await settle();
    expect((q.progress, q.remaining, q.stage), (0, null, null), reason: 'idle resets');
  });

  test('auto fake engine finishes a job', () async {
    final fast = JobQueue(engine: FakeEngine(), library: lib, estimator: GenerationEstimator(tmp.path));
    final a = fast.enqueueGenerate(style: 's', lyrics: 'l', cot: 'off');
    await settle();
    await settle();
    expect(statusOf(a), 'done');
    fast.dispose();
  });
}
