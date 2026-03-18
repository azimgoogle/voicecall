import 'package:flutter/services.dart';

import '../interfaces/audio_service.dart';

/// Android implementation of [AudioService] that talks to the platform via
/// the `com.familycall/audio` MethodChannel.
class PlatformAudioService implements AudioService {
  static const _channel = MethodChannel('com.familycall/audio');

  /// Set AudioManager to MODE_IN_COMMUNICATION, request audio focus,
  /// and start listening for wired headset plug/unplug events.
  /// Automatically routes to earphone if one is already connected.
  @override
  Future<void> startAudioSession() async {
    await _channel.invokeMethod('startAudioSession');
  }

  /// Abandon audio focus, unregister headset receiver,
  /// and reset AudioManager to MODE_NORMAL.
  @override
  Future<void> stopAudioSession() async {
    await _channel.invokeMethod('stopAudioSession');
  }

  /// Acquire PROXIMITY_SCREEN_OFF_WAKE_LOCK so the screen turns off
  /// when the phone is held to the ear. Also registers a proximity
  /// sensor listener to route audio to earpiece when near / speaker when far.
  @override
  Future<void> acquireProximityWakeLock() async {
    await _channel.invokeMethod('acquireProximityWakeLock');
  }

  /// Release the proximity wake lock and restore audio routing.
  @override
  Future<void> releaseProximityWakeLock() async {
    await _channel.invokeMethod('releaseProximityWakeLock');
  }
}
