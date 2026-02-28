import 'dart:async';

import 'package:flutter/material.dart';

class CallScreen extends StatefulWidget {
  final bool isCaller;
  final VoidCallback onEndCall;
  final Stream<Map<String, dynamic>>? statsStream;

  /// Initial volume level (0.0–1.0). Only used when [isCaller] is true.
  final double initialVolume;

  /// Initial mute state. Only used when [isCaller] is true.
  final bool initialMuted;

  /// When the call started. Used to display a live elapsed-time counter.
  /// Only used when [isCaller] is true.
  final DateTime? callStartedAt;

  /// Called whenever the user moves the volume slider.
  /// Receives the new level (0.0–1.0). Only fired when [isCaller] is true.
  final void Function(double)? onVolumeChanged;

  /// Called when the mute button is toggled.
  /// [muted] is true when muting, false when unmuting.
  /// Separate from [onVolumeChanged] so the caller's saved level is never
  /// overwritten with 0.0 during a mute.
  final void Function(bool muted)? onMuteToggled;

  /// Called when the remote side disconnects unexpectedly (caller-only).
  /// HomeScreen wires this to its _endCall so the screen tears down after
  /// the banner has been shown briefly.
  final VoidCallback? onRemoteDisconnected;

  const CallScreen({
    super.key,
    required this.isCaller,
    required this.onEndCall,
    this.statsStream,
    this.initialVolume = 1.0,
    this.initialMuted = false,
    this.callStartedAt,
    this.onVolumeChanged,
    this.onMuteToggled,
    this.onRemoteDisconnected,
  });

  @override
  State<CallScreen> createState() => CallScreenState();
}

class CallScreenState extends State<CallScreen> {
  int _bytesSent = 0;
  int _bytesReceived = 0;
  StreamSubscription<Map<String, dynamic>>? _statsSub;
  late double _volume;
  bool _muted = false;
  Timer? _clockTimer;
  Duration _elapsed = Duration.zero;
  bool _remoteDisconnected = false;

  @override
  void initState() {
    super.initState();
    _volume = widget.initialVolume;
    _muted = widget.initialMuted;
    if (widget.isCaller) {
      _statsSub = widget.statsStream?.listen((stats) {
        setState(() {
          _bytesSent = stats['bytesSent'] as int? ?? 0;
          _bytesReceived = stats['bytesReceived'] as int? ?? 0;
        });
      });

      // Seed elapsed immediately so the first frame shows the correct time,
      // then update every second in sync with wall clock.
      final startedAt = widget.callStartedAt;
      if (startedAt != null) {
        _elapsed = DateTime.now().difference(startedAt);
        _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          setState(() {
            _elapsed = DateTime.now().difference(startedAt);
          });
        });
      }
    }
  }

  /// Called by HomeScreen when WebRTC or Firebase signals remote disconnect.
  /// Shows a banner for 2 s, then triggers the full call teardown.
  void notifyRemoteDisconnected() {
    if (_remoteDisconnected || !mounted) return;
    setState(() => _remoteDisconnected = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) widget.onRemoteDisconnected?.call();
    });
  }

  @override
  void dispose() {
    _statsSub?.cancel();
    _clockTimer?.cancel();
    super.dispose();
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('In Call')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.isCaller && _remoteDisconnected)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  border: Border.all(color: Colors.red.shade200),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.signal_cellular_connected_no_internet_4_bar,
                        color: Colors.red.shade400, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Callee disconnected',
                      style: TextStyle(
                          color: Colors.red.shade700,
                          fontWeight: FontWeight.w600,
                          fontSize: 14),
                    ),
                  ],
                ),
              ),
            Text(
              widget.isCaller ? 'You are calling...' : 'In call...',
              style: const TextStyle(fontSize: 20),
            ),
            if (widget.isCaller) ...[
              const SizedBox(height: 24),
              if (widget.callStartedAt != null)
                Text(
                  _formatElapsed(_elapsed),
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 2,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Column(
                  children: [
                    const Text(
                      'Data Usage',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _StatTile(
                          icon: Icons.arrow_upward,
                          color: Colors.blue,
                          label: 'Sent',
                          value: _formatBytes(_bytesSent),
                        ),
                        const SizedBox(width: 32),
                        _StatTile(
                          icon: Icons.arrow_downward,
                          color: Colors.green,
                          label: 'Received',
                          value: _formatBytes(_bytesReceived),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Volume control — does NOT change system volume
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Call Volume',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.volume_down,
                            size: 20, color: Colors.grey),
                        Expanded(
                          child: Slider(
                            value: _volume,
                            min: 0.0,
                            max: 1.0,
                            divisions: 10,
                            label: '${(_volume * 100).round()}%',
                            // null disables the slider and greys it out
                            onChanged: _muted
                                ? null
                                : (v) {
                                    setState(() => _volume = v);
                                    widget.onVolumeChanged?.call(v);
                                  },
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            _muted ? Icons.volume_off : Icons.volume_up,
                            size: 20,
                            color: _muted ? Colors.red : Colors.grey,
                          ),
                          tooltip: _muted ? 'Unmute' : 'Mute',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            final nowMuted = !_muted;
                            setState(() => _muted = nowMuted);
                            widget.onMuteToggled?.call(nowMuted);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 32),
            if (widget.isCaller)
              ElevatedButton(
                onPressed: widget.onEndCall,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 48, vertical: 16),
                ),
                child:
                    const Text('End Call', style: TextStyle(fontSize: 20)),
              )
            else
              const Text(
                'Waiting for caller to end the call',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;

  const _StatTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold)),
        Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
