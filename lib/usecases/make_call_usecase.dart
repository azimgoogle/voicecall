import 'package:shared_preferences/shared_preferences.dart';

import '../interfaces/call_log_repository.dart';
import '../interfaces/peer_connection_service.dart';
import '../interfaces/signaling_service.dart';
import '../models/call_log_entry.dart';
import '../services/audio_service.dart';
import '../services/foreground_service.dart';

/// Encapsulates all logic for initiating an outgoing call.
///
/// Dependencies are injected so the use case can be unit-tested in isolation
/// without a real Firebase or WebRTC implementation.
class MakeCallUseCase {
  final SignalingService _signaling;
  final PeerConnectionService _peerConnection;
  final CallLogRepository _logRepository;

  MakeCallUseCase({
    required SignalingService signaling,
    required PeerConnectionService peerConnection,
    required CallLogRepository logRepository,
  })  : _signaling = signaling,
        _peerConnection = peerConnection,
        _logRepository = logRepository;

  static const String _lastRemoteIdKey = 'last_remote_id';
  static const String _callMuteKey = 'call_mute';

  /// Initiates a call from [callerId] to [remoteId] using [turnServer].
  ///
  /// Returns the newly created [CallLogEntry] so the caller can track it.
  /// Invokes [onIceCandidate] whenever a local ICE candidate must be forwarded.
  /// Invokes [onConnectionLost] / [onConnectionEstablished] on state changes.
  Future<CallLogEntry> execute({
    required String callerId,
    required String remoteId,
    required String turnServer,
    required double initialVolume,
    required void Function() onConnectionLost,
    required void Function() onConnectionEstablished,
  }) async {
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
    await AudioService.startAudioSession();
    await AudioService.acquireProximityWakeLock();

    await _logRepository.saveEntry(logEntry);

    _peerConnection.onIceCandidate = (candidate) {
      _signaling.writeIceCandidate(
          callId: callId, isCaller: true, candidate: candidate);
    };

    final offer = await _peerConnection.createOffer();
    await _signaling.writeOffer(
        callId: callId, offer: offer, caller: callerId, callee: remoteId);
    await _signaling.notifyRemoteUser(remoteId, callId);
    await updateForegroundNotification(
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

    return logEntry;
  }
}
