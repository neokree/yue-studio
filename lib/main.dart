import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(StudioApp(services: await Services.bootstrap()));
}
