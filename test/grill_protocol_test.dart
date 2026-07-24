import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smarter_smoker/controllers/grill_controller.dart';
import 'package:smarter_smoker/protocol/grill_protocol.dart';
import 'package:smarter_smoker/services/grill_ble_discovery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('probe alerts transition at five degrees below target', () {
    expect(
      GrillController.probeAlertLevel(current: -1, target: 165),
      ProbeAlertLevel.none,
    );
    expect(
      GrillController.probeAlertLevel(current: 159, target: 165),
      ProbeAlertLevel.none,
    );
    expect(
      GrillController.probeAlertLevel(current: 160, target: 165),
      ProbeAlertLevel.preAlarm,
    );
    expect(
      GrillController.probeAlertLevel(current: 164, target: 165),
      ProbeAlertLevel.preAlarm,
    );
    expect(
      GrillController.probeAlertLevel(current: 165, target: 165),
      ProbeAlertLevel.targetReached,
    );
  });

  test('a probe target can be cleared and removed from storage', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = GrillController();
    await controller.initialize();

    controller.setProbeTarget(1, 165);
    await Future<void>.delayed(Duration.zero);
    controller.clearProbeTarget(1);
    await Future<void>.delayed(Duration.zero);

    final preferences = await SharedPreferences.getInstance();
    expect(controller.probeTargets[0], -1);
    expect(preferences.getInt('probe_target_1'), isNull);
    controller.dispose();
  });

  test('out-of-range probe readings are treated as disconnected', () {
    expect(GrillProtocol.isValidProbeReading(500), isTrue);
    expect(GrillProtocol.isValidProbeReading(501), isFalse);
    expect(GrillProtocol.isValidProbeReading(960), isFalse);
    expect(GrillProtocol.isValidProbeReading(260, fahrenheit: false), isTrue);
    expect(GrillProtocol.isValidProbeReading(261, fahrenheit: false), isFalse);
  });

  test('smoker-ready detection validates target and actual temperatures', () {
    expect(
      GrillProtocol.hasReachedGrillTarget(current: 224, target: 225),
      isFalse,
    );
    expect(
      GrillProtocol.hasReachedGrillTarget(current: 225, target: 225),
      isTrue,
    );
    expect(
      GrillProtocol.hasReachedGrillTarget(current: 960, target: 225),
      isFalse,
    );
    expect(
      GrillProtocol.hasReachedGrillTarget(current: 70, target: 70),
      isFalse,
    );
    expect(
      GrillProtocol.hasReachedGrillTarget(
        current: 107,
        target: 107,
        fahrenheit: false,
      ),
      isTrue,
    );
  });
}
