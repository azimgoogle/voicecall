import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'di/service_locator.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/foreground_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  setupServiceLocator();
  initForegroundService();

  // Show onboarding only on first launch (no userId saved yet)
  final prefs = await SharedPreferences.getInstance();
  final hasUserId = prefs.getString('userId') != null;

  runApp(MaterialApp(
    home: hasUserId ? const HomeScreen() : const OnboardingScreen(),
  ));
}
