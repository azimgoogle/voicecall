import 'package:flutter/material.dart';

import '../core/app_bootstrapper.dart';
import 'home_screen.dart';
import 'login_screen.dart';

/// Shown when [AppBootstrapper.boot] throws on startup (e.g. Firebase init
/// failed due to a missing config file or no network on first launch).
///
/// The user can tap Retry to attempt startup again without restarting the app.
class StartupErrorScreen extends StatefulWidget {
  const StartupErrorScreen({super.key});

  @override
  State<StartupErrorScreen> createState() => _StartupErrorScreenState();
}

class _StartupErrorScreenState extends State<StartupErrorScreen> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      final hasUserId = await AppBootstrapper.boot();
      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) =>
              hasUserId ? const HomeScreen() : const LoginScreen(),
        ));
      }
    } catch (_) {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 64, color: Colors.grey),
                const SizedBox(height: 24),
                const Text(
                  'Unable to connect',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Could not reach the server. Please check your internet '
                  'connection and try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: Colors.grey),
                ),
                const SizedBox(height: 32),
                _retrying
                    ? const CircularProgressIndicator()
                    : ElevatedButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
