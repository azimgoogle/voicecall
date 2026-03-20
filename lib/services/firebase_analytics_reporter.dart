import 'package:firebase_analytics/firebase_analytics.dart';

import '../interfaces/analytics_repository.dart';

/// Concrete analytics adapter backed by [FirebaseAnalytics].
///
/// To swap to a different backend, replace this class and update the DI
/// registration in service_locator.dart — no call-site changes required.
class FirebaseAnalyticsReporter implements AnalyticsRepository {
  final _analytics = FirebaseAnalytics.instance;

  @override
  Future<void> logEvent(String name, {Map<String, Object>? parameters}) =>
      _analytics.logEvent(name: name, parameters: parameters);

  @override
  Future<void> setUserId(String userId) => _analytics.setUserId(id: userId);
}
