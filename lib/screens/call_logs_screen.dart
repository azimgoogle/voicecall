import 'package:flutter/material.dart';

import '../di/service_locator.dart';
import '../interfaces/call_log_repository.dart';
import '../models/call_log_entry.dart';

class CallLogsScreen extends StatefulWidget {
  const CallLogsScreen({super.key});

  @override
  State<CallLogsScreen> createState() => _CallLogsScreenState();
}

class _CallLogsScreenState extends State<CallLogsScreen> {
  final _service = sl<CallLogRepository>();
  List<CallLogEntry> _logs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final logs = await _service.loadLogs();
    if (mounted) setState(() { _logs = logs; _loading = false; });
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear logs?'),
        content: const Text('All call history will be deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Clear', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed == true) {
      await _service.clearLogs();
      if (mounted) setState(() => _logs = []);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) return '${d.inHours}h ${m}m ${s}s';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${s}s';
    return '${d.inSeconds}s';
  }

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final day = DateTime(dt.year, dt.month, dt.day);

    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (day == today) return 'Today, $time';
    if (day == yesterday) return 'Yesterday, $time';
    return '${dt.day}/${dt.month}/${dt.year}, $time';
  }

  String _turnLabel(String turnServer) {
    switch (turnServer) {
      case 'metered':
        return 'Metered';
      case 'expressturn':
        return 'ExpressTURN';
      case 'both':
        return 'Both';
      case 'direct':
        return 'Direct';
      case 'stun':
        return 'STUN';
      case 'turn':
        return 'TURN';
      case 'unknown':
        return 'Unknown';
      default:
        return turnServer;
    }
  }

  /// Icon + colour for the actual connection type used.
  ({IconData icon, Color color}) _turnUsedStyle(String turnUsed) {
    switch (turnUsed) {
      case 'direct':
        return (icon: Icons.bolt, color: Colors.green);
      case 'stun':
        return (icon: Icons.wifi_tethering, color: Colors.blue);
      case 'metered':
      case 'expressturn':
      case 'turn':
        return (icon: Icons.swap_horiz, color: Colors.orange);
      case 'unknown':
      default:
        return (icon: Icons.help_outline, color: Colors.grey);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Call Logs'),
        actions: [
          if (_logs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear all logs',
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history, size: 48, color: Colors.grey),
                      SizedBox(height: 12),
                      Text('No call history',
                          style:
                              TextStyle(fontSize: 16, color: Colors.grey)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadLogs,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _logs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _LogCard(
                      entry: _logs[index],
                      formatBytes: _formatBytes,
                      formatDuration: _formatDuration,
                      formatDateTime: _formatDateTime,
                      turnLabel: _turnLabel,
                      turnUsedStyle: _turnUsedStyle,
                    ),
                  ),
                ),
    );
  }
}

class _LogCard extends StatelessWidget {
  final CallLogEntry entry;
  final String Function(int) formatBytes;
  final String Function(Duration) formatDuration;
  final String Function(DateTime) formatDateTime;
  final String Function(String) turnLabel;
  final ({IconData icon, Color color}) Function(String) turnUsedStyle;

  const _LogCard({
    required this.entry,
    required this.formatBytes,
    required this.formatDuration,
    required this.formatDateTime,
    required this.turnLabel,
    required this.turnUsedStyle,
  });

  @override
  Widget build(BuildContext context) {
    final isCaller = entry.isCaller;
    final roleColor = isCaller ? Colors.blue : Colors.green;
    final roleIcon = isCaller ? Icons.call_made : Icons.call_received;
    final roleLabel = isCaller ? 'Outgoing' : 'Incoming';

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: role + time
            Row(
              children: [
                Icon(roleIcon, color: roleColor, size: 18),
                const SizedBox(width: 6),
                Text(roleLabel,
                    style: TextStyle(
                        color: roleColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                const Spacer(),
                Text(
                  formatDateTime(entry.startedAt),
                  style:
                      const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Remote user + duration
            Row(
              children: [
                const Icon(Icons.person_outline,
                    size: 16, color: Colors.grey),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    entry.remoteUserId,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.timer_outlined,
                    size: 16, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  formatDuration(entry.duration),
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),

            // Data usage row
            Row(
              children: [
                // Sent
                const Icon(Icons.arrow_upward,
                    size: 14, color: Colors.blue),
                const SizedBox(width: 3),
                Text(formatBytes(entry.bytesSent),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                const SizedBox(width: 4),
                const Text('sent',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(width: 16),

                // Received
                const Icon(Icons.arrow_downward,
                    size: 14, color: Colors.green),
                const SizedBox(width: 3),
                Text(formatBytes(entry.bytesReceived),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                const SizedBox(width: 4),
                const Text('received',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),

            // TURN row: selected config + actual connection used
            Row(
              children: [
                // Selected TURN config
                const Text('Config:',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(width: 4),
                _Badge(
                  label: turnLabel(entry.turnServer),
                  color: Colors.grey.shade200,
                  textColor: Colors.black54,
                ),
                const SizedBox(width: 10),
                const Text('Used:',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(width: 4),
                Builder(builder: (_) {
                  final style = turnUsedStyle(entry.turnUsed);
                  final label = turnLabel(entry.turnUsed);
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(style.icon, size: 13, color: style.color),
                      const SizedBox(width: 3),
                      _Badge(
                        label: label,
                        color: style.color.withValues(alpha: 0.12),
                        textColor: style.color,
                      ),
                    ],
                  );
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;

  const _Badge({
    required this.label,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11,
            color: textColor,
            fontWeight: FontWeight.w500),
      ),
    );
  }
}
