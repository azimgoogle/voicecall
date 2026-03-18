/// Sealed hierarchy representing every possible call state in the app.
///
/// The UI switches exhaustively on this type — adding a new state forces
/// every switch arm to handle it at compile time, preventing silent gaps.
sealed class CallState {
  const CallState();
}

/// No call in progress; the app is idle and listening for incoming calls.
final class Idle extends CallState {
  const Idle();
}

/// A non-whitelisted remote user is calling; waiting for the user to tap Answer.
final class IncomingCall extends CallState {
  final String callId;
  final String callerId;
  const IncomingCall({required this.callId, required this.callerId});
}

/// An active call — either we placed it ([isCaller] = true) or we answered it.
///
/// Holds all per-call UI data (volume, mute, start time) so the screen
/// can render purely from state — no extra fields needed in the widget.
final class ActiveCall extends CallState {
  final bool isCaller;
  final String remoteUserId;
  final String callId;
  final DateTime startedAt;
  final String turnServer;
  final double volume;
  final bool muted;

  const ActiveCall({
    required this.isCaller,
    required this.remoteUserId,
    required this.callId,
    required this.startedAt,
    this.turnServer = 'both',
    this.volume = 1.0,
    this.muted = false,
  });

  ActiveCall copyWith({double? volume, bool? muted}) => ActiveCall(
        isCaller: isCaller,
        remoteUserId: remoteUserId,
        callId: callId,
        startedAt: startedAt,
        turnServer: turnServer,
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
      );
}
