import '../models/call_log_entry.dart';

/// Abstract persistence layer for call history.
///
/// Implementations may use SharedPreferences, SQLite, a remote API, etc.
abstract class CallLogRepository {
  Future<List<CallLogEntry>> loadLogs();

  Future<void> saveEntry(CallLogEntry entry);

  Future<void> clearLogs();
}
