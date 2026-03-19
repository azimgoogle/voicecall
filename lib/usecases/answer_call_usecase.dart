import '../core/app_error.dart';
import '../core/result.dart';
import '../interfaces/call_log_repository.dart';
import '../interfaces/crash_reporter.dart';
import '../interfaces/foreground_service.dart';
import '../interfaces/peer_connection_service.dart';
import '../interfaces/signaling_service.dart';
import '../models/call_log_entry.dart';

/// Encapsulates all logic for answering an incoming call.
///
/// Connection-event subscriptions ([connectionLost]) are the caller's
/// responsibility — subscribe to [PeerConnectionService] streams after
/// this method returns [Ok].
class AnswerCallUseCase {
  final SignalingService _signaling;
  final PeerConnectionService _peerConnection;
  final CallLogRepository _logRepository;
  final ForegroundService _foreground;
  final CrashReporter _crashReporter;

  AnswerCallUseCase({
    required SignalingService signaling,
    required PeerConnectionService peerConnection,
    required CallLogRepository logRepository,
    required ForegroundService foregroundService,
    required CrashReporter crashReporter,
  })  : _signaling = signaling,
        _peerConnection = peerConnection,
        _logRepository = logRepository,
        _foreground = foregroundService,
        _crashReporter = crashReporter;

  /// Answers the call identified by [callId].
  ///
  /// Returns [Ok] carrying the new [CallLogEntry] on success, or [Err] carrying
  /// an [AppError] if any step fails. On failure the caller should dismiss the
  /// incoming call UI and reset to idle.
  Future<Result<CallLogEntry, AppError>> execute({
    required String callId,
  }) async {
    try {
      _crashReporter.log('answerCall: init peerConnection');
      await _peerConnection.init(isCaller: false);

      final parts = callId.split('_');
      final remoteUserId = parts.length >= 2 ? parts[0] : callId;

      final logEntry = CallLogEntry(
        callId: callId,
        role: 'callee',
        remoteUserId: remoteUserId,
        turnServer: 'both',
        startedAt: DateTime.now(),
      );

      await _logRepository.saveEntry(logEntry);

      // Forward local ICE candidates to signaling.
      // The subscription auto-cancels when the iceCandidate controller closes
      // at call teardown (PeerConnectionService.close).
      _peerConnection.iceCandidate.listen(
        (candidate) {
          _signaling.writeIceCandidate(
              callId: callId, isCaller: false, candidate: candidate);
        },
        onError: (Object e, StackTrace s) =>
            _crashReporter.recordError(e, s, reason: 'iceCandidateSend'),
      );

      _crashReporter.log('answerCall: reading offer from Firebase');
      final offer = await _signaling.readOffer(callId);

      _crashReporter.log('answerCall: setRemoteDescription done');
      await _peerConnection.setRemoteDescription(offer);

      _crashReporter.log('answerCall: creating answer');
      final answer = await _peerConnection.createAnswer();

      _crashReporter.log('answerCall: writing answer to Firebase');
      await _signaling.writeAnswer(callId: callId, answer: answer);
      await _foreground.updateNotification('In call...', showEndCall: true);

      _crashReporter.log('answerCall: listening for ICE candidates');

      // Apply remote ICE candidates from the caller.
      // The subscription auto-cancels when cancelListeners closes the stream.
      _signaling.iceCandidates(callId, true).listen(
        (candidate) {
          _peerConnection.addIceCandidate(candidate);
        },
        onError: (Object e, StackTrace s) =>
            _crashReporter.recordError(e, s, reason: 'iceCandidatesCaller'),
      );

      return Ok(logEntry);
    } catch (e) {
      return Err(ConnectionError(e));
    }
  }
}
