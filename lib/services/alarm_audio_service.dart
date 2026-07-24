import 'package:flutter/services.dart';

class AlarmAudioService {
  static const _channel = MethodChannel(
    'com.wwhitmoyer.smartersmoker/system_sounds',
  );

  Future<void> playPreAlarm({
    required int probe,
    required int current,
    required int target,
  }) async {
    try {
      await _channel.invokeMethod<void>('playPreAlarm', {
        'probe': probe,
        'current': current,
        'target': target,
      });
    } on MissingPluginException {
      await SystemSound.play(SystemSoundType.alert);
    }
  }

  Future<void> startTargetAlarm({
    required int probe,
    required int current,
    required int target,
  }) async {
    try {
      await _channel.invokeMethod<void>('startTargetAlarm', {
        'probe': probe,
        'current': current,
        'target': target,
      });
    } on MissingPluginException {
      await SystemSound.play(SystemSoundType.alert);
    }
  }

  Future<void> cancelProbeAlert(int probe) async {
    try {
      await _channel.invokeMethod<void>('cancelProbeAlert', {'probe': probe});
    } on MissingPluginException {
      // Lock-screen notifications are currently implemented on Android.
    }
  }

  Future<void> notifySmokerReady({
    required int current,
    required int target,
  }) async {
    try {
      await _channel.invokeMethod<void>('notifySmokerReady', {
        'current': current,
        'target': target,
      });
    } on MissingPluginException {
      await SystemSound.play(SystemSoundType.alert);
    }
  }

  Future<void> cancelSmokerReady() async {
    try {
      await _channel.invokeMethod<void>('cancelSmokerReady');
    } on MissingPluginException {
      // Lock-screen notifications are currently implemented on Android.
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stopAlarm');
    } on MissingPluginException {
      // SystemSound cannot be stopped and is only used as a non-Android fallback.
    }
  }

  Future<void> dispose() => stop();
}
