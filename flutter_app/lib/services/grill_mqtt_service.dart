import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class GrillMqttService {
  static const host = 'iot.taylorgrill.com';
  static const port = 1883;
  static const username = 'Taylor';
  static const password = 'YKC6WLIFUZaBaMQU';

  final _payloads = StreamController<Uint8List>.broadcast();
  final _connections = StreamController<bool>.broadcast();
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  String? _deviceId;

  Stream<Uint8List> get payloads => _payloads.stream;
  Stream<bool> get connections => _connections.stream;
  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  Future<void> connect(String deviceId) async {
    final id = deviceId.trim();
    if (!RegExp(r'^GRILL[A-Za-z0-9_-]*$', caseSensitive: false).hasMatch(id)) {
      throw const FormatException('Grill ID must begin with GRILL');
    }
    await disconnect();
    _deviceId = id;
    final random = Random().nextInt(0xffffff).toRadixString(16).padLeft(6, '0');
    final client = MqttServerClient.withPort(
      host,
      'smarter_grill_$random',
      port,
    );
    client.keepAlivePeriod = 20;
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;
    client.logging(on: false);
    client.onConnected = () {
      _connections.add(true);
    };
    client.onDisconnected = () {
      _connections.add(false);
    };
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier('smarter_grill_$random')
        .authenticateAs(username, password)
        .startClean();
    _client = client;
    final status = await client.connect();
    if (status?.state != MqttConnectionState.connected) {
      client.disconnect();
      throw StateError('MQTT connection failed: ${status?.returnCode}');
    }
    client.subscribe('$id/dev2app', MqttQos.exactlyOnce);
    _updates = client.updates?.listen((messages) {
      for (final received in messages) {
        final message = received.payload as MqttPublishMessage;
        _payloads.add(Uint8List.fromList(message.payload.message));
      }
    });
    _connections.add(true);
  }

  void publish(Uint8List payload) {
    final client = _client;
    final id = _deviceId;
    if (client == null || id == null || !isConnected) {
      throw StateError('Grill is not connected');
    }
    final builder = MqttClientPayloadBuilder();
    for (final byte in payload) {
      builder.addByte(byte);
    }
    client.publishMessage(
      '$id/app2dev',
      MqttQos.exactlyOnce,
      builder.payload!,
      retain: true,
    );
  }

  Future<void> disconnect() async {
    await _updates?.cancel();
    _updates = null;
    _client?.disconnect();
    _client = null;
    _connections.add(false);
  }

  Future<void> dispose() async {
    await disconnect();
    await _payloads.close();
    await _connections.close();
  }
}
