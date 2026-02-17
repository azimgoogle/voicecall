import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'screens/home_screen.dart';
import 'services/foreground_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  initForegroundService();
  runApp(const MaterialApp(home: HomeScreen()));
}
