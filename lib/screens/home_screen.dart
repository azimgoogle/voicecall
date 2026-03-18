import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../di/service_locator.dart';
import '../models/call_state.dart';
import '../viewmodels/home_view_model.dart';
import 'call_logs_screen.dart';
import 'call_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HomeViewModel _viewModel;
  final _remoteIdController = TextEditingController();
  final _callScreenKey = GlobalKey<CallScreenState>();

  String _myUserId = '';
  String _selectedTurnServer = 'both';

  late StreamSubscription<HomeEvent> _eventsSub;

  @override
  void initState() {
    super.initState();
    _viewModel = sl<HomeViewModel>();
    _remoteIdController.addListener(() => setState(() {}));
    _initAsync();
  }

  Future<void> _initAsync() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('userId')!;
    final lastRemoteId = await _viewModel.loadLastRemoteId();

    if (mounted) {
      setState(() {
        _myUserId = userId;
        _remoteIdController.text = lastRemoteId;
      });
    }

    await _viewModel.init(userId);
    FlutterForegroundTask.addTaskDataCallback(_onForegroundData);
    _eventsSub = _viewModel.events.listen(_onEvent);
  }

  /// Receives action IDs forwarded from the foreground notification buttons.
  void _onForegroundData(Object data) {
    if (data == 'end_call') {
      _viewModel.endCall();
    } else if (data == 'mute') {
      _viewModel.applyMute(true);
    } else if (data == 'unmute') {
      _viewModel.applyMute(false);
    }
  }

  /// Handles one-shot events that require Scaffold context.
  void _onEvent(HomeEvent event) {
    switch (event) {
      case HomeEvent.remoteDisconnected:
        _callScreenKey.currentState?.notifyRemoteDisconnected();
        if (_callScreenKey.currentState == null) {
          _viewModel.endCall();
        }

      case HomeEvent.calleeBusy:
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${_remoteIdController.text.trim()} is busy.'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 3),
          ));
        }

      case HomeEvent.callTimeout:
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No answer. Call ended.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ));
        }
    }
  }

  @override
  void dispose() {
    _eventsSub.cancel();
    _remoteIdController.dispose();
    FlutterForegroundTask.removeTaskDataCallback(_onForegroundData);
    _viewModel.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CallState>(
      stream: _viewModel.stateStream,
      initialData: _viewModel.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? const Idle();
        return switch (state) {
          ActiveCall() => _buildActiveCall(state),
          IncomingCall() => _buildIncomingCall(state),
          Idle() => _buildIdle(),
        };
      },
    );
  }

  Widget _buildActiveCall(ActiveCall state) {
    return CallScreen(
      key: _callScreenKey,
      isCaller: state.isCaller,
      onEndCall: _viewModel.endCall,
      statsStream: _viewModel.statsStream,
      initialVolume: state.volume,
      initialMuted: state.muted,
      callStartedAt: state.startedAt,
      onRemoteDisconnected: state.isCaller ? _viewModel.endCall : null,
      onVolumeChanged: _viewModel.setVolume,
      onMuteToggled: _viewModel.applyMute,
    );
  }

  Widget _buildIncomingCall(IncomingCall state) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.phone_in_talk, size: 80, color: Colors.green),
            const SizedBox(height: 24),
            const Text('Incoming call from',
                style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 8),
            Text(
              state.callerId,
              style: const TextStyle(
                  fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 48),
            ElevatedButton.icon(
              onPressed: () => _viewModel.acceptIncomingCall(state.callId),
              icon: const Icon(Icons.phone),
              label: const Text('Answer', style: TextStyle(fontSize: 18)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 48, vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIdle() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Call POC'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Call Logs',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CallLogsScreen()),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('My ID: $_myUserId',
                style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 32),
            TextField(
              controller: _remoteIdController,
              decoration: const InputDecoration(
                labelText: 'Remote User ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            const Text('TURN Server',
                style: TextStyle(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'metered',
                  label: Text('Metered'),
                  icon: Icon(Icons.cloud),
                ),
                ButtonSegment(
                  value: 'both',
                  label: Text('Both'),
                  icon: Icon(Icons.merge_type),
                ),
                ButtonSegment(
                  value: 'expressturn',
                  label: Text('ExpressTURN'),
                  icon: Icon(Icons.swap_horiz),
                ),
              ],
              selected: {_selectedTurnServer},
              onSelectionChanged: (selection) {
                setState(() => _selectedTurnServer = selection.first);
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _remoteIdController.text.trim().isNotEmpty
                    ? () => _viewModel.makeCall(
                          _remoteIdController.text.trim(),
                          _selectedTurnServer,
                        )
                    : null,
                child: const Text('Call'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
