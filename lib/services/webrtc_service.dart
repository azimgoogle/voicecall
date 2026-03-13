import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

class WebRtcService {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  Timer? _statsTimer;
  final _statsController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Remote audio track received by the caller — used for volume control.
  MediaStreamTrack? _remoteAudioTrack;

  /// Volume to apply as soon as the remote track arrives (0.0–1.0).
  double? _pendingVolume;

  /// Fired once when the peer connection permanently fails or disconnects.
  /// Only the first terminal state triggers this — subsequent state changes
  /// are ignored. Caller sets this before [init].
  void Function()? onConnectionLost;

  /// Fired when the peer connection reaches the 'connected' state.
  void Function()? onConnectionEstablished;

  /// Stream of live stats: `{bytesSent: int, bytesReceived: int}`.
  /// Emits every second while the call is active.
  Stream<Map<String, dynamic>> get statsStream => _statsController.stream;

  static const String _meteredApiKey = '21601028951dce7b0c1a015657dd0a3ce67d';
  static const String _meteredApiUrl =
      'https://voicecallpoc.metered.live/api/v1/turn/credentials?apiKey=$_meteredApiKey';

  /// ExpressTURN static credentials (free tier — refreshed manually from dashboard).
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

  /// Fetch ICE servers based on the selected TURN provider.
  ///
  /// [turnServer] options:
  ///   - 'metered'     → Metered.ca only (dynamic credentials fetched via API)
  ///   - 'expressturn' → ExpressTURN only (static credentials, no HTTP fetch)
  ///   - 'both'        → Metered + ExpressTURN merged (used by callee)
  Future<List<Map<String, dynamic>>> _fetchIceServers({
    String turnServer = 'both',
  }) async {
    if (turnServer == 'expressturn') {
      // Static credentials — no network call needed
      return [..._stunServers, ..._expressTurnServers];
    }

    // For 'metered' or 'both', fetch dynamic Metered credentials
    try {
      final response = await http
          .get(Uri.parse(_meteredApiUrl))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        final meteredServers = data.cast<Map<String, dynamic>>();

        if (turnServer == 'metered') {
          return meteredServers; // Metered only (includes their STUN entries)
        }
        // 'both': merge Metered + ExpressTURN
        return [...meteredServers, ..._expressTurnServers];
      }
    } catch (_) {
      // Network error or timeout — fall through to fallback
    }

    // Fallback when Metered fetch fails
    if (turnServer == 'metered') {
      // Nothing we can do without credentials — STUN only
      return _stunServers;
    }
    // 'both' fallback: at least use ExpressTURN + STUN
    return [..._stunServers, ..._expressTurnServers];
  }

  /// Create peer connection and acquire audio-only local stream.
  ///
  /// One-way audio (callee → caller):
  ///   - Caller: mic OFF (muted), listens to remote audio from callee
  ///   - Callee: mic ON (sends audio), ignores remote audio from caller
  ///
  /// [turnServer]: 'metered' | 'expressturn' | 'both'
  Future<void> init({bool isCaller = false, String turnServer = 'both'}) async {
    final iceServers = await _fetchIceServers(turnServer: turnServer);

    final rtcConfig = {
      'iceServers': iceServers,
      'iceTransportPolicy': 'all',
    };

    _pc = await createPeerConnection(rtcConfig);

    // Monitor connection health. 'disconnected' can self-recover; 'failed'
    // and 'closed' are terminal. Fire onConnectionLost only once.
    bool _connectionLostFired = false;
    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onConnectionEstablished?.call();
      }
      if (_connectionLostFired) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _connectionLostFired = true;
        onConnectionLost?.call();
      }
    };

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    // Caller: mute mic — caller only listens, never sends audio
    if (isCaller) {
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = false;
      }
    }

    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    if (isCaller) {
      // Caller: capture the remote audio track so volume can be adjusted.
      // WebRTC plays it automatically; we just need a handle for Helper.setVolume.
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
      // Callee: discard incoming remote audio — callee never hears caller
      _pc!.onTrack = (event) {
        // Discard remote tracks — callee doesn't play any audio
      };
    }

    _startStatsPolling();
  }

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

  /// Create SDP offer.
  Future<RTCSessionDescription> createOffer() async {
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    return offer;
  }

  /// Create SDP answer.
  Future<RTCSessionDescription> createAnswer() async {
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    return answer;
  }

  /// Set remote SDP description.
  Future<void> setRemoteDescription(String sdp, String type) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
  }

  /// Add a remote ICE candidate.
  Future<void> addIceCandidate(
      String candidate, String? sdpMid, int? sdpMLineIndex) async {
    await _pc?.addCandidate(
        RTCIceCandidate(candidate, sdpMid, sdpMLineIndex));
  }

  /// Set callback for local ICE candidates.
  set onIceCandidate(void Function(RTCIceCandidate candidate) callback) {
    _pc!.onIceCandidate = callback;
  }

  /// Inspect the active ICE candidate pair to determine what relay was actually
  /// used for this call. Returns one of:
  ///   'direct'      — host-to-host, no server involved
  ///   'stun'        — server-reflexive (STUN helped, no relay)
  ///   'metered'     — relayed via Metered TURN (*.metered.live / openrelay)
  ///   'expressturn' — relayed via ExpressTURN (*.expressturn.com)
  ///   'turn'        — relayed via an unrecognised TURN server
  ///   'unknown'     — stats not available or no active pair found
  Future<String> resolveActualTurnUsed() async {
    if (_pc == null) return 'unknown';
    try {
      final reports = await _pc!.getStats();

      // Find the succeeded candidate-pair
      String? localCandidateId;
      for (final r in reports) {
        if (r.type == 'candidate-pair') {
          final state = r.values['state'] as String? ?? '';
          final nominated = r.values['nominated'] as bool? ?? false;
          if (state == 'succeeded' || nominated) {
            localCandidateId =
                r.values['localCandidateId'] as String?;
            break;
          }
        }
      }

      if (localCandidateId == null) return 'unknown';

      // Look up the local candidate for that pair
      for (final r in reports) {
        if (r.type == 'local-candidate' && r.id == localCandidateId) {
          final candidateType = r.values['candidateType'] as String? ?? '';
          if (candidateType != 'relay') {
            return candidateType == 'host' ? 'direct' : 'stun';
          }
          // It's a relay — figure out which TURN server
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
          return 'turn'; // relay via an unrecognised server
        }
      }
    } catch (_) {
      // getStats() failed — not critical
    }
    return 'unknown';
  }

  /// Set the receive-side volume for the caller (0.0 = silent, 1.0 = full).
  /// Uses WebRTC's internal AudioTrack gain — no system volume change.
  /// Safe to call before the remote track has arrived; value is applied
  /// immediately once the track is received.
  Future<void> setRemoteVolume(double volume) async {
    _pendingVolume = volume;
    final track = _remoteAudioTrack;
    if (track != null) {
      await Helper.setVolume(volume, track);
    }
  }

  /// Close peer connection and release media resources.
  Future<void> close() async {
    onConnectionLost = null; // prevent stale callbacks after teardown
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
}
