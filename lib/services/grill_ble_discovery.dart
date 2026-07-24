import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class DiscoveredGrill {
  const DiscoveredGrill({
    required this.id,
    required this.platformId,
    required this.rssi,
  });
  final String id;
  final String platformId;
  final int rssi;
}

class GrillBleDiscovery {
  static final _idPattern = RegExp(r'(GRILL[A-Z0-9_-]*)', caseSensitive: false);
  static final _serviceUuid = Guid('0000abf0-0000-1000-8000-00805f9b34fb');
  static final _writeUuid = Guid('0000abf1-0000-1000-8000-00805f9b34fb');
  static final _notifyUuid = Guid('0000abf2-0000-1000-8000-00805f9b34fb');
  static final _provisioningSuccess = Uint8List.fromList([
    0xfa,
    0x05,
    0xfc,
    0x00,
    0xff,
  ]);

  Future<DiscoveredGrill?> discover({
    Duration timeout = const Duration(seconds: 12),
    String? expectedId,
  }) async {
    final result = Completer<DiscoveredGrill?>();
    late StreamSubscription<List<ScanResult>> subscription;
    subscription = FlutterBluePlus.scanResults.listen((results) {
      for (final scan in results) {
        final candidates = <String>[
          scan.device.platformName,
          scan.advertisementData.advName,
          for (final bytes in scan.advertisementData.manufacturerData.values)
            latin1.decode(bytes, allowInvalid: true),
        ];
        for (final candidate in candidates) {
          final match = _idPattern.firstMatch(candidate);
          final id = match?.group(1)?.toUpperCase();
          if (id != null &&
              (expectedId == null || id == expectedId.toUpperCase()) &&
              !result.isCompleted) {
            result.complete(
              DiscoveredGrill(
                id: id,
                platformId: scan.device.remoteId.str,
                rssi: scan.rssi,
              ),
            );
            return;
          }
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      return await result.future.timeout(
        timeout + const Duration(seconds: 1),
        onTimeout: () => null,
      );
    } finally {
      await FlutterBluePlus.stopScan();
      await subscription.cancel();
    }
  }

  static Uint8List buildWifiProvisioningFrame(String ssid, String password) {
    final ssidBytes = utf8.encode(ssid);
    final passwordBytes = utf8.encode(password);
    final length = ssidBytes.length + passwordBytes.length + 5;
    if (ssidBytes.isEmpty) {
      throw const FormatException('Wi-Fi name cannot be empty');
    }
    if (passwordBytes.isEmpty) {
      throw const FormatException('Wi-Fi password cannot be empty');
    }
    if (length > 255) {
      throw const FormatException('Wi-Fi name and password are too long');
    }
    return Uint8List.fromList([
      0xfa,
      length,
      0xfb,
      ...ssidBytes,
      0xf1,
      ...passwordBytes,
      0xff,
    ]);
  }

  Future<void> provisionWifi({
    required String grillId,
    required String ssid,
    required String password,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final found = await discover(expectedId: grillId);
    if (found == null) {
      throw StateError('$grillId was not found over Bluetooth');
    }

    final frame = buildWifiProvisioningFrame(ssid, password);
    final device = BluetoothDevice.fromId(found.platformId);
    StreamSubscription<List<int>>? responseSubscription;
    final success = Completer<void>();
    try {
      await device.connect(license: License.nonprofit, timeout: timeout);
      final services = await device.discoverServices();
      final service = services
          .where((item) => item.uuid == _serviceUuid)
          .firstOrNull;
      if (service == null) {
        throw StateError('The grill Wi-Fi setup service was not found');
      }
      final write = service.characteristics
          .where((item) => item.uuid == _writeUuid)
          .firstOrNull;
      final notify = service.characteristics
          .where((item) => item.uuid == _notifyUuid)
          .firstOrNull;
      if (write == null || notify == null) {
        throw StateError('The grill Wi-Fi setup controls were not found');
      }

      responseSubscription = notify.onValueReceived.listen((value) {
        if (_bytesEqual(value, _provisioningSuccess) && !success.isCompleted) {
          success.complete();
        }
      });
      await notify.setNotifyValue(true);
      for (var offset = 0; offset < frame.length; offset += 20) {
        final end = offset + 20 < frame.length ? offset + 20 : frame.length;
        await write.write(frame.sublist(offset, end), withoutResponse: false);
        if (end < frame.length) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      await success.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'The grill did not confirm the Wi-Fi settings',
          timeout,
        ),
      );
    } finally {
      await responseSubscription?.cancel();
      await device.disconnect();
    }
  }

  static bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
