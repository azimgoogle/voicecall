/// Fallback retention when no user preference has been saved yet.
const int kCallLogRetentionDays = 7;

/// A single call log entry. Pure Dart — no dependency on any service or library.
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
