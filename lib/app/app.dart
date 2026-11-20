import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../setup/setup_screen.dart';
import '../theme/theme.dart';
import 'services.dart';
import 'shell.dart';

class StudioApp extends StatelessWidget {
  const StudioApp({super.key, required this.services});
  final Services services;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: t.app.title,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        builder: (context, child) => RepaintBoundary(key: const Key('app.screenshot'), child: child),
        home: ListenableBuilder(
          listenable: services.installer,
          builder: (_, _) => services.installer.complete
              ? Shell(services: services)
              : SetupScreen(installer: services.installer),
        ),
      );
}
