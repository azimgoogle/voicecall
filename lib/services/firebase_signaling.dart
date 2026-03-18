import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import '../interfaces/signaling_service.dart';
import '../models/ice_candidate_model.dart';
import '../models/session_description.dart';

/// Firebase Realtime Database implementation of [SignalingService].
///
/// All WebRTC-specific types are gone — this class only knows about
/// [SessionDescription] and [IceCandidateModel] from the domain layer,
/// so it can be swapped for a WebSocket or HTTP implementation without
/// touching any other file.
class FirebaseSignaling implements SignalingService {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final List<StreamSubscription> _subs = [];

  // ── Call ID ───────────────────────────────────────────────────────────────

  @override
  String generateCallId(String callerId, String calleeId) =>
      '${callerId}_${calleeId}_${DateTime.now().millisecondsSinceEpoch}';

  // ── Offer / Answer ────────────────────────────────────────────────────────

  @override
  Future<void> writeOffer({
    required String callId,
    required SessionDescription offer,
    required String caller,
    required String callee,
  }) async {
    await _db.child('calls/$callId').set({
      'offer': {'sdp': offer.sdp, 'type': offer.type},
      'caller': caller,
      'callee': callee,
    });
  }

  @override
  Future<SessionDescription> readOffer(String callId) async {
    final snap = await _db.child('calls/$callId/offer').get();
    final data = Map<String, dynamic>.from(snap.value as Map);
    return SessionDescription(
      sdp: data['sdp'] as String,
      type: data['type'] as String,
    );
  }

  @override
  Future<void> writeAnswer({
    required String callId,
    required SessionDescription answer,
  }) async {
    await _db.child('calls/$callId/answer').set({
      'sdp': answer.sdp,
      'type': answer.type,
    });
  }

  // ── ICE candidates ────────────────────────────────────────────────────────

  @override
  Future<void> writeIceCandidate({
    required String callId,
    required bool isCaller,
    required IceCandidateModel candidate,
  }) async {
    final node = isCaller ? 'offerCandidates' : 'answerCandidates';
    await _db.child('calls/$callId/$node').push().set({
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    });
  }

  @override
  void listenForIceCandidates(
    String callId,
    bool fromCaller,
    void Function(IceCandidateModel candidate) callback,
  ) {
    final node = fromCaller ? 'offerCandidates' : 'answerCandidates';
    _subs.add(_db.child('calls/$callId/$node').onChildAdded.listen((event) {
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      callback(IceCandidateModel(
        candidate: data['candidate'] as String,
        sdpMid: data['sdpMid'] as String?,
        sdpMLineIndex: data['sdpMLineIndex'] as int?,
      ));
    }));
  }

  // ── Call lifecycle ────────────────────────────────────────────────────────

  @override
  Future<void> notifyRemoteUser(String remoteUserId, String callId) async {
    await _db.child('users/$remoteUserId/incomingCall').set(callId);
  }

  @override
  void listenForAnswer(
    String callId,
    void Function(SessionDescription answer) callback,
  ) {
    _subs.add(_db.child('calls/$callId/answer').onValue.listen((event) {
      final data = event.snapshot.value;
      if (data != null) {
        final map = Map<String, dynamic>.from(data as Map);
        callback(SessionDescription(
          sdp: map['sdp'] as String,
          type: map['type'] as String,
        ));
      }
    }));
  }

  @override
  Future<void> writeCancelledSignal(String callId) async {
    await _db.child('calls/$callId/cancelled').set(true);
  }

  @override
  StreamSubscription<dynamic> listenForCallCancelled(
    String callId,
    void Function() callback,
  ) {
    return _db.child('calls/$callId/cancelled').onValue.listen((event) {
      if (event.snapshot.value == true) {
        callback();
      }
    });
  }

  @override
  StreamSubscription<dynamic> listenForIncomingCall(
    String userId,
    void Function(String callId) callback,
  ) {
    final ref = _db.child('users/$userId/incomingCall');
    return ref.onValue.listen((event) async {
      final callId = event.snapshot.value as String?;
      if (callId != null) {
        await ref.remove();
        callback(callId);
      }
    });
  }

  // ── Busy signal ───────────────────────────────────────────────────────────

  @override
  Future<void> writeBusySignal(String callerId) async {
    await _db.child('users/$callerId/busySignal').set(true);
  }

  @override
  void listenForBusySignal(String userId, void Function() callback) {
    _subs.add(
        _db.child('users/$userId/busySignal').onValue.listen((event) async {
      if (event.snapshot.value != null) {
        await _db.child('users/$userId/busySignal').remove();
        callback();
      }
    }));
  }

  // ── Identity ──────────────────────────────────────────────────────────────

  @override
  Future<bool> isUserIdTaken(String userId) async {
    final snap = await _db.child('users/$userId').get();
    return snap.exists;
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  @override
  Future<void> cancelListeners() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }
}
