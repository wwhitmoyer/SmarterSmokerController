import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smarter_smoker/controllers/cook_timer_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('timer duration uses a fixed hours minutes seconds display', () {
    expect(formatTimerDuration(Duration.zero), '00:00:00');
    expect(
      formatTimerDuration(const Duration(hours: 2, minutes: 3, seconds: 4)),
      '02:03:04',
    );
  });

  test('count-up timer uses wall-clock elapsed time across a pause', () async {
    var now = DateTime(2026, 7, 24, 12);
    final controller = CookTimerController(
      now: () => now,
      onSchedule: (_, _) async {},
      onCancelSchedule: () async {},
      onFinished: (_) async {},
    );
    await controller.initialize();
    await controller.configure(
      newMode: CookTimerMode.countUp,
      newLabel: 'Rest',
      duration: Duration.zero,
    );

    await controller.startOrResume();
    now = now.add(const Duration(minutes: 12, seconds: 5));
    expect(controller.displayed, const Duration(minutes: 12, seconds: 5));

    await controller.pause();
    now = now.add(const Duration(minutes: 3));
    expect(controller.displayed, const Duration(minutes: 12, seconds: 5));
    expect(controller.status, CookTimerStatus.paused);
    controller.dispose();
  });

  test('countdown schedules its persisted finish time', () async {
    final now = DateTime(2026, 7, 24, 12);
    DateTime? scheduledFor;
    final controller = CookTimerController(
      now: () => now,
      onSchedule: (_, finishAt) async => scheduledFor = finishAt,
      onCancelSchedule: () async {},
      onFinished: (_) async {},
    );
    await controller.initialize();
    await controller.configure(
      newMode: CookTimerMode.countDown,
      newLabel: 'Wrap',
      duration: const Duration(minutes: 30),
    );

    await controller.startOrResume();

    expect(scheduledFor, now.add(const Duration(minutes: 30)));
    expect(controller.displayed, const Duration(minutes: 30));
    controller.dispose();
  });
}
