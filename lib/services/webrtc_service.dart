import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../interfaces/peer_connection_service.dart';
import '../models/ice_candidate_model.dart';
import '../models/session_description.dart';

/// flutter_webrtc implementation of [PeerConnectionService].
///
/// All WebRTC library types (RTCSessionDescription, RTCIceCandidate, etc.)
/// are fully contained here. Callers only see domain models, so this class
/// can be swapped for a different media stack without touching any other file.
class WebRtcService implements PeerConnectionService {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  Timer? _statsTimer;
  final _statsController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Remote audio track received by the caller — used for volume control.
  MediaStreamTrack? _remoteAudioTrack;

  /// Volume to apply as soon as the remote track arrives (0.0–1.0).
  double? _pendingVolume;

  // ── PeerConnectionService: connection event hooks ─────────────────────────

  @override
  void Function()? onConnectionLost;

  @override
  void Function()? onConnectionEstablished;

  @override
  set onIceCandidate(void Function(IceCandidateModel candidate) callback) {
    _pc!.onIceCandidate = (RTCIceCandidate c) {
      callback(IceCandidateModel(
        candidate: c.candidate ?? '',
        sdpMid: c.sdpMid,
        sdpMLineIndex: c.sdpMLineIndex,
      ));
    };
  }

  @override
  Stream<Map<String, dynamic>> get statsStream => _statsController.stream;

  // ── TURN / ICE server config ───────────────────────────────────────────────

  static const String _meteredApiKey = '21601028951dce7b0c1a015657dd0a3ce67d';
  static const String _meteredApiUrl =
      'https://voicecallpoc.metered.live/api/v1/turn/credentials?apiKey=$_meteredApiKey';

  static const List<Map<String, dynamic>> _expressTurnServers = [
    {
      'urls': 'turn:free.expressturn.com:3478',
      'username': 'efPU52K4SLOQ34W2QY',
      'credential': '1TJPNFxHKXrZfelz',
    },
  ];

  static const List<Map<String, dynamic>> _stunServers = [
    {
      'urls': [
        'stun:stun.l.google.com:19302',
        'stun:stun1.l.google.com:19302',
        'stun:stun2.l.google.com:19302',
      ]
    },
  ];

  Future<List<Map<String, dynamic>>> _fetchIceServers({
    String turnServer = 'both',
  }) async {
    if (turnServer == 'expressturn') {
      return [..._stunServers, ..._expressTurnServers];
    }

    try {
      final response = await http
          .get(Uri.parse(_meteredApiUrl))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        final meteredServers = data.cast<Map<String, dynamic>>();

        if (turnServer == 'metered') {
          return meteredServers;
        }
        return [...meteredServers, ..._expressTurnServers];
      }
    } catch (_) {
      // Network error or timeout — fall through to fallback
    }

    if (turnServer == 'metered') {
      return _stunServers;
    }
    return [..._stunServers, ..._expressTurnServers];
  }

  // ── PeerConnectionService: lifecycle ──────────────────────────────────────

  /// One-way audio (callee → caller):
  ///   - Caller: mic OFF, listens to remote audio from callee
  ///   - Callee: mic ON, ignores remote audio from caller
  @override
  Future<void> init({bool isCaller = false, String turnServer = 'both'}) async {
    final iceServers = await _fetchIceServers(turnServer: turnServer);

    final rtcConfig = {
      'iceServers': iceServers,
      'iceTransportPolicy': 'all',
    };

    _pc = await createPeerConnection(rtcConfig);

    bool connectionLostFired = false;
    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onConnectionEstablished?.call();
      }
      if (connectionLostFired) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        connectionLostFired = true;
        onConnectionLost?.call();
      }
    };

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    if (isCaller) {
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = false;
      }
    }

    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    if (isCaller) {
      _pc!.onTrack = (event) {
        if (event.track.kind == 'audio') {
          _remoteAudioTrack = event.track;
          final pending = _pendingVolume;
          if (pending != null) {
            Helper.setVolume(pending, event.track);
          }
        }
      };
    } else {
      _pc!.onTrack = (event) {
        // Callee discards incoming audio — one-way design
      };
    }

    _startStatsPolling();
  }

  @override
  Future<void> close() async {
    onConnectionLost = null;
    onConnectionEstablished = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    await _pc?.close();
    _pc = null;
    _remoteAudioTrack = null;
    _pendingVolume = null;
  }

  // ── PeerConnectionService: negotiation ────────────────────────────────────

  @override
  Future<SessionDescription> createOffer() async {
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    return SessionDescription(sdp: offer.sdp!, type: offer.type!);
  }

  @override
  Future<SessionDescription> createAnswer() async {
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    return SessionDescription(sdp: answer.sdp!, type: answer.type!);
  }

  @override
  Future<void> setRemoteDescription(SessionDescription description) async {
    await _pc!.setRemoteDescription(
      RTCSessionDescription(description.sdp, description.type),
    );
  }

  @override
  Future<void> addIceCandidate(IceCandidateModel candidate) async {
    await _pc?.addCandidate(RTCIceCandidate(
      candidate.candidate,
      candidate.sdpMid,
      candidate.sdpMLineIndex,
    ));
  }

  // ── PeerConnectionService: audio control ──────────────────────────────────

  @override
  Future<void> setRemoteVolume(double volume) async {
    _pendingVolume = volume;
    final track = _remoteAudioTrack;
    if (track != null) {
      await Helper.setVolume(volume, track);
    }
  }

  @override
  Future<String> resolveActualTurnUsed() async {
    if (_pc == null) return 'unknown';
    try {
      final reports = await _pc!.getStats();

      String? localCandidateId;
      for (final r in reports) {
        if (r.type == 'candidate-pair') {
          final state = r.values['state'] as String? ?? '';
          final nominated = r.values['nominated'] as bool? ?? false;
          if (state == 'succeeded' || nominated) {
            localCandidateId = r.values['localCandidateId'] as String?;
            break;
          }
        }
      }

      if (localCandidateId == null) return 'unknown';

      for (final r in reports) {
        if (r.type == 'local-candidate' && r.id == localCandidateId) {
          final candidateType = r.values['candidateType'] as String? ?? '';
          if (candidateType != 'relay') {
            return candidateType == 'host' ? 'direct' : 'stun';
          }
          final ip = (r.values['ip'] ??
                  r.values['address'] ??
                  r.values['relatedAddress'] ??
                  '') as String;
          final url = r.values['url'] as String? ?? '';
          final combined = '$ip $url'.toLowerCase();
          if (combined.contains('metered') ||
              combined.contains('openrelay')) {
            return 'metered';
          }
          if (combined.contains('expressturn')) {
            return 'expressturn';
          }
          return 'turn';
        }
      }
    } catch (_) {
      // getStats() failed — not critical
    }
    return 'unknown';
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _startStatsPolling() {
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_pc == null) return;
      final reports = await _pc!.getStats();
      int bytesSent = 0;
      int bytesReceived = 0;
      for (final report in reports) {
        final values = report.values;
        if (report.type == 'outbound-rtp') {
          bytesSent += (values['bytesSent'] as num?)?.toInt() ?? 0;
        } else if (report.type == 'inbound-rtp') {
          bytesReceived += (values['bytesReceived'] as num?)?.toInt() ?? 0;
        }
      }
      if (!_statsController.isClosed) {
        _statsController.add({
          'bytesSent': bytesSent,
          'bytesReceived': bytesReceived,
        });
      }
    });
  }
}
