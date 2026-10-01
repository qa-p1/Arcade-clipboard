import 'dart:collection';
import 'dart:io';

/// Developer diagnostics for capture, overlay, and sync lifecycle events.
///
/// Entries describe what happened, never clipboard contents. They are kept in
/// a small in-memory ring for the Settings diagnostics view, and echoed to
/// stderr when the app is started with ARCADE_DEBUG=1.
class Diagnostics {
  Diagnostics._();

  static const int _capacity = 200;
  static final Queue<String> _entries = Queue<String>();
  static final bool _echo = Platform.environment['ARCADE_DEBUG'] == '1';

  static List<String> get entries => List.unmodifiable(_entries);

  static void log(String area, String message) {
    final now = DateTime.now();
    final stamp = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final line = '$stamp [$area] $message';
    _entries.addLast(line);
    while (_entries.length > _capacity) {
      _entries.removeFirst();
    }
    if (_echo) stderr.writeln(line);
  }
}
