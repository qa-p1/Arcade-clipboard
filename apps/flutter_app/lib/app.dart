import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'arcade_widgets.dart';
import 'clipboard_widgets.dart';
import 'design/arcade_format.dart';
import 'design/arcade_icons.dart';
import 'design/arcade_theme.dart';
import 'design/arcade_widgets.dart';
import 'models.dart';
import 'platform/desktop_adapter.dart';
import 'services/app_controller.dart';
import 'services/invite_qr_decoder.dart';
import 'services/link_service.dart';

part 'dialogs/invite_dialog.dart';
part 'overlay/quick_overlay.dart';
part 'pages/devices.dart';
part 'pages/history.dart';
part 'pages/settings.dart';
part 'pages/welcome.dart';
part 'shell.dart';

/// Clipboard's Link id, which picks the pink accent from the kit.
const String clipboardAppId = 'arcade.clipboard';

class ArcadeApp extends StatefulWidget {
  const ArcadeApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<ArcadeApp> createState() => _ArcadeAppState();
}

class _ArcadeAppState extends State<ArcadeApp> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.start());
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Arcade Clipboard',
          themeMode: widget.controller.themeMode,
          theme: arcadeTheme(Brightness.light, clipboardAppId),
          darkTheme: arcadeTheme(Brightness.dark, clipboardAppId),
          home: widget.controller.overlayOpen
              ? MeshOverlay(controller: widget.controller)
              : _AppHome(controller: widget.controller),
        ),
      );
}
