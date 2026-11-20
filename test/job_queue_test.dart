import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:yue2_studio/engine/fake_engine.dart';
import 'package:yue2_studio/engine/protocol.dart';
import 'package:yue2_studio/library/library_store.dart';
import 'package:yue2_studio/library/song.dart';
import 'package:yue2_studio/queue/job_queue.dart';

const _req = SongRequest(style: 's', lyrics: 'l', cot: CotMode.full, seed: 1);

void main() {
  late Directory tmp;
  late LibraryStore lib;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yue2q');
    lib = LibraryStore(tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('runs jobs one at a time and records the result', () async {
    final engine = FakeEngine(auto: false);
    final q = JobQueue(engine: engine, library: lib);
    final a = lib.create(title: 'a', request: _req);
    final b = lib.create(title: 'b', request: _req);
    q.enqueue(a);
    q.enqueue(b);
    await settle();
    expect(engine.sent.length, 1, reason: 'second job waits for the first');
    expect(lib.byId(a.id)!.status, SongStatus.generating);
    expect(lib.byId(b.id)!.status, SongStatus.queued);
    expect((engine.sent.single as GenerateRequest).out, lib.dirOf(a.id));

    engine.emit(ProgressEvent(job: a.id, stage: 'nar', done: 1, total: 4));
    expect(q.progress?.stage, 'nar');
    engine.emit(ResultEvent(job: a.id, dir: lib.dirOf(a.id), audio: 'audio.wav', seed: 9, duration: 1.5));
    await settle();
    final done = lib.byId(a.id)!;
    expect((done.status, done.audio, done.duration, done.request.seed), (SongStatus.done, 'audio.wav', 1.5, 9));
    expect(engine.sent.length, 2);
    expect(lib.byId(b.id)!.status, SongStatus.generating);
  });

  test('error and cancel mark failed and the queue moves on', () async {
    final engine = FakeEngine(auto: false);
    final q = JobQueue(engine: engine, library: lib);
    final a = lib.create(title: 'a', request: _req);
    final b = lib.create(title: 'b', request: _req);
    final c = lib.create(title: 'c', request: _req);
    q.enqueue(a);
    q.enqueue(b);
    q.enqueue(c);
    await settle();
    q.cancel(c.id); // still queued
    expect(lib.byId(c.id)!.status, SongStatus.failed);
    engine.emit(ErrorEvent(job: a.id, message: 'boom'));
    await settle();
    expect(lib.byId(a.id)!.error, 'boom');
    expect(lib.byId(b.id)!.status, SongStatus.generating);
    q.cancel(b.id); // running: asks the engine
    expect(engine.sent.last, isA<CancelRequest>());
    engine.emit(ErrorEvent(job: b.id, message: 'x', cancelled: true));
    await settle();
    expect(lib.byId(b.id)!.error, 'Cancelled');
    expect(q.current, isNull);
  });

  test('auto fake engine finishes a job', () async {
    final q = JobQueue(engine: FakeEngine(), library: lib);
    final a = lib.create(title: 'a', request: _req);
    q.enqueue(a);
    await settle();
    await settle();
    expect(lib.byId(a.id)!.status, SongStatus.done);
  });
}
