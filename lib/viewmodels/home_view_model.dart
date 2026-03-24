import 'dart:async';

import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_error.dart';
import '../core/result.dart';
import '../interfaces/analytics_repository.dart';
import '../interfaces/audio_service.dart';
import '../interfaces/call_log_repository.dart';
import '../interfaces/crash_reporter.dart';
import '../interfaces/foreground_service.dart';
import '../interfaces/peer_connection_service.dart';
import '../interfaces/remote_config_repository.dart';
import '../interfaces/settings_repository.dart';
import '../interfaces/signaling_service.dart';
import '../models/call_log_entry.dart';
import '../models/call_state.dart';
import '../usecases/answer_call_usecase.dart';
import '../usecases/end_call_usecase.dart';
import '../usecases/make_call_usecase.dart';

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

  /// A use-case failed to set up or tear down a call; show an error snackbar.
  callSetupFailed,

  /// Microphone permission was not granted; user needs to enable it in Settings.
  microphonePermissionDenied,

  /// The user has consumed their 100-minute weekly call allowance.
  weeklyLimitReached,
}

/// Orchestrates the entire call lifecycle for [HomeScreen].
///
/// The screen owns no call logic — it observes [stateStream] and [events],
/// and forwards user actions to the public methods below.
///
/// Use-cases ([MakeCallUseCase], [AnswerCallUseCase], [EndCallUseCase]) handle
/// all I/O and protocol work; the ViewModel manages state transitions, timers,
/// and one-shot UI events.
///
/// All async event APIs use Streams — no mutable callback properties are set
/// on the underlying services. The ViewModel subscribes to the relevant streams
/// after each use-case succeeds and cancels subscriptions on call teardown.
class HomeViewModel {
  final SignalingService _signaling;
  final PeerConnectionService _peerConnection;
  final CallLogRepository _logRepository;
  final SettingsRepository _settings;
  final ForegroundService _foreground;
  final CrashReporter _crashReporter;
  final AnalyticsRepository _analytics;
  final RemoteConfigRepository _remoteConfig;

  late final MakeCallUseCase _makeCall;
  late final AnswerCallUseCase _answerCall;
  late final EndCallUseCase _endCall;

  HomeViewModel({
    required SignalingService signaling,
    required PeerConnectionService peerConnection,
    required CallLogRepository logRepository,
    required SettingsRepository settings,
    required AudioService audioService,
    required ForegroundService foregroundService,
    required CrashReporter crashReporter,
    required AnalyticsRepository analytics,
    required RemoteConfigRepository remoteConfig,
  })  : _signaling = signaling,
        _peerConnection = peerConnection,
        _logRepository = logRepository,
        _settings = settings,
        _foreground = foregroundService,
        _crashReporter = crashReporter,
        _analytics = analytics,
        _remoteConfig = remoteConfig {
    _makeCall = MakeCallUseCase(
      signaling: signaling,
      peerConnection: peerConnection,
      logRepository: logRepository,
      audioService: audioService,
      foregroundService: foregroundService,
      crashReporter: crashReporter,
    );
    _answerCall = AnswerCallUseCase(
      signaling: signaling,
      peerConnection: peerConnection,
      logRepository: logRepository,
      foregroundService: foregroundService,
      crashReporter: crashReporter,
    );
    _endCall = EndCallUseCase(
      signaling: signaling,
      peerConnection: peerConnection,
      logRepository: logRepository,
      audioService: audioService,
      foregroundService: foregroundService,
    );
  }

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

  /// Subscription to the ViewModel-lifetime incoming-call stream.
  StreamSubscription? _incomingCallSub;

  /// Subscription to the caller-cancellation stream (IncomingCall state only).
  StreamSubscription? _incomingCallCancelSub;

  /// Subscription to the live stats stream (ActiveCall state, caller only).
  StreamSubscription? _statsSub;

  /// Subscriptions to per-call connection-event streams from [PeerConnectionService].
  StreamSubscription? _connectionLostSub;
  StreamSubscription? _connectionEstablishedSub;

  /// Subscription to the busy-signal stream (ActiveCall state, caller only).
  StreamSubscription? _busySignalSub;

  Timer? _incomingCallTimeoutTimer;
  Timer? _callTimeoutTimer;
  bool _callConnected = false;

  /// Set before calling [endCall] from internal paths so [endCall] can attach
  /// the correct [end_reason] to the [call_ended] analytics event.
  /// Defaults to 'user_ended' if not set.
  String? _pendingEndReason;

  static const String _callVolumeKey = 'call_volume';

  // ── Public API ────────────────────────────────────────────────────────────

  /// Must be called once after construction. Requests mic permission,
  /// loads persisted prefs, starts the incoming-call listener, and
  /// starts the foreground service.
  Future<void> init(String userId) async {
    await Permission.microphone.request();
    _userId = userId;
    await _crashReporter.setUserIdentifier(userId);
    unawaited(_analytics.setUserId(userId));

    final prefs = await SharedPreferences.getInstance();
    _defaultVolume = prefs.getDouble(_callVolumeKey) ?? 1.0;

    _listenForIncomingCalls();
    await _foreground.start();
  }

  /// Returns the current weekly call limit from Remote Config.
  /// 0 means no limit is enforced.
  int getWeeklyLimitMinutes() => _remoteConfig.getWeeklyCallLimitMinutes();

  /// Returns the last-dialled remote ID from SharedPreferences.
  Future<String> loadLastRemoteId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('last_remote_id') ?? '';
  }

  /// Returns the total call minutes used in the current ISO week (Mon–Sun).
  ///
  /// Loads call logs and sums durations for entries whose [startedAt] falls
  /// on or after the most recent Monday at midnight.
  Future<int> getWeeklyUsedMinutes() async {
    final now = DateTime.now();
    final weekStart = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    final logs = await _logRepository.loadLogs();
    final totalSeconds = logs
        .where((e) => e.role == 'caller' && !e.startedAt.isBefore(weekStart))
        .fold<int>(0, (sum, e) => sum + e.duration.inSeconds);
    return totalSeconds ~/ 60;
  }

  /// Initiates an outgoing call to [remoteEmail] using [turnServer].
  ///
  /// [remoteEmail] is the recipient's email address. It is resolved to a
  /// Firebase UID via the /emailToUid RTDB index before the call is set up.
  /// Emits [HomeEvent.callSetupFailed] if the email is not found.
  ///
  /// Delegates all I/O to [MakeCallUseCase]; then subscribes to the
  /// per-call connection-event streams exposed by [PeerConnectionService].
  /// Emits [HomeEvent.callSetupFailed] and resets to [Idle] on [Err].
  Future<void> makeCall(String remoteEmail, String turnServer) async {
    if (remoteEmail.isEmpty) return;

    if (!(await Permission.microphone.status).isGranted) {
      _emitEvent(HomeEvent.microphonePermissionDenied);
      return;
    }

    // Resolve email → UID. Emit failure immediately if not registered.
    final remoteId = await _signaling.lookupUidByEmail(remoteEmail);
    if (remoteId == null) {
      _emitEvent(HomeEvent.callSetupFailed);
      return;
    }

    final weeklyLimit = _remoteConfig.getWeeklyCallLimitMinutes();
    if (weeklyLimit > 0 && await getWeeklyUsedMinutes() >= weeklyLimit) {
      _emitEvent(HomeEvent.weeklyLimitReached);
      return;
    }

    _crashReporter.setCustomKey('role', 'caller');
    _crashReporter.setCustomKey('turn_server_selected', turnServer);
    unawaited(_analytics.logEvent('call_initiated', parameters: {
      'turn_server_selected': turnServer,
      'remote_id': remoteId,
    }));

    final result = await _makeCall.execute(
      callerId: _userId,
      remoteId: remoteId,
      turnServer: turnServer,
      initialVolume: _defaultVolume,
    );

    switch (result) {
      case Ok(:final value):
        _currentLogEntry = value;

        // Subscribe to per-call connection events now that init() has run.
        _connectionEstablishedSub =
            _peerConnection.connectionEstablished.listen((_) {
          _callConnected = true;
          _callTimeoutTimer?.cancel();
          _callTimeoutTimer = null;
          if (_currentLogEntry != null) {
            final ms = DateTime.now()
                .difference(_currentLogEntry!.startedAt)
                .inMilliseconds;
            unawaited(_analytics.logEvent('call_connected', parameters: {
              'time_to_connect_ms': ms,
              'role': 'caller',
              'turn_server_selected': _currentLogEntry!.turnServer,
            }));
          }
        });
        _connectionLostSub = _peerConnection.connectionLost.listen((_) {
          _onCallerConnectionLost();
        });

        // Subscribe to busy signal from the callee side.
        _busySignalSub =
            _signaling.busySignal(_userId).listen((_) => _onCalleeBusy());

        _emit(ActiveCall(
          isCaller: true,
          remoteUserId: remoteEmail,
          callId: value.callId,
          startedAt: value.startedAt,
          turnServer: turnServer,
          volume: _defaultVolume,
          muted: false,
        ));
        _startStatsTracking();
        _callConnected = false;
        _callTimeoutTimer = Timer(const Duration(seconds: 30), () {
          if (_state is ActiveCall && !_callConnected) _onCallTimeout();
        });

      case Err(:final error):
        _crashReporter.recordError(error, null, reason: 'makeCall');
        unawaited(_analytics.logEvent('call_failed', parameters: {
          'error_type': switch (error) {
            SignalingError() => 'signaling',
            ConnectionError() => 'connection',
            AudioError() => 'audio',
          },
        }));
        _emitEvent(HomeEvent.callSetupFailed);
        _emit(const Idle());
    }
  }

  /// Answers an incoming call identified by [callId].
  ///
  /// Delegates all I/O to [AnswerCallUseCase]; then subscribes to the
  /// per-call connectionLost stream. Resets to [Idle] silently on [Err].
  Future<void> answerCall(String callId) async {
    if (!(await Permission.microphone.status).isGranted) {
      _emitEvent(HomeEvent.microphonePermissionDenied);
      return;
    }

    final weeklyLimit = _remoteConfig.getWeeklyCallLimitMinutes();
    if (weeklyLimit > 0 && await getWeeklyUsedMinutes() >= weeklyLimit) {
      _emitEvent(HomeEvent.weeklyLimitReached);
      return;
    }

    _crashReporter.setCustomKey('role', 'callee');

    final result = await _answerCall.execute(callId: callId);

    switch (result) {
      case Ok(:final value):
        _currentLogEntry = value;

        // Subscribe to connection-lost events now that init() has run.
        _connectionLostSub = _peerConnection.connectionLost.listen((_) {
          _onCallEnded();
        });

        final parts = callId.split('_');
        final remoteUserId = parts.length >= 2 ? parts[0] : callId;
        _emit(ActiveCall(
          isCaller: false,
          remoteUserId: remoteUserId,
          callId: callId,
          startedAt: _currentLogEntry!.startedAt,
          turnServer: 'both',
        ));

      case Err(:final error):
        _crashReporter.recordError(error, null, reason: 'answerCall');
        unawaited(_analytics.logEvent('call_failed', parameters: {
          'error_type': switch (error) {
            SignalingError() => 'signaling',
            ConnectionError() => 'connection',
            AudioError() => 'audio',
          },
        }));
        _emitEvent(HomeEvent.callSetupFailed);
        _emit(const Idle());
    }
  }

  /// Accepts a pending [IncomingCall] — cancels the timeout then answers.
  Future<void> acceptIncomingCall(String callId) async {
    unawaited(_analytics.logEvent('incoming_call_answered'));
    _incomingCallTimeoutTimer?.cancel();
    _incomingCallTimeoutTimer = null;
    _incomingCallCancelSub?.cancel();
    _incomingCallCancelSub = null;
    await answerCall(callId);
  }

  /// Explicitly ends the active call (user tap or notification button).
  ///
  /// Cancels all call-scoped subscriptions, delegates teardown to
  /// [EndCallUseCase], and always emits [Idle] even on [Err].
  Future<void> endCall() async {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    _callConnected = false;

    _connectionLostSub?.cancel();
    _connectionLostSub = null;
    _connectionEstablishedSub?.cancel();
    _connectionEstablishedSub = null;
    _busySignalSub?.cancel();
    _busySignalSub = null;

    _statsSub?.cancel();
    _statsSub = null;
    final entry = _currentLogEntry;
    _currentLogEntry = null;

    final endReason = _pendingEndReason ?? 'user_ended';
    _pendingEndReason = null;

    // Ignore Err: teardown failures don't require user action; Idle is
    // the correct next state regardless.
    await _endCall.execute(
      currentEntry: entry,
      writeCancelled: true,
      releaseAudio: true,
    );

    if (entry != null) {
      unawaited(_analytics.logEvent('call_ended', parameters: {
        'duration_s':
            DateTime.now().difference(entry.startedAt).inSeconds,
        'role': entry.role,
        'turn_server_selected': entry.turnServer,
        'bytes_sent': entry.bytesSent,
        'bytes_received': entry.bytesReceived,
        'end_reason': endReason,
      }));
    }
    _emit(const Idle());
  }

  /// Mutes or unmutes by setting WebRTC volume to 0 / saved level.
  Future<void> applyMute(bool muted) async {
    final current = _state;
    if (current is! ActiveCall || current.muted == muted) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('call_mute', muted);
    await _peerConnection.setRemoteVolume(muted ? 0.0 : current.volume);
    await _foreground.updateNotification(
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
    _incomingCallCancelSub?.cancel();
    _statsSub?.cancel();
    _connectionLostSub?.cancel();
    _connectionEstablishedSub?.cancel();
    _busySignalSub?.cancel();
    _signaling.cancelListeners();
    _peerConnection.close();
    _stateController.close();
    _eventsController.close();
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _emit(CallState newState) {
    _crashReporter.log('callState → ${newState.runtimeType}');
    _crashReporter.setCustomKey('call_state', newState.runtimeType.toString());
    _state = newState;
    if (!_stateController.isClosed) _stateController.add(newState);
  }

  void _emitEvent(HomeEvent event) {
    if (!_eventsController.isClosed) _eventsController.add(event);
  }

  /// Subscribes to the incoming-call stream. Called once in [init].
  /// The subscription persists for the ViewModel's lifetime —
  /// [SignalingService.cancelListeners] does NOT cancel it.
  void _listenForIncomingCalls() {
    _incomingCallSub?.cancel();
    _incomingCallSub = _signaling.incomingCall(_userId).listen(
      (callId) async {
      final callerUid = callId.split('_').first;

      if (_state is ActiveCall || _state is IncomingCall) {
        await _signaling.writeBusySignal(callerUid);
        return;
      }

      final autoAnswer = await _settings.isAutoAnswer(callerUid);
      unawaited(_analytics.logEvent('incoming_call_received', parameters: {
        'auto_answer_eligible': autoAnswer,
      }));

      // Resolve UID → email for a human-readable caller display name.
      final callerDisplay =
          await _signaling.lookupEmailByUid(callerUid) ?? callerUid;

      if (autoAnswer) {
        unawaited(_analytics.logEvent('incoming_call_auto_answered'));
        await answerCall(callId);
      } else {
        _emit(IncomingCall(callId: callId, callerId: callerDisplay));
        _incomingCallCancelSub =
            _signaling.callCancelled(callId).listen((_) {
          _onIncomingCallCancelled();
        });
        _incomingCallTimeoutTimer = Timer(const Duration(seconds: 40), () {
          unawaited(_analytics.logEvent('incoming_call_missed'));
          _onIncomingCallCancelled();
        });
      }
    },
      onError: (Object e, StackTrace s) =>
          _crashReporter.recordError(e, s, reason: 'incomingCallStream'),
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
    _pendingEndReason = 'callee_busy';
    unawaited(_analytics.logEvent('callee_busy'));
    _emitEvent(HomeEvent.calleeBusy);
    endCall();
  }

  void _onCallTimeout() {
    if (_state is! ActiveCall) return;
    _pendingEndReason = 'timed_out';
    unawaited(_analytics.logEvent('call_timed_out', parameters: {
      'remote_id': (_state as ActiveCall).remoteUserId,
    }));
    _emitEvent(HomeEvent.callTimeout);
    endCall();
  }

  /// Caller-side connection lost: emit event so the screen can show the banner,
  /// then the screen calls [endCall] after the 2-second display window.
  void _onCallerConnectionLost() {
    _pendingEndReason = 'remote_disconnected';
    if (_currentLogEntry != null) {
      final duration =
          DateTime.now().difference(_currentLogEntry!.startedAt).inSeconds;
      unawaited(_analytics.logEvent('remote_disconnected', parameters: {
        'role': 'caller',
        'duration_s': duration,
      }));
    }
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

    _connectionLostSub?.cancel();
    _connectionLostSub = null;
    _connectionEstablishedSub?.cancel();
    _connectionEstablishedSub = null;

    _statsSub?.cancel();
    _statsSub = null;
    final entry = _currentLogEntry;
    _currentLogEntry = null;

    // Ignore Err: callee-side teardown failures don't require user action.
    _endCall.execute(
      currentEntry: entry,
      writeCancelled: false,
      releaseAudio: false,
    ).then((_) {
      if (entry != null) {
        unawaited(_analytics.logEvent('call_ended', parameters: {
          'duration_s':
              DateTime.now().difference(entry.startedAt).inSeconds,
          'role': entry.role,
          'turn_server_selected': entry.turnServer,
          'bytes_sent': entry.bytesSent,
          'bytes_received': entry.bytesReceived,
          'end_reason': 'remote_disconnected',
        }));
      }
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
}
