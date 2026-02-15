import 'package:flutter/material.dart';

class CallScreen extends StatelessWidget {
  final bool isCaller;
  final VoidCallback onEndCall;

  const CallScreen({
    super.key,
    required this.isCaller,
    required this.onEndCall,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('In Call')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              isCaller ? 'You are calling...' : 'In call...',
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 24),
            if (isCaller)
              ElevatedButton(
                onPressed: onEndCall,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                ),
                child: const Text('End Call', style: TextStyle(fontSize: 20)),
              )
            else
              const Text(
                'Waiting for caller to end the call',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
          ],
        ),
      ),
    );
  }
}
