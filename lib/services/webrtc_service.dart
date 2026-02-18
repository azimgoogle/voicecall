import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

class WebRtcService {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;

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

    // Callee: discard incoming remote audio — callee never hears caller
    if (!isCaller) {
      _pc!.onTrack = (event) {
        // Discard remote tracks — callee doesn't play any audio
      };
    }
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

  /// Close peer connection and release media resources.
  Future<void> close() async {
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    await _pc?.close();
    _pc = null;
  }
}
