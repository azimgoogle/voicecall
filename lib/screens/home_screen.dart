import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/call_log_service.dart';
import '../services/firebase_signaling.dart';
import '../services/foreground_service.dart';
import '../services/webrtc_service.dart';
import 'call_logs_screen.dart';
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
  final _logService = CallLogService();
  StreamSubscription? _incomingCallSub;
  StreamSubscription? _statsSub;
  bool _inCall = false;
  bool _isCallerRole = false;
  String? _currentCallId;
  String _selectedTurnServer = 'both';

  static const String _lastRemoteIdKey = 'last_remote_id';

  // Call log tracking
  CallLogEntry? _currentLogEntry;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await Permission.microphone.request();

    // userId is guaranteed to exist — set by OnboardingScreen on first launch
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('userId')!;
    final lastRemoteId = prefs.getString(_lastRemoteIdKey) ?? '';
    setState(() {
      _myUserId = userId;
      _remoteIdController.text = lastRemoteId;
    });

    await _firebase.setUserOnline(_myUserId);
    _listenForIncomingCalls();
    await startForegroundService();
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

  /// Start tracking stats into the current log entry (caller only).
  void _startStatsTracking() {
    _statsSub = _webrtc.statsStream.listen((stats) {
      if (_currentLogEntry == null) return;
      _currentLogEntry = _currentLogEntry!.copyWith(
        bytesSent: stats['bytesSent'] as int? ?? 0,
        bytesReceived: stats['bytesReceived'] as int? ?? 0,
      );
    });
  }

  /// Finalise and persist the current log entry.
  Future<void> _finaliseLog() async {
    if (_currentLogEntry == null) return;
    final turnUsed = await _webrtc.resolveActualTurnUsed();
    final finalEntry = _currentLogEntry!.copyWith(
      endedAt: DateTime.now(),
      turnUsed: turnUsed,
    );
    await _logService.saveEntry(finalEntry);
    _currentLogEntry = null;
    _statsSub?.cancel();
    _statsSub = null;
  }

  /// Caller: create offer → Firebase → listen for answer + ICE
  Future<void> _makeCall() async {
    final remoteId = _remoteIdController.text.trim();
    if (remoteId.isEmpty) return;

    // Persist so it auto-populates next time
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastRemoteIdKey, remoteId);

    _inCall = true;
    _isCallerRole = true;
    setState(() {});

    await _webrtc.init(isCaller: true, turnServer: _selectedTurnServer);
    final callId = _firebase.generateCallId(_myUserId, remoteId);
    _currentCallId = callId;

    // Start a log entry for this outgoing call
    _currentLogEntry = CallLogEntry(
      callId: callId,
      role: 'caller',
      remoteUserId: remoteId,
      turnServer: _selectedTurnServer,
      startedAt: DateTime.now(),
    );
    await _logService.saveEntry(_currentLogEntry!);
    _startStatsTracking();

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
    await updateForegroundNotification('In call...');

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
    await _webrtc.init(isCaller: false);

    // Derive remote user ID from callId format: {callerId}_{calleeId}_{ts}
    final parts = callId.split('_');
    final remoteUserId = parts.length >= 2 ? parts[0] : callId;

    // Start a log entry for this incoming call (callee — no TURN selection)
    _currentLogEntry = CallLogEntry(
      callId: callId,
      role: 'callee',
      remoteUserId: remoteUserId,
      turnServer: 'both',
      startedAt: DateTime.now(),
    );
    await _logService.saveEntry(_currentLogEntry!);

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
    await updateForegroundNotification('In call...');

    // Listen for remote ICE candidates (from caller)
    _firebase.listenForIceCandidates(callId, true, (data) {
      _webrtc.addIceCandidate(
          data['candidate'], data['sdpMid'], data['sdpMLineIndex']);
    });

    // Listen for call ended
    _firebase.listenForStatus(callId, 'ended', _onCallEnded);
  }

  void _onCallEnded() async {
    await _finaliseLog();
    // Local cleanup only — no Firebase status write.
    // Caller already wrote "ended"; callee just cleans up.
    await _firebase.cancelListeners();
    await _webrtc.close();
    _inCall = false;
    _isCallerRole = false;
    _currentCallId = null;
    await updateForegroundNotification('Waiting for calls...');
    if (mounted) setState(() {});
  }

  Future<void> _endCall() async {
    await _finaliseLog();
    if (_currentCallId != null) {
      await _firebase.setStatus(_currentCallId!, 'ended');
    }
    await _firebase.cancelListeners();
    await _webrtc.close();
    _inCall = false;
    _isCallerRole = false;
    _currentCallId = null;
    await updateForegroundNotification('Waiting for calls...');
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _incomingCallSub?.cancel();
    _statsSub?.cancel();
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
      return CallScreen(
        isCaller: _isCallerRole,
        onEndCall: _endCall,
        statsStream: _webrtc.statsStream,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Call POC'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Call Logs',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const CallLogsScreen()),
            ),
          ),
        ],
      ),
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
            const SizedBox(height: 24),
            const Text('TURN Server',
                style: TextStyle(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'metered',
                  label: Text('Metered'),
                  icon: Icon(Icons.cloud),
                ),
                ButtonSegment(
                  value: 'both',
                  label: Text('Both'),
                  icon: Icon(Icons.merge_type),
                ),
                ButtonSegment(
                  value: 'expressturn',
                  label: Text('ExpressTURN'),
                  icon: Icon(Icons.swap_horiz),
                ),
              ],
              selected: {_selectedTurnServer},
              onSelectionChanged: (selection) {
                setState(() => _selectedTurnServer = selection.first);
              },
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
