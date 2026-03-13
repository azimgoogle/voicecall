import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class FirebaseSignaling {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final List<StreamSubscription> _subs = [];

  StreamSubscription? _connectedSub;

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

  /// Set user online and keep them online across reconnects.
  ///
  /// Listens to `/.info/connected`. Every time Firebase reconnects (including
  /// the initial connection and after any network interruption) it:
  ///   1. Re-registers the onDisconnect guard (cleared on each disconnect).
  ///   2. Writes online:true so the presence badge on other devices updates.
  ///
  /// This is the standard Firebase presence pattern — without it the user
  /// stays offline:false after regaining network because the onDisconnect
  /// handler fires once and is never re-registered.
  Future<void> setUserOnline(String userId) async {
    _connectedSub?.cancel();

    _connectedSub = _db.child('.info/connected').onValue.listen((event) {
      final connected = event.snapshot.value == true;
      if (!connected) return; // wait for the reconnect event

      final ref = _db.child('users/$userId');
      // Must re-register onDisconnect on every new connection — the server
      // discards the previous handler when the socket closes.
      ref.onDisconnect().update({'online': false, 'onCall': false});
      ref.update({'online': true});
    });
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

  /// Cancel all active Firebase listeners, including the presence watcher.
  Future<void> cancelListeners() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _connectedSub?.cancel();
    _connectedSub = null;
  }
}
