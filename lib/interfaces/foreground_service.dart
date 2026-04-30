/// Port for the Android foreground service that keeps the process alive.
///
/// Implementations drive the persistent notification and its action buttons.
/// Swap the concrete in [setupServiceLocator] to change notification behaviour
/// without touching any business logic.
abstract class ForegroundService {
  /// Start the foreground service with an idle "Waiting for calls…" notification.
  Future<void> start();

  /// Update the notification text and optional action buttons.
  ///
  /// [showEndCall] adds an End Call button (caller and callee).
  /// [showMute] adds a Mute/Unmute toggle button (caller only).
  /// [isMuted] controls the label: `true` → "Unmute", `false` → "Mute".
  Future<void> updateNotification(
    String text, {
    bool showEndCall = false,
    bool showMute = false,
    bool isMuted = false,
  });

  /// Stop the foreground service entirely.
  Future<void> stop();
}
