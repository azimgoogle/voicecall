import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_error.dart';
import '../core/result.dart';
import '../interfaces/audio_service.dart';
import '../interfaces/call_log_repository.dart';
import '../interfaces/crash_reporter.dart';
import '../interfaces/foreground_service.dart';
import '../interfaces/peer_connection_service.dart';
import '../interfaces/signaling_service.dart';
import '../models/call_log_entry.dart';

/// Encapsulates all logic for initiating an outgoing call.
///
/// Dependencies are injected so the use case can be unit-tested in isolation
/// without a real Firebase, WebRTC, or platform-audio implementation.
class MakeCallUseCase {
  final SignalingService _signaling;
  final PeerConnectionService _peerConnection;
  final CallLogRepository _logRepository;
  final AudioService _audio;
  final ForegroundService _foreground;
  final CrashReporter _crashReporter;

  MakeCallUseCase({
    required SignalingService signaling,
    required PeerConnectionService peerConnection,
    required CallLogRepository logRepository,
    required AudioService audioService,
    required ForegroundService foregroundService,
    required CrashReporter crashReporter,
  })  : _signaling = signaling,
        _peerConnection = peerConnection,
        _logRepository = logRepository,
        _audio = audioService,
        _foreground = foregroundService,
        _crashReporter = crashReporter;

  static const String _lastRemoteIdKey = 'last_remote_id';

  /// Initiates a call from [callerId] to [remoteId] using [turnServer].
  ///
  /// [callerHandle] is the current user's display handle — stored in the call
  /// record so the callee can read it when logging the call.
  /// [remoteHandle] is the recipient's display handle — stored directly in the
  /// log entry so no post-hoc UID→handle lookup is needed.
  ///
  /// Returns [Ok] carrying the new [CallLogEntry] on success, or [Err] carrying
  /// an [AppError] if any step fails. On failure the caller should treat the
  /// call as not started and reset UI state accordingly.
  ///
  /// Connection-event subscriptions ([connectionLost], [connectionEstablished])
  /// are the caller's responsibility — subscribe to [PeerConnectionService]
  /// streams after this method returns [Ok].
  Future<Result<CallLogEntry, AppError>> execute({
    required String callerId,
    required String remoteId,
    required String callerHandle,
    required String remoteHandle,
    required String turnServer,
    required double initialVolume,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastRemoteIdKey, remoteHandle);

      final callId = _signaling.generateCallId(callerId, remoteId);
      final logEntry = CallLogEntry(
        callId: callId,
        role: 'caller',
        remoteUserId: remoteHandle,
        turnServer: turnServer,
        startedAt: DateTime.now(),
      );

      _crashReporter.log('makeCall: init peerConnection (turn=$turnServer)');
      await _peerConnection.init(isCaller: true, turnServer: turnServer);
      await _peerConnection.setRemoteVolume(initialVolume);

      _crashReporter.log('makeCall: starting audio session');
      await _audio.startAudioSession();
      await _audio.acquireProximityWakeLock();

      await _logRepository.saveEntry(logEntry);

      // Forward local ICE candidates to signaling.
      // The subscription auto-cancels when the iceCandidate controller closes
      // at call teardown (PeerConnectionService.close).
      _peerConnection.iceCandidate.listen(
        (candidate) {
          _signaling.writeIceCandidate(
              callId: callId, isCaller: true, candidate: candidate);
        },
        onError: (Object e, StackTrace s) =>
            _crashReporter.recordError(e, s, reason: 'iceCandidateSend'),
      );

      _crashReporter.log('makeCall: creating offer');
      final offer = await _peerConnection.createOffer();

      _crashReporter.log('makeCall: writing offer to Firebase');
      await _signaling.writeOffer(
          callId: callId,
          offer: offer,
          caller: callerId,
          callee: remoteId,
          callerHandle: callerHandle);

      _crashReporter.log('makeCall: notifying callee');
      await _signaling.notifyRemoteUser(remoteId, callId);
      await _foreground.updateNotification(
        'In call...',
        showEndCall: true,
        showMute: true,
        isMuted: false,
      );

      _crashReporter.log('makeCall: listening for answer and ICE candidates');

      // Apply callee's answer when it arrives.
      // The subscription auto-cancels when cancelListeners closes the stream.
      _signaling.answerStream(callId).listen(
        (answer) {
          _peerConnection.setRemoteDescription(answer);
        },
        onError: (Object e, StackTrace s) =>
            _crashReporter.recordError(e, s, reason: 'answerStream'),
      );

      // Apply remote ICE candidates from the callee.
      // The subscription auto-cancels when cancelListeners closes the stream.
      _signaling.iceCandidates(callId, false).listen(
        (candidate) {
          _peerConnection.addIceCandidate(candidate);
        },
        onError: (Object e, StackTrace s) =>
            _crashReporter.recordError(e, s, reason: 'iceCandidatesCallee'),
      );

      return Ok(logEntry);
    } catch (e) {
      return Err(ConnectionError(e));
    }
  }
}
