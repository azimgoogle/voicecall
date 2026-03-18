import 'package:shared_preferences/shared_preferences.dart';

import '../interfaces/settings_repository.dart';

/// SharedPreferences implementation of [SettingsRepository].
///
/// Swap for a remote-API or SQLite implementation without touching any screen.
class SettingsService implements SettingsRepository {
  static const String retentionDaysKey = 'settings_retention_days';
  static const String _whitelistKey = 'settings_whitelist';

  @override
  Future<int> getRetentionDays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(retentionDaysKey) ??
        SettingsRepository.defaultRetentionDays;
  }

  @override
  Future<void> setRetentionDays(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        retentionDaysKey, days.clamp(1, SettingsRepository.maxRetentionDays));
  }

  @override
  Future<List<String>> getWhitelist() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_whitelistKey) ?? [];
  }

  @override
  Future<void> setWhitelist(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_whitelistKey, ids);
  }

  @override
  Future<bool> isAutoAnswer(String userId) async {
    final list = await getWhitelist();
    return list.contains(userId);
  }
}
