import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models.dart';
import 'diagnostics.dart';
import 'html_text.dart';

/// The most a single clip may hold, across all its representations.
const int maxClipBytes = 16 * 1024 * 1024;

/// The core's limit for a clip's text field.
const int _maxPreviewTextBytes = 32 * 1024;

/// What a copy on this desktop becomes.
sealed class CapturedCopy {
  const CapturedCopy();
}

/// Nothing to store: an empty copy, or only formats the app does not keep.
final class NothingToCapture extends CapturedCopy {
  const NothingToCapture();
}

/// Over [maxClipBytes]. [name] is the copied file's name, when there is one.
final class CopyTooLarge extends CapturedCopy {
  const CopyTooLarge(this.name);

  final String? name;
}

/// A single photo over [maxClipBytes], which Link can compress: either
/// copied image data ([bytes] and [mime]) or a copied file ([path], [size]).
final class LargePhoto extends CapturedCopy {
  const LargePhoto({this.bytes, this.mime, this.path, this.size});

  final Uint8List? bytes;
  final String? mime;
  final String? path;
  final int? size;
}

/// A clip for the core's `capture` request.
final class ClipToCapture extends CapturedCopy {
  const ClipToCapture(
      {required this.text,
      required this.kind,
      required this.representations,
      required this.textOnly});

  /// Drives search, previews and the mobile keyboard; bounded to the core's
  /// text limit. The full content always travels as a representation.
  final String text;
  final String kind;
  final List<ClipRepresentation> representations;

  /// Plain text that fits the text field needs no representations.
  final bool textOnly;

  Map<String, Object?> request({required bool initial}) => {
        'text': _boundedText(text),
        'kind': kind,
        if (initial) 'only_if_new': true,
        if (!textOnly)
          'representations':
              representations.map((value) => value.toJson()).toList()
      };
}

/// Turns a native clipboard read (`formats`, `files`) into a clip. Copied
/// files are read from disk; a copied folder becomes a clip holding its
/// location.
Future<CapturedCopy> captureCopy(Map<String, Object?> clipboard) async {
  final representations = <ClipRepresentation>[];
  var text = '';
  var size = 0;
  final files = (clipboard['files'] as List<dynamic>? ?? const [])
      .whereType<String>()
      .toList();
  if (files.isNotEmpty) {
    for (final path in files) {
      final name = Uri.file(path)
          .pathSegments
          .lastWhere((segment) => segment.isNotEmpty, orElse: () => path);
      if (await FileSystemEntity.isDirectory(path)) {
        // CB-2: a copied folder becomes a clip holding its location.
        text = text.isEmpty ? path : '$text\n$path';
        representations.add(ClipRepresentation(
            mimeType: 'text/uri-list',
            name: name,
            bytes: Uint8List.fromList(utf8.encode(Uri.file(path).toString()))));
        continue;
      }
      final file = File(path);
      // Only regular files: a device or pipe (file:///dev/zero, a FIFO)
      // reports length 0 and never ends.
      if (await FileSystemEntity.type(path) != FileSystemEntityType.file) {
        Diagnostics.log('capture', 'skipped a copied path: not a regular file');
        continue;
      }
      final length = await file.length();
      size += length;
      if (size > maxClipBytes) {
        Diagnostics.log('capture',
            'skipped a copy: over ${maxClipBytes ~/ (1024 * 1024)} MB');
        if (files.length == 1 &&
            RegExp(r'\.(png|jpe?g)$', caseSensitive: false).hasMatch(path)) {
          return LargePhoto(path: path, size: size);
        }
        return CopyTooLarge(name);
      }
      representations.add(ClipRepresentation(
          mimeType: 'application/octet-stream',
          name: name,
          bytes: await _readAtMost(file, length)));
    }
  } else {
    final formats = clipboard['formats'] as List<dynamic>? ?? const [];
    for (final format in formats.whereType<Map<dynamic, dynamic>>()) {
      final mime = format['mimeType'];
      final bytes = format['bytes'];
      if ((mime == 'image/png' || mime == 'image/jpeg') &&
          bytes is Uint8List &&
          bytes.length > maxClipBytes) {
        return LargePhoto(bytes: bytes, mime: mime as String);
      }
    }
    final hasPlain = formats
        .whereType<Map<dynamic, dynamic>>()
        .any((format) => format['mimeType'] == 'text/plain');
    var htmlText = '';
    for (final format in formats.whereType<Map<dynamic, dynamic>>()) {
      final mime = format['mimeType'];
      final bytes = format['bytes'];
      if (mime is! String || bytes is! Uint8List) continue;
      if (!const {
        'text/plain',
        'text/html',
        'text/uri-list',
        'image/png',
        'image/jpeg'
      }.contains(mime)) {
        continue;
      }
      size += bytes.length;
      if (size > maxClipBytes) {
        Diagnostics.log('capture',
            'skipped a copy: over ${maxClipBytes ~/ (1024 * 1024)} MB');
        return const CopyTooLarge(null);
      }
      if (mime == 'text/plain') {
        text = utf8.decode(bytes, allowMalformed: true);
      }
      representations.add(ClipRepresentation(mimeType: mime, bytes: bytes));
      if (mime == 'text/html' && !hasPlain) {
        htmlText = htmlToPlainText(utf8.decode(bytes, allowMalformed: true));
      }
    }
    // CB-7: an HTML-only copy is shown and searched as readable text; the
    // markup stays as a representation.
    if (text.isEmpty && htmlText.isNotEmpty) text = htmlText;
  }
  if (representations.isEmpty) return const NothingToCapture();
  final kind = files.isNotEmpty
      ? files.length > 1
          ? 'files'
          : 'file'
      : representations.any((value) => value.mimeType.startsWith('image/'))
          ? 'image'
          : representations.any((value) => value.mimeType == 'text/html')
              ? 'rich_text'
              : _isWebUrl(text)
                  ? 'url'
                  : 'text';
  final textOnly = representations.length == 1 &&
      representations.single.mimeType == 'text/plain' &&
      utf8.encode(text).length <= _maxPreviewTextBytes;
  if (text.trim().isEmpty && textOnly) return const NothingToCapture();
  return ClipToCapture(
      text: text,
      kind: kind,
      representations: representations,
      textOnly: textOnly);
}

bool _isWebUrl(String text) {
  final trimmed = text.trim();
  if (trimmed.contains(RegExp(r'\s'))) return false;
  return const {'http', 'https'}.contains(Uri.tryParse(trimmed)?.scheme);
}

/// Truncates on a character boundary to the core's 32 KiB text field limit.
String _boundedText(String text) {
  if (utf8.encode(text).length <= _maxPreviewTextBytes) return text;
  final buffer = StringBuffer();
  var size = 0;
  for (final rune in text.runes) {
    final length = utf8.encode(String.fromCharCode(rune)).length;
    if (size + length > _maxPreviewTextBytes) break;
    buffer.writeCharCode(rune);
    size += length;
  }
  return buffer.toString();
}

/// The first [length] bytes of [file]: a file that grows after its size was
/// checked is not read past it.
Future<Uint8List> _readAtMost(File file, int length) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, length)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
