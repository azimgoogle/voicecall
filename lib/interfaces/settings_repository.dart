/// Abstract persistence layer for user settings.
///
/// Implementations may use SharedPreferences, SQLite, a remote API, etc.
abstract class SettingsRepository {
  static const int defaultRetentionDays = 7;
  static const int maxRetentionDays = 30;

  Future<int> getRetentionDays();

  Future<void> setRetentionDays(int days);

  Future<List<String>> getWhitelist();

  Future<void> setWhitelist(List<String> ids);

  /// Returns true if [userId] is in the auto-answer whitelist.
  Future<bool> isAutoAnswer(String userId);
}
