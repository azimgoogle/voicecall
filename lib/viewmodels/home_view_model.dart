import 'dart:async';

import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../interfaces/call_log_repository.dart';
import '../interfaces/peer_connection_service.dart';
import '../interfaces/settings_repository.dart';
import '../interfaces/signaling_service.dart';
import '../models/call_log_entry.dart';
import '../models/call_state.dart';
import '../services/audio_service.dart';
import '../services/foreground_service.dart';

/// One-shot UI events emitted by [HomeViewModel].
///
/// These are side-effects that require Scaffold context (snackbars, banners)
/// and therefore cannot live in the [CallState] stream.
enum HomeEvent {
  /// The callee was already in a call; caller sees a "busy" snackbar.
  calleeBusy,

  /// WebRTC never reached connected state within 30 s; caller is notified.
  callTimeout,

  /// The remote side dropped the connection; caller's screen shows a banner.
  remoteDisconnected,
}

/// Orchestrates the entire call lifecycle for [HomeScreen].
///
/// The screen owns no call logic — it observes [stateStream] and [events],
/// and forwards user actions to the public methods below.
class HomeViewModel {
  final SignalingService _signaling;
  final PeerConnectionService _peerConnection;
  final CallLogRepository _logRepository;
  final SettingsRepository _settings;

  HomeViewModel({
    required SignalingService signaling,
    required PeerConnectionService peerConnection,
    required CallLogRepository logRepository,
    required SettingsRepository settings,
  })  : _signaling = signaling,
        _peerConnection = peerConnection,
        _logRepository = logRepository,
        _settings = settings;

  // ── State / event streams ─────────────────────────────────────────────────

  final _stateController = StreamController<CallState>.broadcast();
  final _eventsController = StreamController<HomeEvent>.broadcast();

  CallState _state = const Idle();

  /// Current state — safe to read synchronously for [StreamBuilder.initialData].
  CallState get state => _state;

  /// Emits the latest [CallState] on every transition.
  Stream<CallState> get stateStream => _stateController.stream;

  /// One-shot UI events (snackbars, banners). Subscribe once in initState.
  Stream<HomeEvent> get events => _eventsController.stream;

  /// Live WebRTC stats forwarded directly from [PeerConnectionService].
  Stream<Map<String, dynamic>> get statsStream => _peerConnection.statsStream;

  // ── Private state ─────────────────────────────────────────────────────────

  String _userId = '';
  double _defaultVolume = 1.0;

  CallLogEntry? _currentLogEntry;

  StreamSubscription? _incomingCallSub;
  StreamSubscription? _incomingCallCancelSub;
  StreamSubscription? _statsSub;
  Timer? _incomingCallTimeoutTimer;
  Timer? _callTimeoutTimer;
  bool _callConnected = false;

  static const String _lastRemoteIdKey = 'last_remote_id';
  static const String _callVolumeKey = 'call_volume';
  static const String _callMuteKey = 'call_mute';

  // ── Public API ────────────────────────────────────────────────────────────

  /// Must be called once after construction. Requests mic permission,
  /// loads persisted prefs, starts the incoming-call listener, and
  /// starts the foreground service.
  Future<void> init(String userId) async {
    await Permission.microphone.request();
    _userId = userId;

    final prefs = await SharedPreferences.getInstance();
    _defaultVolume = prefs.getDouble(_callVolumeKey) ?? 1.0;

    _listenForIncomingCalls();
    await startForegroundService();
  }

  /// Returns the last-dialled remote ID from SharedPreferences.
  Future<String> loadLastRemoteId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastRemoteIdKey) ?? '';
  }

  /// Initiates an outgoing call to [remoteId] using [turnServer].
  Future<void> makeCall(String remoteId, String turnServer) async {
    if (remoteId.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastRemoteIdKey, remoteId);

    final callId = _signaling.generateCallId(_userId, remoteId);

    // Always reset mute at the start of a new call.
    await prefs.setBool(_callMuteKey, false);

    _currentLogEntry = CallLogEntry(
      callId: callId,
      role: 'caller',
      remoteUserId: remoteId,
      turnServer: turnServer,
      startedAt: DateTime.now(),
    );

    _emit(ActiveCall(
      isCaller: true,
      remoteUserId: remoteId,
      callId: callId,
      startedAt: _currentLogEntry!.startedAt,
      turnServer: turnServer,
      volume: _defaultVolume,
      muted: false,
    ));

    _peerConnection.onConnectionLost = _onCallerConnectionLost;
    _peerConnection.onConnectionEstablished = () {
      _callConnected = true;
      _callTimeoutTimer?.cancel();
      _callTimeoutTimer = null;
    };

    await _peerConnection.init(isCaller: true, turnServer: turnServer);
    await _peerConnection.setRemoteVolume(_defaultVolume);
    await AudioService.startAudioSession();
    await AudioService.acquireProximityWakeLock();

    await _logRepository.saveEntry(_currentLogEntry!);
    _startStatsTracking();

    _peerConnection.onIceCandidate = (candidate) {
      _signaling.writeIceCandidate(
          callId: callId, isCaller: true, candidate: candidate);
    };

    final offer = await _peerConnection.createOffer();
    await _signaling.writeOffer(
        callId: callId, offer: offer, caller: _userId, callee: remoteId);
    await _signaling.notifyRemoteUser(remoteId, callId);
    await updateForegroundNotification(
      'In call...',
      showEndCall: true,
      showMute: true,
      isMuted: false,
    );

    _callConnected = false;
    _callTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (_state is ActiveCall && !_callConnected) _onCallTimeout();
    });

    _signaling.listenForBusySignal(_userId, _onCalleeBusy);
    _signaling.listenForAnswer(callId, (answer) {
      _peerConnection.setRemoteDescription(answer);
    });
    _signaling.listenForIceCandidates(callId, false, (candidate) {
      _peerConnection.addIceCandidate(candidate);
    });
  }

  /// Answers an incoming call identified by [callId].
  Future<void> answerCall(String callId) async {
    _peerConnection.onConnectionLost = _onCallEnded;
    await _peerConnection.init(isCaller: false);

    final parts = callId.split('_');
    final remoteUserId = parts.length >= 2 ? parts[0] : callId;

    _currentLogEntry = CallLogEntry(
      callId: callId,
      role: 'callee',
      remoteUserId: remoteUserId,
      turnServer: 'both',
      startedAt: DateTime.now(),
    );

    _emit(ActiveCall(
      isCaller: false,
      remoteUserId: remoteUserId,
      callId: callId,
      startedAt: _currentLogEntry!.startedAt,
      turnServer: 'both',
    ));

    await _logRepository.saveEntry(_currentLogEntry!);

    _peerConnection.onIceCandidate = (candidate) {
      _signaling.writeIceCandidate(
          callId: callId, isCaller: false, candidate: candidate);
    };

    final offer = await _signaling.readOffer(callId);
    await _peerConnection.setRemoteDescription(offer);

    final answer = await _peerConnection.createAnswer();
    await _signaling.writeAnswer(callId: callId, answer: answer);
    await updateForegroundNotification('In call...', showEndCall: true);

    _signaling.listenForIceCandidates(callId, true, (candidate) {
      _peerConnection.addIceCandidate(candidate);
    });
  }

  /// Accepts a pending [IncomingCall] — cancels the timeout then answers.
  Future<void> acceptIncomingCall(String callId) async {
    _incomingCallTimeoutTimer?.cancel();
    _incomingCallTimeoutTimer = null;
    _incomingCallCancelSub?.cancel();
    _incomingCallCancelSub = null;
    await answerCall(callId);
  }

  /// Explicitly ends the active call (user or notification button).
  Future<void> endCall() async {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    _callConnected = false;

    final callId = _currentLogEntry?.callId;
    await _finaliseLog();
    if (callId != null) await _signaling.writeCancelledSignal(callId);
    await _signaling.cancelListeners();
    await _peerConnection.close();
    await AudioService.releaseProximityWakeLock();
    await AudioService.stopAudioSession();
    await updateForegroundNotification('Waiting for calls...');
    _emit(const Idle());
  }

  /// Mutes or unmutes by setting WebRTC volume to 0 / saved level.
  Future<void> applyMute(bool muted) async {
    final current = _state;
    if (current is! ActiveCall || current.muted == muted) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_callMuteKey, muted);
    await _peerConnection.setRemoteVolume(muted ? 0.0 : current.volume);
    await updateForegroundNotification(
      'In call...',
      showEndCall: true,
      showMute: true,
      isMuted: muted,
    );
    _emit(current.copyWith(muted: muted));
  }

  /// Adjusts the per-call WebRTC volume. Persisted across calls.
  Future<void> setVolume(double volume) async {
    final current = _state;
    if (current is! ActiveCall) return;

    _defaultVolume = volume;
    await _peerConnection.setRemoteVolume(volume);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_callVolumeKey, volume);
    _emit(current.copyWith(volume: volume));
  }

  /// Release all resources. Call from [State.dispose].
  void dispose() {
    _callTimeoutTimer?.cancel();
    _incomingCallTimeoutTimer?.cancel();
    _incomingCallSub?.cancel();
    _statsSub?.cancel();
    _incomingCallCancelSub?.cancel();
    _signaling.cancelListeners();
    _peerConnection.close();
    _stateController.close();
    _eventsController.close();
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _emit(CallState newState) {
    _state = newState;
    if (!_stateController.isClosed) _stateController.add(newState);
  }

  void _emitEvent(HomeEvent event) {
    if (!_eventsController.isClosed) _eventsController.add(event);
  }

  /// Subscribes to the incoming-call channel. Called once in [init].
  /// The returned subscription persists for the ViewModel's lifetime —
  /// [SignalingService.cancelListeners] does NOT cancel it.
  void _listenForIncomingCalls() {
    _incomingCallSub?.cancel();
    _incomingCallSub = _signaling.listenForIncomingCall(
      _userId,
      (callId) async {
        final callerId = callId.split('_').first;

        if (_state is ActiveCall || _state is IncomingCall) {
          await _signaling.writeBusySignal(callerId);
          return;
        }

        final autoAnswer = await _settings.isAutoAnswer(callerId);
        if (autoAnswer) {
          await answerCall(callId);
        } else {
          _emit(IncomingCall(callId: callId, callerId: callerId));
          _incomingCallCancelSub = _signaling.listenForCallCancelled(
              callId, _onIncomingCallCancelled);
          _incomingCallTimeoutTimer =
              Timer(const Duration(seconds: 40), _onIncomingCallCancelled);
        }
      },
    );
  }

  void _onIncomingCallCancelled() {
    _incomingCallTimeoutTimer?.cancel();
    _incomingCallTimeoutTimer = null;
    _incomingCallCancelSub?.cancel();
    _incomingCallCancelSub = null;
    _emit(const Idle());
  }

  void _onCalleeBusy() {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    _emitEvent(HomeEvent.calleeBusy);
    endCall();
  }

  void _onCallTimeout() {
    if (_state is! ActiveCall) return;
    _emitEvent(HomeEvent.callTimeout);
    endCall();
  }

  /// Caller-side connection lost: emit event so the screen can show the banner,
  /// then the screen calls [endCall] after the 2-second display window.
  void _onCallerConnectionLost() {
    _emitEvent(HomeEvent.remoteDisconnected);
  }

  /// Callee-side connection lost: end the call immediately with no banner.
  void _onCallEnded() {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    _callConnected = false;
    _incomingCallTimeoutTimer?.cancel();
    _incomingCallTimeoutTimer = null;
    _incomingCallCancelSub?.cancel();
    _incomingCallCancelSub = null;

    _finaliseLog().then((_) async {
      await _signaling.cancelListeners();
      await _peerConnection.close();
      await updateForegroundNotification('Waiting for calls...');
      _emit(const Idle());
    });
  }

  void _startStatsTracking() {
    _statsSub?.cancel();
    _statsSub = _peerConnection.statsStream.listen((stats) {
      if (_currentLogEntry == null) return;
      _currentLogEntry = _currentLogEntry!.copyWith(
        bytesSent: stats['bytesSent'] as int? ?? 0,
        bytesReceived: stats['bytesReceived'] as int? ?? 0,
      );
    });
  }

  Future<void> _finaliseLog() async {
    if (_currentLogEntry == null) return;
    final turnUsed = await _peerConnection.resolveActualTurnUsed();
    final finalEntry = _currentLogEntry!.copyWith(
      endedAt: DateTime.now(),
      turnUsed: turnUsed,
    );
    await _logRepository.saveEntry(finalEntry);
    _currentLogEntry = null;
    _statsSub?.cancel();
    _statsSub = null;
  }
}
