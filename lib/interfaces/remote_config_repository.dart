/// Abstract port for runtime configuration values fetched from a remote source.
///
/// The concrete implementation uses Firebase Remote Config; swapping to another
/// backend (LaunchDarkly, custom API, etc.) requires changing only the DI
/// registration in [service_locator.dart].
abstract class RemoteConfigRepository {
  /// Fetches the latest values from the remote source and activates them.
  ///
  /// Should be called once during app startup. The implementation must not
  /// throw — failures should be swallowed so the app starts with defaults.
  Future<void> fetchAndActivate();

  /// Returns the maximum number of outgoing call minutes allowed per user
  /// per ISO week (Monday–Sunday).
  ///
  /// A value of **0** means no limit is enforced.
  /// The Remote Config key is `weekly_call_limit_minutes`; the in-app default
  /// is [defaultWeeklyLimitMinutes] in case the fetch has never succeeded.
  int getWeeklyCallLimitMinutes();

  /// Returns whether the TURN server selector UI should be shown.
  ///
  /// Intended for internal / QA builds only — hide from regular users.
  /// The Remote Config key is `turn_selector_enabled`; the in-app default
  /// is [defaultTurnSelectorEnabled] (false = hidden for everyone).
  ///
  /// ## Firebase Console setup
  /// 1. Add parameter `turn_selector_enabled` (Boolean, default = false).
  /// 2. Add a condition targeting your internal tester user property
  ///    (e.g. `user_property: internal_tester = true`) and set it to true.
  /// 3. Publish — testers on any build type see the selector; regular users never do.
  bool isTurnSelectorEnabled();

  /// The in-app fallback used when Remote Config has never been fetched.
  static const int defaultWeeklyLimitMinutes = 100;

  /// The in-app fallback for the TURN selector flag.
  static const bool defaultTurnSelectorEnabled = false;
}
