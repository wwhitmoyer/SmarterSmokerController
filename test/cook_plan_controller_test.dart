import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smarter_smoker/controllers/cook_plan_controller.dart';

void main() {
  late List<int> smokerTargets;
  late List<String> readyStages;
  late DateTime now;
  late CookPlanController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    smokerTargets = [];
    readyStages = [];
    now = DateTime(2026, 7, 24, 12);
    controller = CookPlanController(
      onSetSmokerTarget: smokerTargets.add,
      onSetProbeTarget: (_, _) {},
      onStageReady: (stage) async => readyStages.add(stage.name),
      now: () => now,
    );
  });

  tearDown(() => controller.dispose());

  test('ask-first stage waits for approval after its condition', () async {
    controller.loadDraft(
      CookPlan(
        name: 'Wings',
        stages: [
          _stage(
            name: 'Preheat',
            target: 250,
            condition: CookPlanCondition.chamberTemperature,
            mode: CookPlanAdvanceMode.askFirst,
            probeTarget: 260,
          ),
          _stage(name: 'Cook', target: 250),
        ],
      ),
    );

    await controller.approveAndStart();
    await controller.updateTelemetry(
      chamberTemperature: 256,
      probeTemperatures: const [-1, -1, -1],
    );

    expect(controller.currentStageIndex, 0);
    expect(controller.readyToAdvance, isTrue);
    expect(readyStages, ['Preheat']);
    await controller.advance();
    expect(controller.currentStageIndex, 1);
  });

  test('automatic stage starts the next stage immediately', () async {
    controller.loadDraft(
      CookPlan(
        name: 'Wings',
        stages: [
          _stage(
            name: 'Smoke',
            target: 250,
            condition: CookPlanCondition.duration,
            mode: CookPlanAdvanceMode.automatic,
            duration: const Duration(minutes: 30),
          ),
          _stage(name: 'Finish', target: 425),
        ],
      ),
    );

    await controller.approveAndStart();
    now = now.add(const Duration(minutes: 30));
    await controller.updateTelemetry(
      chamberTemperature: 250,
      probeTemperatures: const [-1, -1, -1],
    );

    expect(controller.currentStageIndex, 1);
    expect(smokerTargets, [250, 425]);
  });

  test('manual-only stage never advances from telemetry', () async {
    controller.loadDraft(
      CookPlan(
        name: 'Wings',
        stages: [
          _stage(
            name: 'Flip',
            target: 250,
            condition: CookPlanCondition.manual,
            mode: CookPlanAdvanceMode.manualOnly,
          ),
          _stage(name: 'Finish', target: 425),
        ],
      ),
    );

    await controller.approveAndStart();
    now = now.add(const Duration(hours: 2));
    await controller.updateTelemetry(
      chamberTemperature: 500,
      probeTemperatures: const [500, 500, 500],
    );

    expect(controller.currentStageIndex, 0);
    expect(controller.readyToAdvance, isFalse);
    await controller.advance();
    expect(controller.currentStageIndex, 1);
  });
}

CookPlanStage _stage({
  required String name,
  required int target,
  CookPlanCondition condition = CookPlanCondition.manual,
  CookPlanAdvanceMode mode = CookPlanAdvanceMode.manualOnly,
  Duration? duration,
  int? probeTarget,
}) => CookPlanStage(
  name: name,
  instructions: name,
  smokerTarget: target,
  condition: condition,
  advanceMode: mode,
  duration: duration,
  probe: condition == CookPlanCondition.chamberTemperature ? 0 : 1,
  probeTarget: probeTarget,
);
