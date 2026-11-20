import 'dart:async';

import 'engine.dart';
import 'protocol.dart';

/// In-memory engine for tests. With [auto] it answers every generate with progress + result.
class FakeEngine implements Engine {
  FakeEngine({this.auto = true});

  final bool auto;
  final sent = <EngineRequest>[];
  final _events = StreamController<EngineEvent>.broadcast(sync: true);
  int starts = 0;

  @override
  Stream<EngineEvent> get events => _events.stream;

  /// Push an event as if the sidecar had printed it.
  void emit(EngineEvent e) => _events.add(e);

  @override
  Future<void> start() async => starts++;

  @override
  void send(EngineRequest r) {
    sent.add(r);
    if (!auto || r is! GenerateRequest) return;
    scheduleMicrotask(() {
      emit(ProgressEvent(job: r.job, stage: 'semantic', done: 25));
      emit(ResultEvent(job: r.job, dir: r.out, audio: 'audio.wav', seed: r.seed, duration: 1.5));
    });
  }

  @override
  Future<void> dispose() async => _events.close();
}
