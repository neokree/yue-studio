import '../i18n/strings.g.dart';

String stageLabel(String stage) => switch (stage) {
      'load' => t.library.stage.load,
      'abc' => t.library.stage.abc,
      'semantic' => t.library.stage.semantic,
      'nar' => t.library.stage.nar,
      'vae' => t.library.stage.vae,
      'transcribe' => t.library.stage.transcribe,
      _ => stage,
    };
