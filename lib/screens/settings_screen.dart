import 'dart:math' show max;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../di/service_locator.dart';
import '../interfaces/call_log_repository.dart';
import '../interfaces/remote_config_repository.dart';
import '../interfaces/settings_repository.dart';
import 'login_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = sl<SettingsRepository>();
  final _logService = sl<CallLogRepository>();
  final _remoteConfig = sl<RemoteConfigRepository>();

  int _retentionDays = SettingsRepository.defaultRetentionDays;
  List<String> _whitelist = [];
  int _weeklyUsedMinutes = 0;
  int _weeklyLimitMinutes = RemoteConfigRepository.defaultWeeklyLimitMinutes;
  bool _isAnonymous = false;
  int _anonSecondsUsed = 0;

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

    // Compute weekly usage from outgoing (caller) calls in current ISO week.
    final now = DateTime.now();
    final weekStart = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    final weeklySeconds = logs
        .where((e) => e.role == 'caller' && !e.startedAt.isBefore(weekStart))
        .fold<int>(0, (sum, e) => sum + e.duration.inSeconds);
    final weeklyUsed = weeklySeconds ~/ 60;

    // Unique remote handles from logs, excluding those already whitelisted.
    final seen = <String>{};
    final suggestions = <String>[];
    for (final log in logs) {
      if (seen.add(log.remoteUserId) && !whitelist.contains(log.remoteUserId)) {
        suggestions.add(log.remoteUserId);
      }
    }

    final firebaseUser = FirebaseAuth.instance.currentUser;
    final isAnonymous = firebaseUser?.isAnonymous ?? false;
    final anonSecondsUsed =
        isAnonymous ? await _settings.getAnonSecondsUsed() : 0;

    if (mounted) {
      setState(() {
        _retentionDays = days;
        _whitelist = List<String>.from(whitelist);
        _suggestions = suggestions;
        _weeklyUsedMinutes = weeklyUsed;
        _weeklyLimitMinutes = _remoteConfig.getWeeklyCallLimitMinutes();
        _isAnonymous = isAnonymous;
        _anonSecondsUsed = anonSecondsUsed;
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
    final unlimited = _weeklyLimitMinutes == 0;
    final atLimit = !unlimited && _weeklyUsedMinutes >= _weeklyLimitMinutes;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // ── Guest Trial Upsell (anonymous + limit enabled) ─────
                if (_isAnonymous && !unlimited) ...[
                  _AnonUpsellCard(
                    anonSecondsUsed: _anonSecondsUsed,
                    onRegister: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 20),
                ],

                // ── Weekly Call Usage (hidden when unlimited) ───────────
                if (!unlimited) ...[
                  Text('Weekly Call Usage',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text(
                    'Outgoing calls only. Resets every Monday.',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (_weeklyUsedMinutes / _weeklyLimitMinutes)
                          .clamp(0.0, 1.0),
                      minHeight: 8,
                      backgroundColor: Colors.grey.shade200,
                      color: atLimit ? Colors.red : Colors.blue,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$_weeklyUsedMinutes / $_weeklyLimitMinutes min used',
                    style: TextStyle(
                      fontSize: 13,
                      color: atLimit ? Colors.red : Colors.grey.shade700,
                      fontWeight:
                          atLimit ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 20),
                ],

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
                  'Calls from these handle addresses are answered automatically. '
                  'All others show an Answer button.',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 16),

                // Current whitelist entries
                if (_whitelist.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('No handles in whitelist.',
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
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Add handle',
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

// ── Anonymous guest upsell card ───────────────────────────────────────────────

class _AnonUpsellCard extends StatelessWidget {
  const _AnonUpsellCard({
    required this.anonSecondsUsed,
    required this.onRegister,
  });

  final int anonSecondsUsed;
  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) {
    const total = SettingsRepository.anonGuestMinutesAllowed;
    final usedMinutes = anonSecondsUsed ~/ 60;
    final remaining = max(0, total - usedMinutes);
    final progress = (usedMinutes / total).clamp(0.0, 1.0);
    final atLimit = remaining == 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: atLimit ? Colors.red.shade50 : Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: atLimit ? Colors.red.shade200 : Colors.orange.shade200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.card_giftcard,
                color: atLimit ? Colors.red.shade700 : Colors.orange.shade700,
                size: 20),
            const SizedBox(width: 8),
            Text(
              'Guest Trial',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color:
                    atLimit ? Colors.red.shade700 : Colors.orange.shade700,
              ),
            ),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.grey.shade200,
              color: atLimit ? Colors.red : Colors.orange,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            atLimit
                ? 'All $total guest minutes used.'
                : '$remaining of $total guest minutes remaining.',
            style: TextStyle(
              fontSize: 13,
              color: atLimit ? Colors.red.shade700 : Colors.grey.shade700,
              fontWeight: atLimit ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Create a free account and get 100 extra minutes as a welcome bonus.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onRegister,
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: const Text('Create Free Account'),
            ),
          ),
        ],
      ),
    );
  }
}
