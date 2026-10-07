import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:arcade_desktop_bridge/arcade_desktop_bridge.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../services/diagnostics.dart';

/// The desktop features the current OS session can perform safely.
class DesktopCapabilities {
  DesktopCapabilities({
    required this.platform,
    required this.clipboardCapture,
    required this.globalShortcut,
    required this.overlay,
    required this.paste,
    required this.copyFallback,
    required this.detail,
  });

  final String platform;
  final bool clipboardCapture;
  bool globalShortcut;
  final bool overlay;
  bool paste;
  final bool copyFallback;
  String detail;

  /// Keep consumers holding the initialized capability object current when
  /// permission-sensitive values change during the desktop session.
  void updateFrom(DesktopCapabilities value) {
    globalShortcut = value.globalShortcut;
    paste = value.paste;
    detail = value.detail;
  }

  DesktopCapabilities copyWith({
    bool? clipboardCapture,
    bool? globalShortcut,
    bool? overlay,
    bool? paste,
    String? detail,
  }) =>
      DesktopCapabilities(
        platform: platform,
        clipboardCapture: clipboardCapture ?? this.clipboardCapture,
        globalShortcut: globalShortcut ?? this.globalShortcut,
        overlay: overlay ?? this.overlay,
        paste: paste ?? this.paste,
        copyFallback: copyFallback,
        detail: detail ?? this.detail,
      );
}

/// Raised when this desktop cannot perform an action with the current session.
class DesktopIntegrationException implements Exception {
  const DesktopIntegrationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Owns desktop clipboard capture, system shortcuts, compact-window behavior,
/// and the final native focus/paste handoff.
class DesktopAdapter with WidgetsBindingObserver, WindowListener {
  DesktopAdapter({ArcadeDesktopBridge? bridge})
      : _bridge = bridge ?? ArcadeDesktopBridge();

  static const Size _overlaySize = Size(430, 510);
  static const Duration _pasteSuppressionLifetime = Duration(seconds: 3);
  static const Duration _commandTimeout = Duration(seconds: 3);
  static const Duration _captureWatcherStartupGrace =
      Duration(milliseconds: 200);
  static const Duration _captureWatcherStopGrace = Duration(seconds: 2);

  final ArcadeDesktopBridge _bridge;
  final _CaptureSuppression _suppression = _CaptureSuppression();
  Future<void> _captureCallbackQueue = Future<void>.value();
  Future<void> _captureControlQueue = Future<void>.value();

  Future<void> Function(String text)? _onTextCaptured;
  Future<void> Function(Map<String, Object?> clipboard,
      {required bool initial})? _onRichCaptured;
  // wl-paste --watch reports the current selection when it starts.
  bool _nextEventIsInitial = false;
  final Map<String, DateTime> _richSuppression = {};

  void setRichCaptureHandler(
      Future<void> Function(Map<String, Object?> clipboard,
              {required bool initial})
          handler) {
    _onRichCaptured = handler;
  }

  Future<Map<String, Object?>> readClipboard() =>
      Platform.isLinux && _isWayland && _wlPastePath != null
          ? _readWaylandClipboard()
          : _bridge.readClipboard();
  bool _backgroundEnabled = false;

  Future<void> setBackgroundEnabled(bool enabled) async {
    await _bridge.setBackgroundEnabled(enabled);
    _backgroundEnabled = enabled;
    if (Platform.isMacOS) await windowManager.setPreventClose(enabled);
  }

  @override
  void onWindowClose() {
    if (Platform.isMacOS && _backgroundEnabled) unawaited(windowManager.hide());
  }

  Future<void> setLaunchAtLogin(bool enabled) =>
      _bridge.setLaunchAtLogin(enabled);
  Future<bool> launchAtLoginEnabled() => _bridge.launchAtLoginEnabled();
  /// Linux login starts are kept unmapped by the runner itself; hiding a
  /// window before its first frame breaks the GL surface there.
  Future<void> hideMainWindow() async {
    if (await windowManager.isVisible()) await windowManager.hide();
  }

  Future<void> showMainWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }
  Future<void> Function()? _onOverlayRequested;

  /// Runs application shutdown (core and desktop cleanup) before exit.
  Future<void> Function()? onQuit;

  /// Shows the Settings page (the tray's Open Settings item and click).
  void Function()? onOpenSettings;

  /// Set on the successor started by [restart]: the old process id, which it
  /// waits for before claiming the single instance (see main.dart, main.cc).
  static const restartEnvironment = 'ARCADE_CLIPBOARD_RESTART_AFTER';

  /// Starts a new background instance, then quits. Quitting without a
  /// successor would silently remove the app, so a failed start keeps it.
  Future<void> restart() async {
    try {
      await Process.start(Platform.resolvedExecutable, ['--background'],
          environment: {restartEnvironment: '$pid'},
          mode: ProcessStartMode.detached);
    } catch (error) {
      Diagnostics.log('lifecycle', 'restart failed: $error');
      return;
    }
    await _quit();
  }
  final List<StreamSubscription<ProcessSignal>> _exitSignals = [];
  bool _quitting = false;

  /// Quits like the tray's Quit item (also used by Arcade Link's app.quit).
  Future<void> quit() => _quit();

  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    Diagnostics.log('lifecycle', 'quitting');
    try {
      await (onQuit?.call() ?? dispose())
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      // Exit regardless; stale binds are guarded by PID start time.
    }
    exit(0);
  }
  DesktopCapabilities? _capabilities;
  HotKey? _registeredHotKey;
  StreamSubscription<ProcessSignal>? _signalSubscription;
  _WindowSnapshot? _windowSnapshot;
  _HyprlandTarget? _hyprlandTarget;
  _HyprlandBinding? _hyprlandBinding;
  bool? _hyprlandLua;
  final List<_HyprlandBinding> _hyprlandBindings = [];
  String? _wlPastePath;
  String? _wlCopyPath;
  String? _waylandCaptureHelper;
  bool _waylandCaptureAvailable = false;
  int _watcherRestarts = 0;
  Process? _waylandCaptureProcess;
  StreamSubscription<List<int>>? _waylandCaptureOutput;
  bool _initialized = false;
  bool _captureEnabled = false;
  bool _overlayVisible = false;
  bool _closed = false;

  void _setCapabilities(DesktopCapabilities value) {
    final current = _capabilities;
    if (current == null) {
      _capabilities = value;
    } else {
      current.updateFrom(value);
    }
  }

  DesktopCapabilities get capabilities =>
      _capabilities ??
      DesktopCapabilities(
        platform: 'unknown',
        clipboardCapture: false,
        globalShortcut: false,
        overlay: false,
        paste: false,
        copyFallback: false,
        detail: 'Desktop integration has not been initialized.',
      );

  static String get defaultShortcut => switch (Platform.operatingSystem) {
        'macos' => 'CMD+SHIFT+V',
        'windows' => 'CTRL+ALT+V',
        _ => 'CTRL+SHIFT+SPACE',
      };

  Future<DesktopCapabilities> initialize({
    required Future<void> Function(String text) onTextCaptured,
    required Future<void> Function() onOverlayRequested,
  }) async {
    if (_initialized) return capabilities;
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      throw const DesktopIntegrationException(
          'Desktop integration is available on Windows, macOS, and Linux.');
    }
    _onTextCaptured = onTextCaptured;
    _onOverlayRequested = onOverlayRequested;

    await windowManager.ensureInitialized();
    final native = await _bridge.capabilities();
    final detail = (native['detail'] as String?) ??
        'Clipboard capture and local copy are available.';
    var platform = Platform.operatingSystem;
    var clipboardCapture = false;
    var globalShortcut = true;
    var overlay = true;
    var paste = native['paste'] == true;

    if (Platform.isLinux) {
      final wayland = _isWayland;
      if (wayland) {
        _wlPastePath = _findExecutable('wl-paste');
        _wlCopyPath = _findExecutable('wl-copy');
        _waylandCaptureHelper = _captureHelperPath;
        clipboardCapture = await _probeWaylandCapture();
        _waylandCaptureAvailable = clipboardCapture;
      }
      if (wayland && _isHyprland) {
        platform = 'linux-wayland-hyprland';
        globalShortcut = await _probeHyprland();
        paste = globalShortcut;
      } else if (wayland) {
        platform = 'linux-wayland';
        globalShortcut = false;
        paste = false;
      } else if (Platform.environment['DISPLAY'] == null) {
        platform = 'linux-headless';
        globalShortcut = false;
        paste = false;
      } else {
        platform = 'linux-x11';
      }
    }

    if (!(Platform.isLinux && _isWayland)) {
      try {
        await _bridge.clipboardRevision();
        clipboardCapture = true;
      } catch (_) {
        clipboardCapture = false;
      }
    }

    _capabilities ??= DesktopCapabilities(
      platform: platform,
      clipboardCapture: clipboardCapture,
      globalShortcut: globalShortcut,
      overlay: overlay,
      paste: paste,
      copyFallback: true,
      detail: _desktopDetail(platform, native, globalShortcut, paste, detail),
    );
    if (Platform.isLinux) {
      // Installed up front: SIGUSR1's default action would terminate the app.
      _signalSubscription ??=
          ProcessSignal.sigusr1.watch().listen((_) => _requestOverlay());
    }
    if (!Platform.isWindows) {
      // Logout and service managers stop the app with SIGTERM; release the
      // compositor shortcut and clipboard watcher before exiting.
      for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
        _exitSignals.add(signal.watch().listen((_) => unawaited(_quit())));
      }
    }
    if (Platform.isLinux) {
      // Relaunches forward here from the native runner (single instance).
      const MethodChannel('arcade_clipboard/instance')
          .setMethodCallHandler((call) async {
        if (call.method == 'overlay') {
          await _requestOverlay();
        } else if (call.method == 'show') {
          await showMainWindow();
        } else if (call.method == 'quit') {
          await _quit();
        }
      });
    }
    _bridge.setLifecycleHandler((action) async {
      if (action == 'showMainWindow') {
        await windowManager.show();
        await windowManager.focus();
      } else if (action == 'clipboardChanged') {
        await onClipboardChanged();
      } else if (action == 'quitRequested') {
        await _quit();
      } else if (action == 'showSettings') {
        await showMainWindow();
        onOpenSettings?.call();
      } else if (action == 'restartRequested') {
        await restart();
      }
    });
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    return capabilities;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _initialized &&
        !_closed &&
        Platform.isMacOS) {
      unawaited(_refreshCapabilitiesQuietly());
    }
  }

  Future<void> onClipboardChanged() async {
    if (!_initialized || _closed || !_captureEnabled) return;
    try {
      if (_onRichCaptured != null) {
        await _enqueueRichCapture();
        return;
      }
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!_initialized || _closed || !_captureEnabled) return;
      final text = data?.text;
      if (text == null) return;
      await _enqueueCapturedText(text);
    } on PlatformException {
      // Clipboard formats and access vary by OS. Unsupported reads are ignored.
    } catch (_) {
      // Never log clipboard data or surface watcher exceptions as app errors.
    }
  }

  /// Enables or disables clipboard text reads for mesh capture. The Hyprland
  /// watcher exists only while capture is enabled, and the callback gate is
  /// closed synchronously before its process group is stopped.
  Future<void> setCaptureEnabled(bool enabled) {
    if (_closed) return Future<void>.value();
    _captureEnabled = enabled;
    final operation = _captureControlQueue.then((_) async {
      if (_closed || enabled != _captureEnabled) return;
      if (!(Platform.isLinux && _isWayland)) {
        if (enabled && !capabilities.clipboardCapture) {
          _captureEnabled = false;
          throw const DesktopIntegrationException(
              'Clipboard monitoring is not available in this session.');
        }
        await _bridge.setClipboardCaptureEnabled(enabled);
        return;
      }
      if (Platform.isLinux && _isWayland) {
        if (enabled && !capabilities.clipboardCapture) {
          _captureEnabled = false;
          throw DesktopIntegrationException(_waylandCaptureDetail());
        }
        if (enabled) {
          await _startWaylandClipboardCapture();
          if (_captureEnabled && _waylandCaptureProcess == null) {
            throw const DesktopIntegrationException(
              'Clipboard capture stopped before it became ready. Turn capture off and on to retry.',
            );
          }
        } else {
          await _stopWaylandClipboardCapture();
        }
      }
    });
    _captureControlQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _enqueueCapturedText(String text) {
    if (text.isEmpty || _suppression.isSuppressed(text)) {
      return Future<void>.value();
    }
    final operation = _captureCallbackQueue.then((_) async {
      if (!_initialized || _closed || !_captureEnabled) return;
      try {
        await _onTextCaptured?.call(text);
      } catch (_) {
        // Clipboard text and capture callback failures are never logged here.
      }
    });
    _captureCallbackQueue = operation.catchError((Object _) {});
    return operation;
  }

  String _clipboardFingerprint(Map<String, Object?> clipboard) {
    final formats = clipboard['formats'] as List<dynamic>? ?? const [];
    final digests = formats.whereType<Map<dynamic, dynamic>>().map((format) {
      final bytes = format['bytes'];
      return '${format['mimeType']}:${bytes is Uint8List ? sha256.convert(bytes) : ''}';
    }).join('|');
    return '$digests|${clipboard['files']}';
  }

  Future<void> _enqueueRichCapture({bool initial = false}) {
    final operation = _captureCallbackQueue.then((_) async {
      if (!_initialized || _closed || !_captureEnabled) return;
      try {
        final clipboard = await readClipboard();
        final formatCount =
            (clipboard['formats'] as List<dynamic>? ?? const []).length;
        Diagnostics.log('capture',
            'read clipboard: $formatCount formats, sensitive=${clipboard['sensitive']}');
        if (clipboard['sensitive'] == true || !_captureEnabled || _closed) {
          return;
        }
        final formats = clipboard['formats'] as List<dynamic>? ?? const [];
        for (final format in formats.whereType<Map<dynamic, dynamic>>()) {
          final bytes = format['bytes'];
          if (format['mimeType'] == 'text/plain' &&
              bytes is Uint8List &&
              _suppression
                  .isSuppressed(utf8.decode(bytes, allowMalformed: true))) {
            return;
          }
        }
        final now = DateTime.now();
        _richSuppression.removeWhere((_, expiry) => !expiry.isAfter(now));
        if (_richSuppression.containsKey(_clipboardFingerprint(clipboard))) {
          return;
        }
        await _onRichCaptured?.call(clipboard, initial: initial);
      } catch (error) {
        // A clipboard owner can disappear while its data is being read.
        Diagnostics.log('capture', 'read failed: ${error.runtimeType}');
      }
    });
    _captureCallbackQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> copyContent(
      {required List<Map<String, Object?>> formats,
      List<String> files = const []}) async {
    final clipboard = <String, Object?>{'formats': formats, 'files': files};
    final fingerprint = _clipboardFingerprint(clipboard);
    _richSuppression[fingerprint] =
        DateTime.now().add(_pasteSuppressionLifetime);
    for (final format in formats) {
      if (format['mimeType'] == 'text/plain' && format['bytes'] is Uint8List) {
        _suppression.add(
            utf8.decode(format['bytes']! as Uint8List, allowMalformed: true),
            lifetime: _pasteSuppressionLifetime);
      }
    }
    try {
      if (!(Platform.isLinux &&
          _isWayland &&
          await _writeWaylandClipboard(formats, files))) {
        await _bridge.writeClipboard(formats: formats, files: files);
      }
    } catch (_) {
      _richSuppression.remove(fingerprint);
      rethrow;
    }
  }

  Future<void> pasteContent(
          {required List<Map<String, Object?>> formats,
          List<String> files = const []}) =>
      _pasteClipboard(() => copyContent(formats: formats, files: files));

  void _deliverWaylandCaptureFrame(Process process, Uint8List bytes) {
    if (!_initialized ||
        _closed ||
        !_captureEnabled ||
        !identical(_waylandCaptureProcess, process)) {
      return;
    }
    if (bytes.length == 1 && bytes[0] == 49) {
      final initial = _nextEventIsInitial;
      _nextEventIsInitial = false;
      Diagnostics.log('capture', 'clipboard change event${initial ? ' (initial)' : ''}');
      unawaited(_enqueueRichCapture(initial: initial));
    }
  }

  Future<void> _startWaylandClipboardCapture() async {
    if (_waylandCaptureProcess != null) return;
    final helper = _waylandCaptureHelper;
    final wlPaste = _wlPastePath;
    if (helper == null || wlPaste == null) {
      _captureEnabled = false;
      throw DesktopIntegrationException(_waylandCaptureDetail());
    }

    late final Process process;
    try {
      process = await Process.start(
        helper,
        ['--watcher-events', wlPaste, helper],
        runInShell: false,
      );
    } catch (_) {
      _captureEnabled = false;
      throw const DesktopIntegrationException(
        'Clipboard capture could not start. Check the wl-clipboard installation and restart the app.',
      );
    }

    _waylandCaptureProcess = process;
    _nextEventIsInitial = true;
    Diagnostics.log('capture', 'watcher started (pid ${process.pid})');
    final decoder = _LengthPrefixedTextDecoder(maximumLength: 32 * 1024);
    _waylandCaptureOutput = process.stdout.listen(
      (chunk) {
        if (!identical(_waylandCaptureProcess, process) ||
            !_captureEnabled ||
            _closed) {
          return;
        }
        try {
          decoder.add(
              chunk, (frame) => _deliverWaylandCaptureFrame(process, frame));
        } on FormatException {
          _captureEnabled = false;
          _setCapabilities(capabilities.copyWith(
            detail:
                'Clipboard capture stopped after receiving an invalid frame. Re-enable capture to retry.',
          ));
          unawaited(_stopWaylandClipboardCapture().catchError((Object _) {}));
        }
      },
      onError: (_) {
        if (!identical(_waylandCaptureProcess, process)) return;
        _captureEnabled = false;
        _setCapabilities(capabilities.copyWith(
          detail:
              'Clipboard capture stopped unexpectedly. Re-enable capture to retry.',
        ));
        unawaited(_stopWaylandClipboardCapture().catchError((Object _) {}));
      },
    );
    unawaited(process.stderr.drain<void>().catchError((Object _) {}));
    unawaited(process.exitCode.then<void>(
      (_) => _handleWaylandCaptureExit(process),
      onError: (Object _) => _handleWaylandCaptureExit(process),
    ));

    if (_closed || !_captureEnabled) {
      await _stopWaylandClipboardCapture();
      return;
    }

    final earlyExit = await Future.any<int?>([
      process.exitCode.then((code) => code),
      Future<int?>.delayed(_captureWatcherStartupGrace, () => null),
    ]);
    if (earlyExit == null) {
      final started = process;
      unawaited(Future<void>.delayed(const Duration(seconds: 30), () {
        if (identical(_waylandCaptureProcess, started)) _watcherRestarts = 0;
      }));
    }
    if (earlyExit != null) {
      await _stopWaylandClipboardCapture();
      _captureEnabled = false;
      throw const DesktopIntegrationException(
        'Clipboard capture could not start. Confirm wl-clipboard 2.2 or newer and compositor data-control support.',
      );
    }
  }

  Future<void> _handleWaylandCaptureExit(Process process) async {
    Diagnostics.log('capture', 'watcher ${process.pid} exited');
    if (!identical(_waylandCaptureProcess, process)) return;
    final stoppedUnexpectedly = !_closed && _captureEnabled;
    _waylandCaptureProcess = null;
    final output = _waylandCaptureOutput;
    _waylandCaptureOutput = null;
    await output?.cancel();
    if (!stoppedUnexpectedly) return;

    try {
      await _signalWaylandCaptureGroup(process.pid, 'term');
    } catch (_) {
      // The watcher is already gone; a surviving child is best-effort cleanup.
    }
    // A compositor restart or a wl-paste crash should not silently turn
    // capture off. Retry with backoff while capture is still wanted.
    _watcherRestarts++;
    if (_watcherRestarts > 6) {
      _captureEnabled = false;
      _setCapabilities(capabilities.copyWith(
        detail:
            'Clipboard capture stopped repeatedly. Turn capture off and on to retry.',
      ));
      return;
    }
    final delay = Duration(seconds: 1 << (_watcherRestarts - 1));
    Diagnostics.log('capture', 'restarting watcher in ${delay.inSeconds}s');
    await Future<void>.delayed(delay);
    if (_closed || !_captureEnabled || _waylandCaptureProcess != null) return;
    final restart = _captureControlQueue.then((_) async {
      if (_closed || !_captureEnabled || _waylandCaptureProcess != null) return;
      await _startWaylandClipboardCapture();
    });
    _captureControlQueue = restart.catchError((Object _) {});
    try {
      await restart;
    } catch (error) {
      Diagnostics.log('capture', 'watcher restart failed: $error');
    }
  }

  Future<void> _stopWaylandClipboardCapture() async {
    final process = _waylandCaptureProcess;
    if (process == null) return;
    _waylandCaptureProcess = null;

    try {
      await _signalWaylandCaptureGroup(process.pid, 'term');
    } catch (_) {
      process.kill(ProcessSignal.sigterm);
    }
    try {
      await process.exitCode.timeout(_captureWatcherStopGrace);
    } on TimeoutException {
      try {
        await _signalWaylandCaptureGroup(process.pid, 'kill');
      } catch (_) {
        process.kill(ProcessSignal.sigkill);
      }
      try {
        await process.exitCode.timeout(_captureWatcherStopGrace);
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(_captureWatcherStopGrace);
        } on TimeoutException {
          throw const DesktopIntegrationException(
            'Clipboard capture could not be stopped. Close the app only after the watcher exits.',
          );
        }
      }
    } finally {
      final output = _waylandCaptureOutput;
      _waylandCaptureOutput = null;
      await output?.cancel();
    }
  }

  Future<void> _signalWaylandCaptureGroup(int pid, String signal) async {
    final helper = _waylandCaptureHelper;
    if (helper == null) {
      throw const DesktopIntegrationException(
          'The clipboard watcher could not be stopped safely.');
    }
    try {
      final result = await Process.run(
        helper,
        ['--signal-group', signal, '$pid'],
        runInShell: false,
      );
      if (result.exitCode != 0) {
        throw const DesktopIntegrationException(
            'The clipboard watcher could not be stopped safely.');
      }
    } catch (error) {
      if (error is DesktopIntegrationException) rethrow;
      throw const DesktopIntegrationException(
          'The clipboard watcher could not be stopped safely.');
    }
  }

  Future<bool> _probeWaylandCapture() async {
    final helper = _waylandCaptureHelper;
    final wlPaste = _wlPastePath;
    if (helper == null || wlPaste == null) return false;

    Process? process;
    StreamSubscription<List<int>>? stdout;
    StreamSubscription<List<int>>? stderr;
    final output = BytesBuilder(copy: false);
    void appendVersionOutput(List<int> chunk) {
      if (output.length >= 256) return;
      final take = chunk.length < 256 - output.length
          ? chunk.length
          : 256 - output.length;
      output.add(chunk.sublist(0, take));
    }

    try {
      process = await Process.start(wlPaste, ['--version'], runInShell: false);
      stdout = process.stdout.listen(appendVersionOutput);
      stderr = process.stderr.listen(appendVersionOutput);
      final stdoutDone = stdout.asFuture<void>();
      final stderrDone = stderr.asFuture<void>();
      final code = await process.exitCode.timeout(const Duration(seconds: 1));
      await Future.wait([stdoutDone, stderrDone])
          .timeout(const Duration(seconds: 1));
      if (code != 0) return false;

      final versionText =
          utf8.decode(output.takeBytes(), allowMalformed: false);
      final match =
          RegExp(r'\b(\d+)\.(\d+)(?:\.\d+)?\b').firstMatch(versionText);
      if (match == null) return false;
      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(2)!);
      return major > 2 || (major == 2 && minor >= 2);
    } catch (_) {
      process?.kill(ProcessSignal.sigterm);
      try {
        await process?.exitCode.timeout(const Duration(seconds: 1));
      } catch (_) {
        process?.kill(ProcessSignal.sigkill);
      }
      return false;
    } finally {
      await stdout?.cancel();
      await stderr?.cancel();
    }
  }

  String? get _captureHelperPath {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final separator = Platform.pathSeparator;
    for (final candidate in [
      '$executableDirectory${separator}lib${separator}arcade_clipboard_wl_capture',
      '$executableDirectory${separator}arcade_clipboard_wl_capture',
    ]) {
      if (_isExecutableFile(candidate)) return candidate;
    }
    return null;
  }

  String? _findExecutable(String program) {
    final path = Platform.environment['PATH'];
    if (path == null) return null;
    for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
      if (directory.isEmpty) continue;
      final candidate = '$directory${Platform.pathSeparator}$program';
      if (_isExecutableFile(candidate)) return candidate;
    }
    return null;
  }

  bool _isExecutableFile(String path) {
    try {
      final stat = File(path).statSync();
      return stat.type == FileSystemEntityType.file && (stat.mode & 0x49) != 0;
    } catch (_) {
      return false;
    }
  }

  String _waylandCaptureDetail() =>
      'Automatic capture needs wl-clipboard 2.2 or newer (install the wl-clipboard package) and a compositor with clipboard data-control support.';

  Future<void> configureShortcut(String shortcut) async {
    if (!_initialized) {
      throw const DesktopIntegrationException(
          'Desktop integration has not finished initializing.');
    }
    if (_closed) {
      throw const DesktopIntegrationException(
          'Desktop integration has been closed.');
    }
    final parsed = DesktopShortcut.parse(shortcut);
    final conflict = _shortcutConflict(parsed);
    if (conflict != null) throw DesktopIntegrationException(conflict);
    if (!capabilities.globalShortcut) {
      throw DesktopIntegrationException(capabilities.detail);
    }

    if (Platform.isLinux && _isWayland && _isHyprland) {
      await _configureHyprland(parsed);
    } else {
      await _configureNativeShortcut(parsed);
    }
    _setCapabilities(capabilities.copyWith(
      globalShortcut: true,
      detail: _desktopDetail(
        capabilities.platform,
        const {},
        true,
        capabilities.paste,
        capabilities.detail,
      ),
    ));
  }

  static const String _mainTitle = 'Arcade Clipboard';
  static const String _overlayTitle = 'Mesh Clipboard';

  /// Shows the picker. With `paste: false` (choosing a clip for another
  /// Arcade app) nothing will be pasted, so a missing paste target is fine.
  Future<void> showOverlay({bool paste = true}) async {
    if (!_initialized || _closed) {
      throw const DesktopIntegrationException(
          'Desktop integration is not available.');
    }
    if (_overlayVisible) return;
    if (Platform.isLinux && _isWayland && _isHyprland) {
      try {
        final target = await _captureHyprlandTarget();
        // Invoking the picker from this app itself has no other app to paste into.
        _hyprlandTarget = target.pid == pid ? null : target;
      } catch (_) {
        // Keep the picker usable for explicit copy fallback when the focused
        // app has no addressable Hyprland window.
        _hyprlandTarget = null;
      }
      await _showHyprlandOverlay();
      return;
    } else {
      try {
        await _rememberTarget();
      } catch (_) {
        if (capabilities.paste && paste) rethrow;
        // The overlay and copy fallback remain useful without a paste target.
      }
    }

    try {
      _windowSnapshot = _WindowSnapshot(
        visible: await windowManager.isVisible(),
        size: await windowManager.getSize(),
        position: await windowManager.getPosition(),
        alwaysOnTop: await windowManager.isAlwaysOnTop(),
        skipTaskbar: await windowManager.isSkipTaskbar(),
        resizable: await windowManager.isResizable(),
      );
      await windowManager.setResizable(false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setSize(_overlaySize);
      // Wayland compositors own window placement; ask for a centered initial
      // placement, but do not treat a compositor refusal as a paste failure.
      try {
        await windowManager.setAlignment(Alignment.center);
      } catch (_) {
        // The compositor may ignore client-side positioning requests.
      }
      await windowManager.show();
      await windowManager.focus();
      _overlayVisible = true;
    } catch (error) {
      final snapshot = _windowSnapshot;
      if (snapshot != null) {
        try {
          await windowManager.hide();
        } catch (_) {
          // The show operation may already have left the window hidden.
        }
        await _restoreWindowSnapshot(snapshot);
      }
      _overlayVisible = false;
      await _restoreTargetFocus();
      throw DesktopIntegrationException(
          'The clipboard picker window could not open: $error');
    }
  }

  /// Hyprland tiles new windows, so the picker is mapped under a dedicated
  /// title that a runtime window rule floats, sizes, centers and pins at map
  /// time. Dispatchers repeat that placement if the rule is unavailable.
  Future<void> _showHyprlandOverlay() async {
    try {
      final wasVisible = await windowManager.isVisible();
      _windowSnapshot = _WindowSnapshot(
        visible: wasVisible,
        size: await windowManager.getSize(),
        position: Offset.zero,
        alwaysOnTop: false,
        skipTaskbar: false,
        resizable: true,
      );
      // Rules apply when a window maps; unmap first if the main window is open.
      if (wasVisible) await windowManager.hide();
      await windowManager.setTitle(_overlayTitle);
      await windowManager.setSize(_overlaySize);
      await _ensureHyprlandPickerRule();
      await windowManager.show();
      _overlayVisible = true;
      final own = await _ownHyprlandWindow();
      if (own != null) {
        if (own['floating'] != true) {
          await _hyprlandWindowAction(own['address'] as String, [
            'hl.dsp.window.float({ action = "set", window = w })',
            'hl.dsp.window.resize({ x = ${_overlaySize.width.toInt()}, y = ${_overlaySize.height.toInt()}, window = w })',
            'hl.dsp.window.center({ window = w })',
          ], legacy: [
            ['setfloating', 'address:${own['address']}'],
            ['resizewindowpixel', 'exact ${_overlaySize.width.toInt()} ${_overlaySize.height.toInt()},address:${own['address']}'],
            ['centerwindow', ''],
          ]);
        }
        await _hyprlandWindowAction(own['address'] as String,
            ['hl.dsp.focus({ window = w })'],
            legacy: [
              ['focuswindow', 'address:${own['address']}']
            ]);
      }
    } catch (error) {
      _overlayVisible = false;
      await _restoreHyprlandMainWindow(focusTarget: true);
      throw DesktopIntegrationException(
          'The clipboard picker window could not open: $error');
    }
  }

  Future<void> _restoreHyprlandMainWindow({required bool focusTarget}) async {
    final snapshot = _windowSnapshot;
    _windowSnapshot = null;
    try {
      await windowManager.hide();
      await windowManager.setTitle(_mainTitle);
      if (snapshot != null) await windowManager.setSize(snapshot.size);
    } catch (_) {
      // The window may already be hidden.
    }
    if (focusTarget && _hyprlandTarget != null) {
      await _restoreTargetFocus();
    } else if (snapshot?.visible == true || _hyprlandTarget == null) {
      // The picker was opened from the main window (or from no app at all):
      // bring the main window back as it was.
      if (snapshot?.visible == true) {
        try {
          await windowManager.show();
        } catch (_) {
          // Best effort; the tray can reopen the window.
        }
      }
    }
  }

  Future<void> _ensureHyprlandPickerRule() async {
    if (await _detectHyprlandLua()) {
      final width = _overlaySize.width.toInt();
      final height = _overlaySize.height.toInt();
      final result = await _runCommand('hyprctl', [
        'eval',
        'if not rawget(_G, "ARCADE_CLIPBOARD_PICKER_RULE") then '
            'hl.window_rule({ match = { class = "^dev[.]arcade[.]clipboard\$", title = "^$_overlayTitle\$" }, '
            'float = true, pin = true, center = true, size = "$width $height" }); '
            'rawset(_G, "ARCADE_CLIPBOARD_PICKER_RULE", true) end'
      ]);
      if (result.exitCode != 0) {
        Diagnostics.log('overlay', 'picker rule rejected: ${_processError(result)}');
      }
    }
  }

  Future<Map<String, Object?>?> _ownHyprlandWindow() async {
    final result = await _runCommand('hyprctl', ['-j', 'clients']);
    if (result.exitCode != 0) return null;
    try {
      final clients = jsonDecode(result.stdout as String);
      if (clients is! List) return null;
      for (final client in clients) {
        if (client is Map &&
            client['pid'] == pid &&
            client['title'] == _overlayTitle &&
            client['address'] is String) {
          return {'address': client['address'], 'floating': client['floating']};
        }
      }
    } catch (_) {
      // Unreadable client list; placement falls back to the window rule.
    }
    return null;
  }

  Future<void> _hyprlandWindowAction(String address, List<String> luaActions,
      {required List<List<String>> legacy}) async {
    if (!RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(address)) return;
    if (await _detectHyprlandLua()) {
      final body = luaActions.map((action) => 'hl.dispatch($action)').join('; ');
      await _runCommand('hyprctl', [
        'eval',
        'local w = hl.get_window(${_luaString('address:$address')}); if w then $body end'
      ]);
      return;
    }
    for (final action in legacy) {
      await _runCommand('hyprctl', ['dispatch', action[0], action[1]]);
    }
  }

  Future<void> hideOverlay() async {
    if (!_overlayVisible) return;
    if (Platform.isLinux && _isWayland && _isHyprland) {
      _overlayVisible = false;
      await _restoreHyprlandMainWindow(focusTarget: true);
      return;
    }
    final snapshot = _windowSnapshot;
    try {
      await windowManager.hide();
    } finally {
      _overlayVisible = false;
      if (snapshot != null) {
        await _restoreWindowSnapshot(snapshot);
      }
      await _restoreTargetFocus();
    }
  }

  /// Copies a mesh clip to the system clipboard without simulating paste.
  Future<void> copyText(String text) async {
    if (text.isEmpty) return;
    await _writeClipboardForUserAction(text);
  }

  /// Only explicit user copy/paste actions reach the OS clipboard. Background
  /// mesh synchronization has no call path into this method.
  Future<void> _writeClipboardForUserAction(String text) => copyContent(
        formats: [
          {'mimeType': 'text/plain', 'bytes': Uint8List.fromList(utf8.encode(text))}
        ],
      );

  /// Refreshes permission-sensitive native paste support after system settings
  /// change. On macOS this reflects Accessibility permission immediately.
  Future<DesktopCapabilities> refreshCapabilities() async {
    if (!_initialized || _closed) return capabilities;
    final native = await _bridge.capabilities();
    final paste =
        Platform.isMacOS ? native['paste'] == true : capabilities.paste;
    final detail = (native['detail'] as String?) ?? capabilities.detail;
    _setCapabilities(capabilities.copyWith(
      paste: paste,
      detail: _desktopDetail(capabilities.platform, native,
          capabilities.globalShortcut, paste, detail),
    ));
    return capabilities;
  }

  Future<void> _refreshCapabilitiesQuietly() async {
    try {
      await refreshCapabilities();
    } catch (_) {
      // Permission state can only be refreshed while the native bridge is available.
    }
  }

  /// Requests macOS Accessibility permission without sending a key event.
  /// Capabilities refresh after an immediate grant or when the app resumes
  /// from System Settings.
  Future<DesktopCapabilities> requestPasteAccess() async {
    if (!Platform.isMacOS) return capabilities;
    final granted = await _bridge.requestPasteAccess();
    if (granted) return refreshCapabilities();
    // macOS may open System Settings for the user to grant permission. The
    // lifecycle observer rechecks when the app returns, after the grant.
    return capabilities;
  }

  /// Places [text] on the system clipboard, restores the remembered target,
  /// and sends the platform's native paste shortcut.
  Future<void> pasteText(String text) async {
    if (text.isEmpty) return;
    await _pasteClipboard(() => _writeClipboardForUserAction(text));
  }

  Future<void> _pasteClipboard(Future<void> Function() writeClipboard) async {
    if (Platform.isMacOS && !capabilities.paste) await refreshCapabilities();
    if (!capabilities.paste) {
      throw DesktopIntegrationException(capabilities.detail);
    }

    if (Platform.isLinux && _isWayland && _isHyprland) {
      final target = _hyprlandTarget;
      if (target == null) {
        throw const DesktopIntegrationException(
            'The previously focused Hyprland window is unavailable. Copy the clip and paste manually.');
      }
      // The start-time check rejects a reused PID; the dispatch itself
      // re-verifies the window address and PID inside the compositor.
      await _assertHyprlandTargetExists(target);
      await writeClipboard();
      await _dispatchHyprland('focuswindow', 'address:${target.address}');
      await _dispatchHyprland('sendshortcut',
          '${target.pasteModifiers},V,address:${target.address}',
          modifiers: target.pasteModifiers);
      Diagnostics.log('paste', 'sent ${target.pasteModifiers}+V to ${target.className}');
      return;
    }

    if (Platform.isLinux) {
      await _restoreX11Focus();
      await writeClipboard();
      await _pasteX11();
      return;
    }
    await _bridge.restoreTargetFocus();
    await writeClipboard();
    await _bridge.pasteKey();
  }

  String? _x11Target;
  String _x11TargetClass = '';

  Future<void> _rememberTarget() async {
    if (!Platform.isLinux) return _bridge.rememberTarget();
    _x11Target = null;
    if (_isWayland) return;
    final active = await _runCommand('xdotool', ['getactivewindow']);
    final id = (active.stdout as String).trim();
    if (active.exitCode != 0 || !RegExp(r'^[0-9]+$').hasMatch(id)) {
      // X11 sessions without an EWMH window manager have no active-window
      // property. The picker still works; selection can copy without paste.
      Diagnostics.log('overlay', 'No X11 paste target; using copy fallback.');
      return;
    }
    final className = await _runCommand('xdotool', ['getwindowclassname', id]);
    _x11TargetClass =
        className.exitCode == 0 ? (className.stdout as String).trim() : '';
    _x11Target = id;
  }

  Future<void> _restoreX11Focus() async {
    final target = _x11Target;
    if (target == null) {
      throw const DesktopIntegrationException(
          'The previously focused window is unavailable. The clip was copied instead.');
    }
    final result =
        await _runCommand('xdotool', ['windowactivate', '--sync', target]);
    if (result.exitCode != 0) {
      throw const DesktopIntegrationException(
          'The previous window could not be focused. The clip was copied instead.');
    }
  }

  Future<void> _pasteX11() async {
    final target = _x11Target;
    final active = await _runCommand('xdotool', ['getactivewindow']);
    if (target == null || (active.stdout as String).trim() != target) {
      throw const DesktopIntegrationException(
          'Focus changed before paste. The clip was copied instead.');
    }
    final chord =
        isTerminalWindowClass(_x11TargetClass) ? 'ctrl+shift+v' : 'ctrl+v';
    final result =
        await _runCommand('xdotool', ['key', '--clearmodifiers', chord]);
    if (result.exitCode != 0) {
      throw const DesktopIntegrationException(
          'Paste could not be sent. The clip was copied instead.');
    }
  }

  Future<void> dispose() async {
    windowManager.removeListener(this);
    _bridge.setLifecycleHandler(null);
    if (_closed) return;
    _closed = true;
    _captureEnabled = false;
    WidgetsBinding.instance.removeObserver(this);
    await _captureControlQueue;
    await _stopWaylandClipboardCapture();
    final registered = _registeredHotKey;
    _registeredHotKey = null;
    if (registered != null) {
      try {
        await hotKeyManager.unregister(registered);
      } catch (_) {
        // The application is already closing; there is no further action.
      }
    }
    await _removeHyprlandBinding();
    await _signalSubscription?.cancel();
    _signalSubscription = null;
    _suppression.clear();
  }

  Future<void> _configureNativeShortcut(DesktopShortcut shortcut) async {
    final replacement = HotKey(
      identifier: 'arcade-clipboard-mesh-picker',
      key: shortcut.physicalKey,
      modifiers: shortcut.hotKeyModifiers,
      scope: HotKeyScope.system,
    );
    final current = _registeredHotKey;
    if (current != null) {
      try {
        await hotKeyManager.unregister(current);
      } catch (error) {
        throw DesktopIntegrationException(
          'The previous shortcut could not be released, so the new binding was not installed. $error',
        );
      }
    }
    try {
      await hotKeyManager.register(
        replacement,
        keyDownHandler: (_) => _requestOverlay(),
      );
      _registeredHotKey = replacement;
    } catch (error) {
      if (current != null) {
        try {
          await hotKeyManager.register(current,
              keyDownHandler: (_) => _requestOverlay());
          _registeredHotKey = current;
        } catch (_) {
          _registeredHotKey = null;
          _setCapabilities(capabilities.copyWith(
            globalShortcut: false,
            detail:
                'The shortcut could not be registered and the previous binding could not be restored. $error',
          ));
        }
      } else {
        _registeredHotKey = null;
        _setCapabilities(capabilities.copyWith(
          // A conflict can reject one key while the platform still supports
          // global bindings; leave retries enabled for another combination.
          detail:
              'The requested shortcut could not be registered. ${_registrationError(error)}',
        ));
      }
      throw DesktopIntegrationException(_registrationError(error));
    }
  }

  Future<void> _configureHyprland(DesktopShortcut shortcut) async {
    final lua = await _detectHyprlandLua();
    var previous = _hyprlandBinding;
    if (previous != null) {
      final current = await _readHyprlandBinds();
      final owned = previous;
      final present = current.any((bind) =>
          bind.modifierMask == owned.modifierMask &&
          bind.key.toUpperCase() == owned.key.toUpperCase() &&
          bind.argument.contains(owned.marker));
      if (!present) {
        // A compositor reload removes runtime binds and their Lua handles.
        _hyprlandBindings.remove(previous);
        _hyprlandBinding = null;
        previous = null;
      } else if (previous.modifierMask == shortcut.hyprlandModifierMask &&
          previous.key.toUpperCase() == shortcut.hyprlandKey.toUpperCase() &&
          (previous.luaHandle != null) == lua) {
        return;
      }
    }

    // A prior failed rollback can leave an extra app-owned binding. Remove
    // those before starting another transaction, while retaining the binding
    // that is currently considered authoritative.
    for (final owned in List<_HyprlandBinding>.of(_hyprlandBindings)) {
      if (identical(owned, previous)) continue;
      await _unbindHyprlandBinding(owned);
      _hyprlandBindings.remove(owned);
    }

    final binds = await _readHyprlandBinds();
    await _removeStaleOwnedHyprlandBinds(binds);
    final current = await _readHyprlandBinds();
    final mask = shortcut.hyprlandModifierMask;
    final key = shortcut.hyprlandKey;
    final conflict = current.any((bind) {
      if (bind.modifierMask != mask ||
          bind.key.toUpperCase() != key.toUpperCase()) {
        return false;
      }
      return !_hyprlandBindings.any((owned) =>
          owned.modifierMask == bind.modifierMask &&
          owned.key.toUpperCase() == bind.key.toUpperCase() &&
          bind.argument.contains(owned.marker));
    });
    if (conflict) {
      throw const DesktopIntegrationException(
          'That shortcut is already assigned in Hyprland. Choose another combination.');
    }

    _signalSubscription ??=
        ProcessSignal.sigusr1.watch().listen((_) => _requestOverlay());
    final processId = pid;
    final startTicks = await _processStartTicks(processId);
    final marker = 'ACBMESH_SIGNAL_${processId}_$startTicks';
    // Hyprland dispatches this command through its session IPC. The shell
    // command includes a start-time guard so a stale bind cannot signal a
    // different process if Linux later reuses this PID.
    final command =
        'sh -c \': $marker; test "\$(sed "s/^.*) //" /proc/$processId/stat | cut -d" " -f20)" = "$startTicks" && kill -USR1 $processId\'';
    final value =
        '${shortcut.hyprlandModifiers},${shortcut.hyprlandKey},exec,$command';
    final luaHandle = lua ? _hyprlandHandle(marker, mask, key) : null;
    final chord = [...shortcut.hyprlandModifiers.split(' '), key].join(' + ');
    final result = await _runCommand(
        'hyprctl',
        lua
            ? [
                'eval',
                'local b = hl.bind(${_luaString(chord)}, hl.dsp.exec_cmd(${_luaString(command)}), { description = ${_luaString('Arcade Clipboard $marker')} }); '
                    'assert(b, "Hyprland rejected the shortcut"); _G[${_luaString(luaHandle!)}] = b'
              ]
            : ['keyword', 'bind', value]);
    _requireHyprlandOk(
        result, 'The Hyprland shortcut could not be registered.');
    final replacement = _HyprlandBinding(
      modifiers: shortcut.hyprlandModifiers,
      key: shortcut.hyprlandKey,
      modifierMask: mask,
      marker: marker,
      luaHandle: luaHandle,
    );
    _hyprlandBindings.add(replacement);

    if (previous != null) {
      try {
        await _unbindHyprlandBinding(previous);
        _hyprlandBindings.remove(previous);
      } catch (error) {
        try {
          await _unbindHyprlandBinding(replacement);
          _hyprlandBindings.remove(replacement);
        } catch (rollbackError) {
          // Keep both references so dispose can retry cleanup. The old binding
          // remains authoritative; both commands carry PID/start-time guards.
          throw DesktopIntegrationException(
            'The new shortcut was registered, but the old binding could not be removed and rollback also failed. '
            'The previous shortcut remains active. $error $rollbackError',
          );
        }
        throw DesktopIntegrationException(
          'The new shortcut could not replace the previous binding. The previous shortcut remains active. $error',
        );
      }
    }
    _hyprlandBinding = replacement;
  }

  Future<void> _removeHyprlandBinding() async {
    final bindings = List<_HyprlandBinding>.of(_hyprlandBindings);
    if (bindings.isEmpty && _hyprlandBinding != null) {
      bindings.add(_hyprlandBinding!);
    }
    _hyprlandBindings.clear();
    _hyprlandBinding = null;
    if (!_isHyprland) return;
    for (final binding in bindings) {
      try {
        await _unbindHyprlandBinding(binding);
      } catch (_) {
        // The command also checks this process start time before signaling, so
        // an orphaned bind cannot signal a later process that reuses its PID.
      }
    }
  }

  Future<void> _unbindHyprlandBinding(_HyprlandBinding binding) async {
    final lua = await _detectHyprlandLua();
    final handle = binding.luaHandle ??
        _hyprlandHandle(binding.marker, binding.modifierMask, binding.key);
    final result = await _runCommand(
        'hyprctl',
        lua
            ? ['eval', _removeHyprlandLuaHandle(handle)]
            : ['keyword', 'unbind', '${binding.modifiers},${binding.key}']);
    _requireHyprlandOk(result, 'The Hyprland shortcut could not be removed.');
  }

  Future<void> _removeStaleOwnedHyprlandBinds(List<_HyprlandBind> binds) async {
    for (final bind in binds) {
      final marker =
          RegExp(r'ACBMESH_SIGNAL_(\d+)_(\d+)').firstMatch(bind.argument);
      if (marker == null ||
          _hyprlandBindings.any((owned) => owned.marker == marker.group(0))) {
        continue;
      }
      final pid = int.tryParse(marker.group(1)!);
      final startTicks = int.tryParse(marker.group(2)!);
      if (pid == null || startTicks == null) continue;
      try {
        if (await _processStartTicks(pid) == startTicks) continue;
      } on DesktopIntegrationException catch (error) {
        if (!error.message.contains('no longer available')) continue;
      }
      final markerText = marker.group(0)!;
      final hasOtherBinding = binds.any((other) =>
          !identical(other, bind) &&
          other.modifierMask == bind.modifierMask &&
          other.key.toUpperCase() == bind.key.toUpperCase() &&
          !other.argument.contains(markerText));
      if (hasOtherBinding) continue;
      final modifiers = _modifiersFromMask(bind.modifierMask);
      if (modifiers.isEmpty || bind.key.isEmpty) continue;
      try {
        final lua = await _detectHyprlandLua();
        final result = await _runCommand(
            'hyprctl',
            lua
                ? [
                    'eval',
                    _removeHyprlandLuaHandle(_hyprlandHandle(
                        markerText, bind.modifierMask, bind.key))
                  ]
                : ['keyword', 'unbind', '${modifiers.join(' ')},${bind.key}']);
        _requireHyprlandOk(
            result, 'A stale Arcade shortcut could not be removed.');
      } catch (_) {
        // Continue cleanup for the remaining app-owned binds.
      }
    }
  }

  Future<List<_HyprlandBind>> _readHyprlandBinds() async {
    final result = await _runCommand('hyprctl', ['-j', 'binds']);
    if (result.exitCode != 0) {
      throw DesktopIntegrationException(
          'Hyprland shortcut support is unavailable: ${_processError(result)}');
    }
    try {
      final value = jsonDecode(result.stdout as String);
      if (value is! List) throw const FormatException('Expected a bind list.');
      return value
          .whereType<Map<String, dynamic>>()
          .map(_HyprlandBind.fromJson)
          .toList(growable: false);
    } catch (_) {
      throw const DesktopIntegrationException(
          'Hyprland did not return a readable shortcut list. No shortcut was changed.');
    }
  }

  Future<bool> _probeHyprland() async {
    try {
      // Reading the bind table verifies that this process can reach the
      // compositor's runtime configuration endpoint. It must not depend on a
      // focused window: login sessions often start on an empty workspace.
      await _readHyprlandBinds();
      return true;
    } catch (error) {
      Diagnostics.log('shortcut', 'Hyprland probe failed: $error');
      return false;
    }
  }

  Future<_HyprlandTarget> _captureHyprlandTarget() async {
    final result = await _runCommand('hyprctl', ['-j', 'activewindow']);
    if (result.exitCode != 0) {
      throw DesktopIntegrationException(
          'Hyprland could not identify the focused app: ${_processError(result)}');
    }
    dynamic value;
    try {
      value = jsonDecode(result.stdout as String);
    } catch (_) {
      throw const DesktopIntegrationException(
          'Hyprland returned unreadable focused-window data. Copy fallback is available.');
    }
    final address = value is Map ? value['address'] : null;
    final pid = value is Map && value['pid'] is num
        ? (value['pid'] as num).toInt()
        : null;
    if (address is! String || !RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(address)) {
      throw const DesktopIntegrationException(
          'Hyprland did not provide a focused window address. Copy fallback is available.');
    }
    if (pid == null || pid <= 0) {
      throw const DesktopIntegrationException(
          'Hyprland did not provide the focused app PID. Copy fallback is available.');
    }
    final startTicks = await _processStartTicks(pid);
    final className =
        value is Map && value['class'] is String ? value['class'] as String : '';
    return _HyprlandTarget(
        address: address.toLowerCase(),
        pid: pid,
        startTicks: startTicks,
        className: className);
  }

  Future<void> _assertHyprlandTargetExists(_HyprlandTarget target,
      {bool requireActive = false}) async {
    final startTicks = await _processStartTicks(target.pid);
    if (startTicks != target.startTicks) {
      throw const DesktopIntegrationException(
          'The previously focused Hyprland app has exited or its PID was reused. Copy the clip and paste manually.');
    }

    final result = await _runCommand('hyprctl', ['-j', 'clients']);
    if (result.exitCode != 0) {
      throw DesktopIntegrationException(
          'Hyprland could not verify the previous window: ${_processError(result)}');
    }
    dynamic clients;
    try {
      clients = jsonDecode(result.stdout as String);
    } catch (_) {
      throw const DesktopIntegrationException(
          'Hyprland returned unreadable window data. Copy fallback is available.');
    }
    final exists = clients is List &&
        clients.any((client) =>
            client is Map &&
            client['address'] is String &&
            (client['address'] as String).toLowerCase() == target.address &&
            client['pid'] is num &&
            (client['pid'] as num).toInt() == target.pid);
    if (!exists) {
      throw const DesktopIntegrationException(
          'The previously focused Hyprland window is no longer available. Copy the clip and paste manually.');
    }
    if (requireActive) {
      final active = await _captureHyprlandTarget();
      if (!active.sameIdentity(target)) {
        throw const DesktopIntegrationException(
            'Hyprland did not restore the previous app focus. Copy the clip and paste manually.');
      }
    }
  }

  Future<void> _dispatchHyprland(String dispatcher, String argument,
      {String modifiers = 'CTRL'}) async {
    if (!await _detectHyprlandLua()) {
      final result =
          await _runCommand('hyprctl', ['dispatch', dispatcher, argument]);
      _requireHyprlandOk(
          result, 'Hyprland could not complete the paste action.');
      return;
    }
    final target = _hyprlandTarget;
    if (target == null ||
        !RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(target.address)) {
      throw const DesktopIntegrationException(
          'The paste target is no longer available.');
    }
    final action = switch (dispatcher) {
      'focuswindow' => 'hl.dsp.focus({ window = w })',
      'sendshortcut' =>
        'hl.dsp.send_shortcut({ mods = ${_luaString(modifiers)}, key = "V", window = w })',
      _ => throw DesktopIntegrationException(
          'Unsupported Hyprland action: $dispatcher'),
    };
    final expression =
        'local w = hl.get_window(${_luaString('address:${target.address}')}); '
        'assert(w and w.pid == ${target.pid}, "The paste target is no longer available"); '
        'local r = hl.dispatch($action); assert(r and r.ok, r and r.error or "Hyprland rejected the paste action")';
    final result = await _runCommand('hyprctl', ['eval', expression]);
    _requireHyprlandOk(result, 'Hyprland could not complete the paste action.');
  }

  Future<bool> _detectHyprlandLua() async {
    if (_hyprlandLua != null) return _hyprlandLua!;
    final status = await _runCommand('hyprctl', ['-j', 'status']);
    if (status.exitCode == 0) {
      try {
        final value = jsonDecode(status.stdout as String);
        if (value is Map && value['configProvider'] is String) {
          return _hyprlandLua = value['configProvider'] == 'lua';
        }
      } on FormatException catch (_) {
        // Older compositors do not expose the configuration provider.
      }
    }
    if (_hyprlandLua != null) return _hyprlandLua!;
    final probe = await _runCommand('hyprctl', [
      'eval',
      'assert(type(hl) == "table" and type(hl.bind) == "function")'
    ]);
    return _hyprlandLua = probe.exitCode == 0 &&
        (probe.stdout as String).trim().toLowerCase() == 'ok';
  }

  void _requireHyprlandOk(ProcessResult result, String fallback) {
    if (result.exitCode != 0 ||
        (result.stdout as String).trim().toLowerCase() != 'ok') {
      final reason = _processError(result);
      throw DesktopIntegrationException(
          '$fallback${reason.isEmpty ? '' : ' $reason'}');
    }
  }

  Future<int> _processStartTicks(int pid) async {
    late final String stat;
    try {
      stat = await File('/proc/$pid/stat').readAsString();
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (code == 2 || code == 3) {
        throw const DesktopIntegrationException(
            'The target Hyprland app process is no longer available.');
      }
      throw const DesktopIntegrationException(
          'Could not safely verify the target Hyprland app process.');
    } catch (_) {
      throw const DesktopIntegrationException(
          'Could not safely verify the target Hyprland app process.');
    }
    final closingParenthesis = stat.lastIndexOf(')');
    if (closingParenthesis < 0) {
      throw const DesktopIntegrationException(
          'Could not safely register a Hyprland shortcut for this process.');
    }
    final fields =
        stat.substring(closingParenthesis + 1).trim().split(RegExp(r'\s+'));
    // /proc/PID/stat fields 3..22 follow the process name; starttime is field 22.
    if (fields.length <= 19) {
      throw const DesktopIntegrationException(
          'Could not safely register a Hyprland shortcut for this process.');
    }
    final ticks = int.tryParse(fields[19]);
    if (ticks == null) {
      throw const DesktopIntegrationException(
          'Could not safely register a Hyprland shortcut for this process.');
    }
    return ticks;
  }

  /// Runs a short-lived helper with binary stdin/stdout. Child processes are
  /// started from Dart on Linux because the Dart VM reaps every child once it
  /// owns one, which makes GLib's GSubprocess exit-status checks unreliable.
  Future<Uint8List?> _runBytes(
    String executable,
    List<String> arguments, {
    List<int>? input,
    int maxBytes = 32 * 1024 * 1024,
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    Process? process;
    try {
      process = await Process.start(executable, arguments, runInShell: false);
      final output = BytesBuilder(copy: false);
      var overflow = false;
      final collected = process.stdout.listen((chunk) {
        if (overflow) return;
        if (output.length + chunk.length > maxBytes) {
          overflow = true;
          process?.kill(ProcessSignal.sigkill);
          return;
        }
        output.add(chunk);
      }).asFuture<void>();
      unawaited(process.stderr.drain<void>().catchError((Object _) {}));
      if (input != null) process.stdin.add(input);
      await process.stdin.close();
      final code = await process.exitCode.timeout(timeout);
      await collected.timeout(timeout);
      if (code != 0 || overflow) return null;
      return output.takeBytes();
    } on TimeoutException {
      process?.kill(ProcessSignal.sigkill);
      return null;
    } catch (_) {
      process?.kill(ProcessSignal.sigkill);
      return null;
    }
  }

  static const _sensitiveMimeTypes = {
    'x-kde-passwordmanagerhint',
    'application/x-keepassxc-clipboard',
  };

  /// Preferred source target → canonical representation. Alternative
  /// encodings of one representation are collapsed to the first match.
  static const _readCandidates = [
    ('text/plain;charset=utf-8', 'text/plain'),
    ('UTF8_STRING', 'text/plain'),
    ('text/plain', 'text/plain'),
    ('text/html', 'text/html'),
    ('image/png', 'image/png'),
    ('image/jpeg', 'image/jpeg'),
    ('text/uri-list', 'text/uri-list'),
  ];

  Future<Map<String, Object?>> _readWaylandClipboard() async {
    final wlPaste = _wlPastePath;
    if (wlPaste == null) return _bridge.readClipboard();
    const empty = <String, Object?>{
      'formats': <Object?>[],
      'files': <Object?>[],
      'sensitive': false
    };
    final listed = await _runBytes(wlPaste, ['--list-types'],
        maxBytes: 16 * 1024, timeout: const Duration(seconds: 2));
    // A cleared clipboard has no selection and wl-paste exits nonzero.
    if (listed == null) return empty;
    final names = utf8
        .decode(listed, allowMalformed: true)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(256)
        .toList();
    if (names.any((name) => _sensitiveMimeTypes.contains(name.toLowerCase()))) {
      return {...empty, 'sensitive': true};
    }
    final formats = <Map<String, Object?>>[];
    final files = <String>[];
    final seen = <String>{};
    var total = 0;
    for (final (target, mime) in _readCandidates) {
      if (!names.contains(target) || seen.contains(mime)) continue;
      if (mime == 'image/jpeg' && seen.contains('image/png')) continue;
      seen.add(mime);
      final bytes = await _runBytes(
          wlPaste, ['--no-newline', '--type', target],
          maxBytes: 32 * 1024 * 1024 - total);
      if (bytes == null || bytes.isEmpty) continue;
      total += bytes.length;
      if (mime == 'text/uri-list') {
        files.addAll(_localPathsFromUriList(utf8.decode(bytes, allowMalformed: true)));
        continue;
      }
      formats.add({'mimeType': mime, 'bytes': bytes});
    }
    return {'formats': formats, 'files': files, 'sensitive': false};
  }

  static List<String> _localPathsFromUriList(String value) {
    final paths = <String>[];
    for (final line in const LineSplitter().convert(value)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final uri = Uri.tryParse(trimmed);
      if (uri == null || uri.scheme != 'file') continue;
      if (uri.host.isNotEmpty && uri.host != 'localhost') continue;
      try {
        paths.add(uri.toFilePath());
      } catch (_) {
        // Not a local path representation.
      }
      if (paths.length >= 256) break;
    }
    return paths;
  }

  /// Writes the best single representation with wl-copy. wl-copy serves the
  /// selection from its own background process through the data-control
  /// protocol, so it works while the picker window is hidden.
  Future<bool> _writeWaylandClipboard(
      List<Map<String, Object?>> formats, List<String> files) async {
    final wlCopy = _wlCopyPath;
    if (wlCopy == null) return false;
    Uint8List? bytesFor(String mime) {
      for (final format in formats) {
        final bytes = format['bytes'];
        if (format['mimeType'] == mime && bytes is Uint8List) return bytes;
      }
      return null;
    }

    late final List<String> arguments;
    late final List<int> data;
    if (files.isNotEmpty) {
      arguments = ['--type', 'text/uri-list'];
      data = utf8.encode(
          files.map((path) => '${Uri.file(path)}\r\n').join());
    } else if (bytesFor('image/png') case final png?) {
      arguments = ['--type', 'image/png'];
      data = png;
    } else if (bytesFor('image/jpeg') case final jpeg?) {
      arguments = ['--type', 'image/jpeg'];
      data = jpeg;
    } else if (bytesFor('text/plain') case final text?) {
      // Without --type, wl-copy offers every common text target
      // (text/plain, UTF8_STRING, STRING, ...), which terminals need.
      arguments = const [];
      data = text;
    } else if (bytesFor('text/html') case final html?) {
      arguments = ['--type', 'text/html'];
      data = html;
    } else {
      return false;
    }
    // wl-copy forks a server that inherits stdout; redirect it so this call
    // completes when the selection is set instead of when it is replaced.
    final result = await _runBytes(
        '/bin/sh', ['-c', r'exec "$0" "$@" >/dev/null 2>&1', wlCopy, ...arguments],
        input: data, maxBytes: 4096, timeout: const Duration(seconds: 3));
    return result != null;
  }

  Future<ProcessResult> _runCommand(
      String executable, List<String> arguments) async {
    Process? process;
    Future<String>? stdoutFuture;
    Future<String>? stderrFuture;
    Future<int>? exitCodeFuture;
    Future<List<String>>? outputFuture;
    try {
      process = await Process.start(executable, arguments, runInShell: false);
      stdoutFuture = process.stdout.transform(utf8.decoder).join();
      stderrFuture = process.stderr.transform(utf8.decoder).join();
      exitCodeFuture = process.exitCode;
      outputFuture = Future.wait([stdoutFuture, stderrFuture]);
      final completed = () async {
        final exitCode = await exitCodeFuture!;
        final output = await outputFuture!;
        return ProcessResult(process!.pid, exitCode, output[0], output[1]);
      }();
      return await completed.timeout(_commandTimeout);
    } on TimeoutException {
      process?.kill(ProcessSignal.sigkill);
      if (process != null) {
        try {
          await exitCodeFuture!.timeout(const Duration(milliseconds: 500));
        } catch (_) {
          // Do not let an unresponsive desktop utility hold up the app.
        }
        try {
          await outputFuture!.timeout(const Duration(milliseconds: 500));
        } catch (_) {
          // A child may keep the pipes open after termination.
        }
      }
      return ProcessResult(
          process?.pid ?? -1, -1, '', '$executable timed out.');
    } catch (error) {
      process?.kill(ProcessSignal.sigkill);
      if (process != null) {
        try {
          await Future.wait([exitCodeFuture!, outputFuture!])
              .timeout(const Duration(milliseconds: 500));
        } catch (_) {
          // Process startup or output failed; report the original problem.
        }
      }
      final message =
          error is ProcessException ? error.message : error.toString();
      return ProcessResult(process?.pid ?? -1, -1, '', message);
    }
  }

  Future<void> _restoreWindowSnapshot(_WindowSnapshot snapshot) async {
    try {
      await windowManager.setSize(snapshot.size);
      await windowManager.setPosition(snapshot.position);
      await windowManager.setResizable(snapshot.resizable);
      await windowManager.setAlwaysOnTop(snapshot.alwaysOnTop);
      await windowManager.setSkipTaskbar(snapshot.skipTaskbar);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      if (snapshot.visible) await windowManager.show(inactive: true);
    } catch (_) {
      // A compositor may deny geometry restoration after the overlay hid.
    }
  }

  Future<void> _restoreTargetFocus() async {
    if (Platform.isLinux && _isWayland && _isHyprland) {
      final target = _hyprlandTarget;
      if (target != null) {
        try {
          await _assertHyprlandTargetExists(target);
          await _dispatchHyprland('focuswindow', 'address:${target.address}');
          await _assertHyprlandTargetExists(target, requireActive: true);
        } catch (_) {
          // Paste performs the same checks and reports an actionable failure.
        }
      }
      return;
    }
    try {
      if (Platform.isLinux) {
        if (_x11Target != null) await _restoreX11Focus();
      } else {
        await _bridge.restoreTargetFocus();
      }
    } catch (_) {
      // Hiding a picker should still succeed if the original app exited.
    }
  }

  Future<void> _requestOverlay() async {
    if (!_initialized || _closed || _onOverlayRequested == null) return;
    await _onOverlayRequested!.call();
  }

  String? _shortcutConflict(DesktopShortcut shortcut) {
    final modifiers = shortcut._modifiers.toSet();
    final signature =
        '${modifiers.map((modifier) => modifier.name).toList()..sort()}+${shortcut.keyName}';
    const reserved = {
      'control+alt+delete',
      'alt+f4',
      'meta+tab',
      'meta+space',
      'meta+l',
      'meta+q',
      'control+c',
      'control+v',
      'meta+c',
      'meta+v',
    };
    if (reserved.contains(signature.toLowerCase())) {
      return 'That shortcut is reserved by the operating system or a common copy/paste action. Choose another combination.';
    }
    if (modifiers.isEmpty) {
      return 'A global shortcut must include at least one modifier key.';
    }
    return null;
  }

  String _registrationError(Object error) {
    final platformDetail = Platform.isLinux
        ? 'On Linux X11, install the keybinder-3.0 runtime library. Wayland shortcuts are supported here only on Hyprland.'
        : 'Another application or the operating system may already use this combination.';
    return 'The shortcut could not be registered. $platformDetail $error';
  }

  String _desktopDetail(
    String platform,
    Map<String, Object?> native,
    bool globalShortcut,
    bool paste,
    String nativeDetail,
  ) {
    if (platform == 'linux-wayland') {
      final capture = _waylandCaptureAvailable
          ? 'Copies are captured automatically.'
          : _waylandCaptureDetail();
      return '$capture This desktop does not let apps register global shortcuts or paste into other windows. Bind a system shortcut to “clipboard --overlay”; choosing a clip copies it so you can paste with Ctrl+V.';
    }
    if (platform == 'linux-wayland-hyprland') {
      final integration = globalShortcut && paste
          ? 'Hyprland shortcut and direct paste are active.'
          : 'Hyprland could not be reached through hyprctl.';
      final capture = _waylandCaptureAvailable
          ? 'Copies are captured automatically while capture is on.'
          : _waylandCaptureDetail();
      return '$integration $capture';
    }
    if (!globalShortcut) {
      return 'Global shortcut registration is unavailable. $nativeDetail';
    }
    if (!paste) return nativeDetail;
    return nativeDetail;
  }

  bool get _isWayland =>
      Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty == true ||
      Platform.environment['XDG_SESSION_TYPE']?.toLowerCase() == 'wayland';

  bool get _isHyprland =>
      Platform.environment['HYPRLAND_INSTANCE_SIGNATURE']?.isNotEmpty == true;
}

/// Canonical shortcut representation shared by the Flutter and compositor paths.
class DesktopShortcut {
  DesktopShortcut._(
      {required this.keyName, required List<_ShortcutModifier> modifiers})
      : _modifiers = modifiers;

  final String keyName;
  final List<_ShortcutModifier> _modifiers;

  String get normalized =>
      [..._modifiers.map((modifier) => modifier.uiName), keyName].join('+');

  List<HotKeyModifier> get hotKeyModifiers =>
      _modifiers.map((modifier) => modifier.hotKeyModifier).toList();

  PhysicalKeyboardKey get physicalKey {
    final key = keyName.toUpperCase();
    if (key.length == 1) {
      final code = key.codeUnitAt(0);
      if (code >= 0x41 && code <= 0x5a) {
        return _letterKeys[code] ??
            (throw const DesktopIntegrationException(
                'That key is not supported.'));
      }
      if (code >= 0x30 && code <= 0x39) {
        return _digitKeys[code] ??
            (throw const DesktopIntegrationException(
                'That key is not supported.'));
      }
    }
    final name = switch (key) {
      'SPACE' => 'space',
      'ENTER' => 'enter',
      'ESC' || 'ESCAPE' => 'escape',
      'TAB' => 'tab',
      'BACKSPACE' => 'backspace',
      'DELETE' => 'delete',
      'INSERT' => 'insert',
      'HOME' => 'home',
      'END' => 'end',
      _ => key.toLowerCase(),
    };
    final keyCode = int.tryParse(name.substring(1));
    if (name.startsWith('f') &&
        keyCode != null &&
        keyCode >= 1 &&
        keyCode <= 24) {
      return PhysicalKeyboardKey(0x0007003a + keyCode - 1);
    }
    return switch (name) {
      'space' => PhysicalKeyboardKey.space,
      'enter' => PhysicalKeyboardKey.enter,
      'escape' => PhysicalKeyboardKey.escape,
      'tab' => PhysicalKeyboardKey.tab,
      'backspace' => PhysicalKeyboardKey.backspace,
      'delete' => PhysicalKeyboardKey.delete,
      'insert' => PhysicalKeyboardKey.insert,
      'home' => PhysicalKeyboardKey.home,
      'end' => PhysicalKeyboardKey.end,
      _ => throw const DesktopIntegrationException(
          'That key is not supported. Use a letter, number, F1–F24, or a supported navigation key.'),
    };
  }

  int get hyprlandModifierMask =>
      _modifiers.fold(0, (mask, modifier) => mask | modifier.hyprlandMask);

  String get hyprlandModifiers =>
      _modifiers.map((modifier) => modifier.hyprlandName).join(' ');

  String get hyprlandKey => switch (keyName.toUpperCase()) {
        'SPACE' => 'space',
        'ENTER' => 'Return',
        'ESC' || 'ESCAPE' => 'Escape',
        'TAB' => 'Tab',
        'BACKSPACE' => 'BackSpace',
        'DELETE' => 'Delete',
        _ => keyName.toUpperCase(),
      };

  static DesktopShortcut parse(String value) {
    final parts = value.trim().split('+').map((part) => part.trim()).toList();
    if (parts.length < 2 || parts.any((part) => part.isEmpty)) {
      throw const DesktopIntegrationException(
          'Enter a shortcut such as Ctrl+Alt+V.');
    }
    final key = _canonicalKey(parts.removeLast());
    final modifiers = <_ShortcutModifier>[];
    for (final value in parts) {
      final modifier = _ShortcutModifier.parse(value);
      if (modifiers.contains(modifier)) {
        throw const DesktopIntegrationException(
            'A shortcut cannot repeat the same modifier.');
      }
      modifiers.add(modifier);
    }
    // Validate that Flutter can bind the physical key before touching any OS state.
    final shortcut = DesktopShortcut._(keyName: key, modifiers: modifiers);
    shortcut.physicalKey;
    return shortcut;
  }

  static String _canonicalKey(String value) {
    final upper = value.toUpperCase();
    if (upper.length == 1 && RegExp(r'^[A-Z0-9]$').hasMatch(upper)) {
      return upper;
    }
    if (RegExp(r'^F([1-9]|1[0-9]|2[0-4])$').hasMatch(upper)) return upper;
    return switch (upper) {
      'SPACE' => 'SPACE',
      'ENTER' || 'RETURN' => 'ENTER',
      'ESC' || 'ESCAPE' => 'ESCAPE',
      'TAB' => 'TAB',
      'BACKSPACE' => 'BACKSPACE',
      'DELETE' || 'DEL' => 'DELETE',
      'INSERT' => 'INSERT',
      'HOME' => 'HOME',
      'END' => 'END',
      _ => throw const DesktopIntegrationException(
          'That key is not supported. Use a letter, number, F1–F24, or a supported navigation key.'),
    };
  }

  static const Map<int, PhysicalKeyboardKey> _letterKeys = {
    0x41: PhysicalKeyboardKey.keyA,
    0x42: PhysicalKeyboardKey.keyB,
    0x43: PhysicalKeyboardKey.keyC,
    0x44: PhysicalKeyboardKey.keyD,
    0x45: PhysicalKeyboardKey.keyE,
    0x46: PhysicalKeyboardKey.keyF,
    0x47: PhysicalKeyboardKey.keyG,
    0x48: PhysicalKeyboardKey.keyH,
    0x49: PhysicalKeyboardKey.keyI,
    0x4a: PhysicalKeyboardKey.keyJ,
    0x4b: PhysicalKeyboardKey.keyK,
    0x4c: PhysicalKeyboardKey.keyL,
    0x4d: PhysicalKeyboardKey.keyM,
    0x4e: PhysicalKeyboardKey.keyN,
    0x4f: PhysicalKeyboardKey.keyO,
    0x50: PhysicalKeyboardKey.keyP,
    0x51: PhysicalKeyboardKey.keyQ,
    0x52: PhysicalKeyboardKey.keyR,
    0x53: PhysicalKeyboardKey.keyS,
    0x54: PhysicalKeyboardKey.keyT,
    0x55: PhysicalKeyboardKey.keyU,
    0x56: PhysicalKeyboardKey.keyV,
    0x57: PhysicalKeyboardKey.keyW,
    0x58: PhysicalKeyboardKey.keyX,
    0x59: PhysicalKeyboardKey.keyY,
    0x5a: PhysicalKeyboardKey.keyZ,
  };
  static const Map<int, PhysicalKeyboardKey> _digitKeys = {
    0x30: PhysicalKeyboardKey.digit0,
    0x31: PhysicalKeyboardKey.digit1,
    0x32: PhysicalKeyboardKey.digit2,
    0x33: PhysicalKeyboardKey.digit3,
    0x34: PhysicalKeyboardKey.digit4,
    0x35: PhysicalKeyboardKey.digit5,
    0x36: PhysicalKeyboardKey.digit6,
    0x37: PhysicalKeyboardKey.digit7,
    0x38: PhysicalKeyboardKey.digit8,
    0x39: PhysicalKeyboardKey.digit9,
  };
}

enum _ShortcutModifier {
  control('CTRL', 'CTRL', 4, HotKeyModifier.control),
  shift('SHIFT', 'SHIFT', 1, HotKeyModifier.shift),
  alt('ALT', 'ALT', 8, HotKeyModifier.alt),
  meta('CMD', 'SUPER', 64, HotKeyModifier.meta);

  const _ShortcutModifier(
      this.uiName, this.hyprlandName, this.hyprlandMask, this.hotKeyModifier);

  final String uiName;
  final String hyprlandName;
  final int hyprlandMask;
  final HotKeyModifier hotKeyModifier;

  static _ShortcutModifier parse(String value) =>
      switch (value.trim().toLowerCase()) {
        'ctrl' || 'control' => control,
        'shift' => shift,
        'alt' || 'option' => alt,
        'cmd' || 'command' || 'meta' || 'super' || 'win' => meta,
        _ => throw const DesktopIntegrationException(
            'Use Ctrl, Shift, Alt/Option, or Cmd/Super as shortcut modifiers.'),
      };
}

class _CaptureSuppression {
  final Map<String, DateTime> _entries = {};

  void add(String text, {required Duration lifetime}) {
    final now = DateTime.now();
    _entries.removeWhere((_, expiresAt) => !expiresAt.isAfter(now));
    _entries[text] = now.add(lifetime);
    while (_entries.length > 16) {
      _entries.remove(_entries.keys.first);
    }
  }

  bool isSuppressed(String text) {
    final now = DateTime.now();
    _entries.removeWhere((_, expiresAt) => !expiresAt.isAfter(now));
    return _entries.containsKey(text);
  }

  void remove(String text) => _entries.remove(text);

  void clear() => _entries.clear();
}

class _LengthPrefixedTextDecoder {
  _LengthPrefixedTextDecoder({required this.maximumLength});

  final int maximumLength;
  final List<int> _header = [];
  final List<int> _payload = [];
  int? _expectedLength;

  void add(List<int> bytes, void Function(Uint8List frame) onFrame) {
    var offset = 0;
    while (offset < bytes.length) {
      final expected = _expectedLength;
      if (expected == null) {
        final count =
            (4 - _header.length).clamp(0, bytes.length - offset).toInt();
        _header.addAll(bytes.getRange(offset, offset + count));
        offset += count;
        if (_header.length < 4) continue;

        final length = (_header[0] << 24) |
            (_header[1] << 16) |
            (_header[2] << 8) |
            _header[3];
        _header.clear();
        if (length <= 0 || length > maximumLength) {
          throw const FormatException('Invalid clipboard frame length.');
        }
        _expectedLength = length;
        continue;
      }

      final count =
          (expected - _payload.length).clamp(0, bytes.length - offset).toInt();
      _payload.addAll(bytes.getRange(offset, offset + count));
      offset += count;
      if (_payload.length == expected) {
        final frame = Uint8List.fromList(_payload);
        _payload.clear();
        _expectedLength = null;
        onFrame(frame);
      }
    }
  }
}

class _WindowSnapshot {
  const _WindowSnapshot({
    required this.visible,
    required this.size,
    required this.position,
    required this.alwaysOnTop,
    required this.skipTaskbar,
    required this.resizable,
  });

  final bool visible;
  final Size size;
  final Offset position;
  final bool alwaysOnTop;
  final bool skipTaskbar;
  final bool resizable;
}

class _HyprlandBinding {
  const _HyprlandBinding({
    required this.modifiers,
    required this.key,
    required this.modifierMask,
    required this.marker,
    this.luaHandle,
  });

  final String modifiers;
  final String key;
  final int modifierMask;
  final String marker;
  final String? luaHandle;
}

class _HyprlandTarget {
  const _HyprlandTarget(
      {required this.address,
      required this.pid,
      required this.startTicks,
      this.className = ''});

  final String address;
  final int pid;
  final int startTicks;
  final String className;

  /// Terminals reserve Ctrl+V; they paste the clipboard with Ctrl+Shift+V.
  String get pasteModifiers =>
      isTerminalWindowClass(className) ? 'CTRL SHIFT' : 'CTRL';

  bool sameIdentity(_HyprlandTarget other) =>
      address == other.address &&
      pid == other.pid &&
      startTicks == other.startTicks;
}

class _HyprlandBind {
  const _HyprlandBind(
      {required this.modifierMask, required this.key, required this.argument});

  final int modifierMask;
  final String key;
  final String argument;

  factory _HyprlandBind.fromJson(Map<String, dynamic> value) => _HyprlandBind(
        modifierMask: value['modmask'] is int ? value['modmask'] as int : -1,
        key: value['key'] is String ? value['key'] as String : '',
        argument: '${value['arg'] is String ? value['arg'] : ''} '
            '${value['description'] is String ? value['description'] : ''}',
      );
}

List<String> _modifiersFromMask(int mask) {
  const maskToName = <int, String>{
    4: 'CTRL',
    1: 'SHIFT',
    8: 'ALT',
    64: 'SUPER'
  };
  final names = <String>[];
  for (final entry in maskToName.entries) {
    if ((mask & entry.key) != 0) names.add(entry.value);
  }
  return names;
}

String _processError(ProcessResult result) {
  final stderr = (result.stderr as String).trim();
  if (stderr.isNotEmpty) return stderr;
  return (result.stdout as String).trim();
}

String _hyprlandHandle(String marker, int mask, String key) =>
    '${marker}_${mask}_${key.toUpperCase()}';

String _removeHyprlandLuaHandle(String handle) {
  final key = _luaString(handle);
  return 'local b = rawget(_G, $key); if b then b:remove(); rawset(_G, $key, nil) end';
}

String _luaString(String value) {
  final result = StringBuffer('"');
  for (final rune in value.runes) {
    if (rune == 34 || rune == 92) {
      result.write('\\${String.fromCharCode(rune)}');
    } else if (rune < 32 || rune == 127) {
      result.write('\\${rune.toString().padLeft(3, '0')}');
    } else {
      result.write(String.fromCharCode(rune));
    }
  }
  return '${result.toString()}"';
}

/// Window classes of terminal emulators, which paste with Ctrl+Shift+V.
bool isTerminalWindowClass(String value) => RegExp(
      r'(^|[.\-_ ])(kitty|foot|footclient|alacritty|wezterm|ghostty|konsole|'
      r'console|terminal|term|xterm|urxvt|rxvt|st-256color|tilix|terminator|'
      r'terminology|contour|rio|blackbox|warp|tabby|hyper|cool-retro-term)'
      r'($|[.\-_ ])',
      caseSensitive: false,
    ).hasMatch(value) ||
    value.toLowerCase().contains('terminal');
