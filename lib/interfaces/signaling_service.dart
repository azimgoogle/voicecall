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
    required String callerHandle,
  });

  /// Reads the caller's handle stored in the call record.
  /// Returns null if not present (legacy calls before this field was added).
  Future<String?> readCallerHandle(String callId);

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

  /// Stream of ICE candidates from the remote peer.
  ///
  /// [fromCaller] true → reads offerCandidates; false → answerCandidates.
  /// The stream is call-scoped and is closed by [cancelListeners].
  Stream<IceCandidateModel> iceCandidates(String callId, bool fromCaller);

  // ── Call lifecycle ────────────────────────────────────────────────────────

  /// Notify the remote user of an incoming call.
  Future<void> notifyRemoteUser(String remoteUserId, String callId);

  /// Stream that emits the callee's answer [SessionDescription] once written.
  ///
  /// The stream is call-scoped and is closed by [cancelListeners].
  Stream<SessionDescription> answerStream(String callId);

  /// Write a cancellation signal when the caller hangs up before answer.
  Future<void> writeCancelledSignal(String callId);

  /// Stream that emits once when a cancellation signal is detected.
  ///
  /// The caller manages the subscription lifetime directly (returned
  /// subscription is cancelled by the ViewModel on accept or dismiss).
  Stream<void> callCancelled(String callId);

  /// Stream that emits an incoming call ID each time a new call arrives.
  ///
  /// The implementation clears the incoming-call node after each emit to
  /// prevent re-delivery. The ViewModel manages the subscription lifetime
  /// (persists for the ViewModel's lifetime; not cancelled by [cancelListeners]).
  Stream<String> incomingCall(String userId);

  // ── Busy signal ───────────────────────────────────────────────────────────

  Future<void> writeBusySignal(String callerId);

  /// Stream that emits once when a busy signal is detected for [userId].
  ///
  /// The implementation clears the busy-signal node after each emit.
  /// The stream is call-scoped and is closed by [cancelListeners].
  Stream<void> busySignal(String userId);

  // ── Identity ──────────────────────────────────────────────────────────────

  /// Resolves [handle] to a Firebase UID via the identity index.
  /// Returns null if the handle is not registered.
  Future<String?> lookupUidByHandle(String handle);

  /// Resolves [uid] to a display handle via the identity index.
  /// Returns null if the profile has not been written yet.
  Future<String?> lookupHandleByUid(String uid);

  // ── Cleanup ───────────────────────────────────────────────────────────────

  /// Cancel all active call-scoped Firebase listeners and close their streams.
  ///
  /// Does NOT cancel the [incomingCall] or [callCancelled] subscriptions —
  /// those are managed directly by the ViewModel.
  Future<void> cancelListeners();
}
