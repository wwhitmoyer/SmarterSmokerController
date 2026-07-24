import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CookTimerMode { countUp, countDown }

enum CookTimerStatus { idle, running, paused, completed }

typedef TimerScheduleCallback =
    Future<void> Function(String label, DateTime finishAt);
typedef TimerCallback = Future<void> Function(String label);

class CookTimerController extends ChangeNotifier {
  CookTimerController({
    required this.onSchedule,
    required this.onCancelSchedule,
    required this.onFinished,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const _modeKey = 'cook_timer_mode';
  static const _statusKey = 'cook_timer_status';
  static const _labelKey = 'cook_timer_label';
  static const _durationKey = 'cook_timer_duration_ms';
  static const _accumulatedKey = 'cook_timer_accumulated_ms';
  static const _startedAtKey = 'cook_timer_started_at_ms';

  final TimerScheduleCallback onSchedule;
  final AsyncCallback onCancelSchedule;
  final TimerCallback onFinished;
  final DateTime Function() _now;

  Timer? _ticker;
  CookTimerMode mode = CookTimerMode.countUp;
  CookTimerStatus status = CookTimerStatus.idle;
  String label = 'Cook timer';
  Duration countdownDuration = const Duration(hours: 1);
  Duration _accumulated = Duration.zero;
  DateTime? _startedAt;

  bool get isRunning => status == CookTimerStatus.running;
  bool get canConfigure => !isRunning;

  Duration get elapsed {
    final startedAt = _startedAt;
    if (!isRunning || startedAt == null) return _accumulated;
    return _accumulated + _now().difference(startedAt);
  }

  Duration get displayed {
    if (mode == CookTimerMode.countUp) return elapsed;
    final remaining = countdownDuration - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    mode = _enumValue(
      CookTimerMode.values,
      preferences.getString(_modeKey),
      CookTimerMode.countUp,
    );
    status = _enumValue(
      CookTimerStatus.values,
      preferences.getString(_statusKey),
      CookTimerStatus.idle,
    );
    label = preferences.getString(_labelKey) ?? 'Cook timer';
    countdownDuration = Duration(
      milliseconds:
          preferences.getInt(_durationKey) ??
          const Duration(hours: 1).inMilliseconds,
    );
    _accumulated = Duration(
      milliseconds: preferences.getInt(_accumulatedKey) ?? 0,
    );
    final startedAtMilliseconds = preferences.getInt(_startedAtKey);
    _startedAt = startedAtMilliseconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(startedAtMilliseconds);

    if (isRunning) {
      if (mode == CookTimerMode.countDown && elapsed >= countdownDuration) {
        await _complete(notify: false);
      } else {
        _startTicker();
      }
    }
    notifyListeners();
  }

  Future<void> configure({
    required CookTimerMode newMode,
    required String newLabel,
    required Duration duration,
  }) async {
    if (!canConfigure) return;
    mode = newMode;
    label = newLabel.trim().isEmpty ? 'Cook timer' : newLabel.trim();
    countdownDuration = duration;
    status = CookTimerStatus.idle;
    _accumulated = Duration.zero;
    _startedAt = null;
    await onCancelSchedule();
    await _persist();
    notifyListeners();
  }

  Future<void> startOrResume() async {
    if (isRunning) return;
    if (mode == CookTimerMode.countDown && countdownDuration <= Duration.zero) {
      return;
    }
    if (status == CookTimerStatus.completed) {
      _accumulated = Duration.zero;
    }
    _startedAt = _now();
    status = CookTimerStatus.running;
    if (mode == CookTimerMode.countDown) {
      await onSchedule(label, _now().add(displayed));
    }
    _startTicker();
    await _persist();
    notifyListeners();
  }

  Future<void> pause() async {
    if (!isRunning) return;
    _accumulated = elapsed;
    _startedAt = null;
    status = CookTimerStatus.paused;
    _ticker?.cancel();
    await onCancelSchedule();
    await _persist();
    notifyListeners();
  }

  Future<void> reset() async {
    _ticker?.cancel();
    _accumulated = Duration.zero;
    _startedAt = null;
    status = CookTimerStatus.idle;
    await onCancelSchedule();
    await _persist();
    notifyListeners();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mode == CookTimerMode.countDown && elapsed >= countdownDuration) {
        unawaited(_complete());
      } else {
        notifyListeners();
      }
    });
  }

  Future<void> _complete({bool notify = true}) async {
    _ticker?.cancel();
    _accumulated = countdownDuration;
    _startedAt = null;
    status = CookTimerStatus.completed;
    await onCancelSchedule();
    await _persist();
    notifyListeners();
    if (notify) await onFinished(label);
  }

  Future<void> _persist() async {
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setString(_modeKey, mode.name),
      preferences.setString(_statusKey, status.name),
      preferences.setString(_labelKey, label),
      preferences.setInt(_durationKey, countdownDuration.inMilliseconds),
      preferences.setInt(_accumulatedKey, _accumulated.inMilliseconds),
      if (_startedAt case final startedAt?)
        preferences.setInt(_startedAtKey, startedAt.millisecondsSinceEpoch)
      else
        preferences.remove(_startedAtKey),
    ]);
  }

  static T _enumValue<T extends Enum>(
    List<T> values,
    String? name,
    T fallback,
  ) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

String formatTimerDuration(Duration duration) {
  final totalSeconds = duration.inSeconds.clamp(0, 359999);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  return [
    hours.toString().padLeft(2, '0'),
    minutes.toString().padLeft(2, '0'),
    seconds.toString().padLeft(2, '0'),
  ].join(':');
}
