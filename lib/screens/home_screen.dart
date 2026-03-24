import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/uid_utils.dart';
import '../di/service_locator.dart';
import '../interfaces/auth_repository.dart';
import '../interfaces/call_log_repository.dart';
import '../interfaces/remote_config_repository.dart';
import '../models/call_log_entry.dart';
import '../models/call_state.dart';
import '../viewmodels/home_view_model.dart';
import 'call_logs_screen.dart';
import 'call_screen.dart';
import 'login_screen.dart';
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
  final _logRepository = sl<CallLogRepository>();
  final _remoteConfig = sl<RemoteConfigRepository>();
  final _inputFocusNode = FocusNode();

  String _myUserHandle = '';
  String _selectedTurnServer = 'both';
  bool _micPermissionDenied = false;
  bool _turnSelectorEnabled = false;
  List<CallLogEntry> _recentContacts = [];

  late StreamSubscription<HomeEvent> _eventsSub;

  @override
  void initState() {
    super.initState();
    _viewModel = sl<HomeViewModel>();
    _remoteIdController.addListener(() => setState(() {}));
    _initAsync();
  }

  Future<void> _initAsync() async {
    final firebaseUser = FirebaseAuth.instance.currentUser;
    if (firebaseUser == null) {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      }
      return;
    }
    final userId = firebaseUser.uid;
    final userHandle = firebaseUser.email ?? shortUidHash(firebaseUser.uid);

    final lastRemoteId = await _viewModel.loadLastRemoteId();

    if (mounted) {
      setState(() {
        _myUserHandle = userHandle;
        _remoteIdController.text = lastRemoteId;
      });
    }

    // Load most recent log entry per unique remote user (newest first, max 5).
    final logs = await _logRepository.loadLogs();
    final seen = <String>{};
    final recent = <CallLogEntry>[];
    for (final log in logs.reversed) {
      if (seen.add(log.remoteUserId) && recent.length < 5) {
        recent.add(log);
      }
    }
    if (mounted) {
      setState(() {
        _recentContacts = recent;
        _turnSelectorEnabled = _remoteConfig.isTurnSelectorEnabled();
      });
    }

    await _viewModel.init(userId, userHandle,
        isAnonymous: firebaseUser.isAnonymous);
    FlutterForegroundTask.addTaskDataCallback(_onForegroundData);
    _eventsSub = _viewModel.events.listen(_onEvent);

    final micStatus = await Permission.microphone.status;
    if (mounted && !micStatus.isGranted) {
      setState(() => _micPermissionDenied = true);
    }

    // Request focus after all setState calls have settled so that no subsequent
    // rebuild dismisses the keyboard again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocusNode.requestFocus();
    });
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

      case HomeEvent.callSetupFailed:
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Call failed to connect. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ));
        }

      case HomeEvent.microphonePermissionDenied:
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
              'Microphone permission is required. '
              'Please enable it in Settings.',
            ),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ));
        }

      case HomeEvent.weeklyLimitReached:
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Weekly call limit reached. Resets on Monday.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ));
        }

      case HomeEvent.anonLimitReached:
        if (mounted) _showAnonUpsellDialog();
    }
  }

  void _showAnonUpsellDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.card_giftcard, size: 40, color: Colors.orange),
        title: const Text('Guest Minutes Used Up'),
        content: const Text(
          'You have used all 100 free guest minutes.\n\n'
          'Create a free account and get 100 extra minutes as a welcome bonus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              );
            },
            child: const Text('Create Account'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _eventsSub.cancel();
    _remoteIdController.dispose();
    _inputFocusNode.dispose();
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

  Future<void> _requestMicPermission() async {
    final status = await Permission.microphone.request();
    if (!mounted) return;
    if (status.isGranted) {
      setState(() => _micPermissionDenied = false);
    } else if (status.isPermanentlyDenied) {
      await openAppSettings();
    }
  }

  void _makeCallTo(String remoteId) {
    if (remoteId.isEmpty) return;
    _remoteIdController.text = remoteId;
    _viewModel.makeCall(remoteId, _selectedTurnServer);
  }

  // ── Idle screen ────────────────────────────────────────────────────────────

  Widget _buildIdle() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family Voice Call'),
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
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign Out',
            onPressed: () async {
              await sl<AuthRepository>().signOut();
              if (!mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                (_) => false,
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_micPermissionDenied) _buildMicPermissionBanner(),

          // Scrollable content — recent list can grow to 5 items.
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _myUserHandle,
                    style: const TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _remoteIdController,
                    focusNode: _inputFocusNode,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (value) => _makeCallTo(value.trim()),
                    decoration: const InputDecoration(
                      labelText: 'Enter handle to call',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _remoteIdController.text.trim().isNotEmpty
                          ? () => _makeCallTo(_remoteIdController.text.trim())
                          : null,
                      child: const Text('Call'),
                    ),
                  ),
                  if (_recentContacts.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text(
                      'RECENT',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ..._recentContacts.map(_buildRecentContactTile),
                  ],
                  if (_turnSelectorEnabled) ...[
                    const SizedBox(height: 24),
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
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Recent contact tile ───────────────────────────────────────────────────

  Widget _buildRecentContactTile(CallLogEntry entry) {
    final isOutgoing = entry.isCaller;
    return InkWell(
      onTap: () => _makeCallTo(entry.remoteUserId),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.deepPurple.shade100,
              child: Text(
                entry.remoteUserId[0].toUpperCase(),
                style: TextStyle(
                  color: Colors.deepPurple.shade700,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.remoteUserId,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_formatCallDate(entry.startedAt)} · ${_formatDuration(entry.duration)}',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _buildDirectionBadge(isOutgoing),
          ],
        ),
      ),
    );
  }

  Widget _buildDirectionBadge(bool isOutgoing) {
    final color = isOutgoing ? Colors.green : Colors.blue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isOutgoing ? Icons.call_made : Icons.call_received,
            size: 14,
            color: color.shade700,
          ),
          const SizedBox(width: 4),
          Text(
            isOutgoing ? 'Outgoing' : 'Incoming',
            style: TextStyle(
              fontSize: 12,
              color: color.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ── Formatting helpers ────────────────────────────────────────────────────

  String _formatCallDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final date = DateTime(dt.year, dt.month, dt.day);

    if (date == today) return 'Today';
    if (date == yesterday) return 'Yesterday';

    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${weekdays[dt.weekday - 1]}, ${dt.day} ${months[dt.month - 1]}';
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return '$m min ${s.toString().padLeft(2, '0')} sec';
  }

  // ── Mic permission banner ─────────────────────────────────────────────────

  Widget _buildMicPermissionBanner() {
    return MaterialBanner(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: const Icon(Icons.mic_off, color: Colors.white),
      backgroundColor: Colors.red.shade700,
      content: const Text(
        'Microphone access is required to make and receive calls.',
        style: TextStyle(color: Colors.white),
      ),
      actions: [
        TextButton(
          onPressed: _requestMicPermission,
          child: const Text('Grant', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
