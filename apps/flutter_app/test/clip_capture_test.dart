import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:arcade_clipboard/services/clip_capture.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> formats(Map<String, List<int>> values) => {
      'formats': [
        for (final entry in values.entries)
          {'mimeType': entry.key, 'bytes': Uint8List.fromList(entry.value)}
      ],
      'files': <Object?>[],
    };

void main() {
  test('plain text is a text clip that needs no representations', () async {
    final copy = await captureCopy(formats({'text/plain': utf8.encode('hi')}));
    expect(copy, isA<ClipToCapture>());
    final clip = copy as ClipToCapture;
    expect((clip.kind, clip.textOnly), ('text', true));
    expect(clip.request(initial: false), {'text': 'hi', 'kind': 'text'});
    expect(clip.request(initial: true)['only_if_new'], true);
  });

  test('a lone web address is a url clip', () async {
    final copy = await captureCopy(
        formats({'text/plain': utf8.encode(' https://example.com/a ')}));
    expect((copy as ClipToCapture).kind, 'url');
  });

  test('an HTML-only copy is searched as its readable text (CB-7)', () async {
    final copy = await captureCopy(
        formats({'text/html': utf8.encode('<p>Hello <b>there</b></p>')}));
    final clip = copy as ClipToCapture;
    expect(clip.kind, 'rich_text');
    expect(clip.text, contains('Hello there'));
    expect(clip.textOnly, false);
    expect(clip.request(initial: false)['representations'], hasLength(1));
  });

  test('blank text and formats the app does not keep store nothing', () async {
    expect(await captureCopy(formats({'text/plain': utf8.encode('  \n')})),
        isA<NothingToCapture>());
    expect(
        await captureCopy(formats({
          'application/x-thing': [1, 2]
        })),
        isA<NothingToCapture>());
  });

  test('a photo over the limit is offered to Link, other copies are refused',
      () async {
    final big = List<int>.filled(maxClipBytes + 1, 0);
    final photo = await captureCopy(formats({'image/png': big}));
    expect(photo, isA<LargePhoto>());
    expect((photo as LargePhoto).mime, 'image/png');
    final text = await captureCopy(formats({'text/plain': big}));
    expect(text, isA<CopyTooLarge>());
    expect((text as CopyTooLarge).name, isNull);
  });

  test('a copied folder is a clip holding its location (CB-2)', () async {
    final folder = await Directory.systemTemp.createTemp('clip capture');
    addTearDown(() => folder.delete(recursive: true));
    final copy = await captureCopy({
      'formats': <Object?>[],
      'files': [folder.path],
    });
    final clip = copy as ClipToCapture;
    expect((clip.kind, clip.text), ('file', folder.path));
    expect(clip.representations.single.mimeType, 'text/uri-list');
    expect(utf8.decode(clip.representations.single.bytes!),
        Uri.file(folder.path).toString());
  });

  test('the text field is cut on a character boundary at 32 KiB', () async {
    // 3-byte characters: 10923 of them is 32769 bytes, one over the limit.
    final text = '€' * 10923;
    final copy = await captureCopy(formats({'text/plain': utf8.encode(text)}));
    final clip = copy as ClipToCapture;
    expect(clip.textOnly, false);
    final sent = clip.request(initial: false)['text'] as String;
    expect(sent, '€' * 10922);
    expect(clip.request(initial: false)['representations'], hasLength(1));
  });
}
