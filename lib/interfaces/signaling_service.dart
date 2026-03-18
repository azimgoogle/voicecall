import 'dart:async';

import '../models/ice_candidate_model.dart';
import '../models/session_description.dart';

/// Abstract signaling layer.
///
/// Implementations may use Firebase RTDB, plain WebSockets, HTTP long-polling,
/// or any other transport — callers are fully decoupled from the wire format.
abstract class SignalingService {
  // ── Call ID ───────────────────────────────────────────────────────────────

  /// Generate a unique call ID for a caller → callee session.
  String generateCallId(String callerId, String calleeId);

  // ── Offer / Answer ────────────────────────────────────────────────────────

  Future<void> writeOffer({
    required String callId,
    required SessionDescription offer,
    required String caller,
    required String callee,
  });

  Future<SessionDescription> readOffer(String callId);

  Future<void> writeAnswer({
    required String callId,
    required SessionDescription answer,
  });

  // ── ICE candidates ────────────────────────────────────────────────────────

  Future<void> writeIceCandidate({
    required String callId,
    required bool isCaller,
    required IceCandidateModel candidate,
  });

  /// Listen for ICE candidates from the remote peer.
  /// [fromCaller] true → read offerCandidates; false → answerCandidates.
  void listenForIceCandidates(
    String callId,
    bool fromCaller,
    void Function(IceCandidateModel candidate) callback,
  );

  // ── Call lifecycle ────────────────────────────────────────────────────────

  /// Notify the remote user of an incoming call.
  Future<void> notifyRemoteUser(String remoteUserId, String callId);

  /// Listen for the callee's answer SDP.
  void listenForAnswer(
    String callId,
    void Function(SessionDescription answer) callback,
  );

  /// Write a cancellation signal when the caller hangs up before answer.
  Future<void> writeCancelledSignal(String callId);

  /// Listen for a cancellation signal.
  /// Returns the subscription so the callee can cancel it on accept.
  StreamSubscription<dynamic> listenForCallCancelled(
    String callId,
    void Function() callback,
  );

  /// Listen for an incoming call notification.
  /// Returns the subscription for external lifecycle management.
  StreamSubscription<dynamic> listenForIncomingCall(
    String userId,
    void Function(String callId) callback,
  );

  // ── Busy signal ───────────────────────────────────────────────────────────

  Future<void> writeBusySignal(String callerId);

  void listenForBusySignal(String userId, void Function() callback);

  // ── Identity ──────────────────────────────────────────────────────────────

  /// Returns true if [userId] already exists in the backend.
  Future<bool> isUserIdTaken(String userId);

  // ── Cleanup ───────────────────────────────────────────────────────────────

  Future<void> cancelListeners();
}
