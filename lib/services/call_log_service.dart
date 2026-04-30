import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../interfaces/call_log_repository.dart';
import '../models/call_log_entry.dart';

export '../models/call_log_entry.dart';

/// SharedPreferences implementation of [CallLogRepository].
///
/// Swap for a SQLite or remote-API implementation without touching any screen.
class CallLogService implements CallLogRepository {
  static const String _prefsKey = 'call_logs';

  Future<int> _getRetentionDays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('settings_retention_days') ?? kCallLogRetentionDays;
  }

  @override
  Future<List<CallLogEntry>> loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return [];

    try {
      final retentionDays = await _getRetentionDays();
      final List<dynamic> jsonList = jsonDecode(raw);
      final cutoff = DateTime.now().subtract(Duration(days: retentionDays));

      return jsonList
          .map((e) => CallLogEntry.fromJson(e as Map<String, dynamic>))
          .where((entry) => entry.startedAt.isAfter(cutoff))
          .toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    } catch (e) {
      // Stored JSON is corrupted (e.g. mid-write crash). Clear it so the
      // next launch doesn't crash again, and return empty list gracefully.
      debugPrint('CallLogService: corrupted log data cleared — $e');
      await prefs.remove(_prefsKey);
      return [];
    }
  }

  @override
  Future<void> saveEntry(CallLogEntry entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await loadLogs();
      final retentionDays = await _getRetentionDays();

      final updated = [
        entry,
        ...existing.where((e) => e.callId != entry.callId),
      ];

      final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
      final pruned =
          updated.where((e) => e.startedAt.isAfter(cutoff)).toList();

      await prefs.setString(
          _prefsKey, jsonEncode(pruned.map((e) => e.toJson()).toList()));
    } catch (e) {
      debugPrint('CallLogService: failed to save log entry — $e');
    }
  }

  @override
  Future<void> clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
