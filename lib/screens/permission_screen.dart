import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'home_screen.dart';

/// Explains why each runtime permission is needed and requests them from the user.
///
/// Shown once after onboarding. For returning users, [HomeScreen] handles the
/// case where the microphone permission is still missing.
class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    _checkAlreadyGranted();
  }

  /// If microphone is already granted, skip straight to HomeScreen
  /// without showing any UI — this handles returning users on every launch.
  Future<void> _checkAlreadyGranted() async {
    final micGranted = await Permission.microphone.isGranted;
    if (micGranted && mounted) _navigateHome();
  }

  Future<void> _requestPermissions() async {
    setState(() => _requesting = true);

    final statuses = await [
      Permission.microphone,
      Permission.notification,
    ].request();

    if (!mounted) return;

    final micGranted =
        statuses[Permission.microphone]?.isGranted ?? false;
    final micPermanentlyDenied =
        statuses[Permission.microphone]?.isPermanentlyDenied ?? false;

    if (micPermanentlyDenied) {
      // Microphone is permanently denied — user must go to Settings.
      setState(() => _requesting = false);
      await _showPermanentlyDeniedDialog();
      return;
    }

    if (!micGranted) {
      // Denied but not permanently — show a warning and let them continue.
      setState(() => _requesting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
            'Microphone access is required to make calls. '
            'You can grant it in Settings.',
          ),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 4),
        ));
      }
    }

    _navigateHome();
  }

  Future<void> _showPermanentlyDeniedDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Microphone Access Required'),
        content: const Text(
          'You have permanently denied microphone access. '
          'Without it this app cannot make or receive calls.\n\n'
          'Please open Settings and enable the Microphone permission '
          'for this app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Not Now'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
    if (mounted) _navigateHome();
  }

  void _navigateHome() {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Icon(Icons.security_rounded,
                  size: 48, color: colorScheme.primary),
              const SizedBox(height: 16),
              const Text(
                'Permissions Needed',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'This app needs the following permissions to work correctly. '
                'We never record or store your audio.',
                style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 32),

              // Microphone card
              _PermissionCard(
                icon: Icons.mic_rounded,
                color: Colors.deepPurple,
                title: 'Microphone',
                description:
                    'Required to transmit your voice during calls. '
                    'Without this permission you cannot speak '
                    'and calls will fail.',
                required: true,
              ),
              const SizedBox(height: 16),

              // Notifications card
              _PermissionCard(
                icon: Icons.notifications_active_rounded,
                color: Colors.orange,
                title: 'Notifications',
                description:
                    'Allows the app to show an ongoing notification while '
                    'a call is active, and keeps the call alive when the '
                    'screen is off. Required on Android 13 and above.',
                required: false,
              ),

              const Spacer(),

              // Grant button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _requesting ? null : _requestPermissions,
                  child: _requesting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.white),
                        )
                      : const Text('Grant Permissions',
                          style: TextStyle(fontSize: 16)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: _requesting ? null : _navigateHome,
                  child: const Text('Skip for now'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
    required this.required,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String description;
  final bool required;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withAlpha(26),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    if (required) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('Required',
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.red.shade700,
                                fontWeight: FontWeight.w500)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(description,
                    style: TextStyle(
                        fontSize: 13, color: Colors.grey.shade600,
                        height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
