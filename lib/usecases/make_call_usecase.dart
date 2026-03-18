import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_error.dart';
import '../core/result.dart';
import '../interfaces/audio_service.dart';
import '../interfaces/call_log_repository.dart';
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

  MakeCallUseCase({
    required SignalingService signaling,
    required PeerConnectionService peerConnection,
    required CallLogRepository logRepository,
    required AudioService audioService,
    required ForegroundService foregroundService,
  })  : _signaling = signaling,
        _peerConnection = peerConnection,
        _logRepository = logRepository,
        _audio = audioService,
        _foreground = foregroundService;

  static const String _lastRemoteIdKey = 'last_remote_id';
  static const String _callMuteKey = 'call_mute';

  /// Initiates a call from [callerId] to [remoteId] using [turnServer].
  ///
  /// Returns [Ok] carrying the new [CallLogEntry] on success, or [Err] carrying
  /// an [AppError] if any step fails. On failure the caller should treat the
  /// call as not started and reset UI state accordingly.
  Future<Result<CallLogEntry, AppError>> execute({
    required String callerId,
    required String remoteId,
    required String turnServer,
    required double initialVolume,
    required void Function() onConnectionLost,
    required void Function() onConnectionEstablished,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastRemoteIdKey, remoteId);
      await prefs.setBool(_callMuteKey, false);

      final callId = _signaling.generateCallId(callerId, remoteId);
      final logEntry = CallLogEntry(
        callId: callId,
        role: 'caller',
        remoteUserId: remoteId,
        turnServer: turnServer,
        startedAt: DateTime.now(),
      );

      _peerConnection.onConnectionLost = onConnectionLost;
      _peerConnection.onConnectionEstablished = onConnectionEstablished;

      await _peerConnection.init(isCaller: true, turnServer: turnServer);
      await _peerConnection.setRemoteVolume(initialVolume);
      await _audio.startAudioSession();
      await _audio.acquireProximityWakeLock();

      await _logRepository.saveEntry(logEntry);

      _peerConnection.onIceCandidate = (candidate) {
        _signaling.writeIceCandidate(
            callId: callId, isCaller: true, candidate: candidate);
      };

      final offer = await _peerConnection.createOffer();
      await _signaling.writeOffer(
          callId: callId, offer: offer, caller: callerId, callee: remoteId);
      await _signaling.notifyRemoteUser(remoteId, callId);
      await _foreground.updateNotification(
        'In call...',
        showEndCall: true,
        showMute: true,
        isMuted: false,
      );

      _signaling.listenForAnswer(callId, (answer) {
        _peerConnection.setRemoteDescription(answer);
      });
      _signaling.listenForIceCandidates(callId, false, (candidate) {
        _peerConnection.addIceCandidate(candidate);
      });

      return Ok(logEntry);
    } catch (e) {
      return Err(ConnectionError(e));
    }
  }
}
