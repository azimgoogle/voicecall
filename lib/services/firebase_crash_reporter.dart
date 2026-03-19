import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import '../interfaces/crash_reporter.dart';

/// Firebase Crashlytics adapter for [CrashReporter].
///
/// Swap for a Sentry or no-op implementation by changing only the DI
/// registration in service_locator.dart — no call-site code changes needed.
class FirebaseCrashReporter implements CrashReporter {
  @override
  Future<void> recordError(Object error, StackTrace? stack,
          {String? reason}) =>
      FirebaseCrashlytics.instance
          .recordError(error, stack, reason: reason, fatal: false);

  @override
  void log(String message) => FirebaseCrashlytics.instance.log(message);

  @override
  Future<void> setUserIdentifier(String id) =>
      FirebaseCrashlytics.instance.setUserIdentifier(id);
}
