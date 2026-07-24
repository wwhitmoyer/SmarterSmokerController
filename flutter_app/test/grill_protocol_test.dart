import 'package:flutter_test/flutter_test.dart';
import 'package:smarter_grill/protocol/grill_protocol.dart';
import 'package:smarter_grill/services/grill_ble_discovery.dart';

void main() {
  test('known query frames match the vendor app', () {
    expect(GrillProtocol.toHex(GrillProtocol.queryStatus), 'FA06FE0B01FF');
    expect(
      GrillProtocol.toHex(GrillProtocol.querySetTemperatures),
      'FA06FE0D01FF',
    );
    expect(
      GrillProtocol.toHex(GrillProtocol.queryActualTemperatures),
      'FA06FE0E01FF',
    );
    expect(GrillProtocol.toHex(GrillProtocol.queryPidFan), 'FA06FE1F02FF');
  });

  test('temperature builders encode decimal digits', () {
    expect(
      GrillProtocol.toHex(GrillProtocol.grillTemperature(225)),
      'FA09FE0501020205FF',
    );
    expect(
      GrillProtocol.toHex(GrillProtocol.probeTemperature(1, 165)),
      'FA09FE0502010605FF',
    );
  });

  test('grill temperatures enforce unit-specific controller limits', () {
    expect(() => GrillProtocol.grillTemperature(159), throwsRangeError);
    expect(
      GrillProtocol.toHex(GrillProtocol.grillTemperature(160)),
      'FA09FE0501010600FF',
    );
    expect(
      () => GrillProtocol.grillTemperature(70, fahrenheit: false),
      throwsRangeError,
    );
    expect(
      GrillProtocol.toHex(
        GrillProtocol.grillTemperature(71, fahrenheit: false),
      ),
      'FA09FE0501000701FF',
    );
  });

  test('power state is decoded', () {
    final on = GrillProtocol.decode(
      GrillProtocol.fromHex('FA18FE0B00010000000000000000000000000000000000FF'),
    );
    final off = GrillProtocol.decode(
      GrillProtocol.fromHex('FA18FE0B00020000000000000000000000000000000000FF'),
    );
    expect(on.powerOn, isTrue);
    expect(off.powerOn, isFalse);
  });

  test('temperature response is decoded', () {
    final frame = GrillProtocol.decode(
      GrillProtocol.fromHex(
        'FA1AFE0E010000020000030000040000050000060000020205FF',
      ),
    );
    expect(frame.temperatures, [100, 200, 300, 400, 500, 600, 225]);
  });

  test('Wi-Fi provisioning frame matches the vendor APK format', () {
    final frame = GrillBleDiscovery.buildWifiProvisioningFrame(
      'MyWifi',
      'secret',
    );
    expect(GrillProtocol.toHex(frame), 'FA11FB4D7957696669F1736563726574FF');
  });
}
