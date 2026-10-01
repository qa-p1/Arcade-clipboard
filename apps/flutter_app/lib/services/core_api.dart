import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import '../src/rust/api.dart' as rust_api;
import '../src/rust/frb_generated.dart';

abstract interface class CoreApi {
  Future<void> initializeBridge();

  Future<Map<String, dynamic>> invoke(
    String operation, [
    Map<String, Object?> arguments = const {},
  ]);
}

class RustCoreApi implements CoreApi {
  bool _bridgeReady = false;
  Future<void>? _bridgeInitialization;

  @override
  Future<void> initializeBridge() async {
    if (_bridgeReady) return;
    final existing = _bridgeInitialization;
    if (existing != null) return existing;
    final initialization = _initializeBridge();
    _bridgeInitialization = initialization;
    try {
      await initialization;
    } finally {
      if (identical(_bridgeInitialization, initialization)) {
        _bridgeInitialization = null;
      }
    }
  }

  Future<void> _initializeBridge() async {
    final runtimeLibrary = Platform.environment['ARCADE_CORE_LIBRARY']?.trim();
    final buildLibrary =
        const String.fromEnvironment('ARCADE_CORE_LIBRARY').trim();
    var libraryPath =
        runtimeLibrary?.isNotEmpty == true ? runtimeLibrary! : buildLibrary;
    if (libraryPath.isEmpty &&
        (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      final executable = File(Platform.resolvedExecutable).parent;
      final bundled = Platform.isLinux
          ? File('${executable.path}/lib/libarcade_core.so')
          : Platform.isWindows
              ? File('${executable.path}/arcade_core.dll')
              : File(
                  '${executable.parent.path}/Frameworks/libarcade_core.dylib');
      if (await bundled.exists()) libraryPath = bundled.path;
    }
    await RustLib.init(
      externalLibrary: libraryPath.isNotEmpty
          ? ExternalLibrary.open(libraryPath)
          // The iOS Rust core is a static archive force-loaded into the
          // Runner executable, so its symbols resolve from the process.
          : Platform.isIOS
              ? ExternalLibrary.process(iKnowHowToUseIt: true)
              : null,
    );
    _bridgeReady = true;
  }

  @override
  Future<Map<String, dynamic>> invoke(
    String operation, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (!_bridgeReady) await initializeBridge();
    final request = jsonEncode({'op': operation, ...arguments});
    final response = await rust_api.call(request: request);
    final decoded = jsonDecode(response);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is List<dynamic>) return {'items': decoded};
    throw const FormatException(
        'The clipboard service returned an invalid response.');
  }
}
