import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../di/service_locator.dart';
import '../interfaces/auth_repository.dart';
import '../interfaces/remote_config_repository.dart';
import '../services/foreground_service.dart';

/// Encapsulates all one-time startup tasks that must complete before [runApp].
///
/// Keeping these steps out of [main] makes them independently testable and
/// prevents the entry-point from accumulating unrelated concerns over time.
abstract final class AppBootstrapper {
  /// Runs the full startup sequence and returns whether the user is already
  /// signed in via Firebase Auth.
  ///
  /// Sequence:
  ///   1. Ensure Flutter bindings are initialised.
  ///   2. Initialise Firebase.
  ///   3. Enable Crashlytics and wire global error hooks.
  ///   4. Register all services in the DI container.
  ///   5. Configure the foreground service notification channel.
  ///   6. Check FirebaseAuth for an existing signed-in user.
  static Future<bool> boot() async {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp();

    // On iOS/macOS, show notification banner + play sound when app is in
    // foreground. On Android, the onMessage stream handles foreground delivery.
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // Enable Crashlytics crash collection (no-op in debug if disabled there).
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(
      !kDebugMode,
    );

    // Catch Flutter framework / widget-tree errors (e.g. overflow, null layout).
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;

    // Catch async errors thrown outside the Flutter zone (Platform channels,
    // dart:isolate, timer callbacks that escape the zone, etc.).
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };

    setupServiceLocator();
    initForegroundService();

    // Fetch Remote Config values early so they are ready before any call.
    // fetchAndActivate() never throws — failures fall back to in-app defaults.
    await sl<RemoteConfigRepository>().fetchAndActivate();

    final hasUser = FirebaseAuth.instance.currentUser != null;

    // Re-sync the RTDB handle↔UID mapping on every launch so returning users
    // (especially Google sign-in users) are always discoverable by handle,
    // even if the original post-sign-in write failed (offline, rules, etc.).
    if (hasUser) {
      await sl<AuthRepository>().syncProfile();
    }

    return hasUser;
  }
}
