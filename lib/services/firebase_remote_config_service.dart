import 'package:firebase_remote_config/firebase_remote_config.dart';

import '../interfaces/remote_config_repository.dart';

/// Firebase Remote Config implementation of [RemoteConfigRepository].
///
/// ## Remote Config key
/// | Key                        | Type | Default |
/// |----------------------------|------|---------|
/// | `weekly_call_limit_minutes`| int  | 100     |
///
/// Set the value to **0** to disable the weekly limit for any condition.
///
/// ## Country-based conditions (Firebase Console)
/// 1. Open Remote Config → Add condition → "Country/Region is…"
/// 2. Target the desired ISO-3166-1 alpha-2 codes (e.g. "BD", "SA").
/// 3. Assign the per-country value for `weekly_call_limit_minutes`.
/// 4. Publish changes — clients pick them up on next fetch (≤1 h cache).
///
/// ## A/B testing
/// If you want to *experiment* with different limits rather than target by
/// country, use Firebase A/B Testing (built on Remote Config) to randomly
/// split users across variants and measure the impact on call-funnel events.
/// Firebase Remote Config implementation of [RemoteConfigRepository].
///
/// ## Remote Config keys
/// | Key                        | Type    | Default |
/// |----------------------------|---------|---------|
/// | `weekly_call_limit_minutes`| int     | 100     |
/// | `turn_selector_enabled`    | boolean | false   |
///
/// Set `weekly_call_limit_minutes` to **0** to disable the weekly limit for
/// any condition (e.g. internal testers, specific countries).
///
/// Set `turn_selector_enabled` to **true** only for internal tester conditions
/// (e.g. user property `internal_tester = true`) — never as the default.
class FirebaseRemoteConfigService implements RemoteConfigRepository {
  static const String _weeklyLimitKey    = 'weekly_call_limit_minutes';
  static const String _turnSelectorKey   = 'turn_selector_enabled';

  final FirebaseRemoteConfig _config;

  FirebaseRemoteConfigService()
      : _config = FirebaseRemoteConfig.instance;

  @override
  Future<void> fetchAndActivate() async {
    try {
      await _config.setDefaults({
        _weeklyLimitKey  : RemoteConfigRepository.defaultWeeklyLimitMinutes,
        _turnSelectorKey : RemoteConfigRepository.defaultTurnSelectorEnabled,
      });
      await _config.setConfigSettings(RemoteConfigSettings(
        // In production, Firebase enforces a minimum of 1 hour between fetches.
        // Use Duration.zero in debug to allow rapid iteration.
        fetchTimeout: const Duration(seconds: 10),
        minimumFetchInterval: const Duration(hours: 1),
      ));
      await _config.fetchAndActivate();
    } catch (_) {
      // Network unavailable or quota exceeded — the in-app default stays active.
    }
  }

  @override
  int getWeeklyCallLimitMinutes() => _config.getInt(_weeklyLimitKey);

  @override
  bool isTurnSelectorEnabled() => _config.getBool(_turnSelectorKey);
}
