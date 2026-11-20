import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/engine/process_engine.dart';

/// The installed engine dir is filled from the pubspec asset list: a local module missing there ends in
/// "ModuleNotFoundError" at the first job (this shipped once with backends.py).
void main() {
  test('every engine/*.py (and everything sidecar.py imports locally) is a pubspec asset', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final listed = RegExp(
      r'^\s*-\s*(engine/[\w./]+)\s*$',
      multiLine: true,
    ).allMatches(pubspec).map((m) => m.group(1)!).toSet();
    final present = {
      for (final f in Directory('engine').listSync().whereType<File>())
        if (f.path.endsWith('.py')) 'engine/${f.uri.pathSegments.last}',
    };

    final imported = <String>{};
    final todo = ['sidecar'];
    final import = RegExp(r'^\s*(?:from\s+(\w+)\s+import|import\s+(\w+))', multiLine: true);
    while (todo.isNotEmpty) {
      final m = todo.removeLast();
      final f = File('engine/$m.py');
      if (!f.existsSync() || !imported.add('engine/$m.py')) continue;
      for (final x in import.allMatches(f.readAsStringSync())) {
        todo.add(x.group(1) ?? x.group(2)!);
      }
    }
    expect(imported, contains('engine/backends.py'), reason: 'import parsing works');
    expect(imported.difference(listed), isEmpty, reason: 'imported by the sidecar but not bundled');
    expect(present.difference(listed), isEmpty, reason: 'engine runtime files missing from pubspec assets');
  });

  test('engine exit error is one useful line', () {
    expect(
      ProcessEngine.exitMessage(1, [
        'Traceback (most recent call last):',
        '  File "sidecar.py", line 19, in <module>',
        "ModuleNotFoundError: No module named 'backends'",
        '',
      ]),
      "Engine exited (code 1): ModuleNotFoundError: No module named 'backends'",
    );
    expect(ProcessEngine.exitMessage(137, []), 'Engine exited (code 137)');
  });
}
