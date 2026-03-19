/// Abstract reporting layer for runtime crashes and non-fatal errors.
///
/// Implementations may use Firebase Crashlytics, Sentry, or any other
/// crash-reporting backend without touching any screen or use-case code.
abstract class CrashReporter {
  /// Records a non-fatal [error] with an optional [stack] and [reason] label.
  Future<void> recordError(Object error, StackTrace? stack, {String? reason});

  /// Appends a breadcrumb [message] to the current session's log.
  void log(String message);

  /// Associates subsequent reports with [id] (e.g., the app's userId).
  Future<void> setUserIdentifier(String id);

  /// Attaches a key-value pair to every subsequent report in this session.
  ///
  /// [value] must be a bool, int, double, or String.
  void setCustomKey(String key, Object value);
}
