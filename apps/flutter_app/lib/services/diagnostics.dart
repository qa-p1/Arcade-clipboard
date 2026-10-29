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
  static const int _maximumLogBytes = 1024 * 1024;
  static final Queue<String> _entries = Queue<String>();
  static final bool _echo = Platform.environment['ARCADE_DEBUG'] == '1';
  static Directory? _logDirectory;
  static Future<void> _writes = Future<void>.value();

  static List<String> get entries => List.unmodifiable(_entries);

  static Future<void> configure(Directory supportDirectory) async {
    final logs = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}logs',
    );
    await logs.create(recursive: true);
    _logDirectory = logs;
  }

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
    final logDirectory = _logDirectory;
    if (logDirectory != null) {
      final bounded = line.length > 2048 ? '${line.substring(0, 2048)}…' : line;
      _writes = _writes
          .then((_) => _append(logDirectory, bounded))
          .catchError((_) {});
    }
    if (_echo) stderr.writeln(line);
  }

  static Future<void> _append(Directory directory, String line) async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}diagnostics.log',
    );
    if (await file.exists() && await file.length() >= _maximumLogBytes) {
      final previous = File('${file.path}.1');
      if (await previous.exists()) await previous.delete();
      await file.rename(previous.path);
    }
    await file.writeAsString('$line\n', mode: FileMode.append, flush: false);
  }
}
