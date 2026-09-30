import 'dart:async';

import 'package:arcade_clipboard/services/core_api.dart';

class FakeCoreApi implements CoreApi {
  FakeCoreApi({required bool hasMesh})
      : _status = _statusFor(hasMesh: hasMesh);

  final List<CoreCall> calls = [];
  final Map<String, Object> failures = {};
  final Map<String, Future<Map<String, dynamic>> Function()> historyReplies = {};
  final List<_Waiter> _waiters = [];
  Map<String, dynamic> _status;
  int _retentionHours = 24;

  @override
  Future<void> initializeBridge() async {}

  @override
  Future<Map<String, dynamic>> invoke(
    String operation, [
    Map<String, Object?> arguments = const {},
  ]) async {
    calls.add(CoreCall(operation, Map<String, Object?>.of(arguments)));
    final failure = failures[operation];
    if (failure != null) throw failure;

    switch (operation) {
      case 'initialize':
        return Map<String, dynamic>.of(_status);
      case 'status':
        return Map<String, dynamic>.of(_status);
      case 'settings':
        final values = arguments['values'];
        if (values is Map<String, Object?>) {
          if (values['paused'] is bool) _status['paused'] = values['paused'];
          if (values['retention_hours'] is num) {
            _retentionHours = (values['retention_hours'] as num).toInt();
          }
          _bumpRevision();
        }
        return {
          'paused': _status['paused'] == true,
          'retention_hours': _retentionHours,
        };
      case 'create_mesh':
        _status['mesh_id'] = 'mesh-1';
        _status['device_name'] = arguments['device_name'] as String? ?? 'This device';
        _bumpRevision();
        return {'mesh_id': 'mesh-1'};
      case 'history':
        final query = arguments['query'] as String? ?? '';
        final reply = historyReplies[query];
        return reply == null ? {'items': <Map<String, dynamic>>[]} : await reply();
      case 'devices':
        final deviceId = _status['device_id'] as String? ?? '';
        if (_status['mesh_id'] == null || deviceId.isEmpty) {
          return {'devices': <Map<String, dynamic>>[]};
        }
        return {
          'devices': <Map<String, dynamic>>[
            {
              'device_id': deviceId,
              'device_name': _status['device_name'],
              'platform': 'Test',
              'state': 'offline',
              'is_owner': true,
            },
          ],
        };
      case 'create_invite':
        return {
          'invite': '{"version":1,"mesh_id":"mesh-1"}',
          'expires_at': DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch,
        };
      case 'join':
        final pairing = <String, dynamic>{
          'session_id': 'outbound-session',
          'peer_name': 'Owner',
          'verification_code': '123 456',
          'expires_at': DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch,
          'direction': 'outbound',
          'state': 'awaiting_confirmation',
        };
        _status['pending_pairings'] = [pairing];
        _bumpRevision();
        return pairing;
      case 'confirm_pairing':
      case 'revoke':
      case 'delete':
      case 'pin':
      case 'capture':
      case 'shutdown':
        _bumpRevision();
        return {'ok': true};
      case 'wait_for_change':
        final waiter = _Waiter(
          (arguments['after_revision'] as num?)?.toInt() ?? 0,
        );
        _waiters.add(waiter);
        return waiter.completer.future;
      default:
        throw UnsupportedError('Unexpected fake core operation: $operation');
    }
  }

  void setPendingPairings(List<Map<String, dynamic>> pairings) {
    _status['pending_pairings'] = pairings;
    _bumpRevision();
  }

  void signalChange({required int revision}) {
    _status['revision'] = revision;
    final eligible = _waiters.where((waiter) => waiter.afterRevision < revision).toList();
    for (final waiter in eligible) {
      _waiters.remove(waiter);
      waiter.completer.complete({
        'revision': revision,
        'status_revision': revision,
      });
    }
  }

  void _bumpRevision() {
    _status['revision'] = ((_status['revision'] as num?)?.toInt() ?? 0) + 1;
  }

  static Map<String, dynamic> _statusFor({required bool hasMesh}) => {
        'initialized': true,
        'mesh_id': hasMesh ? 'mesh-1' : null,
        'device_id': 'device-1',
        'device_name': 'Test device',
        'paused': false,
        'connection': 'offline',
        'diagnostic': '',
        'revision': 1,
        'pending_pairings': <Map<String, dynamic>>[],
      };
}

class CoreCall {
  const CoreCall(this.operation, this.arguments);

  final String operation;
  final Map<String, Object?> arguments;
}

class _Waiter {
  _Waiter(this.afterRevision);

  final int afterRevision;
  final Completer<Map<String, dynamic>> completer = Completer<Map<String, dynamic>>();
}
