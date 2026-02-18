import 'dart:async';

import 'package:flutter/material.dart';

class CallScreen extends StatefulWidget {
  final bool isCaller;
  final VoidCallback onEndCall;
  final Stream<Map<String, dynamic>>? statsStream;

  const CallScreen({
    super.key,
    required this.isCaller,
    required this.onEndCall,
    this.statsStream,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  int _bytesSent = 0;
  int _bytesReceived = 0;
  StreamSubscription<Map<String, dynamic>>? _statsSub;

  @override
  void initState() {
    super.initState();
    if (widget.isCaller) {
      _statsSub = widget.statsStream?.listen((stats) {
        setState(() {
          _bytesSent = stats['bytesSent'] as int? ?? 0;
          _bytesReceived = stats['bytesReceived'] as int? ?? 0;
        });
      });
    }
  }

  @override
  void dispose() {
    _statsSub?.cancel();
    super.dispose();
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
            Text(
              widget.isCaller ? 'You are calling...' : 'In call...',
              style: const TextStyle(fontSize: 20),
            ),
            if (widget.isCaller) ...[
              const SizedBox(height: 32),
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
