import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Initialize foreground task configuration. Call once in main().
void initForegroundService() {
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'voice_call_service',
      channelName: 'Voice Call Service',
      channelDescription: 'Keeps the app alive to receive calls',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(5000),
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

/// Start the foreground service with "Waiting for calls" notification.
Future<void> startForegroundService() async {
  await FlutterForegroundTask.startService(
    serviceId: 100,
    notificationTitle: 'Voice Call',
    notificationText: 'Waiting for calls...',
    callback: _startCallback,
  );
}

/// Update notification text (e.g., when call starts/ends).
Future<void> updateForegroundNotification(String text) async {
  await FlutterForegroundTask.updateService(
    notificationTitle: 'Voice Call',
    notificationText: text,
  );
}

/// Stop the foreground service entirely.
Future<void> stopForegroundService() async {
  await FlutterForegroundTask.stopService();
}

// ── TaskHandler + callback ──────────────────────────────────────

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_CallTaskHandler());
}

class _CallTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}
}
