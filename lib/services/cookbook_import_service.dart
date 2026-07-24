import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class CookbookRecipe {
  const CookbookRecipe({
    required this.name,
    required this.description,
    required this.source,
    required this.prepMinutes,
    required this.cookMinutes,
    required this.ingredients,
    required this.directions,
    required this.stages,
  });

  final String name;
  final String description;
  final String source;
  final int prepMinutes;
  final int cookMinutes;
  final List<String> ingredients;
  final List<String> directions;
  final List<CookbookStage> stages;

  factory CookbookRecipe.fromJson(Map<String, dynamic> json) {
    final directions = (json['directions'] as List<dynamic>? ?? const [])
        .map((item) => '${(item as Map<String, dynamic>)['text'] ?? ''}'.trim())
        .where((text) => text.isNotEmpty)
        .toList();
    final ingredients = (json['ingredients'] as List<dynamic>? ?? const [])
        .map((item) {
          final ingredient = item as Map<String, dynamic>;
          return [
            ingredient['quantity'],
            ingredient['measure'],
            ingredient['name'],
            ingredient['notes'],
          ].where((part) => '$part'.trim().isNotEmpty).join(' ').trim();
        })
        .where((text) => text.isNotEmpty)
        .toList();
    return CookbookRecipe(
      name: '${json['name'] ?? 'Imported recipe'}'.trim(),
      description: '${json['desc'] ?? ''}'.trim(),
      source: '${json['source'] ?? ''}'.trim(),
      prepMinutes: _asInt(json['preptime']),
      cookMinutes: _asInt(json['cooktime']),
      ingredients: ingredients,
      directions: directions,
      stages: CookbookStage.fromDirections(directions),
    );
  }

  static int _asInt(dynamic value) =>
      value is num ? value.round() : int.tryParse('$value') ?? 0;
}

enum CookbookStageEnd { chamberReady, duration, probeTarget, manual }

class CookbookStage {
  const CookbookStage({
    required this.name,
    required this.smokerTarget,
    required this.end,
    this.duration,
    this.probeTarget,
    required this.direction,
  });

  final String name;
  final int smokerTarget;
  final CookbookStageEnd end;
  final Duration? duration;
  final int? probeTarget;
  final String direction;

  static List<CookbookStage> fromDirections(List<String> directions) {
    final stages = <CookbookStage>[];
    for (final direction in directions) {
      final smokerMatch = _smokerTargetPattern.firstMatch(direction);
      final durationMatch = _durationPattern.firstMatch(direction);
      final probeMatch = _probePattern.firstMatch(direction);
      final lower = direction.toLowerCase();
      if (smokerMatch == null) continue;
      final smokerTarget = int.parse(smokerMatch.group(1)!);
      if (smokerTarget < 150 || smokerTarget > 500) continue;

      Duration? duration;
      if (durationMatch != null) {
        final amount = int.parse(durationMatch.group(1)!);
        duration = durationMatch.group(2)!.toLowerCase().startsWith('hour')
            ? Duration(hours: amount)
            : Duration(minutes: amount);
      }
      final probeTarget = probeMatch == null
          ? null
          : int.parse(probeMatch.group(1)!);
      final isPreheat = lower.contains('preheat');
      if (isPreheat) {
        stages.add(
          CookbookStage(
            name: 'Preheat',
            smokerTarget: smokerTarget,
            end: CookbookStageEnd.chamberReady,
            direction: direction,
          ),
        );
      }
      if (!isPreheat || duration != null || probeTarget != null) {
        stages.add(
          CookbookStage(
            name: probeTarget != null
                ? 'Finish'
                : duration != null
                ? 'Cook'
                : 'Set temperature',
            smokerTarget: smokerTarget,
            end: probeTarget != null
                ? CookbookStageEnd.probeTarget
                : duration != null
                ? CookbookStageEnd.duration
                : CookbookStageEnd.manual,
            duration: duration,
            probeTarget: probeTarget,
            direction: direction,
          ),
        );
      }
    }
    return stages;
  }

  static final _smokerTargetPattern = RegExp(
    r'(?:smoker|grill|heat)[^.]{0,60}?\bto\s+'
    r'(\d{2,3})\s*(?:degrees?|°)(?:\s*f\b)?',
    caseSensitive: false,
  );
  static final _durationPattern = RegExp(
    r'(\d+)\s*(minutes?|hours?)\b',
    caseSensitive: false,
  );
  static final _probePattern = RegExp(
    r'(?:internal temperature|internal temp(?:erature)?)[^\d]*(\d{2,3})',
    caseSensitive: false,
  );
}

class CookbookImportService {
  static const _channel = MethodChannel(
    'com.wwhitmoyer.smartersmoker/cookbook',
  );

  final _recipes = StreamController<CookbookRecipe>.broadcast();
  Stream<CookbookRecipe> get recipes => _recipes.stream;

  Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cookbookFileReceived') {
        final recipe = decodeNativeMessage(call.arguments);
        if (recipe != null) _recipes.add(recipe);
      }
    });
    try {
      final message = await _channel.invokeMapMethod<String, dynamic>(
        'getPendingCookbookFile',
      );
      final recipe = decodeNativeMessage(message);
      if (recipe != null) _recipes.add(recipe);
    } on MissingPluginException {
      // File sharing is currently implemented on Android.
    }
  }

  @visibleForTesting
  static CookbookRecipe? decodeNativeMessage(dynamic message) {
    if (message is! Map) return null;
    final encoded = message['base64'];
    if (encoded is! String || encoded.isEmpty) return null;
    return decodeFileBytes(base64Decode(encoded));
  }

  static CookbookRecipe? decodeFileBytes(Uint8List bytes) {
    try {
      final fileAsBase64 = base64Encode(bytes);
      final decodedBase64 = fileAsBase64.split('').map((character) {
        final digit = int.tryParse(character);
        if (digit != null) return '${9 - digit}';
        final upper = character.toUpperCase();
        final lower = character.toLowerCase();
        if (upper == lower) return character;
        return character == upper ? lower : upper;
      }).join();
      var jsonText = utf8.decode(
        base64Decode(_canonicalizePadding(decodedBase64)),
      );
      if (jsonText.endsWith('|')) {
        jsonText = '${jsonText.substring(0, jsonText.length - 1)}}';
      }
      final json = jsonDecode(jsonText);
      return json is Map<String, dynamic>
          ? CookbookRecipe.fromJson(json)
          : null;
    } on FormatException catch (error) {
      debugPrint('Unable to decode CookBook file: $error');
      return null;
    }
  }

  static String _canonicalizePadding(String value) {
    final padding = value.endsWith('==')
        ? 2
        : value.endsWith('=')
        ? 1
        : 0;
    if (padding == 0) return value;
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final characterIndex = value.length - padding - 1;
    final sextet = alphabet.indexOf(value[characterIndex]);
    if (sextet < 0) return value;
    final mask = padding == 2 ? 0x30 : 0x3c;
    return value.replaceRange(
      characterIndex,
      characterIndex + 1,
      alphabet[sextet & mask],
    );
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _recipes.close();
  }
}
