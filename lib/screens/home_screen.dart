import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

import '../di/service_locator.dart';
import '../services/audio_service.dart';
import '../services/call_log_service.dart';
import '../services/firebase_signaling.dart';
import '../services/foreground_service.dart';
import '../services/settings_service.dart';
import '../services/webrtc_service.dart';
import 'call_logs_screen.dart';
import 'call_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _myUserId = '';
  final _remoteIdController = TextEditingController();
  final _firebase = sl<FirebaseSignaling>();
  final _webrtc = sl<WebRtcService>();
  final _logService = sl<CallLogService>();
  final _settingsService = sl<SettingsService>();
  StreamSubscription? _incomingCallSub;
  StreamSubscription? _statsSub;
  StreamSubscription? _incomingCallCancelSub;
  Timer? _incomingCallTimeoutTimer;
  bool _inCall = false;
  bool _isCallerRole = false;

  // Non-null when a non-whitelisted call is waiting for the user to answer.
  String? _incomingCallId;
  String? _incomingCallerId;

  String _selectedTurnServer = 'both';

  // Key used to call notifyRemoteDisconnected() on the active CallScreen.
  final _callScreenKey = GlobalKey<CallScreenState>();

  // Connection timeout — fires 30 s after _makeCall if the call never connects.
  Timer? _callTimeoutTimer;
  bool _callConnected = false;

  static const String _lastRemoteIdKey = 'last_remote_id';
  static const String _callVolumeKey = 'call_volume';
  static const String _callMuteKey = 'call_mute';

  // Per-call volume (0.0–1.0). Persisted across calls, never touches system volume.
  double _callVolume = 1.0;
  bool _callMuted = false;

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
    final savedVolume = prefs.getDouble(_callVolumeKey) ?? 1.0;
    final savedMute = prefs.getBool(_callMuteKey) ?? false;
    setState(() {
      _myUserId = userId;
      _remoteIdController.text = lastRemoteId;
      _callVolume = savedVolume;
      _callMuted = savedMute;
    });

    _listenForIncomingCalls();
    await startForegroundService();
    FlutterForegroundTask.addTaskDataCallback(_onForegroundData);
  }

  /// Receives data forwarded from the foreground TaskHandler.
  /// Handles the notification "End Call" button (both caller and callee)
  /// and the "Mute / Unmute" button (caller only).
  /// The button ID carries the desired target state, so we set explicitly
  /// rather than toggling — prevents drift from rapid taps or async timing.
  void _onForegroundData(Object data) {
    if (!_inCall) return;
    if (data == 'end_call') {
      _endCall();
    } else if (data == 'mute' && _isCallerRole) {
      _applyMute(true);
    } else if (data == 'unmute' && _isCallerRole) {
      _applyMute(false);
    }
  }

  /// Single source of truth for all mute state changes (notification button,
  /// in-app button). Sets WebRTC volume, syncs CallScreen UI, persists
  /// preference, and refreshes the notification button label.
  Future<void> _applyMute(bool muted) async {
    if (_callMuted == muted) return;
    setState(() => _callMuted = muted);
    _callScreenKey.currentState?.setMuted(muted);
    await _webrtc.setRemoteVolume(muted ? 0.0 : _callVolume);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_callMuteKey, muted);
    await updateForegroundNotification(
      'In call...',
      showEndCall: true,
      showMute: true,
      isMuted: muted,
    );
  }

  void _listenForIncomingCalls() {
    _incomingCallSub = _firebase.listenForIncomingCall(
      _myUserId,
      (callId) async {
        final callerId = callId.split('_').first;

        if (_inCall) {
          await _firebase.writeBusySignal(callerId);
          return;
        }

        // If a non-whitelisted call is already pending, report busy to the new caller.
        if (_incomingCallId != null) {
          await _firebase.writeBusySignal(callerId);
          return;
        }

        final autoAnswer = await _settingsService.isAutoAnswer(callerId);
        if (autoAnswer) {
          _inCall = true;
          _isCallerRole = false;
          await _answerCall(callId);
          if (mounted) setState(() {});
        } else {
          if (mounted) {
            setState(() {
              _incomingCallId = callId;
              _incomingCallerId = callerId;
            });
          }
          // Watch for the caller cancelling before the user answers.
          _incomingCallCancelSub = _firebase.listenForCallCancelled(
              callId, _onIncomingCallCancelled);
          // Safety-net: auto-dismiss after 40 s if the cancellation signal
          // never arrives (e.g. caller crashed before writing it).
          _incomingCallTimeoutTimer =
              Timer(const Duration(seconds: 40), _onIncomingCallCancelled);
        }
      },
    );
  }

  /// Fired when the caller cancels before the user answers,
  /// or when the callee-side 40 s safety timeout fires.
  void _onIncomingCallCancelled() {
    _incomingCallTimeoutTimer?.cancel();
    _incomingCallTimeoutTimer = null;
    _incomingCallCancelSub?.cancel();
    _incomingCallCancelSub = null;
    if (mounted) {
      setState(() {
        _incomingCallId = null;
        _incomingCallerId = null;
      });
    }
  }

  /// Accept a pending incoming call from the Answer button.
  Future<void> _acceptIncomingCall() async {
    final callId = _incomingCallId!;
    _incomingCallTimeoutTimer?.cancel();
    _incomingCallTimeoutTimer = null;
    _incomingCallCancelSub?.cancel();
    _incomingCallCancelSub = null;
    setState(() {
      _incomingCallId = null;
      _incomingCallerId = null;
      _inCall = true;
      _isCallerRole = false;
    });
    await _answerCall(callId);
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

    final callId = _firebase.generateCallId(_myUserId, remoteId);

    // Create the log entry BEFORE setState so callStartedAt is non-null
    // when CallScreen first renders and the timer starts immediately.
    _currentLogEntry = CallLogEntry(
      callId: callId,
      role: 'caller',
      remoteUserId: remoteId,
      turnServer: _selectedTurnServer,
      startedAt: DateTime.now(),
    );

    // Always start each call unmuted regardless of the previous call's state.
    _callMuted = false;
    await prefs.setBool(_callMuteKey, false);

    _inCall = true;
    _isCallerRole = true;
    setState(() {});

    // Notify CallScreen when the remote side drops (WebRTC layer).
    _webrtc.onConnectionLost = _onRemoteDisconnected;

    await _webrtc.init(isCaller: true, turnServer: _selectedTurnServer);
    await _webrtc.setRemoteVolume(_callVolume); // apply saved level; fires when track arrives
    await AudioService.startAudioSession();
    await AudioService.acquireProximityWakeLock();

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
    await updateForegroundNotification(
      'In call...',
      showEndCall: true,
      showMute: true,
      isMuted: _callMuted,
    );

    // Start connection timeout — if callee doesn't answer in 30 s, hang up.
    _callConnected = false;
    _callTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (_inCall && !_callConnected) _onCallTimeout();
    });

    // Cancel timeout when WebRTC connection is established.
    _webrtc.onConnectionEstablished = () {
      _callConnected = true;
      _callTimeoutTimer?.cancel();
      _callTimeoutTimer = null;
    };

    // Listen for busy signal from callee
    _firebase.listenForBusySignal(_myUserId, _onCalleeBusy);

    // Listen for answer
    _firebase.listenForAnswer(callId, (answerData) {
      _webrtc.setRemoteDescription(answerData['sdp'], answerData['type']);
    });

    // Listen for remote ICE candidates (from callee)
    _firebase.listenForIceCandidates(callId, false, (data) {
      _webrtc.addIceCandidate(
          data['candidate'], data['sdpMid'], data['sdpMLineIndex']);
    });
  }

  /// Callee: read offer → create answer → exchange ICE
  Future<void> _answerCall(String callId) async {
    _webrtc.onConnectionLost = _onCallEnded;
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
    await updateForegroundNotification('In call...', showEndCall: true);

    // Listen for remote ICE candidates (from caller)
    _firebase.listenForIceCandidates(callId, true, (data) {
      _webrtc.addIceCandidate(
          data['candidate'], data['sdpMid'], data['sdpMLineIndex']);
    });
  }

  /// Fired when the callee writes a busy signal — they're already in a call.
  void _onCalleeBusy() {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_remoteIdController.text.trim()} is busy.'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 3),
        ),
      );
    }
    _endCall();
  }

  /// Fired when the 30-second connection timeout expires without a connection.
  void _onCallTimeout() {
    if (!_inCall) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No answer. Call ended.'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
    }
    _endCall();
  }

  /// Fired by WebRTC (onConnectionLost) when the remote peer drops.
  /// Shows the banner on CallScreen, then ends the call after its 2 s delay.
  void _onRemoteDisconnected() {
    _callScreenKey.currentState?.notifyRemoteDisconnected();
    // The banner waits 2 s before calling onRemoteDisconnected → _endCall.
    // If the key is stale (screen already gone), end immediately.
    if (_callScreenKey.currentState == null) {
      _endCall();
    }
  }

  void _onCallEnded() async {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    _callConnected = false;
    _incomingCallTimeoutTimer?.cancel();
    _incomingCallTimeoutTimer = null;
    _incomingCallCancelSub?.cancel();
    _incomingCallCancelSub = null;
    await _finaliseLog();
    await _firebase.cancelListeners();
    await _webrtc.close();
    if (_isCallerRole) {
      await AudioService.releaseProximityWakeLock();
      await AudioService.stopAudioSession();
    }
    _inCall = false;
    _isCallerRole = false;
    _incomingCallId = null;
    _incomingCallerId = null;
    await updateForegroundNotification('Waiting for calls...');
    if (mounted) setState(() {});
  }

  Future<void> _endCall() async {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    _callConnected = false;
    // Capture callId BEFORE _finaliseLog nulls out _currentLogEntry.
    final callId = _currentLogEntry?.callId;
    await _finaliseLog();
    // Signal callee to dismiss its answer screen if it hasn't answered yet.
    if (callId != null) await _firebase.writeCancelledSignal(callId);
    await _firebase.cancelListeners();
    await _webrtc.close();
    await AudioService.releaseProximityWakeLock();
    await AudioService.stopAudioSession();
    _inCall = false;
    _isCallerRole = false;
    _incomingCallId = null;
    _incomingCallerId = null;
    await updateForegroundNotification('Waiting for calls...');
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _callTimeoutTimer?.cancel();
    _incomingCallTimeoutTimer?.cancel();
    _incomingCallSub?.cancel();
    _statsSub?.cancel();
    _incomingCallCancelSub?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onForegroundData);
    _firebase.cancelListeners();
    _webrtc.close();
    super.dispose();
  }

  Widget _buildIncomingCallScreen() {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.phone_in_talk, size: 80, color: Colors.green),
            const SizedBox(height: 24),
            const Text('Incoming call from',
                style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 8),
            Text(
              _incomingCallerId ?? '',
              style: const TextStyle(
                  fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 48),
            ElevatedButton.icon(
              onPressed: _acceptIncomingCall,
              icon: const Icon(Icons.phone),
              label: const Text('Answer',
                  style: TextStyle(fontSize: 18)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 48, vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_inCall) {
      return CallScreen(
        key: _callScreenKey,
        isCaller: _isCallerRole,
        onEndCall: _endCall,
        statsStream: _webrtc.statsStream,
        initialVolume: _callVolume,
        initialMuted: _callMuted,
        callStartedAt: _currentLogEntry?.startedAt,
        onRemoteDisconnected: _isCallerRole ? _endCall : null,
        onVolumeChanged: (v) async {
          setState(() => _callVolume = v);
          await _webrtc.setRemoteVolume(v);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setDouble(_callVolumeKey, v);
        },
        onMuteToggled: (muted) => _applyMute(muted),
      );
    }

    if (_incomingCallId != null) {
      return _buildIncomingCallScreen();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Call POC'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
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
            const SizedBox(height: 16),
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
                onPressed: _remoteIdController.text.trim().isNotEmpty
                    ? _makeCall
                    : null,
                child: const Text('Call'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
