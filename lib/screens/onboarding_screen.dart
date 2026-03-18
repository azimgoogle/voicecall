import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../di/service_locator.dart';
import '../interfaces/signaling_service.dart';
import 'home_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = TextEditingController();
  final _firebase = sl<SignalingService>();

  bool _checking = false;
  String? _errorText;

  static const int _minLength = 4;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final id = _controller.text.trim();

    // Local validation first — no network call needed
    if (id.length < _minLength) {
      setState(() =>
          _errorText = 'ID must be at least $_minLength characters.');
      return;
    }

    setState(() {
      _checking = true;
      _errorText = null;
    });

    // Firebase existence check
    final taken = await _firebase.isUserIdTaken(id);

    if (!mounted) return;

    if (taken) {
      setState(() {
        _checking = false;
        _errorText = 'That ID is already taken. Please choose another.';
      });
      return;
    }

    // Persist and navigate
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('userId', id);

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon + title
                const Icon(Icons.phone_in_talk,
                    size: 72, color: Colors.deepPurple),
                const SizedBox(height: 16),
                const Text(
                  'Voice Call POC',
                  style: TextStyle(
                      fontSize: 26, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Choose your unique ID to get started.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: Colors.grey),
                ),
                const SizedBox(height: 40),

                // ID input
                TextField(
                  controller: _controller,
                  enabled: !_checking,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _checking ? null : _submit(),
                  decoration: InputDecoration(
                    labelText: 'Your ID',
                    hintText: 'e.g. alice, bob_123',
                    helperText:
                        'At least $_minLength characters. Must be unique.',
                    errorText: _errorText,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 24),

                // Submit button
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _checking ? null : _submit,
                    child: _checking
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Continue',
                            style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
