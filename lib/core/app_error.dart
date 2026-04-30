/// Sealed hierarchy of domain errors that can surface in this app.
///
/// Each subclass maps to a distinct failure category so callers can
/// pattern-match and respond appropriately without inspecting strings.
sealed class AppError {
  const AppError();
}

/// A Firebase Realtime Database / signaling operation failed.
///
/// Typical causes: network unavailable, RTDB permission denied,
/// stale call record already consumed.
final class SignalingError extends AppError {
  final Object cause;
  const SignalingError(this.cause);

  @override
  String toString() => 'SignalingError($cause)';
}

/// A WebRTC peer-connection operation failed.
///
/// Typical causes: ICE failure, SDP negotiation error,
/// TURN credential fetch timeout, media device unavailable.
final class ConnectionError extends AppError {
  final Object cause;
  const ConnectionError(this.cause);

  @override
  String toString() => 'ConnectionError($cause)';
}

/// An audio-session or proximity-wake-lock operation failed.
///
/// Typical causes: audio focus denied, MethodChannel exception
/// from the platform plugin.
final class AudioError extends AppError {
  final Object cause;
  const AudioError(this.cause);

  @override
  String toString() => 'AudioError($cause)';
}
