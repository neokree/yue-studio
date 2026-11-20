import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Where everything lives (engine/PROTOCOL.md section 6).
class Paths {
  Paths({
    required this.dataDir,
    required this.uv,
    required this.engineDir,
    required this.manifest,
    this.copyAssets = true,
    this.fake = false,
  });

  final String dataDir, uv, engineDir, manifest;

  /// False when YUE2_STUDIO_ENGINE_DIR is set: scripts are used in place.
  final bool copyAssets;
  final bool fake;

  factory Paths.resolve([Map<String, String>? env]) {
    env ??= Platform.environment;
    final home = env['HOME'] ?? '.';
    final data = env['YUE2_STUDIO_DATA_DIR'] ?? p.join(home, 'Library', 'Application Support', 'YuE2 Studio');
    final engineOverride = env['YUE2_STUDIO_ENGINE_DIR'];
    final engine = engineOverride ?? p.join(data, 'engine');
    return Paths(
      dataDir: data,
      uv: env['YUE2_STUDIO_UV'] ?? p.join(data, 'bin', 'uv'),
      engineDir: engine,
      manifest: env['YUE2_STUDIO_MANIFEST'] ?? p.join(engine, 'manifests', 'real.json'),
      copyAssets: engineOverride == null,
      fake: env['YUE2_STUDIO_FAKE'] == '1',
    );
  }

  String venvPython(String name) => p.join(dataDir, 'venvs', name, 'bin', 'python');
  String get libraryDir => p.join(dataDir, 'library');
  String get setupState => p.join(dataDir, 'setup-state.json');
  String get sidecar => p.join(engineDir, 'sidecar.py');
  String get fetcher => p.join(engineDir, 'fetch.py');

  /// Creates the data dir and copies bundled engine scripts (and uv) out of the asset bundle.
  Future<void> prepare([AssetBundle? bundle]) async {
    bundle ??= rootBundle;
    await Directory(dataDir).create(recursive: true);
    await Directory(libraryDir).create(recursive: true);
    final manifest = await AssetManifest.loadFromAssetBundle(bundle);
    for (final key in manifest.listAssets()) {
      if (copyAssets && key.startsWith('engine/')) {
        await _copy(bundle, key, p.join(engineDir, key.substring('engine/'.length)));
      } else if (key == 'assets/uv/uv' && !File(uv).existsSync()) {
        await _copy(bundle, key, uv);
        await Process.run('chmod', ['+x', uv]);
      }
    }
  }

  Future<void> _copy(AssetBundle bundle, String key, String dest) async {
    final data = await bundle.load(key);
    await Directory(p.dirname(dest)).create(recursive: true);
    await File(dest).writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  }
}
