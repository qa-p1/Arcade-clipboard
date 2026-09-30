import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../platform/desktop_adapter.dart';
import '../platform/mobile_share_bridge.dart';
import 'core_api.dart';

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({
    CoreApi? core,
    DesktopAdapter? desktop,
    MobileShareBridge? mobile,
    Directory? dataDirectory,
  })
      : _core = core ?? RustCoreApi(),
        _desktop = desktop ?? DesktopAdapter(),
        _mobile = mobile ?? MobileShareBridge(),
        _dataDirectoryOverride = dataDirectory;

  final CoreApi _core;
  final DesktopAdapter _desktop;
  final MobileShareBridge _mobile;
  final Directory? _dataDirectoryOverride;

  MeshStatus? _status;
  List<ClipboardItem> _items = const [];
  List<ClipboardItem> _keyboardItems = const [];
  List<ClipboardItem> _overlayItems = const [];
  List<MeshDevice> _devices = const [];
  List<PairingRequest> _pairings = const [];
  PairingInvite? _invite;
  PairingRequest? _currentJoin;
  final Set<String> _approvedPairingSessions = {};
  String? _query;
  final Map<String, String> _errors = {};
  final Map<String, int> _errorOrder = {};
  int _errorSerial = 0;
  String? _notice;
  String _shortcut = '';
  int _retentionHours = 24;
  ThemeMode _themeMode = ThemeMode.system;
  bool _ready = false;
  bool _loading = true;
  bool _historyLoading = false;
  bool _devicesLoading = false;
  bool _overlayOpen = false;
  bool _working = false;
  bool _overlayBusy = false;
  bool _overlaySearchLoading = false;
  bool _desktopReady = false;
  bool _desktopCaptureEnabled = false;
  bool _automaticDesktopCapture = false;
  bool _disposed = false;
  bool _observerAdded = false;
  bool _watchRunning = false;
  bool _drainingSharedInbox = false;
  Future<void>? _startFuture;
  int _statusGeneration = 0;
  int _historyGeneration = 0;
  int _overlayHistoryGeneration = 0;
  int _devicesGeneration = 0;
  int _revision = 0;
  Future<void> _keyboardPublishQueue = Future<void>.value();
  String? _overlayQuery;
  DesktopCapabilities? _desktopCapabilities;

  MeshStatus? get status => _status;
  List<ClipboardItem> get items => _items;
  List<ClipboardItem> get overlayItems => _overlayItems;
  List<MeshDevice> get devices => _devices
      .where((device) => device.id != _status?.deviceId)
      .toList(growable: false);
  bool get canManageDevices => _devices.any(
        (device) => device.id == _status?.deviceId && device.isOwner,
      );
  List<PairingRequest> get pairings => _pairings;
  PairingInvite? get invite => _invite;
  PairingRequest? get currentJoin => _currentJoin;
  bool pairingApproved(String sessionId) => _approvedPairingSessions.contains(sessionId);
  String? get query => _query;
  String? get error {
    if (_errors.isEmpty) return null;
    final source = _errorOrder.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    return _errors[source];
  }
  String? get notice => _notice;
  String get shortcut => _shortcut;
  int get retentionHours => _retentionHours;
  ThemeMode get themeMode => _themeMode;
  bool get ready => _ready;
  bool get loading => _loading;
  bool get historyLoading => _historyLoading;
  bool get devicesLoading => _devicesLoading;
  bool get overlayOpen => _overlayOpen;
  bool get working => _working;
  bool get overlayBusy => _overlayBusy;
  bool get overlaySearchLoading => _overlaySearchLoading;
  bool get automaticDesktopCapture => _automaticDesktopCapture;
  DesktopCapabilities? get desktopCapabilities => _desktopCapabilities;
  bool get desktopAvailable => Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  bool get _isMobilePlatform => Platform.isIOS || Platform.isAndroid;
  bool get hasMesh => _status?.hasMesh ?? false;

  Future<void> start() {
    if (_disposed || _ready) return Future<void>.value();
    final existing = _startFuture;
    if (existing != null) return existing;
    final task = _start();
    _startFuture = task;
    return task.whenComplete(() {
      if (identical(_startFuture, task)) _startFuture = null;
    });
  }

  Future<void> _start() async {
    if (!_observerAdded) {
      WidgetsBinding.instance.addObserver(this);
      _observerAdded = true;
    }
    _clearError('startup');
    _loading = true;
    _notifyListeners();
    try {
      await _core.initializeBridge();
      final prefs = await SharedPreferences.getInstance();
      final runtimeDataDir = Platform.environment['ARCADE_DATA_DIR']?.trim();
      final buildDataDir = const String.fromEnvironment('ARCADE_DATA_DIR').trim();
      final configuredDataDir = runtimeDataDir?.isNotEmpty == true ? runtimeDataDir! : buildDataDir;
      final support = _dataDirectoryOverride ?? (configuredDataDir.isNotEmpty
          ? Directory(configuredDataDir)
          : await getApplicationSupportDirectory());
      await support.create(recursive: true);
      if (_disposed) return;
      final deviceName = prefs.getString('device_name') ?? _defaultDeviceName();
      await prefs.setString('device_name', deviceName);
      _shortcut = prefs.getString('mesh_shortcut') ?? _defaultShortcut();
      _themeMode = switch (prefs.getString('appearance_mode')) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      _automaticDesktopCapture = prefs.getBool('automatic_desktop_capture') ?? false;
      final initialized = await _core.invoke('initialize', {
        'data_dir': support.path,
        'device_name': deviceName,
      });
      _status = MeshStatus.fromJson(initialized);
      _revision = _status!.revision;
      await _loadSettings();
      await refreshStatus();
      if (_status?.hasMesh == true) {
        await Future.wait([refreshHistory(), refreshDevices()]);
      }
      _ready = true;
      if (desktopAvailable) {
        try {
          _desktopCapabilities = await _desktop.initialize(
            onTextCaptured: _captureFromDesktop,
            onOverlayRequested: openOverlay,
          );
          _desktopReady = true;
          await _syncDesktopCaptureEnabled();
          if (_desktopCapabilities?.globalShortcut == true) {
            await _desktop.configureShortcut(_shortcut);
          } else {
            _notice = _desktopCapabilities?.detail.isNotEmpty == true
                ? _desktopCapabilities!.detail
                : 'Global shortcuts are not available in this desktop session.';
          }
        } catch (exception) {
          _setError(exception, source: 'desktop');
        }
      }
      await _drainSharedInbox();
      unawaited(_watchChanges());
    } catch (exception) {
      _setError(exception, source: 'startup');
    } finally {
      _loading = false;
      _notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _ready) {
      unawaited(refreshAll());
    }
  }

  Future<void> refreshAll() async {
    await refreshStatus();
    if (hasMesh) {
      await Future.wait([refreshHistory(), refreshDevices()]);
    }
    await _drainSharedInbox();
  }

  Future<void> _watchChanges() async {
    if (_watchRunning || _disposed) return;
    _watchRunning = true;
    var delaySeconds = 1;
    try {
      while (!_disposed && _ready) {
        final afterRevision = _revision;
        try {
          final result = await _core.invoke('wait_for_change', {'after_revision': afterRevision});
          if (_disposed) break;
          final revision = _latestInt(
            _intValue(result['revision']),
            _intValue(result['status_revision']),
          );
          if (revision != null && revision > afterRevision) {
            if (revision > _revision) _revision = revision;
            await refreshStatus();
            if (hasMesh) {
              await Future.wait([
                refreshHistory(query: _query),
                refreshDevices(),
              ]);
            }
            await _drainSharedInbox();
          } else {
            // A timed-out long poll may return the same revision. Keep that
            // path from becoming a tight loop if a core implementation or
            // transient bridge error returns immediately.
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          _clearError('watch');
          delaySeconds = 1;
        } catch (exception) {
          if (!_disposed) _setError(exception, source: 'watch');
          await Future<void>.delayed(Duration(seconds: delaySeconds));
          delaySeconds = (delaySeconds * 2).clamp(1, 15);
          _notifyListeners();
        }
      }
    } finally {
      _watchRunning = false;
    }
  }

  Future<void> refreshStatus() async {
    final generation = ++_statusGeneration;
    try {
      final data = await _core.invoke('status');
      if (_disposed || generation != _statusGeneration) return;
      final status = MeshStatus.fromJson(data);
      _status = status;
      _revision = status.revision > _revision ? status.revision : _revision;
      final now = DateTime.now();
      _pairings = status.pendingPairings
          .where((pairing) => pairing.expiresAt == null || pairing.expiresAt!.isAfter(now))
          .toList(growable: false);
      if (!status.hasMesh) {
        _items = const [];
        _keyboardItems = const [];
        _overlayItems = const [];
        _historyLoading = false;
        _overlaySearchLoading = false;
        _overlayQuery = null;
        _overlaySearchLoading = false;
        _historyGeneration++;
        _overlayHistoryGeneration++;
      }
      if (_currentJoin != null) {
        final matching = _pairings.where((entry) => entry.sessionId == _currentJoin!.sessionId);
        if (matching.isNotEmpty) {
          _currentJoin = matching.first;
        } else if (status.hasMesh) {
          _currentJoin = null;
        } else {
          final expired = _currentJoin!.expiresAt != null && !_currentJoin!.expiresAt!.isAfter(now);
          _currentJoin = null;
          _notice = expired
              ? 'The pairing request expired. Ask for a new invite and try again.'
              : 'The pairing request ended. Ask for a new invite and try again.';
        }
      }
      await _syncDesktopCaptureEnabled();
      _clearError('status');
      await _publishKeyboardHistory();
    } catch (exception) {
      if (!_disposed && generation == _statusGeneration) _setError(exception, source: 'status');
    }
    _notifyListeners();
  }

  Future<void> refreshHistory({String? query, bool publishKeyboard = true}) async {
    if (query != null && query != _query) {
      _query = query;
      _items = const [];
    }
    final generation = ++_historyGeneration;
    _historyLoading = true;
    _notifyListeners();
    if (!hasMesh) {
      _items = const [];
      _keyboardItems = const [];
      _overlayItems = const [];
      _overlayQuery = null;
      _overlaySearchLoading = false;
      _historyLoading = false;
      _clearError('history');
      if (publishKeyboard) await _publishKeyboardHistory();
      _notifyListeners();
      return;
    }
    final activeQuery = _query ?? '';
    var errorSource = 'history';
    try {
      final data = await _core.invoke('history', {'query': activeQuery, 'limit': 250});
      final result = _parseHistory(data);
      if (generation != _historyGeneration || _disposed) return;
      _items = _sortedItems(result);
      _clearError('history');
      if (publishKeyboard && _isMobilePlatform) {
        // The platform keyboard has its own independent cache. Always source
        // it from unfiltered recent history so an app search cannot shrink it.
        errorSource = 'keyboard-history';
        final allData = activeQuery.isEmpty
            ? data
            : await _core.invoke('history', {'query': '', 'limit': 250});
        if (generation == _historyGeneration && !_disposed) {
          _keyboardItems = _recentItems(_parseHistory(allData), limit: 40);
          _clearError('keyboard-history');
        }
      } else if (activeQuery.isEmpty && _isMobilePlatform) {
        _keyboardItems = _recentItems(result, limit: 40);
      }
      if (publishKeyboard && generation == _historyGeneration && !_disposed) {
        await _publishKeyboardHistory();
      }
    } catch (exception) {
      if (generation == _historyGeneration && !_disposed) {
        _setError(exception, source: errorSource);
      }
    } finally {
      if (generation == _historyGeneration) _historyLoading = false;
    }
    _notifyListeners();
  }

  List<ClipboardItem> _parseHistory(Map<String, dynamic> data) {
    final rows = (data['items'] ?? data['history'] ?? data['rows']) as List<dynamic>? ?? const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(ClipboardItem.fromJson)
        .where((item) => item.id.isNotEmpty && !item.isExpiredAt(DateTime.now()))
        .toList(growable: false);
  }

  List<ClipboardItem> _sortedItems(List<ClipboardItem> items) => [...items]
    ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.createdAt.compareTo(a.createdAt);
      });

  List<ClipboardItem> _recentItems(List<ClipboardItem> items, {required int limit}) => [...items]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt))
    ..removeRange(limit < items.length ? limit : items.length, items.length);

  Future<void> refreshDevices() async {
    final generation = ++_devicesGeneration;
    _devicesLoading = true;
    _notifyListeners();
    if (!hasMesh) {
      _devices = const [];
      _devicesLoading = false;
      _clearError('devices');
      _notifyListeners();
      return;
    }
    try {
      final data = await _core.invoke('devices');
      if (generation != _devicesGeneration || _disposed) return;
      final rows = (data['devices'] ?? data['items']) as List<dynamic>? ?? const [];
      _devices = rows
          .whereType<Map<String, dynamic>>()
          .map(MeshDevice.fromJson)
          .where((device) => device.id.isNotEmpty)
          .toList(growable: false);
      _clearError('devices');
    } catch (exception) {
      if (generation == _devicesGeneration && !_disposed) _setError(exception, source: 'devices');
    } finally {
      if (generation == _devicesGeneration) _devicesLoading = false;
    }
    _notifyListeners();
  }

  Future<void> searchOverlay(String query) async {
    final generation = ++_overlayHistoryGeneration;
    final cleanedQuery = query.trim();
    if (_overlayQuery != cleanedQuery) _overlayItems = const [];
    _overlayQuery = cleanedQuery;
    _overlaySearchLoading = true;
    _notifyListeners();
    if (!hasMesh) {
      _overlayItems = const [];
      _overlaySearchLoading = false;
      _clearError('overlay-history');
      _notifyListeners();
      return;
    }
    try {
      final data = await _core.invoke('history', {'query': cleanedQuery, 'limit': 250});
      if (generation != _overlayHistoryGeneration || _disposed) return;
      _overlayItems = _sortedItems(_parseHistory(data));
      _clearError('overlay-history');
    } catch (exception) {
      if (generation == _overlayHistoryGeneration && !_disposed) {
        _setError(exception, source: 'overlay-history');
      }
    } finally {
      if (generation == _overlayHistoryGeneration) {
        _overlaySearchLoading = false;
        _notifyListeners();
      }
    }
  }

  Future<void> createMesh(String deviceName) async => _perform(() async {
        final name = deviceName.trim();
        if (name.isEmpty) throw const AppActionException('Add a name for this device.');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('device_name', name);
        await _core.invoke('create_mesh', {'device_name': name});
        await refreshStatus();
        await Future.wait([refreshHistory(), refreshDevices()]);
      });

  Future<void> createInvite() async => _perform(() async {
        if (!canManageDevices) {
          throw const AppActionException('Only the mesh owner can add devices.');
        }
        _invite = null;
        final response = await _core.invoke('create_invite');
        final invite = PairingInvite.fromJson(response);
        if (invite.invite.isEmpty) {
          throw const AppActionException('The pairing service did not return an invite.');
        }
        _invite = invite;
        _notice = null;
      });

  Future<void> joinMesh({required String invite, required String deviceName}) async =>
      _perform(() async {
        if (invite.trim().isEmpty) throw const AppActionException('Paste the pairing code first.');
        if (deviceName.trim().isEmpty) throw const AppActionException('Add a name for this device.');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('device_name', deviceName.trim());
        final joinData = await _core.invoke('join', {
          'invite': invite.trim(),
          'device_name': deviceName.trim(),
        });
        final pairingData = joinData['pairing'] is Map<String, dynamic>
            ? joinData['pairing'] as Map<String, dynamic>
            : joinData;
        final pairing = PairingRequest.fromJoinResponse(pairingData);
        if (pairing.sessionId.isNotEmpty) _currentJoin = pairing;
        await refreshStatus();
        if (_currentJoin == null) {
          final outbound = _pairings.where((entry) => entry.direction == 'outbound');
          if (outbound.isNotEmpty) _currentJoin = outbound.first;
        }
        await refreshDevices();
        _notice = 'Compare the verification code on both devices before approving.';
      });

  Future<void> confirmPairing(String sessionId, {required bool accept}) async =>
      _perform(() async {
        if (sessionId.isEmpty) throw const AppActionException('This pairing request has expired. Ask for a new invite.');
        await _core.invoke('confirm_pairing', {'session_id': sessionId, 'accept': accept});
        if (accept) _approvedPairingSessions.add(sessionId);
        if (!accept && _currentJoin?.sessionId == sessionId) _currentJoin = null;
        await refreshStatus();
        await refreshDevices();
        if (accept) _notice = 'Pairing approval sent. This device will appear when both sides approve.';
        if (!accept) _notice = 'Pairing request declined.';
      });

  Future<void> revokeDevice(MeshDevice device) async => _perform(() async {
        if (!canManageDevices) {
          throw const AppActionException('Only the mesh owner can remove devices.');
        }
        if (device.id == _status?.deviceId || device.isOwner) {
          throw const AppActionException('The mesh owner cannot be removed.');
        }
        await _core.invoke('revoke', {'device_id': device.id});
        await refreshDevices();
      });

  Future<void> deleteItem(ClipboardItem item) async => _perform(() async {
        await _core.invoke('delete', {'id': item.id});
        await refreshHistory(query: _query);
      });

  Future<void> setPinned(ClipboardItem item, bool pinned) async => _perform(() async {
        await _core.invoke('pin', {'id': item.id, 'pinned': pinned});
        await refreshHistory(query: _query);
      });

  Future<void> setPrivatePause(bool paused) async => _perform(() async {
        await _core.invoke('settings', {'values': {'paused': paused}});
        await refreshStatus();
      });

  Future<void> setRetentionHours(int hours) async => _perform(() async {
        if (!const {1, 24, 168, 720}.contains(hours)) {
          throw const AppActionException('Choose a supported history retention period.');
        }
        await _core.invoke('settings', {'values': {'retention_hours': hours}});
        await _loadSettings();
      });

  Future<void> setThemeMode(ThemeMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('appearance_mode', switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      });
      if (_disposed) return;
      _themeMode = mode;
      _clearError('settings');
    } catch (exception) {
      _setError(exception, source: 'settings');
    }
    _notifyListeners();
  }

  Future<void> setAutomaticDesktopCapture(bool enabled) async => _perform(() async {
        if (!desktopAvailable) {
          throw const AppActionException('Automatic clipboard capture is available on desktop.');
        }
        if (!_desktopReady) {
          throw const AppActionException('Desktop clipboard monitoring is not available in this session.');
        }
        final effective = enabled && hasMesh && _status?.paused != true;
        await _desktop.setCaptureEnabled(effective);
        _desktopCaptureEnabled = effective;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('automatic_desktop_capture', enabled);
        _automaticDesktopCapture = enabled;
        _notice = enabled
            ? 'Desktop clipboard capture is on. Copied text can contain sensitive information; the app cannot identify or exclude passwords.'
            : 'Desktop clipboard capture is off.';
      });

  Future<void> configureShortcut(String shortcut) async => _perform(() async {
        final cleaned = shortcut.trim();
        if (cleaned.isEmpty) throw const AppActionException('Enter a shortcut combination.');
        if (!_desktopReady || _desktopCapabilities?.globalShortcut != true) {
          throw AppActionException(
            _desktopCapabilities?.detail.isNotEmpty == true
                ? _desktopCapabilities!.detail
                : 'Global shortcuts are available on desktop.',
          );
        }
        await _desktop.configureShortcut(cleaned);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('mesh_shortcut', cleaned);
        _shortcut = cleaned;
        _notice = 'Shortcut updated.';
      });

  Future<void> copyLocally(ClipboardItem item) async {
    try {
      if (_desktopReady) {
        await _desktop.copyText(item.text);
      } else {
        await Clipboard.setData(ClipboardData(text: item.text));
      }
      _notice = 'Copied to this device’s clipboard.';
    } catch (exception) {
      _setError(exception, source: 'action');
    }
    _notifyListeners();
  }

  Future<void> openOverlay() async {
    if (!_desktopReady || _desktopCapabilities?.overlay == false || !hasMesh || _overlayBusy || _disposed) return;
    _overlayBusy = true;
    _notifyListeners();
    try {
      _overlayOpen = true;
      _overlayQuery = null;
      unawaited(searchOverlay(''));
      _notifyListeners();
      await _desktop.showOverlay();
    } catch (exception) {
      _overlayOpen = false;
      _setError(exception, source: 'overlay');
    } finally {
      _overlayBusy = false;
      _notifyListeners();
    }
  }

  Future<void> dismissOverlay() async {
    if (!_overlayOpen) return;
    _overlayHistoryGeneration++;
    _overlaySearchLoading = false;
    _overlayOpen = false;
    _notifyListeners();
    try {
      await _desktop.hideOverlay();
    } catch (exception) {
      _setError(exception, source: 'overlay');
    }
  }

  Future<void> selectOverlayItem(ClipboardItem item) async {
    _overlayHistoryGeneration++;
    _overlaySearchLoading = false;
    _overlayOpen = false;
    _notifyListeners();
    try {
      await _desktop.hideOverlay();
      if (_desktopCapabilities?.paste != false) {
        await _desktop.pasteText(item.text);
        _notice = null;
      } else {
        await _desktop.copyText(item.text);
        _notice = 'This desktop cannot paste into other apps here. The clip is ready; press Ctrl+V to paste.';
      }
      _clearError('overlay');
    } catch (exception) {
      try {
        await _desktop.copyText(item.text);
        _notice = 'Automatic paste was unavailable. The clip is on your clipboard; press Ctrl+V to paste.';
      } catch (_) {
        _setError(exception, source: 'overlay');
      }
    }
    _notifyListeners();
  }

  Future<void> _captureFromDesktop(String text) async {
    if (!_automaticDesktopCapture || !hasMesh || text.trim().isEmpty || _status?.paused == true) return;
    try {
      await _core.invoke('capture', {'text': text});
      await refreshHistory(query: _query);
      _notice = null;
    } catch (exception) {
      _setError(exception, source: 'capture');
    }
    _notifyListeners();
  }

  Future<void> _drainSharedInbox() async {
    if (!_isMobilePlatform || _drainingSharedInbox) return;
    if (_status?.paused == true || !hasMesh) return;
    _drainingSharedInbox = true;
    try {
      final clips = await _mobile.drainSharedInbox();
      final acknowledged = <String>[];
      var captureFailed = false;
      for (final clip in clips) {
        try {
          await _core.invoke('capture', {
            'id': clip.id,
            'text': clip.text,
            'kind': clip.kind,
          });
          acknowledged.add(clip.id);
        } catch (exception) {
          captureFailed = true;
          _setError(exception, source: 'mobile-share');
        }
      }
      await _mobile.acknowledgeSharedInbox(acknowledged);
      if (acknowledged.isNotEmpty) await refreshHistory(query: _query);
      if (!captureFailed) {
        _clearError('mobile-share');
        _notifyListeners();
      }
    } catch (exception) {
      _setError(exception, source: 'mobile-share');
    } finally {
      _drainingSharedInbox = false;
    }
  }

  Future<void> _publishKeyboardHistory() async {
    if (!_isMobilePlatform || _disposed) return;
    final items = _keyboardItems.take(40).map((item) => item.toKeyboardJson()).toList(growable: false);
    final paused = _status?.paused ?? false;
    _keyboardPublishQueue = _keyboardPublishQueue.then((_) async {
      if (_disposed) return;
      try {
        await _mobile.publishKeyboardHistory(items: items, paused: paused);
      } on MissingPluginException {
        // The keyboard cache is optional when a mobile extension is not installed.
      } catch (_) {
        // Keep the primary mesh path usable if a platform keyboard cache is unavailable.
      }
    });
    await _keyboardPublishQueue;
  }

  Future<void> _loadSettings() async {
    final result = await _core.invoke('settings');
    _retentionHours = (result['retention_hours'] as num?)?.toInt() ?? 24;
    if (result.containsKey('paused') && _status != null) {
      _status = MeshStatus(
        initialized: _status!.initialized,
        meshId: _status!.meshId,
        deviceId: _status!.deviceId,
        deviceName: _status!.deviceName,
        paused: result['paused'] == true,
        connection: _status!.connection,
        diagnostic: _status!.diagnostic,
        revision: _status!.revision,
        pendingPairings: _status!.pendingPairings,
      );
    }
  }

  Future<void> _syncDesktopCaptureEnabled() async {
    if (!_desktopReady || _disposed) return;
    final enabled = _automaticDesktopCapture && hasMesh && _status?.paused != true;
    if (enabled == _desktopCaptureEnabled) return;
    try {
      await _desktop.setCaptureEnabled(enabled);
      _desktopCaptureEnabled = enabled;
    } catch (exception) {
      _setError(exception, source: 'desktop');
    }
  }

  Future<void> _perform(Future<void> Function() operation) async {
    if (_working || _disposed) return;
    _working = true;
    _clearError('action');
    _notice = null;
    _notifyListeners();
    try {
      await operation();
      _clearError('action');
    } catch (exception) {
      _setError(exception, source: 'action');
    } finally {
      _working = false;
      _notifyListeners();
    }
  }

  void _setError(Object exception, {String source = 'action'}) {
    if (_disposed) return;
    _errors[source] = _friendlyError(exception);
    _errorOrder[source] = ++_errorSerial;
    _notifyListeners();
  }

  void _clearError([String? source]) {
    if (source == null) {
      _errors.clear();
      _errorOrder.clear();
      return;
    }
    _errors.remove(source);
    _errorOrder.remove(source);
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  String _friendlyError(Object exception) {
    if (exception is AppActionException) return exception.message;
    final message = exception.toString().replaceFirst(RegExp(r'^Exception: '), '').trim();
    final normalized = message.toLowerCase();
    if (normalized.contains('keychain') ||
        normalized.contains('keystore') ||
        normalized.contains('secret service') ||
        normalized.contains('keyring') ||
        normalized.contains('secure store')) {
      return 'The secure key store is unavailable. Unlock or set up your system keyring, then retry secure setup.';
    }
    if (normalized.contains('shortcut') && normalized.contains('conflict')) {
      return 'That shortcut is already in use. Choose another key combination.';
    }
    return message.isEmpty ? 'Something went wrong. Try again.' : message;
  }

  String _defaultDeviceName() {
    final host = Platform.localHostname.trim();
    return host.isEmpty ? 'My ${_platformName()}' : host;
  }

  String _platformName() => switch (Platform.operatingSystem) {
        'windows' => 'PC',
        'macos' => 'Mac',
        'linux' => 'Linux device',
        'ios' => 'iPhone',
        'android' => 'Android device',
        _ => 'device',
      };

  String _defaultShortcut() => switch (Platform.operatingSystem) {
        'macos' => 'CMD+SHIFT+V',
        'windows' => 'CTRL+SHIFT+V',
        _ => 'CTRL+SHIFT+SPACE',
      };

  @override
  void dispose() {
    _disposed = true;
    if (_observerAdded) WidgetsBinding.instance.removeObserver(this);
    if (_ready) unawaited(_core.invoke('shutdown').then<void>((_) {}).catchError((_) {}));
    unawaited(_desktop.dispose());
    super.dispose();
  }
}

class AppActionException implements Exception {
  const AppActionException(this.message);

  final String message;

  @override
  String toString() => message;
}

int? _intValue(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

int? _latestInt(int? first, int? second) {
  if (first == null) return second;
  if (second == null) return first;
  return first > second ? first : second;
}
