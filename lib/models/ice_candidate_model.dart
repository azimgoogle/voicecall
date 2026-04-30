/// A signaling-agnostic ICE candidate.
///
/// Wraps the three fields exchanged during WebRTC negotiation without
/// coupling callers to any specific WebRTC library type, so the same model
/// can flow through both [SignalingService] and [PeerConnectionService].
class IceCandidateModel {
  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  const IceCandidateModel({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });
}
