import 'protocol.dart';

abstract class Engine {
  Stream<EngineEvent> get events;

  /// Idempotent: spawns the sidecar if it is not running.
  Future<void> start();
  void send(EngineRequest r);
  Future<void> dispose();
}
