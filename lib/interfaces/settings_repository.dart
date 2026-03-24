/// Abstract persistence layer for user settings.
///
/// Implementations may use SharedPreferences, SQLite, a remote API, etc.
abstract class SettingsRepository {
  static const int defaultRetentionDays = 7;
  static const int maxRetentionDays = 30;

  /// Total call minutes granted to anonymous (guest) users before upsell.
  static const int anonGuestMinutesAllowed = 100;

  Future<int> getRetentionDays();

  Future<void> setRetentionDays(int days);

  Future<List<String>> getWhitelist();

  Future<void> setWhitelist(List<String> ids);

  /// Returns true if [userId] is in the auto-answer whitelist.
  Future<bool> isAutoAnswer(String userId);

  /// Returns the total call seconds accumulated by the anonymous guest user.
  Future<int> getAnonSecondsUsed();

  /// Adds [seconds] to the anonymous guest usage counter.
  Future<void> addAnonSeconds(int seconds);
}
