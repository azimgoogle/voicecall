import 'package:flutter/material.dart';

import 'core/app_bootstrapper.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';

void main() async {
  final hasUserId = await AppBootstrapper.boot();
  runApp(MaterialApp(
    home: hasUserId ? const HomeScreen() : const OnboardingScreen(),
  ));
}
