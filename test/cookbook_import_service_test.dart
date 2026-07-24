import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smarter_smoker/services/cookbook_import_service.dart';

void main() {
  test('native CookBook files decode into recipes and smoker stages', () {
    final file = _encodeCookbookFile({
      'name': 'Crispy Smoked Chicken Wings',
      'preptime': 10,
      'cooktime': 60,
      'source': 'https://example.com/wings',
      'ingredients': [
        {
          'quantity': 5,
          'measure': 'pounds',
          'name': 'chicken wings',
          'notes': '',
        },
      ],
      'directions': [
        {
          'text':
              'Preheat your smoker to 250 degrees F and smoke for 30 minutes.',
        },
        {
          'text':
              'Increase the heat in your smoker to 425 degrees until the internal '
              'temperature reads 175 degrees F.',
        },
        {'text': 'Remove the wings from the grill and serve.'},
      ],
    });

    final recipe = CookbookImportService.decodeFileBytes(file);

    expect(recipe, isNotNull);
    expect(recipe!.name, 'Crispy Smoked Chicken Wings');
    expect(recipe.cookMinutes, 60);
    expect(recipe.ingredients, ['5 pounds chicken wings']);
    expect(recipe.stages, hasLength(3));
    expect(recipe.stages[0].name, 'Preheat');
    expect(recipe.stages[0].smokerTarget, 250);
    expect(recipe.stages[1].duration, const Duration(minutes: 30));
    expect(recipe.stages[2].smokerTarget, 425);
    expect(recipe.stages[2].probeTarget, 175);
  });

  test('invalid native CookBook files are rejected', () {
    expect(
      CookbookImportService.decodeFileBytes(Uint8List.fromList([1, 2, 3])),
      isNull,
    );
  });
}

Uint8List _encodeCookbookFile(Map<String, dynamic> recipe) {
  final jsonAsBase64 = base64Encode(utf8.encode(jsonEncode(recipe)));
  final obfuscatedBase64 = jsonAsBase64.split('').map((character) {
    final digit = int.tryParse(character);
    if (digit != null) return '${9 - digit}';
    final upper = character.toUpperCase();
    final lower = character.toLowerCase();
    if (upper == lower) return character;
    return character == upper ? lower : upper;
  }).join();
  return base64Decode(_canonicalizePadding(obfuscatedBase64));
}

String _canonicalizePadding(String value) {
  final padding = value.endsWith('==')
      ? 2
      : value.endsWith('=')
      ? 1
      : 0;
  if (padding == 0) return value;
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final index = value.length - padding - 1;
  final sextet = alphabet.indexOf(value[index]);
  final mask = padding == 2 ? 0x30 : 0x3c;
  return value.replaceRange(index, index + 1, alphabet[sextet & mask]);
}
