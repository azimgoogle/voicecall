import 'package:flutter/services.dart';

class AudioService {
  static const _channel = MethodChannel('com.familycall/audio');

  /// Set AudioManager to MODE_IN_COMMUNICATION, request audio focus,
  /// and start listening for wired headset plug/unplug events.
  /// Automatically routes to earphone if one is already connected.
  static Future<void> startAudioSession() async {
    await _channel.invokeMethod('startAudioSession');
  }

  /// Abandon audio focus, unregister headset receiver,
  /// and reset AudioManager to MODE_NORMAL.
  static Future<void> stopAudioSession() async {
    await _channel.invokeMethod('stopAudioSession');
  }
}
