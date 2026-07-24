import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/grill_protocol.dart';
import '../services/grill_ble_discovery.dart';
import '../services/grill_mqtt_service.dart';

enum GrillConnectionPhase {
  needsId,
  connecting,
  connected,
  disconnected,
  error,
}

class GrillController extends ChangeNotifier {
  GrillController({GrillMqttService? mqtt, GrillBleDiscovery? discovery})
    : _mqtt = mqtt ?? GrillMqttService(),
      _discovery = discovery ?? GrillBleDiscovery();

  static const _savedIdKey = 'saved_grill_id';
  static const _probeTargetKeyPrefix = 'probe_target_';
  final GrillMqttService _mqtt;
  final GrillBleDiscovery _discovery;
  final logs = <String>[];
  StreamSubscription<Uint8List>? _payloadSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  Timer? _refreshTimer;

  GrillConnectionPhase phase = GrillConnectionPhase.disconnected;
  String? deviceId;
  String? errorMessage;
  bool? powerOn;
  bool fahrenheit = true;
  int? grillTemperature;
  int? grillTarget;
  List<int> probeTemperatures = List<int>.filled(3, -1);
  List<int> probeTargets = List<int>.filled(3, -1);
  bool provisioningWifi = false;

  Future<void> initialize() async {
    _payloadSubscription = _mqtt.payloads.listen(_handlePayload);
    _connectionSubscription = _mqtt.connections.listen((connected) {
      phase = connected
          ? GrillConnectionPhase.connected
          : GrillConnectionPhase.disconnected;
      notifyListeners();
    });
    final preferences = await SharedPreferences.getInstance();
    probeTargets = List<int>.generate(
      3,
      (index) => preferences.getInt('$_probeTargetKeyPrefix${index + 1}') ?? -1,
    );
    deviceId = preferences.getString(_savedIdKey);
    if (deviceId == null || deviceId!.isEmpty) {
      phase = GrillConnectionPhase.needsId;
      notifyListeners();
      return;
    }
    await connect();
  }

  Future<bool> discoverAndSave() async {
    _log('Scanning for a BLE name beginning with GRILL');
    final grill = await _discovery.discover();
    if (grill == null) {
      errorMessage = 'No GRILL device was found';
      notifyListeners();
      return false;
    }
    deviceId = grill.id;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_savedIdKey, grill.id);
    _log('Found ${grill.id} (${grill.rssi} dBm)');
    await connect();
    return true;
  }

  Future<void> setDeviceId(String id, {bool save = true}) async {
    final normalized = id.trim().toUpperCase();
    if (!RegExp(r'^GRILL[A-Z0-9_-]*$').hasMatch(normalized)) {
      throw const FormatException('Grill ID must begin with GRILL');
    }
    deviceId = normalized;
    if (save) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_savedIdKey, normalized);
    }
    await connect();
  }

  Future<void> provisionWifi(String ssid, String password) async {
    final id = deviceId;
    if (id == null || id.isEmpty) {
      throw StateError('Discover or enter a Grill ID first');
    }
    provisioningWifi = true;
    errorMessage = null;
    _log('Starting secure-entry Wi-Fi setup over BLE for $id');
    notifyListeners();
    try {
      await _discovery.provisionWifi(
        grillId: id,
        ssid: ssid.trim(),
        password: password,
      );
      _log('Wi-Fi settings accepted by the grill');
      await connect();
    } catch (error) {
      errorMessage = error.toString();
      _log('Wi-Fi setup failed: $error');
      rethrow;
    } finally {
      provisioningWifi = false;
      notifyListeners();
    }
  }

  Future<void> connect() async {
    final id = deviceId;
    if (id == null || id.isEmpty) return;
    phase = GrillConnectionPhase.connecting;
    errorMessage = null;
    notifyListeners();
    try {
      await _mqtt.connect(id);
      phase = GrillConnectionPhase.connected;
      _log('Connected to $id');
      _startRefresh();
    } catch (error) {
      phase = GrillConnectionPhase.error;
      errorMessage = error.toString();
      _log('Connection failed: $error');
    }
    notifyListeners();
  }

  void _startRefresh() {
    _refreshTimer?.cancel();
    unawaited(refresh());
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(refresh()),
    );
  }

  Future<void> refresh() async {
    if (!_mqtt.isConnected) return;
    _publish(GrillProtocol.queryStatus, 'status');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!_mqtt.isConnected) return;
    _publish(GrillProtocol.querySetTemperatures, 'set temperatures');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!_mqtt.isConnected) return;
    _publish(GrillProtocol.queryActualTemperatures, 'actual temperatures');
  }

  Future<void> togglePower() async {
    if (powerOn == null || !_mqtt.isConnected) {
      await refresh();
      return;
    }
    final expected = !powerOn!;
    _publish(
      GrillProtocol.power(expected),
      expected ? 'power on' : 'power off',
    );
    // OFF often stops the controller before it can return another status frame.
    powerOn = expected;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (_mqtt.isConnected) _publish(GrillProtocol.queryStatus, 'verify power');
  }

  void setGrillTarget(int value) {
    _publish(
      GrillProtocol.grillTemperature(value, fahrenheit: fahrenheit),
      'set grill temperature $value',
    );
    grillTarget = value;
    notifyListeners();
  }

  void setProbeTarget(int probe, int value) {
    if (probe < 1 || probe > probeTargets.length) {
      throw RangeError.range(probe, 1, probeTargets.length, 'probe');
    }
    final minimum = fahrenheit
        ? GrillProtocol.minimumProbeFahrenheit
        : GrillProtocol.minimumProbeCelsius;
    final maximum = fahrenheit
        ? GrillProtocol.maximumProbeFahrenheit
        : GrillProtocol.maximumProbeCelsius;
    if (value < minimum || value > maximum) {
      throw RangeError.range(value, minimum, maximum, 'value');
    }
    probeTargets = List<int>.from(probeTargets)..[probe - 1] = value;
    _log('Probe $probe software target set to $value');
    notifyListeners();
    unawaited(_persistProbeTarget(probe, value));
  }

  Future<void> _persistProbeTarget(int probe, int value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('$_probeTargetKeyPrefix$probe', value);
  }

  void setUnits({required bool useFahrenheit}) {
    _publish(
      GrillProtocol.units(fahrenheit: useFahrenheit),
      useFahrenheit ? 'Fahrenheit' : 'Celsius',
    );
    fahrenheit = useFahrenheit;
    notifyListeners();
  }

  void _publish(Uint8List payload, String label) {
    _mqtt.publish(payload);
    _log('TX $label ${GrillProtocol.toHex(payload)}');
  }

  void _handlePayload(Uint8List payload) {
    final frame = GrillProtocol.decode(payload);
    _log('RX ${frame.description} ${GrillProtocol.toHex(payload)}');
    switch (frame.type) {
      case GrillFrameType.status:
        if (frame.powerOn != null) powerOn = frame.powerOn;
      case GrillFrameType.actualTemperatures:
        if (frame.temperatures.length == 7) {
          probeTemperatures = frame.temperatures.take(3).toList();
          grillTemperature = frame.temperatures[6];
        }
      case GrillFrameType.setTemperatures:
        if (frame.temperatures.length == 7) {
          grillTarget = frame.temperatures[6];
        }
      case GrillFrameType.pidFan:
      case GrillFrameType.shutdownTimer:
      case GrillFrameType.firmware:
      case GrillFrameType.unknown:
        break;
    }
    notifyListeners();
  }

  void _log(String message) {
    final now = DateTime.now();
    logs.insert(
      0,
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}  $message',
    );
    if (logs.length > 200) logs.removeRange(200, logs.length);
    notifyListeners();
  }

  Future<void> clearSavedId() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_savedIdKey);
    deviceId = null;
    phase = GrillConnectionPhase.needsId;
    _refreshTimer?.cancel();
    await _mqtt.disconnect();
    notifyListeners();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    unawaited(_payloadSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    unawaited(_mqtt.dispose());
    super.dispose();
  }
}
