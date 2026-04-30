import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import 'core/app_bootstrapper.dart';
import 'screens/login_screen.dart';
import 'screens/permission_screen.dart';
import 'screens/startup_error_screen.dart';

void main() async {
  // Keep the native splash visible while we initialise Firebase + DI.
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

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
