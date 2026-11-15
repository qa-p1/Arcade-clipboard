import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// The Wayland clipboard through wl-clipboard's wl-paste and wl-copy. These
// run in Dart rather than in the GTK plugin: see _runBytes.

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

const _sensitiveMimeTypes = {
  'x-kde-passwordmanagerhint',
  'application/x-keepassxc-clipboard',
};

/// Preferred source target → canonical representation. Alternative
/// encodings of one representation are collapsed to the first match.
const _readCandidates = [
  ('text/plain;charset=utf-8', 'text/plain'),
  ('UTF8_STRING', 'text/plain'),
  ('text/plain', 'text/plain'),
  ('text/html', 'text/html'),
  ('image/png', 'image/png'),
  ('image/jpeg', 'image/jpeg'),
  ('text/uri-list', 'text/uri-list'),
];

/// Reads every useful representation of the selection through wl-paste,
/// up to 32 MiB in all. A password manager's hint returns no formats and
/// marks the result sensitive.
Future<Map<String, Object?>> readWaylandClipboard(String wlPaste) async {
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
    final bytes = await _runBytes(wlPaste, ['--no-newline', '--type', target],
        maxBytes: 32 * 1024 * 1024 - total);
    if (bytes == null || bytes.isEmpty) continue;
    total += bytes.length;
    if (mime == 'text/uri-list') {
      files.addAll(
          _localPathsFromUriList(utf8.decode(bytes, allowMalformed: true)));
      continue;
    }
    formats.add({'mimeType': mime, 'bytes': bytes});
  }
  return {'formats': formats, 'files': files, 'sensitive': false};
}

List<String> _localPathsFromUriList(String value) {
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
Future<bool> writeWaylandClipboard(String? wlCopy,
    List<Map<String, Object?>> formats, List<String> files) async {
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
    data = utf8.encode(files.map((path) => '${Uri.file(path)}\r\n').join());
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
  final result = await _runBytes('/bin/sh',
      ['-c', r'exec "$0" "$@" >/dev/null 2>&1', wlCopy, ...arguments],
      input: data, maxBytes: 4096, timeout: const Duration(seconds: 3));
  return result != null;
}
