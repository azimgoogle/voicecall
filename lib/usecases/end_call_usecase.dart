import '../core/app_error.dart';
import '../core/result.dart';
import '../interfaces/call_log_repository.dart';
import '../interfaces/peer_connection_service.dart';
import '../interfaces/signaling_service.dart';
import '../models/call_log_entry.dart';
import '../services/audio_service.dart';
import '../services/foreground_service.dart';

/// Encapsulates all cleanup logic for ending a call.
///
/// Handles log finalisation, signaling teardown, WebRTC close, and
/// audio session release in one place so both explicit end and
/// connection-lost paths stay DRY.
class EndCallUseCase {
  final SignalingService _signaling;
  final PeerConnectionService _peerConnection;
  final CallLogRepository _logRepository;

  EndCallUseCase({
    required SignalingService signaling,
    required PeerConnectionService peerConnection,
    required CallLogRepository logRepository,
  })  : _signaling = signaling,
        _peerConnection = peerConnection,
        _logRepository = logRepository;

  /// Tears down an active call.
  ///
  /// [currentEntry] is the in-progress [CallLogEntry] to finalise.
  /// [writeCancelled] true → writes the cancelled signal (caller-side explicit hang-up).
  /// [releaseAudio] true → releases audio session and proximity wake lock (caller only).
  ///
  /// Returns [Ok] on clean teardown, [Err] if a step throws — the caller
  /// should still reset to idle even on [Err] since the connection is gone.
  Future<Result<Unit, AppError>> execute({
    required CallLogEntry? currentEntry,
    bool writeCancelled = false,
    bool releaseAudio = false,
  }) async {
    try {
      // 1. Finalise and save the call log entry.
      if (currentEntry != null) {
        final turnUsed = await _peerConnection.resolveActualTurnUsed();
        final finalEntry = currentEntry.copyWith(
          endedAt: DateTime.now(),
          turnUsed: turnUsed,
        );
        await _logRepository.saveEntry(finalEntry);
      }

      // 2. Notify remote that the caller hung up (before answer).
      if (writeCancelled && currentEntry != null) {
        await _signaling.writeCancelledSignal(currentEntry.callId);
      }

      // 3. Cancel all call-specific Firebase listeners.
      await _signaling.cancelListeners();

      // 4. Tear down the WebRTC peer connection.
      await _peerConnection.close();

      // 5. Release audio resources (caller only).
      if (releaseAudio) {
        await AudioService.releaseProximityWakeLock();
        await AudioService.stopAudioSession();
      }

      // 6. Reset foreground notification to idle state.
      await updateForegroundNotification('Waiting for calls...');

      return const Ok(Unit.instance);
    } catch (e) {
      return Err(SignalingError(e));
    }
  }
}
