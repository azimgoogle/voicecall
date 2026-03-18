import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../di/service_locator.dart';
import '../services/foreground_service.dart';

/// Encapsulates all one-time startup tasks that must complete before [runApp].
///
/// Keeping these steps out of [main] makes them independently testable and
/// prevents the entry-point from accumulating unrelated concerns over time.
abstract final class AppBootstrapper {
  /// Runs the full startup sequence and returns whether the user has already
  /// completed onboarding (i.e., a userId has been persisted).
  ///
  /// Sequence:
  ///   1. Ensure Flutter bindings are initialised.
  ///   2. Initialise Firebase.
  ///   3. Register all services in the DI container.
  ///   4. Configure the foreground service notification channel.
  ///   5. Check SharedPreferences for an existing userId.
  static Future<bool> boot() async {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp();
    setupServiceLocator();
    initForegroundService();

    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('userId') != null;
  }
}
