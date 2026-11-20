import 'dart:io';

import 'package:macos_window_utils/macos_window_utils.dart';

import '../theme/tokens.dart';

/// macOS only: translucent sidebar (vibrancy), transparent title bar, content under the traffic lights.
/// Any failure (plugin not wired in Runner, headless run) leaves the opaque sidebar in place.
Future<void> configureWindow() async {
  if (!Platform.isMacOS) return;
  try {
    await WindowManipulator.initialize().timeout(const Duration(seconds: 3));
    await WindowManipulator.makeTitlebarTransparent();
    await WindowManipulator.enableFullSizeContentView();
    await WindowManipulator.hideTitle();
    await WindowManipulator.setMaterial(NSVisualEffectViewMaterial.sidebar);
    await WindowManipulator.setWindowBackgroundColorToClear();
    Chrome.vibrancy = true;
  } catch (_) {
    Chrome.vibrancy = false;
  }
}
