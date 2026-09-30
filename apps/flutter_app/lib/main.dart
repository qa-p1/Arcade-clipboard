import 'package:flutter/material.dart';

import 'app.dart';
import 'services/app_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ArcadeApp(controller: AppController()));
}
