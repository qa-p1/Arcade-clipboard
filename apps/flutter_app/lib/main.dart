import 'package:flutter/material.dart';

import 'app.dart';
import 'services/app_controller.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ArcadeApp(
      controller: AppController(
          startInBackground: arguments.contains('--background') ||
              arguments.contains('--overlay'),
          openOverlayOnStart: arguments.contains('--overlay'))));
}
