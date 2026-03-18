/// Port for audio-session and proximity-sensor management.
///
/// Implementations talk to the Android AudioManager (via MethodChannel).
/// Swap the concrete in [setupServiceLocator] to change platform behaviour
/// without touching any business logic.
abstract class AudioService {
  /// Set AudioManager to MODE_IN_COMMUNICATION, request audio focus,
  /// and begin listening for wired-headset plug/unplug events.
  Future<void> startAudioSession();

  /// Abandon audio focus, unregister the headset receiver,
  /// and reset AudioManager to MODE_NORMAL.
  Future<void> stopAudioSession();

  /// Acquire PROXIMITY_SCREEN_OFF_WAKE_LOCK so the screen turns off
  /// when the phone is held to the ear.
  Future<void> acquireProximityWakeLock();

  /// Release the proximity wake lock and restore default audio routing.
  Future<void> releaseProximityWakeLock();
}
