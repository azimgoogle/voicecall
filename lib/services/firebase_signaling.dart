import 'dart:async';
import 'dart:ui' show VoidCallback;
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
  /// Also registers onDisconnect to set status→"ended" so a crash on the
  /// caller's side auto-terminates the call in Firebase.
  Future<void> writeOffer({
    required String callId,
    required RTCSessionDescription offer,
    required String caller,
    required String callee,
  }) async {
    await _db.child('calls/$callId').set({
      'offer': {'sdp': offer.sdp, 'type': offer.type},
      'status': 'waiting',
      'caller': caller,
      'callee': callee,
    });
    // If the caller disconnects (crash / network loss), Firebase server
    // will automatically flip status to "ended" so the callee can clean up.
    _db.child('calls/$callId/status').onDisconnect().set('ended');
  }

  /// Read offer from /calls/{callId}/offer
  Future<Map<String, dynamic>> readOffer(String callId) async {
    final snap = await _db.child('calls/$callId/offer').get();
    return Map<String, dynamic>.from(snap.value as Map);
  }

  /// Write answer to /calls/{callId}/answer
  /// Also registers onDisconnect to set status→"ended" so a crash on the
  /// callee's side auto-terminates the call in Firebase, notifying the caller.
  Future<void> writeAnswer({
    required String callId,
    required RTCSessionDescription answer,
  }) async {
    await _db.child('calls/$callId/answer').set({
      'sdp': answer.sdp,
      'type': answer.type,
    });
    // Mirror of what writeOffer does for the caller side.
    _db.child('calls/$callId/status').onDisconnect().set('ended');
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

  /// Set call status (waiting / active / ended).
  Future<void> setStatus(String callId, String status) async {
    await _db.child('calls/$callId/status').set(status);
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

  /// Listen for call status becoming [targetStatus].
  void listenForStatus(
      String callId, String targetStatus, VoidCallback callback) {
    _subs.add(_db.child('calls/$callId/status').onValue.listen((event) {
      if (event.snapshot.value == targetStatus) {
        callback();
      }
    }));
  }

  /// Check if a userId already exists in the database (ever been registered).
  /// Returns true if the node at /users/{userId} exists, false otherwise.
  Future<bool> isUserIdTaken(String userId) async {
    final snap = await _db.child('users/$userId').get();
    return snap.exists;
  }

  /// Set user online with auto-disconnect.
  /// Also pre-registers onDisconnect to clear onCall so that a crash while
  /// in a call doesn't leave the user permanently stuck in "busy" state.
  Future<void> setUserOnline(String userId) async {
    final ref = _db.child('users/$userId');
    // Clear both fields atomically on disconnect (crash / network loss).
    ref.onDisconnect().update({'online': false, 'onCall': false});
    await ref.update({'online': true});
  }

  /// Mark the local user as currently on a call (or not).
  /// Re-registers the onDisconnect guard each time so it always reflects
  /// the latest state even after multiple calls in one session.
  Future<void> setUserOnCall(String userId, bool onCall) async {
    final ref = _db.child('users/$userId');
    // Keep the disconnect handler current.
    ref.onDisconnect().update({'online': false, 'onCall': false});
    await ref.child('onCall').set(onCall);
  }

  /// Returns true if the remote user is currently in a call.
  Future<bool> isUserBusy(String userId) async {
    final snap = await _db.child('users/$userId/onCall').get();
    return snap.value == true;
  }

  /// Stream the live presence of a remote user.
  /// Emits a map with keys: 'online' (bool) and 'onCall' (bool).
  /// Cancel the returned subscription when the caller no longer needs it.
  StreamSubscription listenForUserStatus(
      String userId, void Function(bool online, bool onCall) callback) {
    return _db.child('users/$userId').onValue.listen((event) {
      final data = event.snapshot.value;
      if (data == null) {
        callback(false, false);
        return;
      }
      final map = Map<String, dynamic>.from(data as Map);
      final online = map['online'] == true;
      final onCall = map['onCall'] == true;
      callback(online, onCall);
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
