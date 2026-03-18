import 'package:flutter/material.dart';

import '../di/service_locator.dart';
import '../services/call_log_service.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = sl<SettingsService>();
  final _logService = sl<CallLogService>();

  int _retentionDays = SettingsService.defaultRetentionDays;
  List<String> _whitelist = [];

  /// Unique remote user IDs from recent call logs not already in the whitelist.
  List<String> _suggestions = [];

  bool _loading = true;
  final _addController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final days = await _settings.getRetentionDays();
    final whitelist = await _settings.getWhitelist();
    final logs = await _logService.loadLogs();

    // Unique remote user IDs from logs, excluding those already whitelisted.
    final seen = <String>{};
    final suggestions = <String>[];
    for (final log in logs) {
      if (seen.add(log.remoteUserId) && !whitelist.contains(log.remoteUserId)) {
        suggestions.add(log.remoteUserId);
      }
    }

    if (mounted) {
      setState(() {
        _retentionDays = days;
        _whitelist = List<String>.from(whitelist);
        _suggestions = suggestions;
        _loading = false;
      });
    }
  }

  Future<void> _saveRetention(int days) async {
    await _settings.setRetentionDays(days);
  }

  Future<void> _addToWhitelist(String id) async {
    final trimmed = id.trim();
    if (trimmed.isEmpty || _whitelist.contains(trimmed)) return;
    final updated = [..._whitelist, trimmed];
    await _settings.setWhitelist(updated);
    setState(() {
      _whitelist = updated;
      _suggestions.remove(trimmed);
      _addController.clear();
    });
  }

  Future<void> _removeFromWhitelist(String id) async {
    final updated = _whitelist.where((e) => e != id).toList();
    await _settings.setWhitelist(updated);
    setState(() {
      _whitelist = updated;
      if (!_suggestions.contains(id)) _suggestions.insert(0, id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // ── Call Log Retention ──────────────────────────────────
                Text('Call Log Retention',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Keep logs for $_retentionDays '
                  '${_retentionDays == 1 ? 'day' : 'days'} (max 30)',
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
                Slider(
                  value: _retentionDays.toDouble(),
                  min: 1,
                  max: 30,
                  divisions: 29,
                  label: '$_retentionDays d',
                  onChanged: (v) =>
                      setState(() => _retentionDays = v.round()),
                  onChangeEnd: (v) => _saveRetention(v.round()),
                ),

                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 20),

                // ── Auto-Answer Whitelist ───────────────────────────────
                Text('Auto-Answer Whitelist',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                const Text(
                  'Calls from these IDs are answered automatically. '
                  'All others show an Answer button.',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 16),

                // Current whitelist entries
                if (_whitelist.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('No IDs in whitelist.',
                        style: TextStyle(color: Colors.grey, fontSize: 13)),
                  )
                else
                  ..._whitelist.map((id) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.person_outline),
                        title: Text(id),
                        trailing: IconButton(
                          icon: const Icon(Icons.remove_circle_outline,
                              color: Colors.red),
                          tooltip: 'Remove',
                          onPressed: () => _removeFromWhitelist(id),
                        ),
                      )),

                const SizedBox(height: 8),

                // Add ID row
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _addController,
                        decoration: const InputDecoration(
                          labelText: 'Add user ID',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: _addToWhitelist,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => _addToWhitelist(_addController.text),
                      child: const Text('Add'),
                    ),
                  ],
                ),

                // Suggestions from recent call logs
                if (_suggestions.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Text(
                    'Suggestions from recent calls:',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: _suggestions
                        .map((id) => ActionChip(
                              avatar: const Icon(Icons.add, size: 16),
                              label: Text(id),
                              onPressed: () => _addToWhitelist(id),
                            ))
                        .toList(),
                  ),
                ],
              ],
            ),
    );
  }
}
