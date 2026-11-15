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
import 'hyprland.dart';
import 'wayland_clipboard.dart';

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

  static const Size _overlaySize = Size(480, 520);
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
          ? readWaylandClipboard(_wlPastePath!)
          : _bridge.readClipboard();
  bool _backgroundEnabled = false;

  Future<Map<String, Object?>> askMoveToApplications(
          String title, String body, List<String> buttons) =>
      _bridge.askMoveToApplications(title, body, buttons);

  Future<void> relaunch(String path) => _bridge.relaunch(path);

  /// Shows Private mode's state on the own tray menu (Tools' menu reads it
  /// from the manifest). Kept until the tray exists.
  Future<void> setPrivateMode(bool enabled) async {
    _privateMode = enabled;
    if (!_initialized || _closed) return;
    try {
      await _bridge.setPrivateMode(enabled);
    } on MissingPluginException {
      // Platforms without a tray have no menu to update.
    }
  }

  bool _privateMode = false;

  Future<void> setTrayHosted(bool hosted) async {
    if (!_initialized || _closed) return;
    try {
      await _bridge.setTrayHosted(hosted);
    } on MissingPluginException {
      // Platforms without a tray have nothing to hide.
    }
  }

  /// Whether global shortcuts go through Hyprland's runtime binds.
  bool get shortcutsViaHyprland =>
      Platform.isLinux && _isWayland && _isHyprland;

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

  /// `--toggle`: hides a visible window, shows a hidden one.
  Future<void> toggleMainWindow() async {
    if (await windowManager.isVisible()) {
      await hideMainWindow();
    } else {
      await showMainWindow();
    }
  }

  Future<void> Function()? _onOverlayRequested;

  /// Runs application shutdown (core and desktop cleanup) before exit.
  Future<void> Function()? onQuit;

  /// Shows the Settings page (the tray's Open Settings item and click).
  void Function()? onOpenSettings;

  /// The tray's Private mode item.
  Future<void> Function()? onTogglePrivateMode;

  /// Set on the successor started by [restart]: the old process id, which it
  /// waits for before claiming the single instance (see main.dart, main.cc).
  static const restartEnvironment = 'ARCADE_CLIPBOARD_RESTART_AFTER';

  /// Starts a new background instance, then quits. Quitting without a
  /// successor would silently remove the app, so a failed start keeps it.
  Future<void> restart() async {
    final executable = restartExecutable(
        Platform.environment, Platform.resolvedExecutable, File.new);
    try {
      await Process.start(executable, ['--background'],
          environment: {restartEnvironment: '$pid'},
          mode: ProcessStartMode.detached);
    } catch (error) {
      Diagnostics.log('lifecycle', 'restart failed: $error');
      return;
    }
    await _quit();
  }

  /// The program a restart starts. Inside an AppImage
  /// [resolvedExecutable] lives in the runtime's mount, which disappears when
  /// this process exits; the successor must be the AppImage file itself
  /// (`$APPIMAGE`), which mounts its own copy.
  @visibleForTesting
  static String restartExecutable(Map<String, String> environment,
      String resolvedExecutable, File Function(String) file) {
    final image = environment['APPIMAGE'];
    if (image != null && image.isNotEmpty && file(image).existsSync()) {
      return image;
    }
    return resolvedExecutable;
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
      await (onQuit?.call() ?? dispose()).timeout(const Duration(seconds: 4));
    } catch (_) {
      // Exit regardless; stale binds are guarded by PID start time.
    }
    exit(0);
  }

  DesktopCapabilities? _capabilities;
  HotKey? _registeredHotKey;
  StreamSubscription<ProcessSignal>? _signalSubscription;
  _WindowSnapshot? _windowSnapshot;
  late final Hyprland _hyprland = Hyprland(_runCommand);
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

  /// Losing focus or the pointer leaving never closes the quick picker (fleet
  /// popup rule): it closes on Escape, choosing a clip, the shortcut again or
  /// an explicit click outside. A blur is therefore ignored on purpose.
  @override
  void onWindowBlur() {}

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

  /// The default on every desktop (STANDARD §10): Ctrl+Alt+V, ⌃⌥V on macOS.
  static const String defaultShortcut = 'CTRL+ALT+V';

  /// The default before 0.3.0, which profiles from then keep.
  static String get previousDefaultShortcut =>
      switch (Platform.operatingSystem) {
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
        globalShortcut = await _hyprland.probe();
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
        } else if (call.method == 'hide') {
          await hideMainWindow();
        } else if (call.method == 'toggle') {
          await toggleMainWindow();
        } else if (call.method == 'settings') {
          await showMainWindow();
          onOpenSettings?.call();
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
      } else if (action == 'privateModeRequested') {
        await onTogglePrivateMode?.call();
      }
    });
    _initialized = true;
    if (_privateMode) unawaited(setPrivateMode(true));
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
          await writeWaylandClipboard(_wlCopyPath, formats, files))) {
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
      Diagnostics.log(
          'capture', 'clipboard change event${initial ? ' (initial)' : ''}');
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
        "Couldn't start clipboard capture. Check that wl-clipboard is installed, then restart the app.",
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
        "Couldn't start clipboard capture. It needs wl-clipboard 2.2 or newer and a compositor with data-control support.",
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
            "Couldn't stop clipboard capture. Close the app only after the watcher exits.",
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
          "Couldn't stop the clipboard watcher safely.");
    }
    try {
      final result = await Process.run(
        helper,
        ['--signal-group', signal, '$pid'],
        runInShell: false,
      );
      if (result.exitCode != 0) {
        throw const DesktopIntegrationException(
            "Couldn't stop the clipboard watcher safely.");
      }
    } catch (error) {
      if (error is DesktopIntegrationException) rethrow;
      throw const DesktopIntegrationException(
          "Couldn't stop the clipboard watcher safely.");
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
      await _hyprland.configureShortcut(parsed);
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

  String _mainTitle = 'Arcade Clipboard';

  /// The window title, "`<Page>` — Arcade Clipboard" (STANDARD §8.1). The
  /// picker borrows the window under its own title and restores this one.
  Future<void> setPageTitle(String? page) async {
    final title =
        page == null ? 'Arcade Clipboard' : '$page — Arcade Clipboard';
    if (title == _mainTitle) return;
    _mainTitle = title;
    if (!_initialized || _closed || _overlayVisible) return;
    try {
      await windowManager.setTitle(_mainTitle);
    } catch (_) {
      // A window that is going away keeps its old title.
    }
  }

  // Distinct from the main window's title so window rules can tell them apart.
  static const String _overlayTitle = 'Arcade Clipboard Picker';

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
        final target = await _hyprland.captureTarget();
        // Invoking the picker from this app itself has no other app to paste into.
        _hyprland.target = target.pid == pid ? null : target;
      } catch (_) {
        // Keep the picker usable for explicit copy fallback when the focused
        // app has no addressable Hyprland window.
        _hyprland.target = null;
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
          "Couldn't open the quick picker: $error");
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
      await _hyprland.ensurePickerRule(
          title: _overlayTitle,
          width: _overlaySize.width.toInt(),
          height: _overlaySize.height.toInt());
      await windowManager.show();
      _overlayVisible = true;
      final own = await _hyprland.ownWindow(_overlayTitle);
      if (own != null) {
        if (own['floating'] != true) {
          await _hyprland.windowAction(own['address'] as String, [
            'hl.dsp.window.float({ action = "set", window = w })',
            'hl.dsp.window.resize({ x = ${_overlaySize.width.toInt()}, y = ${_overlaySize.height.toInt()}, window = w })',
            'hl.dsp.window.center({ window = w })',
          ], legacy: [
            ['setfloating', 'address:${own['address']}'],
            [
              'resizewindowpixel',
              'exact ${_overlaySize.width.toInt()} ${_overlaySize.height.toInt()},address:${own['address']}'
            ],
            ['centerwindow', ''],
          ]);
        }
        await _hyprland.windowAction(own['address'] as String, [
          'hl.dsp.focus({ window = w })'
        ], legacy: [
          ['focuswindow', 'address:${own['address']}']
        ]);
      }
    } catch (error) {
      _overlayVisible = false;
      await _restoreHyprlandMainWindow(focusTarget: true);
      throw DesktopIntegrationException(
          "Couldn't open the quick picker: $error");
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
    if (focusTarget && _hyprland.target != null) {
      await _restoreTargetFocus();
    } else if (snapshot?.visible == true || _hyprland.target == null) {
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
          {
            'mimeType': 'text/plain',
            'bytes': Uint8List.fromList(utf8.encode(text))
          }
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
      final target = _hyprland.target;
      if (target == null) {
        throw const DesktopIntegrationException(
            'The previously focused Hyprland window is unavailable. Copy the clip and paste manually.');
      }
      // The start-time check rejects a reused PID; the dispatch itself
      // re-verifies the window address and PID inside the compositor.
      await _hyprland.assertTargetExists(target);
      await writeClipboard();
      await _hyprland.dispatch('focuswindow', 'address:${target.address}');
      await _hyprland.dispatch('sendshortcut',
          '${target.pasteModifiers},V,address:${target.address}',
          modifiers: target.pasteModifiers);
      Diagnostics.log(
          'paste', 'sent ${target.pasteModifiers}+V to ${target.className}');
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
          "Couldn't focus the previous window. The clip was copied instead.");
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
          "Couldn't paste. The clip was copied instead.");
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
    await _hyprland.removeShortcut();
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
          "Couldn't release the previous shortcut, so the new one wasn't set. $error",
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
                "Couldn't register the shortcut or restore the previous one. $error",
          ));
        }
      } else {
        _registeredHotKey = null;
        _setCapabilities(capabilities.copyWith(
          // A conflict can reject one key while the platform still supports
          // global bindings; leave retries enabled for another combination.
          detail:
              "Couldn't register the shortcut. ${_registrationError(error)}",
        ));
      }
      throw DesktopIntegrationException(_registrationError(error));
    }
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
      final target = _hyprland.target;
      if (target != null) {
        try {
          await _hyprland.assertTargetExists(target);
          await _hyprland.dispatch('focuswindow', 'address:${target.address}');
          await _hyprland.assertTargetExists(target, requireActive: true);
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
    return "Couldn't register the shortcut. $platformDetail $error";
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
      return '$capture This desktop does not let apps register global shortcuts or paste into other windows. Bind a system shortcut to “arcade-clipboard --overlay”; choosing a clip copies it so you can paste with Ctrl+V.';
    }
    if (platform == 'linux-wayland-hyprland') {
      final integration = globalShortcut && paste
          ? 'Hyprland shortcut and direct paste are active.'
          : "Couldn't reach Hyprland through hyprctl.";
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

/// Window classes of terminal emulators, which paste with Ctrl+Shift+V.
bool isTerminalWindowClass(String value) =>
    RegExp(
      r'(^|[.\-_ ])(kitty|foot|footclient|alacritty|wezterm|ghostty|konsole|'
      r'console|terminal|term|xterm|urxvt|rxvt|st-256color|tilix|terminator|'
      r'terminology|contour|rio|blackbox|warp|tabby|hyper|cool-retro-term)'
      r'($|[.\-_ ])',
      caseSensitive: false,
    ).hasMatch(value) ||
    value.toLowerCase().contains('terminal');
