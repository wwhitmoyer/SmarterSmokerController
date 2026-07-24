import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controllers/cook_timer_controller.dart';
import 'controllers/cook_plan_controller.dart';
import 'controllers/grill_controller.dart';
import 'protocol/grill_protocol.dart';
import 'services/alarm_audio_service.dart';
import 'services/cookbook_import_service.dart';

void main() => runApp(const SmarterSmokerApp());

class SmarterSmokerApp extends StatelessWidget {
  const SmarterSmokerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const ember = Color(0xffc54b2c);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smarter Smoker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: ember,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff6f3ed),
        cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        useMaterial3: true,
      ),
      home: const GrillDashboard(),
    );
  }
}

class GrillDashboard extends StatefulWidget {
  const GrillDashboard({super.key});

  @override
  State<GrillDashboard> createState() => _GrillDashboardState();
}

class _GrillDashboardState extends State<GrillDashboard> {
  late final GrillController controller;
  final AlarmAudioService _alarmAudio = AlarmAudioService();
  late final CookTimerController timerController;
  late final CookPlanController planController;
  late final CookbookImportService _cookbookImport;
  StreamSubscription<CookbookRecipe>? _cookbookSubscription;
  CookbookRecipe? _importedRecipe;
  List<ProbeAlertLevel> _probeAlerts = List.filled(3, ProbeAlertLevel.none);
  final Set<int> _acknowledgedTargetAlarms = {};
  bool _targetAlarmPlaying = false;
  bool _smokerReady = false;
  static const int _smokerReadyRearmDelta = 5;

  @override
  void initState() {
    super.initState();
    controller = GrillController()..addListener(_changed);
    timerController = CookTimerController(
      onSchedule: (label, finishAt) =>
          _alarmAudio.scheduleTimerAlarm(label: label, finishAt: finishAt),
      onCancelSchedule: _alarmAudio.cancelTimerAlarm,
      onFinished: _timerFinished,
    )..addListener(_timerChanged);
    planController = CookPlanController(
      onSetSmokerTarget: controller.setGrillTarget,
      onSetProbeTarget: controller.setProbeTarget,
      onStageReady: _planStageReady,
    )..addListener(_planChanged);
    _cookbookImport = CookbookImportService();
    _cookbookSubscription = _cookbookImport.recipes.listen(
      _receiveCookbookRecipe,
    );
    controller.initialize();
    timerController.initialize();
    planController.initialize();
    _cookbookImport.initialize();
  }

  void _receiveCookbookRecipe(CookbookRecipe recipe) {
    if (!mounted) return;
    planController.loadDraft(CookPlan.fromRecipe(recipe));
    setState(() => _importedRecipe = recipe);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Imported ${recipe.name} from CookBook'),
        ),
      );
    });
  }

  void _timerChanged() {
    if (mounted) setState(() {});
  }

  void _planChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _planStageReady(CookPlanStage stage) async {
    await _alarmAudio.notifyTimerFinished('${stage.name} is ready to advance');
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 10),
        backgroundColor: const Color(0xffb26a00),
        content: Text('${stage.name} is complete. Approval is required.'),
      ),
    );
  }

  Future<void> _approvePlan() async {
    if (controller.phase != GrillConnectionPhase.connected ||
        controller.powerOn != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            'Connect to the smoker and turn it on before starting automation.',
          ),
        ),
      );
      return;
    }
    await planController.approveAndStart();
  }

  Future<void> _timerFinished(String label) async {
    await _alarmAudio.notifyTimerFinished(label);
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        backgroundColor: Theme.of(context).colorScheme.error,
        content: Text('$label finished'),
      ),
    );
  }

  void _changed() {
    if (!mounted) return;
    final nextAlerts = controller.probeAlertLevels;
    final newlyTriggered = <({int probe, ProbeAlertLevel level})>[];
    for (var index = 0; index < nextAlerts.length; index++) {
      if (_probeAlerts[index] != ProbeAlertLevel.none &&
          nextAlerts[index].index < _probeAlerts[index].index) {
        _alarmAudio.cancelProbeAlert(index + 1);
      }
      if (nextAlerts[index] != ProbeAlertLevel.targetReached) {
        _acknowledgedTargetAlarms.remove(index);
      }
      if (nextAlerts[index].index > _probeAlerts[index].index) {
        newlyTriggered.add((probe: index + 1, level: nextAlerts[index]));
      }
    }
    _probeAlerts = nextAlerts;
    unawaited(
      planController.updateTelemetry(
        chamberTemperature: controller.grillTemperature,
        probeTemperatures: controller.probeTemperatures,
      ),
    );
    final grillTemperature = controller.grillTemperature;
    final grillTarget = controller.grillTarget;
    final reachedGrillTarget =
        controller.powerOn == true &&
        GrillProtocol.hasReachedGrillTarget(
          current: grillTemperature,
          target: grillTarget,
          fahrenheit: controller.fahrenheit,
        );
    var smokerJustReachedTarget = false;
    if (!_smokerReady && reachedGrillTarget) {
      _smokerReady = true;
      smokerJustReachedTarget = true;
    } else if (_smokerReady &&
        (controller.powerOn != true ||
            grillTemperature == null ||
            grillTarget == null ||
            grillTemperature <= grillTarget - _smokerReadyRearmDelta)) {
      _smokerReady = false;
      _alarmAudio.cancelSmokerReady();
    }
    setState(() {});
    if (smokerJustReachedTarget) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            controller.grillTemperature == null ||
            controller.grillTarget == null) {
          return;
        }
        _alarmAudio.notifySmokerReady(
          current: controller.grillTemperature!,
          target: controller.grillTarget!,
        );
        HapticFeedback.mediumImpact();
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 8),
            backgroundColor: const Color(0xff2e7d5b),
            content: Text(
              'Smarter Smoker has reached ${controller.grillTarget}'
              '${controller.fahrenheit ? '°F' : '°C'}',
            ),
          ),
        );
      });
    }
    if (newlyTriggered.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final reachedTarget = newlyTriggered.any(
          (event) => event.level == ProbeAlertLevel.targetReached,
        );
        if (reachedTarget) {
          _targetAlarmPlaying = true;
          for (final event in newlyTriggered.where(
            (event) => event.level == ProbeAlertLevel.targetReached,
          )) {
            final index = event.probe - 1;
            _alarmAudio.startTargetAlarm(
              probe: event.probe,
              current: controller.probeTemperatures[index],
              target: controller.probeTargets[index],
            );
          }
        } else if (!_hasUnacknowledgedTargetAlarm) {
          for (final event in newlyTriggered) {
            final index = event.probe - 1;
            _alarmAudio.playPreAlarm(
              probe: event.probe,
              current: controller.probeTemperatures[index],
              target: controller.probeTargets[index],
            );
          }
        }
        HapticFeedback.mediumImpact();
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 8),
            backgroundColor:
                newlyTriggered.any(
                  (event) => event.level == ProbeAlertLevel.targetReached,
                )
                ? Theme.of(context).colorScheme.error
                : const Color(0xffb26a00),
            content: Text(
              newlyTriggered
                  .map(
                    (event) => event.level == ProbeAlertLevel.targetReached
                        ? 'Probe ${event.probe} reached its target'
                        : 'Probe ${event.probe} is within '
                              '${GrillController.probePreAlarmDelta}° of its target',
                  )
                  .join(' • '),
            ),
          ),
        );
      });
    }
    if (_targetAlarmPlaying && !_hasUnacknowledgedTargetAlarm) {
      _targetAlarmPlaying = false;
      _alarmAudio.stop();
    }
  }

  bool get _hasUnacknowledgedTargetAlarm {
    for (var index = 0; index < _probeAlerts.length; index++) {
      if (_probeAlerts[index] == ProbeAlertLevel.targetReached &&
          !_acknowledgedTargetAlarms.contains(index)) {
        return true;
      }
    }
    return false;
  }

  void _acknowledgeProbeAlarm(int index) {
    _acknowledgedTargetAlarms.add(index);
    _alarmAudio.cancelProbeAlert(index + 1);
    if (!_hasUnacknowledgedTargetAlarm) {
      _targetAlarmPlaying = false;
      _alarmAudio.stop();
    }
    setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    timerController.removeListener(_timerChanged);
    timerController.dispose();
    planController.removeListener(_planChanged);
    planController.dispose();
    unawaited(_cookbookSubscription?.cancel());
    unawaited(_cookbookImport.dispose());
    _alarmAudio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverAppBar.large(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              title: const Text('Smarter Smoker'),
              actions: [
                _ConnectionBadge(phase: controller.phase),
                const SizedBox(width: 16),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
              sliver: SliverList.list(
                children: [
                  if (controller.phase == GrillConnectionPhase.needsId)
                    _SetupCard(controller: controller),
                  _PowerCard(controller: controller),
                  const SizedBox(height: 16),
                  _GrillTemperatureCard(controller: controller),
                  const SizedBox(height: 16),
                  _CookTimerCard(controller: timerController),
                  if (planController.status == CookPlanStatus.active ||
                      planController.status == CookPlanStatus.paused ||
                      planController.status == CookPlanStatus.completed) ...[
                    const SizedBox(height: 16),
                    _ActiveCookPlanCard(controller: planController),
                  ] else if (_importedRecipe case final recipe?) ...[
                    const SizedBox(height: 16),
                    _CookbookRecipeCard(
                      recipe: recipe,
                      controller: planController,
                      onApprove: _approvePlan,
                      onDismiss: () {
                        planController.cancel();
                        setState(() => _importedRecipe = null);
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Food probes',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth > 650
                          ? (constraints.maxWidth - 12) / 2
                          : constraints.maxWidth;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (var i = 0; i < 3; i++)
                            SizedBox(
                              width: width,
                              child: _ProbeCard(
                                controller: controller,
                                index: i,
                                acknowledged: _acknowledgedTargetAlarms
                                    .contains(i),
                                onAcknowledge: () => _acknowledgeProbeAlarm(i),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  _AdvancedCard(controller: controller),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CookbookRecipeCard extends StatelessWidget {
  const _CookbookRecipeCard({
    required this.recipe,
    required this.controller,
    required this.onApprove,
    required this.onDismiss,
  });

  final CookbookRecipe recipe;
  final CookPlanController controller;
  final Future<void> Function() onApprove;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Card.filled(
    color: const Color(0xfffff1e8),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.menu_book_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'IMPORTED FROM COOKBOOK',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .8,
                      ),
                    ),
                    Text(
                      recipe.name,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Dismiss imported recipe',
                onPressed: onDismiss,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (recipe.cookMinutes > 0) ...[
            const SizedBox(height: 4),
            Text('Cook time: ${recipe.cookMinutes} minutes'),
          ],
          const SizedBox(height: 14),
          Text(
            'Suggested cook plan',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (controller.plan?.stages.isEmpty ?? true)
            const Text(
              'No smoker stages were detected automatically. Review the '
              'recipe directions before cooking.',
            )
          else
            for (
              var index = 0;
              index < (controller.plan?.stages.length ?? 0);
              index++
            )
              _CookbookStageRow(
                number: index + 1,
                stage: controller.plan!.stages[index],
                onChanged: (stage) => controller.updateStage(index, stage),
              ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: controller.plan?.stages.isEmpty ?? true
                  ? null
                  : onApprove,
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Approve & start cook plan'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Review every stage. Imported stages ask before advancing.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

class _CookbookStageRow extends StatelessWidget {
  const _CookbookStageRow({
    required this.number,
    required this.stage,
    required this.onChanged,
  });

  final int number;
  final CookPlanStage stage;
  final ValueChanged<CookPlanStage> onChanged;

  @override
  Widget build(BuildContext context) {
    final endText = switch (stage.condition) {
      CookPlanCondition.chamberTemperature =>
        'until Grill reaches ${stage.probeTarget ?? stage.smokerTarget}°F',
      CookPlanCondition.duration =>
        'for ${stage.duration?.inMinutes ?? 0} minutes',
      CookPlanCondition.probeTemperature =>
        'until Probe ${stage.probe} reaches ${stage.probeTarget}°F',
      CookPlanCondition.manual => 'until manually advanced',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Colors.white,
            child: Text(
              '$number',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${stage.name}: ${stage.smokerTarget}°F $endText · '
              '${_advanceModeText(stage.advanceMode)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          PopupMenuButton<CookPlanAdvanceMode>(
            tooltip: 'Choose advancement behavior',
            initialValue: stage.advanceMode,
            onSelected: (mode) {
              onChanged(
                stage.copyWith(
                  advanceMode: mode,
                  condition:
                      stage.condition == CookPlanCondition.manual &&
                          mode != CookPlanAdvanceMode.manualOnly
                      ? CookPlanCondition.chamberTemperature
                      : stage.condition,
                ),
              );
            },
            itemBuilder: (context) => [
              for (final mode in CookPlanAdvanceMode.values)
                PopupMenuItem(value: mode, child: Text(_advanceModeText(mode))),
            ],
          ),
          IconButton(
            tooltip: 'Edit step',
            onPressed: () async {
              final updated = await _editCookPlanStep(context, stage);
              if (updated != null) onChanged(updated);
            },
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
    );
  }
}

String _advanceModeText(CookPlanAdvanceMode mode) => switch (mode) {
  CookPlanAdvanceMode.manualOnly => 'Manual Advance',
  CookPlanAdvanceMode.askFirst => 'Ask before advancing',
  CookPlanAdvanceMode.automatic => 'Advance automatically',
};

Future<CookPlanStage?> _editCookPlanStep(
  BuildContext context,
  CookPlanStage stage,
) async {
  final grillController = TextEditingController(text: '${stage.smokerTarget}');
  final timeController = TextEditingController(
    text: stage.duration == null ? '' : '${stage.duration!.inMinutes}',
  );
  var probe = stage.probe;
  final probeTargetController = TextEditingController(
    text: stage.probeTarget == null ? '' : '${stage.probeTarget}',
  );
  var error = '';

  final result = await showDialog<CookPlanStage>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text('Edit ${stage.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: grillController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Grill set temperature',
                  suffixText: '°F',
                  helperText: 'Target temperature sent to the grill.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: timeController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Time (optional)',
                  suffixText: 'minutes',
                  helperText: 'Leave blank for no timer.',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: probe,
                decoration: const InputDecoration(
                  labelText: 'Evaluation sensor',
                  helperText: 'Determines when this step is ready to advance.',
                ),
                items: [
                  for (var number = 0; number <= 3; number++)
                    DropdownMenuItem(
                      value: number,
                      child: Text(number == 0 ? 'Grill' : 'Probe $number'),
                    ),
                ],
                onChanged: (value) =>
                    setDialogState(() => probe = value ?? probe),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: probeTargetController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Evaluation target (optional)',
                  suffixText: '°F',
                  helperText: 'Leave blank when no sensor target is used.',
                ),
              ),
              if (error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final grillTarget = int.tryParse(grillController.text.trim());
              final timeText = timeController.text.trim();
              final probeTargetText = probeTargetController.text.trim();
              final minutes = timeText.isEmpty ? null : int.tryParse(timeText);
              final probeTarget = probeTargetText.isEmpty
                  ? null
                  : int.tryParse(probeTargetText);

              if (grillTarget == null ||
                  grillTarget < 150 ||
                  grillTarget > 500) {
                setDialogState(
                  () => error = 'Grill temperature must be 150–500°F.',
                );
                return;
              }
              if (timeText.isNotEmpty &&
                  (minutes == null || minutes <= 0 || minutes > 1440)) {
                setDialogState(() => error = 'Time must be 1–1,440 minutes.');
                return;
              }
              final evaluationMinimum = probe == 0 ? 150 : 32;
              final evaluationMaximum = probe == 0 ? 500 : 212;
              if (probeTargetText.isNotEmpty &&
                  (probeTarget == null ||
                      probeTarget < evaluationMinimum ||
                      probeTarget > evaluationMaximum)) {
                setDialogState(
                  () => error = probe == 0
                      ? 'Grill evaluation target must be 150–500°F.'
                      : 'Probe target must be 32–212°F.',
                );
                return;
              }
              if (minutes != null && probeTarget != null) {
                setDialogState(
                  () => error =
                      'Use either a timer or a probe target for one step, '
                      'not both.',
                );
                return;
              }
              if (stage.advanceMode != CookPlanAdvanceMode.manualOnly &&
                  minutes == null &&
                  probeTarget == null) {
                setDialogState(
                  () => error =
                      'Enter a time or evaluation target, or choose '
                      'Manual Advance.',
                );
                return;
              }

              final condition = probeTarget != null
                  ? probe == 0
                        ? CookPlanCondition.chamberTemperature
                        : CookPlanCondition.probeTemperature
                  : minutes != null
                  ? CookPlanCondition.duration
                  : stage.advanceMode == CookPlanAdvanceMode.manualOnly
                  ? CookPlanCondition.manual
                  : CookPlanCondition.chamberTemperature;
              Navigator.pop(
                context,
                CookPlanStage(
                  name: stage.name,
                  instructions: stage.instructions,
                  smokerTarget: grillTarget,
                  condition: condition,
                  advanceMode: stage.advanceMode,
                  duration: minutes == null ? null : Duration(minutes: minutes),
                  probe: probe,
                  probeTarget: probeTarget,
                ),
              );
            },
            child: const Text('Save step'),
          ),
        ],
      ),
    ),
  );
  grillController.dispose();
  timeController.dispose();
  probeTargetController.dispose();
  return result;
}

class _ActiveCookPlanCard extends StatelessWidget {
  const _ActiveCookPlanCard({required this.controller});

  final CookPlanController controller;

  @override
  Widget build(BuildContext context) {
    final plan = controller.plan;
    final stage = controller.currentStage;
    if (plan == null || stage == null) return const SizedBox.shrink();
    final complete = controller.status == CookPlanStatus.completed;
    final nextIndex = controller.currentStageIndex + 1;
    final nextStage = nextIndex < plan.stages.length
        ? plan.stages[nextIndex]
        : null;
    final condition = switch (stage.condition) {
      CookPlanCondition.manual => 'Waiting for you',
      CookPlanCondition.chamberTemperature =>
        'Waiting for Grill to reach '
            '${stage.probeTarget ?? stage.smokerTarget}°F',
      CookPlanCondition.duration =>
        '${formatTimerDuration(controller.stageRemaining ?? Duration.zero)} remaining',
      CookPlanCondition.probeTemperature =>
        'Waiting for Probe ${stage.probe} to reach ${stage.probeTarget}°F',
    };
    return Card.filled(
      color: controller.readyToAdvance
          ? const Color(0xffffe0b2)
          : const Color(0xfffff1e8),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              complete ? 'COOK PLAN COMPLETE' : 'AUTOMATION ACTIVE',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w800,
                letterSpacing: .8,
              ),
            ),
            Text(
              plan.name,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              complete
                  ? 'All stages finished'
                  : 'Stage ${controller.currentStageIndex + 1} of '
                        '${plan.stages.length}: ${stage.name}',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (!complete) ...[
              const SizedBox(height: 4),
              Text(stage.instructions),
              const SizedBox(height: 8),
              Text(
                '${stage.smokerTarget}°F · $condition',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (controller.readyToAdvance)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Condition reached — waiting for your approval.',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              if (nextStage != null) ...[
                const SizedBox(height: 8),
                Text('Next: ${nextStage.name} at ${nextStage.smokerTarget}°F'),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: controller.advance,
                  icon: const Icon(Icons.skip_next),
                  label: Text(
                    nextStage == null
                        ? 'Finish cook'
                        : controller.readyToAdvance
                        ? 'Approve & start ${nextStage.name}'
                        : 'Advance now to ${nextStage.name}',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: controller.status == CookPlanStatus.paused
                          ? controller.resume
                          : controller.pause,
                      icon: Icon(
                        controller.status == CookPlanStatus.paused
                            ? Icons.play_arrow
                            : Icons.pause,
                      ),
                      label: Text(
                        controller.status == CookPlanStatus.paused
                            ? 'Resume'
                            : 'Pause',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _confirmCancelPlan(context, controller),
                      child: const Text('Cancel cook'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: controller.cancel,
                child: const Text('Close cook plan'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> _confirmCancelPlan(
  BuildContext context,
  CookPlanController controller,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Cancel this cook?'),
      content: const Text(
        'Automation will stop. The smoker will remain at its current target.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep cooking'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Cancel cook'),
        ),
      ],
    ),
  );
  if (confirmed == true) await controller.cancel();
}

class _CookTimerCard extends StatelessWidget {
  const _CookTimerCard({required this.controller});

  final CookTimerController controller;

  @override
  Widget build(BuildContext context) {
    final isCompleted = controller.status == CookTimerStatus.completed;
    final statusLabel = switch (controller.status) {
      CookTimerStatus.idle => 'Ready',
      CookTimerStatus.running => 'Running',
      CookTimerStatus.paused => 'Paused',
      CookTimerStatus.completed => 'Finished',
    };
    final modeLabel = controller.mode == CookTimerMode.countUp
        ? 'Count up'
        : 'Count down';
    return Card.filled(
      color: isCompleted
          ? Theme.of(context).colorScheme.errorContainer
          : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  controller.mode == CookTimerMode.countUp
                      ? Icons.timer_outlined
                      : Icons.hourglass_bottom,
                  color: isCompleted
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        controller.label,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text('$modeLabel · $statusLabel'),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Configure timer',
                  onPressed: controller.canConfigure
                      ? () => _timerSetupDialog(context, controller)
                      : null,
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                formatTimerDuration(controller.displayed),
                semanticsLabel:
                    '$modeLabel timer ${formatTimerDuration(controller.displayed)}',
                style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: isCompleted
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: controller.isRunning
                      ? controller.pause
                      : controller.startOrResume,
                  icon: Icon(
                    controller.isRunning ? Icons.pause : Icons.play_arrow,
                  ),
                  label: Text(
                    controller.isRunning
                        ? 'Pause'
                        : controller.status == CookTimerStatus.paused
                        ? 'Resume'
                        : controller.status == CookTimerStatus.completed
                        ? 'Restart'
                        : 'Start',
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed:
                      controller.status == CookTimerStatus.idle &&
                          controller.displayed == Duration.zero
                      ? null
                      : controller.reset,
                  icon: const Icon(Icons.replay),
                  label: const Text('Reset'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.phase});
  final GrillConnectionPhase phase;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (phase) {
      GrillConnectionPhase.connected => ('ONLINE', const Color(0xff2e7d5b)),
      GrillConnectionPhase.connecting => (
        'CONNECTING',
        const Color(0xffb26a00),
      ),
      GrillConnectionPhase.error => (
        'ERROR',
        Theme.of(context).colorScheme.error,
      ),
      GrillConnectionPhase.needsId => ('SETUP', const Color(0xff6d6257)),
      GrillConnectionPhase.disconnected => ('OFFLINE', const Color(0xff6d6257)),
    };
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, color: color, size: 9),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _timerSetupDialog(
  BuildContext context,
  CookTimerController controller,
) async {
  final result =
      await showDialog<({CookTimerMode mode, String label, Duration duration})>(
        context: context,
        builder: (context) => _TimerSetupDialog(
          initialMode: controller.mode,
          initialLabel: controller.label,
          initialDuration: controller.countdownDuration,
        ),
      );
  if (result == null) return;
  await controller.configure(
    newMode: result.mode,
    newLabel: result.label,
    duration: result.duration,
  );
}

class _TimerSetupDialog extends StatefulWidget {
  const _TimerSetupDialog({
    required this.initialMode,
    required this.initialLabel,
    required this.initialDuration,
  });

  final CookTimerMode initialMode;
  final String initialLabel;
  final Duration initialDuration;

  @override
  State<_TimerSetupDialog> createState() => _TimerSetupDialogState();
}

class _TimerSetupDialogState extends State<_TimerSetupDialog> {
  late CookTimerMode mode;
  late final TextEditingController labelController;
  late final TextEditingController hoursController;
  late final TextEditingController minutesController;
  late final TextEditingController secondsController;

  @override
  void initState() {
    super.initState();
    mode = widget.initialMode;
    labelController = TextEditingController(text: widget.initialLabel);
    hoursController = TextEditingController(
      text: widget.initialDuration.inHours.toString(),
    );
    minutesController = TextEditingController(
      text: (widget.initialDuration.inMinutes % 60).toString(),
    );
    secondsController = TextEditingController(
      text: (widget.initialDuration.inSeconds % 60).toString(),
    );
  }

  @override
  void dispose() {
    labelController.dispose();
    hoursController.dispose();
    minutesController.dispose();
    secondsController.dispose();
    super.dispose();
  }

  Duration? get duration {
    final hours = int.tryParse(hoursController.text) ?? 0;
    final minutes = int.tryParse(minutesController.text) ?? 0;
    final seconds = int.tryParse(secondsController.text) ?? 0;
    if (hours < 0 ||
        hours > 99 ||
        minutes < 0 ||
        minutes > 59 ||
        seconds < 0 ||
        seconds > 59) {
      return null;
    }
    final value = Duration(hours: hours, minutes: minutes, seconds: seconds);
    if (mode == CookTimerMode.countDown && value == Duration.zero) return null;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final validDuration = duration;
    return AlertDialog(
      title: const Text('Configure timer'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<CookTimerMode>(
              segments: const [
                ButtonSegment(
                  value: CookTimerMode.countUp,
                  icon: Icon(Icons.timer_outlined),
                  label: Text('Count up'),
                ),
                ButtonSegment(
                  value: CookTimerMode.countDown,
                  icon: Icon(Icons.hourglass_bottom),
                  label: Text('Count down'),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (selection) =>
                  setState(() => mode = selection.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: labelController,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'Timer name',
                hintText: 'Cook timer',
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (mode == CookTimerMode.countDown) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: _TimerNumberField(
                      controller: hoursController,
                      label: 'Hours',
                      onChanged: () => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _TimerNumberField(
                      controller: minutesController,
                      label: 'Minutes',
                      onChanged: () => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _TimerNumberField(
                      controller: secondsController,
                      label: 'Seconds',
                      onChanged: () => setState(() {}),
                    ),
                  ),
                ],
              ),
              if (validDuration == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Enter 1 second to 99:59:59.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: validDuration == null
              ? null
              : () => Navigator.pop(context, (
                  mode: mode,
                  label: labelController.text,
                  duration: validDuration,
                )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _TimerNumberField extends StatelessWidget {
  const _TimerNumberField({
    required this.controller,
    required this.label,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: TextInputType.number,
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(2),
    ],
    decoration: InputDecoration(labelText: label),
    onChanged: (_) => onChanged(),
  );
}

class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.controller});
  final GrillController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Card.filled(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Find your grill',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            const Text(
              'We will look for a nearby BLE device whose name begins with GRILL, save its ID, then connect over Wi-Fi.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => controller.discoverAndSave(),
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Discover grill'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PowerCard extends StatelessWidget {
  const _PowerCard({required this.controller});
  final GrillController controller;

  @override
  Widget build(BuildContext context) {
    final on = controller.powerOn;
    final color = on == true
        ? const Color(0xff2e7d5b)
        : const Color(0xff514a43);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          if (on != null) {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: Text(on ? 'Turn grill off?' : 'Turn grill on?'),
                content: const Text('Confirm this grill power change.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(on ? 'Turn off' : 'Turn on'),
                  ),
                ],
              ),
            );
            if (confirmed != true) return;
          }
          await controller.togglePower();
        },
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [color, Color.lerp(color, Colors.black, .22)!],
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.power_settings_new,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GRILL POWER',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .72),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                    Text(
                      on == null
                          ? 'Checking…'
                          : on
                          ? 'On'
                          : 'Off',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Colors.white.withValues(alpha: .8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GrillTemperatureCard extends StatelessWidget {
  const _GrillTemperatureCard({required this.controller});
  final GrillController controller;

  @override
  Widget build(BuildContext context) => Card.filled(
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          Expanded(
            child: _TemperatureValue(
              label: 'GRILL',
              value: controller.grillTemperature,
              unit: controller.fahrenheit ? '°F' : '°C',
            ),
          ),
          Container(
            width: 1,
            height: 70,
            color: Theme.of(context).dividerColor,
          ),
          Expanded(
            child: InkWell(
              onTap: () => _temperatureDialog(
                context,
                controller.grillTarget ?? 225,
                'Grill target',
                controller.setGrillTarget,
                minimum: controller.fahrenheit
                    ? GrillProtocol.minimumGrillFahrenheit
                    : GrillProtocol.minimumGrillCelsius,
                maximum: controller.fahrenheit
                    ? GrillProtocol.maximumGrillFahrenheit
                    : GrillProtocol.maximumGrillCelsius,
                unit: controller.fahrenheit ? '°F' : '°C',
              ),
              child: _TemperatureValue(
                label: 'TARGET · TAP TO SET',
                value: controller.grillTarget,
                unit: controller.fahrenheit ? '°F' : '°C',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _TemperatureValue extends StatelessWidget {
  const _TemperatureValue({
    required this.label,
    required this.value,
    required this.unit,
  });
  final String label;
  final int? value;
  final String unit;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: const Color(0xff776c61),
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        value == null || value! < 0 ? '—' : '$value$unit',
        style: Theme.of(
          context,
        ).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700),
      ),
    ],
  );
}

class _ProbeCard extends StatelessWidget {
  const _ProbeCard({
    required this.controller,
    required this.index,
    required this.acknowledged,
    required this.onAcknowledge,
  });
  final GrillController controller;
  final int index;
  final bool acknowledged;
  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final current = controller.probeTemperatures[index];
    final target = controller.probeTargets[index];
    final alert = controller.probeAlertLevels[index];
    final alertColor = switch (alert) {
      ProbeAlertLevel.none => null,
      ProbeAlertLevel.preAlarm => const Color(0xffffe0a3),
      ProbeAlertLevel.targetReached => const Color(0xffffc9c2),
    };
    return Card.filled(
      color: alertColor ?? Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (alert == ProbeAlertLevel.targetReached && !acknowledged) {
            onAcknowledge();
            return;
          }
          _temperatureDialog(
            context,
            target > 0 ? target : 165,
            'Probe ${index + 1} target',
            (value) => controller.setProbeTarget(index + 1, value),
            minimum: controller.fahrenheit
                ? GrillProtocol.minimumProbeFahrenheit
                : GrillProtocol.minimumProbeCelsius,
            maximum: controller.fahrenheit
                ? GrillProtocol.maximumProbeFahrenheit
                : GrillProtocol.maximumProbeCelsius,
            unit: controller.fahrenheit ? '°F' : '°C',
            onClear: target >= 0
                ? () => controller.clearProbeTarget(index + 1)
                : null,
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Icon(
                Icons.thermostat,
                color: current < 0
                    ? Colors.grey
                    : Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Probe ${index + 1}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      current < 0
                          ? 'Not connected'
                          : '$current${controller.fahrenheit ? '°F' : '°C'}',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (alert != ProbeAlertLevel.none)
                    Container(
                      margin: const EdgeInsets.only(bottom: 5),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: alert == ProbeAlertLevel.targetReached
                            ? Theme.of(context).colorScheme.error
                            : const Color(0xff9a5b00),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        alert == ProbeAlertLevel.targetReached
                            ? acknowledged
                                  ? 'ACKNOWLEDGED'
                                  : 'TAP TO ACK'
                            : 'PRE-ALARM',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  Text(
                    target < 0 ? 'Set target' : 'Target $target°',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (target >= 0)
                    Text(
                      'Pre-alarm ${target - GrillController.probePreAlarmDelta}°',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdvancedCard extends StatelessWidget {
  const _AdvancedCard({required this.controller});
  final GrillController controller;

  @override
  Widget build(BuildContext context) => Card.filled(
    color: Colors.white,
    child: ExpansionTile(
      title: const Text('Advanced & diagnostics'),
      subtitle: Text(controller.deviceId ?? 'No Grill ID'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('°F')),
            ButtonSegment(value: false, label: Text('°C')),
          ],
          selected: {controller.fahrenheit},
          onSelectionChanged: (value) =>
              controller.setUnits(useFahrenheit: value.first),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: controller.discoverAndSave,
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('BLE discovery'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: controller.clearSavedId,
              child: const Text('Forget grill'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: controller.provisioningWifi
                ? null
                : () => _wifiSetupDialog(context, controller),
            icon: controller.provisioningWifi
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_password),
            label: Text(
              controller.provisioningWifi
                  ? 'Setting up Wi-Fi…'
                  : 'Set up grill Wi-Fi',
            ),
          ),
        ),
        const Divider(height: 28),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Activity log',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 240),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xff25221f),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              controller.logs.isEmpty
                  ? 'Waiting for activity…'
                  : controller.logs.join('\n'),
              style: const TextStyle(
                color: Color(0xffd9d1c7),
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> _wifiSetupDialog(
  BuildContext context,
  GrillController controller,
) async {
  final ssid = TextEditingController();
  final password = TextEditingController();
  var obscurePassword = true;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Set up grill Wi-Fi'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The grill supports 2.4 GHz Wi-Fi. Keep your phone or tablet '
                'near the grill while the settings are sent over Bluetooth.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ssid,
                decoration: const InputDecoration(
                  labelText: 'Wi-Fi network name',
                  prefixIcon: Icon(Icons.wifi),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: obscurePassword,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Wi-Fi password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: () =>
                        setState(() => obscurePassword = !obscurePassword),
                    icon: Icon(
                      obscurePassword ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await controller.provisionWifi(ssid.text, password.text);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (error) {
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(content: Text('Wi-Fi setup failed: $error')),
                );
              }
            },
            child: const Text('Send to grill'),
          ),
        ],
      ),
    ),
  );
  ssid.dispose();
  password.dispose();
}

Future<void> _temperatureDialog(
  BuildContext context,
  int initial,
  String title,
  ValueChanged<int> onSave, {
  required int minimum,
  required int maximum,
  required String unit,
  VoidCallback? onClear,
}) async {
  final result = await showDialog<int>(
    context: context,
    builder: (context) => _TemperatureDialog(
      initial: initial,
      title: title,
      minimum: minimum,
      maximum: maximum,
      unit: unit,
      onClear: onClear,
    ),
  );
  if (result != null) onSave(result);
}

class _TemperatureDialog extends StatefulWidget {
  const _TemperatureDialog({
    required this.initial,
    required this.title,
    required this.minimum,
    required this.maximum,
    required this.unit,
    this.onClear,
  });

  final int initial;
  final String title;
  final int minimum;
  final int maximum;
  final String unit;
  final VoidCallback? onClear;

  @override
  State<_TemperatureDialog> createState() => _TemperatureDialogState();
}

class _TemperatureDialogState extends State<_TemperatureDialog> {
  late int value;
  late final TextEditingController textController;
  String? validationMessage;

  @override
  void initState() {
    super.initState();
    value = widget.initial.clamp(widget.minimum, widget.maximum);
    textController = TextEditingController(text: value.toString());
  }

  @override
  void dispose() {
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value${widget.unit}',
          style: Theme.of(context).textTheme.displayMedium,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: textController,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Temperature',
            suffixText: widget.unit,
            errorText: validationMessage,
            helperText:
                'Allowed range: ${widget.minimum}–${widget.maximum}${widget.unit}',
          ),
          onChanged: (text) {
            final typed = int.tryParse(text);
            setState(() {
              if (typed == null ||
                  typed < widget.minimum ||
                  typed > widget.maximum) {
                validationMessage =
                    'Enter a value from ${widget.minimum} to ${widget.maximum}';
              } else {
                value = typed;
                validationMessage = null;
              }
            });
          },
        ),
        const SizedBox(height: 8),
        Slider(
          min: widget.minimum.toDouble(),
          max: widget.maximum.toDouble(),
          divisions: widget.maximum - widget.minimum,
          value: value.toDouble(),
          onChanged: (next) {
            final rounded = next.round();
            setState(() {
              value = rounded;
              validationMessage = null;
              final text = rounded.toString();
              textController.value = TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: text.length),
              );
            });
          },
        ),
      ],
    ),
    actions: [
      if (widget.onClear != null)
        TextButton(
          onPressed: () {
            widget.onClear!();
            Navigator.pop(context);
          },
          child: const Text('Clear target'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: validationMessage == null && textController.text.isNotEmpty
            ? () => Navigator.pop(context, value)
            : null,
        child: const Text('Set temperature'),
      ),
    ],
  );
}
