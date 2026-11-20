import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../setup/setup_screen.dart';
import '../theme/theme.dart';
import 'services.dart';
import 'shell.dart';

class StudioApp extends StatefulWidget {
  const StudioApp({super.key, required this.services});
  final Services services;

  @override
  State<StudioApp> createState() => _StudioAppState();
}

class _StudioAppState extends State<StudioApp> {
  /// Already installed at launch: straight to the shell. Otherwise the finished setup stays up for 1.2 s first.
  late bool _ready = widget.services.installer.complete;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.services.installer.addListener(_onInstaller);
  }

  void _onInstaller() {
    if (_ready || _timer != null || !widget.services.installer.complete) return;
    _timer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.services.installer.removeListener(_onInstaller);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: t.app.title,
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    builder: (context, child) => RepaintBoundary(key: const Key('app.screenshot'), child: child),
    home: _ready ? Shell(services: widget.services) : SetupScreen(installer: widget.services.installer),
  );
}
