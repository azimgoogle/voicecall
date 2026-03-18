import 'dart:async';

import '../models/ice_candidate_model.dart';
import '../models/session_description.dart';

/// Abstract peer-to-peer media layer.
///
/// Implementations may use flutter_webrtc, a native media stack, or any other
/// transport — callers are fully decoupled from the underlying library types.
abstract class PeerConnectionService {
  // ── Connection event streams ──────────────────────────────────────────────

  /// Emits once when the connection permanently fails or closes.
  ///
  /// The stream is per-call: a new stream is returned after each [init] and
  /// the stream closes (sends a done event) when [close] is called.
  Stream<void> get connectionLost;

  /// Emits once when the connection reaches the 'connected' state.
  ///
  /// The stream is per-call: a new stream is returned after each [init] and
  /// the stream closes (sends a done event) when [close] is called.
  Stream<void> get connectionEstablished;

  /// Emits each local ICE candidate that must be forwarded via [SignalingService].
  ///
  /// The stream is per-call: a new stream is returned after each [init] and
  /// the stream closes (sends a done event) when [close] is called.
  Stream<IceCandidateModel> get iceCandidate;

  /// Emits live stats: `{bytesSent: int, bytesReceived: int}` at ~1 Hz.
  Stream<Map<String, dynamic>> get statsStream;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Initialise the peer connection.
  /// [isCaller] true → mic disabled (listen-only role).
  /// [turnServer] 'metered' | 'expressturn' | 'both'
  Future<void> init({bool isCaller = false, String turnServer = 'both'});

  Future<void> close();

  // ── Negotiation ───────────────────────────────────────────────────────────

  Future<SessionDescription> createOffer();

  Future<SessionDescription> createAnswer();

  Future<void> setRemoteDescription(SessionDescription description);

  Future<void> addIceCandidate(IceCandidateModel candidate);

  // ── Audio control ─────────────────────────────────────────────────────────

  /// Set the receive-side volume (0.0–1.0). Does not touch system volume.
  /// Safe to call before the remote track has arrived.
  Future<void> setRemoteVolume(double volume);

  /// Inspect the active ICE path post-call to detect the relay used.
  /// Returns one of: 'direct' | 'stun' | 'metered' | 'expressturn' | 'turn' | 'unknown'
  Future<String> resolveActualTurnUsed();
}
