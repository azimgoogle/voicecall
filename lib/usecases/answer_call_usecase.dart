import '../core/app_error.dart';
import '../core/result.dart';
import '../interfaces/call_log_repository.dart';
import '../interfaces/foreground_service.dart';
import '../interfaces/peer_connection_service.dart';
import '../interfaces/signaling_service.dart';
import '../models/call_log_entry.dart';

/// Encapsulates all logic for answering an incoming call.
class AnswerCallUseCase {
  final SignalingService _signaling;
  final PeerConnectionService _peerConnection;
  final CallLogRepository _logRepository;
  final ForegroundService _foreground;

  AnswerCallUseCase({
    required SignalingService signaling,
    required PeerConnectionService peerConnection,
    required CallLogRepository logRepository,
    required ForegroundService foregroundService,
  })  : _signaling = signaling,
        _peerConnection = peerConnection,
        _logRepository = logRepository,
        _foreground = foregroundService;

  /// Answers the call identified by [callId].
  ///
  /// Returns [Ok] carrying the new [CallLogEntry] on success, or [Err] carrying
  /// an [AppError] if any step fails. On failure the caller should dismiss the
  /// incoming call UI and reset to idle.
  Future<Result<CallLogEntry, AppError>> execute({
    required String callId,
    required void Function() onConnectionLost,
  }) async {
    try {
      _peerConnection.onConnectionLost = onConnectionLost;
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

      _peerConnection.onIceCandidate = (candidate) {
        _signaling.writeIceCandidate(
            callId: callId, isCaller: false, candidate: candidate);
      };

      final offer = await _signaling.readOffer(callId);
      await _peerConnection.setRemoteDescription(offer);

      final answer = await _peerConnection.createAnswer();
      await _signaling.writeAnswer(callId: callId, answer: answer);
      await _foreground.updateNotification('In call...', showEndCall: true);

      _signaling.listenForIceCandidates(callId, true, (candidate) {
        _peerConnection.addIceCandidate(candidate);
      });

      return Ok(logEntry);
    } catch (e) {
      return Err(ConnectionError(e));
    }
  }
}
