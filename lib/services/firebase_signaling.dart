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

  /// Firebase subscriptions for call-scoped streams.
  /// Cancelled by [cancelListeners] at call teardown.
  final List<StreamSubscription> _subs = [];

  /// StreamControllers backing call-scoped streams.
  /// Closed by [cancelListeners] so subscribers receive a done event.
  final List<StreamController<dynamic>> _callControllers = [];

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
    final raw = snap.value;
    if (raw is! Map) {
      throw StateError('readOffer: unexpected data at calls/$callId/offer — '
          'expected Map, got ${raw.runtimeType}');
    }
    final data = Map<String, dynamic>.from(raw);
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
  Stream<IceCandidateModel> iceCandidates(String callId, bool fromCaller) {
    final node = fromCaller ? 'offerCandidates' : 'answerCandidates';
    final ctrl = StreamController<IceCandidateModel>.broadcast();
    _callControllers.add(ctrl);
    _subs.add(
      _db.child('calls/$callId/$node').onChildAdded.listen((event) {
        if (ctrl.isClosed) return;
        final raw = event.snapshot.value;
        if (raw is! Map) return; // unexpected data shape — skip silently
        final data = Map<String, dynamic>.from(raw);
        ctrl.add(IceCandidateModel(
          candidate: data['candidate'] as String,
          sdpMid: data['sdpMid'] as String?,
          sdpMLineIndex: data['sdpMLineIndex'] as int?,
        ));
      }),
    );
    return ctrl.stream;
  }

  // ── Call lifecycle ────────────────────────────────────────────────────────

  @override
  Future<void> notifyRemoteUser(String remoteUserId, String callId) async {
    await _db.child('users/$remoteUserId/incomingCall').set(callId);
  }

  @override
  Stream<SessionDescription> answerStream(String callId) {
    final ctrl = StreamController<SessionDescription>.broadcast();
    _callControllers.add(ctrl);
    _subs.add(
      _db.child('calls/$callId/answer').onValue.listen((event) {
        if (ctrl.isClosed) return;
        final data = event.snapshot.value;
        if (data == null) return;
        if (data is! Map) return; // unexpected data shape — skip silently
        final map = Map<String, dynamic>.from(data);
        ctrl.add(SessionDescription(
          sdp: map['sdp'] as String,
          type: map['type'] as String,
        ));
      }),
    );
    return ctrl.stream;
  }

  @override
  Future<void> writeCancelledSignal(String callId) async {
    await _db.child('calls/$callId/cancelled').set(true);
  }

  @override
  Stream<void> callCancelled(String callId) {
    // Not call-scoped via _subs: the ViewModel manages this subscription
    // directly (cancelled on accept or dismiss, like the old StreamSubscription).
    return _db
        .child('calls/$callId/cancelled')
        .onValue
        .where((event) => event.snapshot.value == true)
        .map((_) => null);
  }

  @override
  Stream<String> incomingCall(String userId) {
    // Not call-scoped via _subs: the ViewModel holds this subscription for
    // its entire lifetime (mirrors the old listenForIncomingCall behaviour).
    final ref = _db.child('users/$userId/incomingCall');
    return ref.onValue
        .where((event) => event.snapshot.value is String)
        .asyncMap((event) async {
      final callId = event.snapshot.value as String;
      await ref.remove();
      return callId;
    });
  }

  // ── Busy signal ───────────────────────────────────────────────────────────

  @override
  Future<void> writeBusySignal(String callerId) async {
    await _db.child('users/$callerId/busySignal').set(true);
  }

  @override
  Stream<void> busySignal(String userId) {
    final ctrl = StreamController<void>.broadcast();
    _callControllers.add(ctrl);
    _subs.add(
      _db.child('users/$userId/busySignal').onValue.listen((event) async {
        if (event.snapshot.value != null) {
          await _db.child('users/$userId/busySignal').remove();
          if (!ctrl.isClosed) ctrl.add(null);
        }
      }),
    );
    return ctrl.stream;
  }

  // ── Identity ──────────────────────────────────────────────────────────────

  @override
  Future<String?> lookupUidByEmail(String email) async {
    final encoded = email.replaceAll('.', ',');
    final snap = await _db.child('emailToUid/$encoded').get();
    return snap.exists ? snap.value as String? : null;
  }

  @override
  Future<String?> lookupEmailByUid(String uid) async {
    final snap = await _db.child('userProfiles/$uid/email').get();
    return snap.exists ? snap.value as String? : null;
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  @override
  Future<void> cancelListeners() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();

    for (final ctrl in _callControllers) {
      await ctrl.close();
    }
    _callControllers.clear();
  }
}
