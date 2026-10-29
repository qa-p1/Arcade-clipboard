import 'dart:convert';
import 'dart:io';

import 'package:arcade_clipboard/arcade_widgets.dart';
import 'package:arcade_clipboard/design/arcade_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Color _hex(String value) => Color(0xFF000000 | int.parse(value.substring(1), radix: 16));

void main() {
  test('app accents match the bundled kit tokens', () {
    final tokens = jsonDecode(File('assets/arcade/tokens.json').readAsStringSync()) as Map<String, dynamic>;
    final accents = tokens['accent'] as Map<String, dynamic>;
    expect(arcadeAccents.keys, containsAll(accents.keys));
    for (final MapEntry(:key, :value) in accents.entries) {
      final accent = value as Map<String, dynamic>;
      expect(arcadeAccents[key]!.light, _hex(accent['light'] as String), reason: key);
      expect(arcadeAccents[key]!.dark, _hex(accent['dark'] as String), reason: key);
    }
  });

  testWidgets('Shelf and Find glyphs paint in their accents', (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: arcadeTheme(Brightness.light, 'arcade.clipboard'),
        home: const Row(children: [ArcadeGlyph('arcade.shelf'), ArcadeGlyph('arcade.find')])));
    expect(find.byType(ArcadeGlyph), findsNWidgets(2));
    final context = tester.element(find.byType(ArcadeGlyph).first);
    expect(ArcadeGlyph.accentOf(context, 'arcade.shelf'), arcadeAccents['arcade.shelf']!.light);
    expect(tester.takeException(), isNull);
  });
}
