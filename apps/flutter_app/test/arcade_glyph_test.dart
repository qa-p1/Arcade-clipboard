import 'dart:convert';
import 'dart:io';

import 'package:arcade_clipboard/arcade_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('glyph accents match the bundled shared tokens', () {
    final file = File('assets/arcade/tokens.json');
    final tokens = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final accents = tokens['accent'] as Map<String, dynamic>;
    for (final entry in ArcadeGlyph.accents.entries) {
      final hex = (accents[entry.key] as String).substring(1);
      expect(entry.value, Color(0xFF000000 | int.parse(hex, radix: 16)),
          reason: entry.key);
    }
    expect(ArcadeGlyph.accents.keys,
        containsAll(<String>['arcade.shelf', 'arcade.find']));
  });

  testWidgets('Shelf and Find glyphs paint', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Row(children: [
      ArcadeGlyph('arcade.shelf', color: Color(0xFF94A8FF)),
      ArcadeGlyph('arcade.find', color: Color(0xFF22C55E)),
    ])));
    expect(find.byType(ArcadeGlyph), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
