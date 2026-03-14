import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const String retentionDaysKey = 'settings_retention_days';
  static const String _whitelistKey = 'settings_whitelist';

  static const int defaultRetentionDays = 7;
  static const int maxRetentionDays = 30;

  Future<int> getRetentionDays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(retentionDaysKey) ?? defaultRetentionDays;
  }

  Future<void> setRetentionDays(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(retentionDaysKey, days.clamp(1, maxRetentionDays));
  }

  Future<List<String>> getWhitelist() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_whitelistKey) ?? [];
  }

  Future<void> setWhitelist(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_whitelistKey, ids);
  }

  /// Returns true if [userId] is in the auto-answer whitelist.
  Future<bool> isAutoAnswer(String userId) async {
    final list = await getWhitelist();
    return list.contains(userId);
  }
}
