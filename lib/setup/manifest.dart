import 'dart:convert';
import 'dart:io';

/// Setup manifest (engine/PROTOCOL.md section 5).
class SetupStep {
  SetupStep(this.raw);
  final Map<String, dynamic> raw;
  String get id => raw['id'] as String;
  String get kind => raw['kind'] as String;
  String get label => raw['label'] as String? ?? id;
  int get bytes => (raw['bytes'] as num?)?.toInt() ?? 0;
}

class SetupManifest {
  SetupManifest({required this.name, required this.bytes, required this.steps});
  final String name;
  final int bytes;
  final List<SetupStep> steps;

  factory SetupManifest.fromJson(Map<String, dynamic> j) => SetupManifest(
        name: j['name'] as String? ?? 'manifest',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        steps: [for (final s in (j['steps'] as List? ?? const [])) SetupStep(Map<String, dynamic>.from(s as Map))],
      );

  static SetupManifest read(String path) =>
      SetupManifest.fromJson(jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>);
}
