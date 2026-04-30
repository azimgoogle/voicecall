import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import 'core/app_bootstrapper.dart';
import 'screens/login_screen.dart';
import 'screens/permission_screen.dart';
import 'screens/startup_error_screen.dart';

/// Handles FCM messages arriving while the app is terminated or backgrounded.
/// Must be a top-level function so FCM can invoke it in a separate isolate.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Notification messages are displayed automatically by the FCM SDK.
  // Data-only messages can be acted on here when needed.
}

void main() async {
  // Binding must be initialised before any platform channel calls, including
  // FirebaseMessaging.onBackgroundMessage which sets a MethodChannel handler.
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  try {
    final hasUserId = await AppBootstrapper.boot();
    // All async init done — dismiss the splash before rendering the first frame.
    FlutterNativeSplash.remove();
    runZonedGuarded(
      () => runApp(MaterialApp(
        home: hasUserId ? const PermissionScreen() : const LoginScreen(),
      )),
      (error, stack) =>
          FirebaseCrashlytics.instance.recordError(error, stack, fatal: true),
    );
  } catch (_) {
    // Firebase init, DI setup, or foreground service init failed.
    // Dismiss splash and show a recovery screen instead of a silent crash.
    FlutterNativeSplash.remove();
    runApp(const StartupErrorScreen());
  }
}
