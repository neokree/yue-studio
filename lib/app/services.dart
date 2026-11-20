import 'package:flutter/foundation.dart';

import '../create/create_draft.dart';
import '../engine/engine.dart';
import '../engine/process_engine.dart';
import '../generation/estimator.dart';
import '../library/library_store.dart';
import '../player/player_controller.dart';
import '../queue/job_queue.dart';
import '../setup/installer.dart';
import 'paths.dart';

/// The three screens of the sidebar. "Liked" is Library with [LibraryStore.likedOnly].
enum Section { create, cover, library }

/// Everything the UI needs, built once in main() (or by tests with fakes).
class Services {
  Services({
    required this.installer,
    required this.library,
    required this.queue,
    required this.engine,
    ValueNotifier<Section>? nav,
    CreateDraft? createDraft,
    GenerationEstimator? estimator,
    PlayerController? player,
  }) : nav = nav ?? ValueNotifier(Section.create),
       createDraft = createDraft ?? CreateDraft(),
       estimator = estimator ?? queue.estimator,
       player = player ?? PlayerController(library: library) {
    this.createDraft.onPrefill = () => this.nav.value = Section.create;
  }

  final Installer installer;
  final LibraryStore library;
  final JobQueue queue;
  final Engine engine;
  final ValueNotifier<Section> nav;
  final CreateDraft createDraft;
  final GenerationEstimator estimator;
  final PlayerController player;

  static Future<Services> bootstrap([Paths? paths]) async {
    paths ??= Paths.resolve();
    await paths.prepare();
    final installer = await Installer.load(paths);
    final engine = ProcessEngine(paths);
    final library = LibraryStore(paths.libraryDir)..load();
    final estimator = GenerationEstimator(paths.dataDir);
    await estimator.load();
    return Services(
      installer: installer,
      library: library,
      engine: engine,
      queue: JobQueue(engine: engine, library: library, estimator: estimator),
      estimator: estimator,
    );
  }
}
