import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class FirebaseSignaling {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final List<StreamSubscription> _subs = [];

  /// Generate a call ID from caller, callee, and current timestamp.
  String generateCallId(String callerId, String calleeId) {
    return '${callerId}_${calleeId}_${DateTime.now().millisecondsSinceEpoch}';
  }

  /// Write offer + metadata to /calls/{callId}/
  Future<void> writeOffer({
    required String callId,
    required RTCSessionDescription offer,
    required String caller,
    required String callee,
  }) async {
    await _db.child('calls/$callId').set({
      'offer': {'sdp': offer.sdp, 'type': offer.type},
      'caller': caller,
      'callee': callee,
    });
  }

  /// Read offer from /calls/{callId}/offer
  Future<Map<String, dynamic>> readOffer(String callId) async {
    final snap = await _db.child('calls/$callId/offer').get();
    return Map<String, dynamic>.from(snap.value as Map);
  }

  /// Write answer to /calls/{callId}/answer
  Future<void> writeAnswer({
    required String callId,
    required RTCSessionDescription answer,
  }) async {
    await _db.child('calls/$callId/answer').set({
      'sdp': answer.sdp,
      'type': answer.type,
    });
  }

  /// Push an ICE candidate under offerCandidates or answerCandidates.
  /// [isCaller] determines which node to write to.
  Future<void> writeIceCandidate({
    required String callId,
    required bool isCaller,
    required RTCIceCandidate candidate,
  }) async {
    final node = isCaller ? 'offerCandidates' : 'answerCandidates';
    await _db.child('calls/$callId/$node').push().set({
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    });
  }

  /// Notify remote user of incoming call.
  Future<void> notifyRemoteUser(String remoteUserId, String callId) async {
    await _db.child('users/$remoteUserId/incomingCall').set(callId);
  }

  /// Listen for answer on /calls/{callId}/answer.
  void listenForAnswer(
      String callId, void Function(Map<String, dynamic> answer) callback) {
    _subs.add(_db.child('calls/$callId/answer').onValue.listen((event) {
      final data = event.snapshot.value;
      if (data != null) {
        callback(Map<String, dynamic>.from(data as Map));
      }
    }));
  }

  /// Listen for remote ICE candidates.
  /// [fromCaller] true = listen to offerCandidates, false = answerCandidates.
  void listenForIceCandidates(
      String callId,
      bool fromCaller,
      void Function(Map<String, dynamic> candidate) callback) {
    final node = fromCaller ? 'offerCandidates' : 'answerCandidates';
    _subs.add(_db.child('calls/$callId/$node').onChildAdded.listen((event) {
      callback(Map<String, dynamic>.from(event.snapshot.value as Map));
    }));
  }

  /// Check if a userId already exists in the database (ever been registered).
  /// Returns true if the node at /users/{userId} exists, false otherwise.
  Future<bool> isUserIdTaken(String userId) async {
    final snap = await _db.child('users/$userId').get();
    return snap.exists;
  }

  /// Write a busy signal to the caller's user node.
  /// Called by the callee when it receives an incoming call but is already in a call.
  Future<void> writeBusySignal(String callerId) async {
    await _db.child('users/$callerId/busySignal').set(true);
  }

  /// Listen for a busy signal on the caller's own node.
  /// Fires once when the callee writes the signal, then clears it.
  void listenForBusySignal(String userId, void Function() callback) {
    _subs.add(_db.child('users/$userId/busySignal').onValue.listen((event) async {
      if (event.snapshot.value != null) {
        await _db.child('users/$userId/busySignal').remove();
        callback();
      }
    }));
  }

  /// Write a cancellation signal so a waiting callee can dismiss its answer screen.
  Future<void> writeCancelledSignal(String callId) async {
    await _db.child('calls/$callId/cancelled').set(true);
  }

  /// Listen for a cancellation on /calls/{callId}/cancelled.
  /// Returns the subscription so the caller can manage its lifecycle independently
  /// (it must NOT be in _subs — the callee cancels it manually on answer).
  StreamSubscription listenForCallCancelled(
      String callId, void Function() callback) {
    return _db.child('calls/$callId/cancelled').onValue.listen((event) {
      if (event.snapshot.value == true) {
        callback();
      }
    });
  }

  /// Listen for incoming calls on /users/{userId}/incomingCall.
  StreamSubscription listenForIncomingCall(
      String userId, void Function(String callId) callback) {
    final ref = _db.child('users/$userId/incomingCall');
    return ref.onValue.listen((event) async {
      final callId = event.snapshot.value as String?;
      if (callId != null) {
        await ref.remove();
        callback(callId);
      }
    });
  }

  /// Cancel all active Firebase listeners.
  Future<void> cancelListeners() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }
}
