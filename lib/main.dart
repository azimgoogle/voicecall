import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MaterialApp(home: HomeScreen()));
}

// --- Signaling Helper ---

class Signaling {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  final List<StreamSubscription> _subs = [];
  String? _currentCallId;

  final Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'}
    ]
  };

  Future<void> _createPeerConnection() async {
    _pc = await createPeerConnection(_rtcConfig);
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }
  }

  /// Caller: create offer, write to Firebase, listen for answer + ICE
  Future<void> makeCall({
    required String myUserId,
    required String remoteUserId,
    required VoidCallback onCallEnded,
  }) async {
    await _createPeerConnection();
    final callId =
        '${myUserId}_${remoteUserId}_${DateTime.now().millisecondsSinceEpoch}';
    _currentCallId = callId;
    final callRef = _db.child('calls/$callId');

    // Collect ICE candidates
    _pc!.onIceCandidate = (candidate) {
      callRef.child('offerCandidates').push().set({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    // Create and set offer
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    await callRef.set({
      'offer': {'sdp': offer.sdp, 'type': offer.type},
      'status': 'waiting',
      'caller': myUserId,
      'callee': remoteUserId,
    });

    // Notify remote user
    await _db.child('users/$remoteUserId/incomingCall').set(callId);

    // Listen for answer
    _subs.add(callRef.child('answer').onValue.listen((event) async {
      final data = event.snapshot.value;
      if (data != null && _pc != null) {
        final map = Map<String, dynamic>.from(data as Map);
        await _pc!.setRemoteDescription(
          RTCSessionDescription(map['sdp'], map['type']),
        );
      }
    }));

    // Listen for remote ICE candidates
    _subs.add(
        callRef.child('answerCandidates').onChildAdded.listen((event) {
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      _pc?.addCandidate(RTCIceCandidate(
        data['candidate'],
        data['sdpMid'],
        data['sdpMLineIndex'],
      ));
    }));

    // Listen for call ended
    _subs.add(callRef.child('status').onValue.listen((event) {
      if (event.snapshot.value == 'ended') {
        onCallEnded();
      }
    }));
  }

  /// Callee: read offer, create answer, exchange ICE
  Future<void> answerCall({
    required String myUserId,
    required String callId,
    required VoidCallback onCallEnded,
  }) async {
    await _createPeerConnection();
    _currentCallId = callId;
    final callRef = _db.child('calls/$callId');

    // Collect ICE candidates
    _pc!.onIceCandidate = (candidate) {
      callRef.child('answerCandidates').push().set({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    // Read offer
    final offerSnap = await callRef.child('offer').get();
    final offerData = Map<String, dynamic>.from(offerSnap.value as Map);
    await _pc!.setRemoteDescription(
      RTCSessionDescription(offerData['sdp'], offerData['type']),
    );

    // Create and set answer
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    await callRef.child('answer').set({
      'sdp': answer.sdp,
      'type': answer.type,
    });

    // Update status
    await callRef.child('status').set('active');

    // Listen for caller's ICE candidates
    _subs
        .add(callRef.child('offerCandidates').onChildAdded.listen((event) {
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      _pc?.addCandidate(RTCIceCandidate(
        data['candidate'],
        data['sdpMid'],
        data['sdpMLineIndex'],
      ));
    }));

    // Listen for call ended
    _subs.add(callRef.child('status').onValue.listen((event) {
      if (event.snapshot.value == 'ended') {
        onCallEnded();
      }
    }));
  }

  Future<void> endCall() async {
    if (_currentCallId != null) {
      await _db.child('calls/$_currentCallId/status').set('ended');
    }
    await _cleanup();
  }

  Future<void> _cleanup() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    await _pc?.close();
    _pc = null;
    _currentCallId = null;
  }
}

// --- Home Screen ---

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _myUserId = '';
  final _remoteIdController = TextEditingController();
  final _signaling = Signaling();
  StreamSubscription? _incomingCallSub;
  bool _inCall = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await Permission.microphone.request();

    // Generate or retrieve user ID
    final prefs = await SharedPreferences.getInstance();
    var userId = prefs.getString('userId');
    if (userId == null) {
      userId = 'user_${Random().nextInt(99999).toString().padLeft(5, '0')}';
      await prefs.setString('userId', userId);
    }
    setState(() => _myUserId = userId!);

    // Set online presence
    final userRef = FirebaseDatabase.instance.ref('users/$_myUserId');
    await userRef.child('online').set(true);
    userRef.child('online').onDisconnect().set(false);

    // Listen for incoming calls
    _listenForIncomingCalls();
  }

  void _listenForIncomingCalls() {
    final ref =
        FirebaseDatabase.instance.ref('users/$_myUserId/incomingCall');
    _incomingCallSub = ref.onValue.listen((event) async {
      final callId = event.snapshot.value as String?;
      if (callId != null && !_inCall) {
        // Clear the incoming call signal immediately
        await ref.remove();
        // Auto-accept
        _inCall = true;
        await _signaling.answerCall(
          myUserId: _myUserId,
          callId: callId,
          onCallEnded: _onCallEnded,
        );
        if (mounted) setState(() {});
      }
    });
  }

  void _onCallEnded() async {
    await _signaling.endCall();
    _inCall = false;
    if (mounted) setState(() {});
  }

  Future<void> _makeCall() async {
    final remoteId = _remoteIdController.text.trim();
    if (remoteId.isEmpty) return;
    _inCall = true;
    setState(() {});
    await _signaling.makeCall(
      myUserId: _myUserId,
      remoteUserId: remoteId,
      onCallEnded: _onCallEnded,
    );
  }

  Future<void> _endCall() async {
    await _signaling.endCall();
    _inCall = false;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _incomingCallSub?.cancel();
    _signaling.endCall();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_inCall) {
      return Scaffold(
        appBar: AppBar(title: const Text('In Call')),
        body: Center(
          child: ElevatedButton(
            onPressed: _endCall,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
            ),
            child: const Text('End Call', style: TextStyle(fontSize: 20)),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Voice Call POC')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('My ID: $_myUserId',
                style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 32),
            TextField(
              controller: _remoteIdController,
              decoration: const InputDecoration(
                labelText: 'Remote User ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _makeCall,
                child: const Text('Call'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
