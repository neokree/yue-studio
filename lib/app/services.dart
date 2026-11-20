import '../engine/engine.dart';
import '../engine/process_engine.dart';
import '../library/library_store.dart';
import '../queue/job_queue.dart';
import '../setup/installer.dart';
import 'paths.dart';

/// Everything the UI needs, built once in main() (or by tests with fakes).
class Services {
  Services({required this.installer, required this.library, required this.queue, required this.engine});

  final Installer installer;
  final LibraryStore library;
  final JobQueue queue;
  final Engine engine;

  static Future<Services> bootstrap([Paths? paths]) async {
    paths ??= Paths.resolve();
    await paths.prepare();
    final installer = await Installer.load(paths);
    final engine = ProcessEngine(paths);
    final library = LibraryStore(paths.libraryDir)..load();
    return Services(installer: installer, library: library, engine: engine, queue: JobQueue(engine: engine, library: library));
  }
}
