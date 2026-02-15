import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcService {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  final Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'}
    ]
  };

  /// Create peer connection and acquire audio-only local stream.
  Future<void> init() async {
    _pc = await createPeerConnection(_rtcConfig);
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
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
