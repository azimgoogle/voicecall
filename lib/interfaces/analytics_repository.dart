/// Abstract analytics port.
///
/// All product-metric events are logged through this interface.
/// Inject the concrete implementation via DI — swapping backends
/// (e.g. Firebase → Mixpanel) requires changing only the DI registration.
abstract class AnalyticsRepository {
  /// Log a named event with optional key-value parameters.
  ///
  /// [name] must be a valid analytics event name (snake_case, ≤ 40 chars).
  /// [parameters] values must be [String], [int], [double], or [bool].
  Future<void> logEvent(String name, {Map<String, Object>? parameters});

  /// Associate subsequent events with [userId].
  ///
  /// Call once after the user is identified (e.g. on [HomeViewModel.init]).
  Future<void> setUserId(String userId);
}
