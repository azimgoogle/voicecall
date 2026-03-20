import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';

import 'core/app_bootstrapper.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/startup_error_screen.dart';

void main() async {
  try {
    final hasUserId = await AppBootstrapper.boot();
    runZonedGuarded(
      () => runApp(MaterialApp(
        home: hasUserId ? const HomeScreen() : const OnboardingScreen(),
      )),
      (error, stack) =>
          FirebaseCrashlytics.instance.recordError(error, stack, fatal: true),
    );
  } catch (_) {
    // Firebase init, DI setup, or foreground service init failed.
    // Show a recovery screen instead of a silent crash.
    runApp(const StartupErrorScreen());
  }
}
