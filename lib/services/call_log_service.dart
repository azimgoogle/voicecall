import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Fallback retention when no user preference is saved yet.
const int kCallLogRetentionDays = 7;

/// A single call log entry.
class CallLogEntry {
  final String callId;
  final String role; // 'caller' | 'callee'
  final String remoteUserId;
  final String turnServer; // 'metered' | 'expressturn' | 'both' — selected by caller
  final String turnUsed;   // actual relay used: 'metered' | 'expressturn' | 'direct' | 'stun' | 'unknown'
  final DateTime startedAt;
  final DateTime? endedAt;
  final int bytesSent;
  final int bytesReceived;

  CallLogEntry({
    required this.callId,
    required this.role,
    required this.remoteUserId,
    required this.turnServer,
    this.turnUsed = 'unknown',
    required this.startedAt,
    this.endedAt,
    this.bytesSent = 0,
    this.bytesReceived = 0,
  });

  Duration get duration =>
      (endedAt ?? DateTime.now()).difference(startedAt);

  bool get isCaller => role == 'caller';

  Map<String, dynamic> toJson() => {
        'callId': callId,
        'role': role,
        'remoteUserId': remoteUserId,
        'turnServer': turnServer,
        'turnUsed': turnUsed,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'bytesSent': bytesSent,
        'bytesReceived': bytesReceived,
      };

  factory CallLogEntry.fromJson(Map<String, dynamic> json) => CallLogEntry(
        callId: json['callId'] as String,
        role: json['role'] as String,
        remoteUserId: json['remoteUserId'] as String,
        turnServer: json['turnServer'] as String? ?? 'both',
        turnUsed: json['turnUsed'] as String? ?? 'unknown',
        startedAt: DateTime.parse(json['startedAt'] as String),
        endedAt: json['endedAt'] != null
            ? DateTime.parse(json['endedAt'] as String)
            : null,
        bytesSent: json['bytesSent'] as int? ?? 0,
        bytesReceived: json['bytesReceived'] as int? ?? 0,
      );

  /// Returns a copy with updated fields.
  CallLogEntry copyWith({
    DateTime? endedAt,
    int? bytesSent,
    int? bytesReceived,
    String? turnUsed,
  }) =>
      CallLogEntry(
        callId: callId,
        role: role,
        remoteUserId: remoteUserId,
        turnServer: turnServer,
        turnUsed: turnUsed ?? this.turnUsed,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        bytesSent: bytesSent ?? this.bytesSent,
        bytesReceived: bytesReceived ?? this.bytesReceived,
      );
}

/// Persists and retrieves call logs via SharedPreferences.
/// Retention window is read dynamically from user settings.
class CallLogService {
  static const String _prefsKey = 'call_logs';

  /// Reads the user-configured retention days. Falls back to [kCallLogRetentionDays].
  Future<int> _getRetentionDays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('settings_retention_days') ?? kCallLogRetentionDays;
  }

  /// Load all logs within the retention window, sorted newest first.
  Future<List<CallLogEntry>> loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return [];

    final retentionDays = await _getRetentionDays();
    final List<dynamic> jsonList = jsonDecode(raw);
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));

    return jsonList
        .map((e) => CallLogEntry.fromJson(e as Map<String, dynamic>))
        .where((entry) => entry.startedAt.isAfter(cutoff))
        .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }

  /// Persist a new or updated entry, then prune expired entries.
  Future<void> saveEntry(CallLogEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await loadLogs();
    final retentionDays = await _getRetentionDays();

    // Replace if same callId exists (e.g. updating with end time + bytes)
    final updated = [
      entry,
      ...existing.where((e) => e.callId != entry.callId),
    ];

    // Prune anything beyond the retention window
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    final pruned =
        updated.where((e) => e.startedAt.isAfter(cutoff)).toList();

    await prefs.setString(
        _prefsKey, jsonEncode(pruned.map((e) => e.toJson()).toList()));
  }

  /// Clear all stored logs.
  Future<void> clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
