import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/app/paths.dart';

void main() {
  test('env overrides win, defaults live under the data dir', () {
    final d = Paths.resolve({'HOME': '/h'});
    expect(d.dataDir, '/h/Library/Application Support/YuE2 Studio');
    expect(d.uv, '${d.dataDir}/bin/uv');
    expect(d.manifest, '${d.dataDir}/engine/manifests/real.json');
    expect(d.copyAssets, true);
    final o = Paths.resolve({'YUE2_STUDIO_DATA_DIR': '/d', 'YUE2_STUDIO_ENGINE_DIR': '/e', 'YUE2_STUDIO_FAKE': '1', 'YUE2_STUDIO_UV': '/u'});
    expect((o.dataDir, o.uv, o.engineDir, o.manifest, o.copyAssets, o.fake), ('/d', '/u', '/e', '/e/manifests/real.json', false, true));
  });

  test('prepare copies the bundled engine scripts', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final tmp = Directory.systemTemp.createTempSync('yue2paths');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final p = Paths.resolve({'YUE2_STUDIO_DATA_DIR': tmp.path});
    await p.prepare();
    expect(File(p.sidecar).existsSync(), true);
    expect(File(p.manifest).existsSync(), true);
  });
}
