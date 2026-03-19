import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:family_call/core/result.dart';
import 'package:family_call/models/call_log_entry.dart';
import 'package:family_call/usecases/end_call_usecase.dart';

import '../mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(registerFallbackValues);

  late MockSignalingService mockSignaling;
  late MockPeerConnectionService mockPc;
  late MockAudioService mockAudio;
  late MockForegroundService mockForeground;
  late MockCallLogRepository mockLogRepo;
  late EndCallUseCase sut;

  // A minimal in-progress log entry used across tests.
  final activeEntry = CallLogEntry(
    callId: 'alice_bob_1000',
    role: 'caller',
    remoteUserId: 'bob',
    turnServer: 'metered',
    startedAt: DateTime(2024, 1, 1, 10, 0),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});

    mockSignaling = MockSignalingService();
    mockPc = MockPeerConnectionService();
    mockAudio = MockAudioService();
    mockForeground = MockForegroundService();
    mockLogRepo = MockCallLogRepository();

    _stubHappyPath(
      signaling: mockSignaling,
      pc: mockPc,
      audio: mockAudio,
      foreground: mockForeground,
      logRepo: mockLogRepo,
    );

    sut = EndCallUseCase(
      signaling: mockSignaling,
      peerConnection: mockPc,
      logRepository: mockLogRepo,
      audioService: mockAudio,
      foregroundService: mockForeground,
    );
  });

  // ── Happy path — always runs ───────────────────────────────────────────────

  test('execute returns Ok(Unit) on success', () async {
    final result = await sut.execute(currentEntry: activeEntry);

    expect(result, isA<Ok>());
  });

  test('execute always calls cancelListeners', () async {
    await sut.execute(currentEntry: activeEntry);

    verify(() => mockSignaling.cancelListeners()).called(1);
  });

  test('execute always calls peerConnection.close', () async {
    await sut.execute(currentEntry: activeEntry);

    verify(() => mockPc.close()).called(1);
  });

  test('execute always resets foreground notification to idle', () async {
    await sut.execute(currentEntry: activeEntry);

    verify(() => mockForeground.updateNotification('Waiting for calls...'))
        .called(1);
  });

  // ── Log entry finalisation ─────────────────────────────────────────────────

  test('execute saves finalised entry with endedAt set', () async {
    await sut.execute(currentEntry: activeEntry);

    final captured = verify(() => mockLogRepo.saveEntry(captureAny()))
        .captured
        .single as CallLogEntry;
    expect(captured.endedAt, isNotNull);
    expect(captured.callId, activeEntry.callId);
  });

  test('execute saves entry with actual TURN used from peerConnection', () async {
    when(() => mockPc.resolveActualTurnUsed()).thenAnswer((_) async => 'turn');

    await sut.execute(currentEntry: activeEntry);

    final captured = verify(() => mockLogRepo.saveEntry(captureAny()))
        .captured
        .single as CallLogEntry;
    expect(captured.turnUsed, 'turn');
  });

  test('execute skips log save when currentEntry is null', () async {
    await sut.execute(currentEntry: null);

    verifyNever(() => mockLogRepo.saveEntry(any()));
    verifyNever(() => mockPc.resolveActualTurnUsed());
  });

  // ── writeCancelled flag ────────────────────────────────────────────────────

  test(
      'execute writes cancelled signal when writeCancelled=true and entry is not null',
      () async {
    await sut.execute(
      currentEntry: activeEntry,
      writeCancelled: true,
    );

    verify(() => mockSignaling.writeCancelledSignal(activeEntry.callId))
        .called(1);
  });

  test('execute does NOT write cancelled signal when writeCancelled=false',
      () async {
    await sut.execute(
      currentEntry: activeEntry,
      writeCancelled: false,
    );

    verifyNever(() => mockSignaling.writeCancelledSignal(any()));
  });

  test('execute does NOT write cancelled signal when entry is null', () async {
    await sut.execute(
      currentEntry: null,
      writeCancelled: true, // flag is true but entry is null
    );

    verifyNever(() => mockSignaling.writeCancelledSignal(any()));
  });

  // ── releaseAudio flag ──────────────────────────────────────────────────────

  test(
      'execute releases audio session and wake lock when releaseAudio=true',
      () async {
    await sut.execute(
      currentEntry: activeEntry,
      releaseAudio: true,
    );

    verify(() => mockAudio.releaseProximityWakeLock()).called(1);
    verify(() => mockAudio.stopAudioSession()).called(1);
  });

  test('execute does NOT release audio when releaseAudio=false', () async {
    await sut.execute(
      currentEntry: activeEntry,
      releaseAudio: false,
    );

    verifyNever(() => mockAudio.releaseProximityWakeLock());
    verifyNever(() => mockAudio.stopAudioSession());
  });

  // ── Error paths ────────────────────────────────────────────────────────────

  test('execute returns Err when peerConnection.close throws', () async {
    when(() => mockPc.close()).thenThrow(Exception('WebRTC close failed'));

    final result = await sut.execute(currentEntry: activeEntry);

    expect(result, isA<Err>());
  });

  test('execute returns Err when signaling.cancelListeners throws', () async {
    when(() => mockSignaling.cancelListeners())
        .thenThrow(Exception('Firebase error'));

    final result = await sut.execute(currentEntry: activeEntry);

    expect(result, isA<Err>());
  });
}

// ── Stub helpers ──────────────────────────────────────────────────────────────

void _stubHappyPath({
  required MockSignalingService signaling,
  required MockPeerConnectionService pc,
  required MockAudioService audio,
  required MockForegroundService foreground,
  required MockCallLogRepository logRepo,
}) {
  when(() => pc.resolveActualTurnUsed()).thenAnswer((_) async => 'stun');
  when(() => pc.close()).thenAnswer((_) async {});

  when(() => signaling.cancelListeners()).thenAnswer((_) async {});
  when(() => signaling.writeCancelledSignal(any())).thenAnswer((_) async {});

  when(() => audio.releaseProximityWakeLock()).thenAnswer((_) async {});
  when(() => audio.stopAudioSession()).thenAnswer((_) async {});

  when(() => foreground.updateNotification(
        any(),
        showEndCall: any(named: 'showEndCall'),
        showMute: any(named: 'showMute'),
        isMuted: any(named: 'isMuted'),
      )).thenAnswer((_) async {});

  when(() => logRepo.saveEntry(any())).thenAnswer((_) async {});
}
