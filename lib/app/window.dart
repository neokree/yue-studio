import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

const _channel = MethodChannel('yue2/window');

Future<void> _call(String method) async {
  try {
    await _channel.invokeMethod<void>(method);
  } on MissingPluginException {
    // headless runs and tests have no Runner
  }
}

/// Transparent strip over the title-bar area (the Flutter view covers it): drag moves the window, double-click zooms or
/// minimizes per the system setting (MainFlutterWindow.swift reads AppleActionOnDoubleClick). Nothing off macOS.
class TitleBarStrip extends StatelessWidget {
  const TitleBarStrip({super.key, required this.height});
  final double height;

  @override
  Widget build(BuildContext context) => !Platform.isMacOS
      ? const SizedBox.shrink()
      : SizedBox(
          height: height,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: () => _call('doubleClick'),
            onPanStart: (_) => _call('drag'),
          ),
        );
}
