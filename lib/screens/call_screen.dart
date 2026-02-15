import 'package:flutter/material.dart';

class CallScreen extends StatelessWidget {
  final VoidCallback onEndCall;

  const CallScreen({
    super.key,
    required this.onEndCall,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('In Call')),
      body: Center(
        child: ElevatedButton(
          onPressed: onEndCall,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
          ),
          child: const Text('End Call', style: TextStyle(fontSize: 20)),
        ),
      ),
    );
  }
}
