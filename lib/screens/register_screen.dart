import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../di/service_locator.dart';
import '../interfaces/auth_repository.dart';
import 'permission_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _auth = sl<AuthRepository>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _setError(Object e) {
    String msg = 'Registration failed. Please try again.';
    if (e is FirebaseAuthException) {
      msg = switch (e.code) {
        'email-already-in-use' => 'An account already exists for this email.',
        'weak-password' => 'Password is too weak (min 6 characters).',
        'invalid-email' => 'Please enter a valid email address.',
        'network-request-failed' => 'No internet connection.',
        _ => e.message ?? msg,
      };
    }
    if (mounted) setState(() => _errorMessage = msg);
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      await _auth.registerWithEmail(
        _emailCtrl.text.trim(),
        _passwordCtrl.text,
      );
      _navigatePermissions();
    } catch (e) {
      _setError(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _navigatePermissions() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const PermissionScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Account')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Email
                  TextFormField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Please enter your email';
                      if (!v.contains('@')) return 'Enter a valid email';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Password
                  TextFormField(
                    controller: _passwordCtrl,
                    obscureText: true,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Please enter a password';
                      if (v.length < 6) return 'Password must be at least 6 characters';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Confirm password
                  TextFormField(
                    controller: _confirmCtrl,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _register(),
                    decoration: const InputDecoration(
                      labelText: 'Confirm Password',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) {
                      if (v != _passwordCtrl.text) return 'Passwords do not match';
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),

                  if (_errorMessage != null) ...[
                    Text(
                      _errorMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.red),
                    ),
                    const SizedBox(height: 12),
                  ],

                  ElevatedButton(
                    onPressed: _loading ? null : _register,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Create Account'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
