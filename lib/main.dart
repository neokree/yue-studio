import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/services.dart';
import 'app/window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureWindow();
  runApp(StudioApp(services: await Services.bootstrap()));
}
