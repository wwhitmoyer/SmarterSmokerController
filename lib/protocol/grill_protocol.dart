import 'dart:typed_data';

enum GrillFrameType {
  status,
  setTemperatures,
  actualTemperatures,
  pidFan,
  shutdownTimer,
  firmware,
  unknown,
}

class GrillFrame {
  const GrillFrame({
    required this.raw,
    required this.type,
    required this.description,
    this.powerOn,
    this.temperatures = const <int>[],
  });

  final Uint8List raw;
  final GrillFrameType type;
  final String description;
  final bool? powerOn;
  final List<int> temperatures;
}

abstract final class GrillProtocol {
  static const int minimumGrillFahrenheit = 160;
  static const int maximumGrillFahrenheit = 500;
  static const int minimumGrillCelsius = 71;
  static const int maximumGrillCelsius = 260;
  static const int minimumProbeFahrenheit = 0;
  static const int maximumProbeFahrenheit = 500;
  static const int minimumProbeCelsius = 0;
  static const int maximumProbeCelsius = 260;

  static bool isValidProbeReading(int temperature, {bool fahrenheit = true}) {
    final minimum = fahrenheit ? minimumProbeFahrenheit : minimumProbeCelsius;
    final maximum = fahrenheit ? maximumProbeFahrenheit : maximumProbeCelsius;
    return temperature >= minimum && temperature <= maximum;
  }

  static bool hasReachedGrillTarget({
    required int? current,
    required int? target,
    bool fahrenheit = true,
  }) {
    if (current == null || target == null) return false;
    final minimumTarget = fahrenheit
        ? minimumGrillFahrenheit
        : minimumGrillCelsius;
    final maximum = fahrenheit ? maximumGrillFahrenheit : maximumGrillCelsius;
    return target >= minimumTarget &&
        target <= maximum &&
        current >= 0 &&
        current <= maximum &&
        current >= target;
  }

  static Uint8List get queryStatus => _query(0x0b, 0x01);
  static Uint8List get querySetTemperatures => _query(0x0d, 0x01);
  static Uint8List get queryActualTemperatures => _query(0x0e, 0x01);
  static Uint8List get queryPidFan => _query(0x1f, 0x02);
  static Uint8List get queryShutdownTimer => _query(0x27, 0x01);
  static Uint8List get queryFirmware => _query(0x5f, 0x01);

  static Uint8List power(bool on) => _query(0x01, on ? 0x01 : 0x02);
  static Uint8List units({required bool fahrenheit}) =>
      _query(0x09, fahrenheit ? 0x01 : 0x02);

  static Uint8List grillTemperature(int temperature, {bool fahrenheit = true}) {
    final minimum = fahrenheit ? minimumGrillFahrenheit : minimumGrillCelsius;
    final maximum = fahrenheit ? maximumGrillFahrenheit : maximumGrillCelsius;
    if (temperature < minimum || temperature > maximum) {
      throw RangeError.range(temperature, minimum, maximum, 'temperature');
    }
    return _temperature(target: 1, temperature: temperature);
  }

  static Uint8List probeTemperature(
    int probe,
    int temperature, {
    bool fahrenheit = true,
  }) {
    if (probe < 1 || probe > 3) {
      throw RangeError.range(probe, 1, 3, 'probe');
    }
    final minimum = fahrenheit ? minimumProbeFahrenheit : minimumProbeCelsius;
    final maximum = fahrenheit ? maximumProbeFahrenheit : maximumProbeCelsius;
    if (temperature < minimum || temperature > maximum) {
      throw RangeError.range(temperature, minimum, maximum, 'temperature');
    }
    return _temperature(target: probe + 1, temperature: temperature);
  }

  static Uint8List _temperature({
    required int target,
    required int temperature,
  }) {
    if (temperature < 0 || temperature > 999) {
      throw RangeError.range(temperature, 0, 999, 'temperature');
    }
    return Uint8List.fromList(<int>[
      0xfa,
      0x09,
      0xfe,
      0x05,
      target,
      temperature ~/ 100,
      (temperature ~/ 10) % 10,
      temperature % 10,
      0xff,
    ]);
  }

  static Uint8List _query(int command, int value) =>
      Uint8List.fromList(<int>[0xfa, 0x06, 0xfe, command, value, 0xff]);

  static GrillFrame decode(List<int> payload) {
    final raw = Uint8List.fromList(payload);
    if (raw.length < 6 || raw.first != 0xfa || raw.last != 0xff) {
      return GrillFrame(
        raw: raw,
        type: GrillFrameType.unknown,
        description: 'Invalid frame boundary',
      );
    }
    if (raw[1] != raw.length) {
      return GrillFrame(
        raw: raw,
        type: GrillFrameType.unknown,
        description: 'Unexpected frame length',
      );
    }
    switch (raw[3]) {
      case 0x0b:
        final value = raw.length > 5 ? raw[5] : 0;
        final power = value == 1
            ? true
            : value == 2
            ? false
            : null;
        return GrillFrame(
          raw: raw,
          type: GrillFrameType.status,
          powerOn: power,
          description: power == null
              ? 'Grill status'
              : 'Grill power ${power ? 'ON' : 'OFF'}',
        );
      case 0x0d:
        return _temperatureResponse(
          raw,
          GrillFrameType.setTemperatures,
          'Set temperatures',
        );
      case 0x0e:
        return _temperatureResponse(
          raw,
          GrillFrameType.actualTemperatures,
          'Actual temperatures',
        );
      case 0x1f:
        return GrillFrame(
          raw: raw,
          type: GrillFrameType.pidFan,
          description: 'PID/fan parameters',
        );
      case 0x27:
        return GrillFrame(
          raw: raw,
          type: GrillFrameType.shutdownTimer,
          description: 'Shutdown timer',
        );
      case 0x5f:
        return GrillFrame(
          raw: raw,
          type: GrillFrameType.firmware,
          description: 'STM firmware',
        );
      default:
        return GrillFrame(
          raw: raw,
          type: GrillFrameType.unknown,
          description:
              'Unknown command FE${raw[3].toRadixString(16).padLeft(2, '0').toUpperCase()}',
        );
    }
  }

  static GrillFrame _temperatureResponse(
    Uint8List raw,
    GrillFrameType type,
    String description,
  ) {
    if (raw.length != 26) {
      return GrillFrame(
        raw: raw,
        type: type,
        description: '$description (unexpected length)',
      );
    }
    final values = List<int>.generate(
      7,
      (index) => _digits(raw, 4 + index * 3),
    );
    return GrillFrame(
      raw: raw,
      type: type,
      temperatures: values,
      description: description,
    );
  }

  static int _digits(Uint8List raw, int offset) {
    final a = raw[offset];
    final b = raw[offset + 1];
    final c = raw[offset + 2];
    if (a == 9 && b == 9 && c == 9) return -1;
    if (a > 9 || b > 9 || c > 9) return -2;
    return a * 100 + b * 10 + c;
  }

  static String toHex(List<int> bytes) => bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  static Uint8List fromHex(String text) {
    final normalized = text.replaceAll(RegExp('[^0-9a-fA-F]'), '');
    if (normalized.isEmpty || normalized.length.isOdd) {
      throw const FormatException('Hex must contain complete bytes');
    }
    return Uint8List.fromList(<int>[
      for (var i = 0; i < normalized.length; i += 2)
        int.parse(normalized.substring(i, i + 2), radix: 16),
    ]);
  }
}
