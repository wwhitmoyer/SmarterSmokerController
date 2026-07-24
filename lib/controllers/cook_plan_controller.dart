import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/cookbook_import_service.dart';

enum CookPlanAdvanceMode { manualOnly, askFirst, automatic }

enum CookPlanCondition {
  manual,
  chamberTemperature,
  duration,
  probeTemperature,
}

enum CookPlanStatus { draft, active, paused, completed }

class CookPlanStage {
  const CookPlanStage({
    required this.name,
    required this.instructions,
    required this.smokerTarget,
    required this.condition,
    required this.advanceMode,
    this.duration,
    this.probe = 1,
    this.probeTarget,
  });

  final String name;
  final String instructions;
  final int smokerTarget;
  final CookPlanCondition condition;
  final CookPlanAdvanceMode advanceMode;
  final Duration? duration;
  final int probe;
  final int? probeTarget;

  CookPlanStage copyWith({
    String? name,
    String? instructions,
    int? smokerTarget,
    CookPlanCondition? condition,
    CookPlanAdvanceMode? advanceMode,
    Duration? duration,
    int? probe,
    int? probeTarget,
  }) => CookPlanStage(
    name: name ?? this.name,
    instructions: instructions ?? this.instructions,
    smokerTarget: smokerTarget ?? this.smokerTarget,
    condition: condition ?? this.condition,
    advanceMode: advanceMode ?? this.advanceMode,
    duration: duration ?? this.duration,
    probe: probe ?? this.probe,
    probeTarget: probeTarget ?? this.probeTarget,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'instructions': instructions,
    'smokerTarget': smokerTarget,
    'condition': condition.name,
    'advanceMode': advanceMode.name,
    'durationSeconds': duration?.inSeconds,
    'probe': probe,
    'probeTarget': probeTarget,
  };

  factory CookPlanStage.fromJson(Map<String, dynamic> json) => CookPlanStage(
    name: '${json['name'] ?? 'Cook'}',
    instructions: '${json['instructions'] ?? ''}',
    smokerTarget: (json['smokerTarget'] as num?)?.round() ?? 0,
    condition: _enumValue(
      CookPlanCondition.values,
      json['condition'],
      CookPlanCondition.manual,
    ),
    advanceMode: _enumValue(
      CookPlanAdvanceMode.values,
      json['advanceMode'],
      CookPlanAdvanceMode.askFirst,
    ),
    duration: json['durationSeconds'] == null
        ? null
        : Duration(seconds: (json['durationSeconds'] as num).round()),
    probe: (json['probe'] as num?)?.round() ?? 1,
    probeTarget: (json['probeTarget'] as num?)?.round(),
  );
}

class CookPlan {
  const CookPlan({required this.name, required this.stages});

  final String name;
  final List<CookPlanStage> stages;

  factory CookPlan.fromRecipe(CookbookRecipe recipe) => CookPlan(
    name: recipe.name,
    stages: recipe.stages.map((stage) {
      final condition = switch (stage.end) {
        CookbookStageEnd.chamberReady => CookPlanCondition.chamberTemperature,
        CookbookStageEnd.duration => CookPlanCondition.duration,
        CookbookStageEnd.probeTarget => CookPlanCondition.probeTemperature,
        CookbookStageEnd.manual => CookPlanCondition.manual,
      };
      return CookPlanStage(
        name: stage.name,
        instructions: stage.direction,
        smokerTarget: stage.smokerTarget,
        condition: condition,
        advanceMode: condition == CookPlanCondition.manual
            ? CookPlanAdvanceMode.manualOnly
            : CookPlanAdvanceMode.askFirst,
        duration: stage.duration,
        probe: condition == CookPlanCondition.chamberTemperature ? 0 : 1,
        probeTarget: condition == CookPlanCondition.chamberTemperature
            ? stage.smokerTarget
            : stage.probeTarget,
      );
    }).toList(),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'stages': stages.map((stage) => stage.toJson()).toList(),
  };

  factory CookPlan.fromJson(Map<String, dynamic> json) => CookPlan(
    name: '${json['name'] ?? 'Cook plan'}',
    stages: (json['stages'] as List<dynamic>? ?? const [])
        .map((stage) => CookPlanStage.fromJson(stage as Map<String, dynamic>))
        .toList(),
  );
}

typedef StageReadyCallback = Future<void> Function(CookPlanStage stage);

class CookPlanController extends ChangeNotifier {
  CookPlanController({
    required this.onSetSmokerTarget,
    required this.onSetProbeTarget,
    required this.onStageReady,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const _storageKey = 'active_cook_plan';
  final ValueChanged<int> onSetSmokerTarget;
  final void Function(int probe, int target) onSetProbeTarget;
  final StageReadyCallback onStageReady;
  final DateTime Function() _now;

  CookPlan? plan;
  CookPlanStatus status = CookPlanStatus.draft;
  int currentStageIndex = 0;
  bool readyToAdvance = false;
  DateTime? _stageStartedAt;
  DateTime? _pausedAt;
  Timer? _ticker;

  CookPlanStage? get currentStage {
    final currentPlan = plan;
    if (currentPlan == null ||
        currentStageIndex < 0 ||
        currentStageIndex >= currentPlan.stages.length) {
      return null;
    }
    return currentPlan.stages[currentStageIndex];
  }

  Duration get stageElapsed => _stageStartedAt == null
      ? Duration.zero
      : _now().difference(_stageStartedAt!);

  Duration? get stageRemaining {
    final duration = currentStage?.duration;
    if (duration == null) return null;
    final remaining = duration - stageElapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_storageKey);
    if (encoded == null) return;
    try {
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      plan = CookPlan.fromJson(json['plan'] as Map<String, dynamic>);
      status = _enumValue(
        CookPlanStatus.values,
        json['status'],
        CookPlanStatus.draft,
      );
      currentStageIndex = (json['currentStageIndex'] as num?)?.round() ?? 0;
      readyToAdvance = json['readyToAdvance'] == true;
      final startedAt = (json['stageStartedAt'] as num?)?.round();
      _stageStartedAt = startedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(startedAt);
      final pausedAt = (json['pausedAt'] as num?)?.round();
      _pausedAt = pausedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(pausedAt);
      if (status == CookPlanStatus.active) _startTicker();
      notifyListeners();
    } on FormatException {
      await preferences.remove(_storageKey);
    }
  }

  void loadDraft(CookPlan value) {
    _ticker?.cancel();
    plan = value;
    status = CookPlanStatus.draft;
    currentStageIndex = 0;
    readyToAdvance = false;
    _stageStartedAt = null;
    _pausedAt = null;
    notifyListeners();
  }

  void updateStage(int index, CookPlanStage stage) {
    if (status != CookPlanStatus.draft || plan == null) return;
    final stages = List<CookPlanStage>.from(plan!.stages)..[index] = stage;
    plan = CookPlan(name: plan!.name, stages: stages);
    notifyListeners();
  }

  Future<void> approveAndStart() async {
    if (plan == null || plan!.stages.isEmpty) return;
    status = CookPlanStatus.active;
    currentStageIndex = 0;
    await _startCurrentStage();
  }

  Future<void> advance() async {
    if (status != CookPlanStatus.active) return;
    if (currentStageIndex + 1 >= plan!.stages.length) {
      status = CookPlanStatus.completed;
      readyToAdvance = false;
      _stageStartedAt = null;
      _ticker?.cancel();
      await _persist();
      notifyListeners();
      return;
    }
    currentStageIndex++;
    await _startCurrentStage();
  }

  Future<void> pause() async {
    if (status != CookPlanStatus.active) return;
    status = CookPlanStatus.paused;
    _pausedAt = _now();
    _ticker?.cancel();
    await _persist();
    notifyListeners();
  }

  Future<void> resume() async {
    if (status != CookPlanStatus.paused) return;
    final pausedAt = _pausedAt;
    if (pausedAt != null && _stageStartedAt != null) {
      _stageStartedAt = _stageStartedAt!.add(_now().difference(pausedAt));
    }
    _pausedAt = null;
    status = CookPlanStatus.active;
    _startTicker();
    await _persist();
    notifyListeners();
  }

  Future<void> cancel() async {
    _ticker?.cancel();
    plan = null;
    status = CookPlanStatus.draft;
    currentStageIndex = 0;
    readyToAdvance = false;
    _stageStartedAt = null;
    _pausedAt = null;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_storageKey);
    notifyListeners();
  }

  Future<void> updateTelemetry({
    required int? chamberTemperature,
    required List<int> probeTemperatures,
  }) async {
    final stage = currentStage;
    if (status != CookPlanStatus.active ||
        stage == null ||
        readyToAdvance ||
        stage.advanceMode == CookPlanAdvanceMode.manualOnly) {
      return;
    }
    final conditionReached = switch (stage.condition) {
      CookPlanCondition.manual => false,
      CookPlanCondition.chamberTemperature =>
        chamberTemperature != null &&
            chamberTemperature >= (stage.probeTarget ?? stage.smokerTarget) - 5,
      CookPlanCondition.duration =>
        stage.duration != null && stageElapsed >= stage.duration!,
      CookPlanCondition.probeTemperature =>
        stage.probeTarget != null &&
            stage.probe > 0 &&
            stage.probe <= probeTemperatures.length &&
            probeTemperatures[stage.probe - 1] >= stage.probeTarget!,
    };
    if (!conditionReached) return;
    if (stage.advanceMode == CookPlanAdvanceMode.automatic) {
      await advance();
    } else {
      readyToAdvance = true;
      await onStageReady(stage);
      await _persist();
      notifyListeners();
    }
  }

  Future<void> _startCurrentStage() async {
    final stage = currentStage;
    if (stage == null) return;
    readyToAdvance = false;
    _stageStartedAt = _now();
    _pausedAt = null;
    onSetSmokerTarget(stage.smokerTarget);
    if (stage.condition == CookPlanCondition.probeTemperature &&
        stage.probeTarget != null) {
      onSetProbeTarget(stage.probe, stage.probeTarget!);
    }
    _startTicker();
    await _persist();
    notifyListeners();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
      unawaited(
        updateTelemetry(chamberTemperature: null, probeTemperatures: const []),
      );
    });
  }

  Future<void> _persist() async {
    final currentPlan = plan;
    if (currentPlan == null) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _storageKey,
      jsonEncode({
        'plan': currentPlan.toJson(),
        'status': status.name,
        'currentStageIndex': currentStageIndex,
        'readyToAdvance': readyToAdvance,
        'stageStartedAt': _stageStartedAt?.millisecondsSinceEpoch,
        'pausedAt': _pausedAt?.millisecondsSinceEpoch,
      }),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

T _enumValue<T extends Enum>(List<T> values, dynamic name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
