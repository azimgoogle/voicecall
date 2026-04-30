/// A signaling-agnostic SDP (Session Description Protocol) description.
///
/// Wraps the two fields needed for WebRTC offer/answer exchange without
/// coupling callers to any specific WebRTC library type, so the same model
/// can flow through both [SignalingService] and [PeerConnectionService].
class SessionDescription {
  final String sdp;
  final String type; // 'offer' | 'answer'

  const SessionDescription({required this.sdp, required this.type});
}
