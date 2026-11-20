import '../i18n/strings.g.dart';

String stageLabel(String stage) => switch (stage) {
      'load' => t.shell.stage.load,
      'abc' => t.shell.stage.abc,
      'semantic' => t.shell.stage.semantic,
      'nar' => t.shell.stage.nar,
      'vae' => t.shell.stage.vae,
      'transcribe' => t.shell.stage.transcribe,
      _ => stage,
    };

/// One-word stage for tight places (sidebar, library row): "Sound", used as "Sound, step 3 of 5".
String stageShort(String stage) => switch (stage) {
      'abc' => t.generation.stageScore,
      'semantic' => t.generation.stageMelody,
      'nar' => t.generation.stageSound,
      'vae' => t.generation.stageMaster,
      _ => stageLabel(stage),
    };

/// "2 min 40 s", rounded to 10 s (to 1 s under a minute is false precision for an estimate).
String formatEta(Duration d) {
  final total = (d.inSeconds / 10).round() * 10;
  final m = total ~/ 60, s = total % 60;
  if (m == 0) return t.shell.time.sec(s: s < 10 ? 10 : s);
  return s == 0 ? t.shell.time.min(m: m) : t.shell.time.minSec(m: m, s: s);
}