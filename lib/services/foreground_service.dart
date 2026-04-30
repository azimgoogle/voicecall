import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../interfaces/foreground_service.dart';

/// Notification title reflects the build mode so testers can instantly tell
/// which build is running. Resolved at compile time — zero runtime cost.
const _kNotificationTitle = kDebugMode ? '(Dev) Nest Call' : 'Nest Call';

/// Initialize foreground task configuration. Call once in main().
void initForegroundService() {
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'nest_call_service',
      channelName: 'Nest Call Service',
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
    notificationTitle: _kNotificationTitle,
    notificationText: 'Waiting for calls...',
    // 'ic_notification' matches the <meta-data android:name="ic_notification">
    // entry in the ForegroundService declaration in AndroidManifest.xml.
    // The plugin resolves the resource ID from that meta-data at runtime,
    // giving us a monochrome @drawable/ic_notification in the status bar.
    callback: _startCallback,
  );
}

/// Update notification text and action buttons.
/// [showEndCall] adds an End Call button (caller and callee).
/// [showMute] adds a Mute/Unmute toggle button (caller only).
/// [isMuted] controls the label: true → "Unmute", false → "Mute".
Future<void> updateForegroundNotification(
  String text, {
  bool showEndCall = false,
  bool showMute = false,
  bool isMuted = false,
}) async {
  await FlutterForegroundTask.updateService(
    notificationTitle: _kNotificationTitle,
    notificationText: text,
    notificationButtons: [
      if (showMute)
        NotificationButton(
          id: isMuted ? 'unmute' : 'mute',
          text: isMuted ? 'Unmute' : 'Mute',
        ),
      if (showEndCall)
        NotificationButton(id: 'end_call', text: 'End Call'),
    ],
  );
}

/// Stop the foreground service entirely.
Future<void> stopForegroundService() async {
  await FlutterForegroundTask.stopService();
}

// ── ForegroundService implementation ─────────────────────────────────────────

/// Concrete [ForegroundService] implementation backed by [FlutterForegroundTask].
///
/// Register as a singleton in the DI container so use-cases and view-models
/// can depend on the [ForegroundService] interface without knowing the plugin.
class ForegroundServiceImpl implements ForegroundService {
  @override
  Future<void> start() => startForegroundService();

  @override
  Future<void> updateNotification(
    String text, {
    bool showEndCall = false,
    bool showMute = false,
    bool isMuted = false,
  }) =>
      updateForegroundNotification(
        text,
        showEndCall: showEndCall,
        showMute: showMute,
        isMuted: isMuted,
      );

  @override
  Future<void> stop() => stopForegroundService();
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
  void onNotificationButtonPressed(String id) {
    // Forward button ID to the main isolate so HomeScreen can react.
    FlutterForegroundTask.sendDataToMain(id);
  }

  @override
  void onNotificationPressed() {}
}
