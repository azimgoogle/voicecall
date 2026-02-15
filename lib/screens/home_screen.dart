import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/firebase_signaling.dart';
import '../services/webrtc_service.dart';
import 'call_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _myUserId = '';
  final _remoteIdController = TextEditingController();
  final _firebase = FirebaseSignaling();
  final _webrtc = WebRtcService();
  StreamSubscription? _incomingCallSub;
  bool _inCall = false;
  bool _isCallerRole = false;
  String? _currentCallId;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await Permission.microphone.request();

    final prefs = await SharedPreferences.getInstance();
    var userId = prefs.getString('userId');
    if (userId == null) {
      userId = 'user_${Random().nextInt(99999).toString().padLeft(5, '0')}';
      await prefs.setString('userId', userId);
    }
    setState(() => _myUserId = userId!);

    await _firebase.setUserOnline(_myUserId);
    _listenForIncomingCalls();
  }

  void _listenForIncomingCalls() {
    _incomingCallSub = _firebase.listenForIncomingCall(
      _myUserId,
      (callId) async {
        if (_inCall) return;
        _inCall = true;
        _isCallerRole = false;
        _currentCallId = callId;
        await _answerCall(callId);
        if (mounted) setState(() {});
      },
    );
  }

  /// Caller: create offer → Firebase → listen for answer + ICE
  Future<void> _makeCall() async {
    final remoteId = _remoteIdController.text.trim();
    if (remoteId.isEmpty) return;

    _inCall = true;
    _isCallerRole = true;
    setState(() {});

    await _webrtc.init();
    final callId = _firebase.generateCallId(_myUserId, remoteId);
    _currentCallId = callId;

    // Send local ICE candidates to Firebase
    _webrtc.onIceCandidate = (candidate) {
      _firebase.writeIceCandidate(
          callId: callId, isCaller: true, candidate: candidate);
    };

    // Create and write offer
    final offer = await _webrtc.createOffer();
    await _firebase.writeOffer(
      callId: callId,
      offer: offer,
      caller: _myUserId,
      callee: remoteId,
    );
    await _firebase.notifyRemoteUser(remoteId, callId);

    // Listen for answer
    _firebase.listenForAnswer(callId, (answerData) {
      _webrtc.setRemoteDescription(answerData['sdp'], answerData['type']);
    });

    // Listen for remote ICE candidates (from callee)
    _firebase.listenForIceCandidates(callId, false, (data) {
      _webrtc.addIceCandidate(
          data['candidate'], data['sdpMid'], data['sdpMLineIndex']);
    });

    // Listen for call ended
    _firebase.listenForStatus(callId, 'ended', _onCallEnded);
  }

  /// Callee: read offer → create answer → exchange ICE
  Future<void> _answerCall(String callId) async {
    await _webrtc.init();

    // Send local ICE candidates to Firebase
    _webrtc.onIceCandidate = (candidate) {
      _firebase.writeIceCandidate(
          callId: callId, isCaller: false, candidate: candidate);
    };

    // Read offer and set remote description
    final offerData = await _firebase.readOffer(callId);
    await _webrtc.setRemoteDescription(offerData['sdp'], offerData['type']);

    // Create and write answer
    final answer = await _webrtc.createAnswer();
    await _firebase.writeAnswer(callId: callId, answer: answer);
    await _firebase.setStatus(callId, 'active');

    // Listen for remote ICE candidates (from caller)
    _firebase.listenForIceCandidates(callId, true, (data) {
      _webrtc.addIceCandidate(
          data['candidate'], data['sdpMid'], data['sdpMLineIndex']);
    });

    // Listen for call ended
    _firebase.listenForStatus(callId, 'ended', _onCallEnded);
  }

  void _onCallEnded() async {
    // Local cleanup only — no Firebase status write.
    // Caller already wrote "ended"; callee just cleans up.
    await _firebase.cancelListeners();
    await _webrtc.close();
    _inCall = false;
    _isCallerRole = false;
    _currentCallId = null;
    if (mounted) setState(() {});
  }

  Future<void> _endCall() async {
    if (_currentCallId != null) {
      await _firebase.setStatus(_currentCallId!, 'ended');
    }
    await _firebase.cancelListeners();
    await _webrtc.close();
    _inCall = false;
    _isCallerRole = false;
    _currentCallId = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _incomingCallSub?.cancel();
    if (_isCallerRole && _currentCallId != null) {
      _firebase.setStatus(_currentCallId!, 'ended');
    }
    _firebase.cancelListeners();
    _webrtc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_inCall) {
      return CallScreen(isCaller: _isCallerRole, onEndCall: _endCall);
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
