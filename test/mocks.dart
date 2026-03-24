import 'package:mocktail/mocktail.dart';

import 'package:family_call/interfaces/analytics_repository.dart';
import 'package:family_call/interfaces/auth_repository.dart';
import 'package:family_call/interfaces/audio_service.dart';
import 'package:family_call/interfaces/call_log_repository.dart';
import 'package:family_call/interfaces/crash_reporter.dart';
import 'package:family_call/interfaces/foreground_service.dart';
import 'package:family_call/interfaces/peer_connection_service.dart';
import 'package:family_call/interfaces/remote_config_repository.dart';
import 'package:family_call/interfaces/settings_repository.dart';
import 'package:family_call/interfaces/signaling_service.dart';
import 'package:family_call/models/call_log_entry.dart';
import 'package:family_call/models/ice_candidate_model.dart';
import 'package:family_call/models/session_description.dart';

// ── Mock classes ──────────────────────────────────────────────────────────────

class MockAuthRepository extends Mock implements AuthRepository {}

class MockAnalyticsRepository extends Mock implements AnalyticsRepository {}

class MockSignalingService extends Mock implements SignalingService {}

class MockPeerConnectionService extends Mock implements PeerConnectionService {}

class MockAudioService extends Mock implements AudioService {}

class MockForegroundService extends Mock implements ForegroundService {}

class MockCallLogRepository extends Mock implements CallLogRepository {}

class MockSettingsRepository extends Mock implements SettingsRepository {}

class MockRemoteConfigRepository extends Mock implements RemoteConfigRepository {}

class MockCrashReporter extends Mock implements CrashReporter {}

// ── Fallback values for any() matchers ───────────────────────────────────────

/// Call once from setUpAll in every test file that uses these mocks.
void registerFallbackValues() {
  registerFallbackValue(<String, Object>{});
  registerFallbackValue(const SessionDescription(sdp: 'fallback', type: 'offer'));
  registerFallbackValue(const IceCandidateModel(candidate: 'fallback'));
  registerFallbackValue(
    CallLogEntry(
      callId: 'fallback_callId',
      role: 'caller',
      remoteUserId: 'fallback_remote',
      turnServer: 'both',
      startedAt: DateTime(2024),
    ),
  );
}
