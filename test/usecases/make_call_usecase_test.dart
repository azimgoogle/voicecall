import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:family_call/core/result.dart';
import 'package:family_call/models/ice_candidate_model.dart';
import 'package:family_call/models/session_description.dart';
import 'package:family_call/usecases/make_call_usecase.dart';

import '../mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(registerFallbackValues);

  late MockSignalingService mockSignaling;
  late MockPeerConnectionService mockPc;
  late MockAudioService mockAudio;
  late MockForegroundService mockForeground;
  late MockCallLogRepository mockLogRepo;
  late MockCrashReporter mockCrash;
  late StreamController<IceCandidateModel> iceCandidateCtrl;
  late MakeCallUseCase sut;

  setUp(() {
    SharedPreferences.setMockInitialValues({});

    mockSignaling = MockSignalingService();
    mockPc = MockPeerConnectionService();
    mockAudio = MockAudioService();
    mockForeground = MockForegroundService();
    mockLogRepo = MockCallLogRepository();
    mockCrash = MockCrashReporter();
    iceCandidateCtrl = StreamController<IceCandidateModel>.broadcast();

    _stubHappyPath(
      signaling: mockSignaling,
      pc: mockPc,
      audio: mockAudio,
      foreground: mockForeground,
      logRepo: mockLogRepo,
      crash: mockCrash,
      iceCandidateCtrl: iceCandidateCtrl,
    );

    sut = MakeCallUseCase(
      signaling: mockSignaling,
      peerConnection: mockPc,
      logRepository: mockLogRepo,
      audioService: mockAudio,
      foregroundService: mockForeground,
      crashReporter: mockCrash,
    );
  });

  tearDown(() => iceCandidateCtrl.close());

  // ── Happy path ─────────────────────────────────────────────────────────────

  test('execute returns Ok<CallLogEntry> on success', () async {
    final result = await sut.execute(
      callerId: 'alice',
      remoteId: 'bob',
      turnServer: 'metered',
      initialVolume: 1.0,
    );

    expect(result, isA<Ok>());
    final entry = (result as Ok).value;
    expect(entry.role, 'caller');
    expect(entry.remoteUserId, 'bob');
    expect(entry.turnServer, 'metered');
    expect(entry.endedAt, isNull); // call is still active
  });

  test('execute calls peerConnection.init with isCaller=true and turnServer',
      () async {
    await sut.execute(
      callerId: 'alice',
      remoteId: 'bob',
      turnServer: 'expressturn',
      initialVolume: 1.0,
    );

    verify(() => mockPc.init(isCaller: true, turnServer: 'expressturn'))
        .called(1);
  });

  test('execute starts audio session and acquires wake lock', () async {
    await sut.execute(
      callerId: 'alice',
      remoteId: 'bob',
      turnServer: 'metered',
      initialVolume: 0.8,
    );

    verify(() => mockAudio.startAudioSession()).called(1);
    verify(() => mockAudio.acquireProximityWakeLock()).called(1);
  });

  test('execute sets remote volume to initialVolume', () async {
    await sut.execute(
      callerId: 'alice',
      remoteId: 'bob',
      turnServer: 'metered',
      initialVolume: 0.5,
    );

    verify(() => mockPc.setRemoteVolume(0.5)).called(1);
  });

  test('execute writes offer and notifies remote user', () async {
    await sut.execute(
      callerId: 'alice',
      remoteId: 'bob',
      turnServer: 'metered',
      initialVolume: 1.0,
    );

    verify(() => mockSignaling.writeOffer(
          callId: any(named: 'callId'),
          offer: any(named: 'offer'),
          caller: 'alice',
          callee: 'bob',
        )).called(1);
    verify(() => mockSignaling.notifyRemoteUser('bob', any())).called(1);
  });

  test('execute saves a log entry before returning', () async {
    await sut.execute(
      callerId: 'alice',
      remoteId: 'bob',
      turnServer: 'metered',
      initialVolume: 1.0,
    );

    verify(() => mockLogRepo.saveEntry(any())).called(1);
  });

  test('execute persists last_remote_id in SharedPreferences', () async {
    await sut.execute(
      callerId: 'alice',
      remoteId: 'bob',
      turnServer: 'metered',
      initialVolume: 1.0,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('last_remote_id'), 'bob');
  });

  // ── Error paths ────────────────────────────────────────────────────────────

  test('execute returns Err<ConnectionError> when peerConnection.init throws',
      () async {
    when(() => mockPc.init(
          isCaller: any(named: 'isCaller'),
          turnServer: any(named: 'turnServer'),
        )).thenThrow(Exception('WebRTC init failed'));

    final result = await sut.execute(
      callerId: 'alice',
      remoteId: 'bob',
      turnServer: 'metered',
      initialVolume: 1.0,
    );

    expect(result, isA<Err>());
  });

  test('execute returns Err when signaling.writeOffer throws', () async {
    when(() => mockSignaling.writeOffer(
          callId: any(named: 'callId'),
          offer: any(named: 'offer'),
          caller: any(named: 'caller'),
          callee: any(named: 'callee'),
        )).thenThrow(Exception('Firebase write failed'));

    final result = await sut.execute(
      callerId: 'alice',
      remoteId: 'bob',
      turnServer: 'metered',
      initialVolume: 1.0,
    );

    expect(result, isA<Err>());
  });

  test('execute returns Err when createOffer throws', () async {
    when(() => mockPc.createOffer()).thenThrow(Exception('SDP failed'));

    final result = await sut.execute(
      callerId: 'alice',
      remoteId: 'bob',
      turnServer: 'metered',
      initialVolume: 1.0,
    );

    expect(result, isA<Err>());
  });

  // ── Service call order ─────────────────────────────────────────────────────

  test('peerConnection.init is called before createOffer', () async {
    final callOrder = <String>[];
    when(() => mockPc.init(
          isCaller: any(named: 'isCaller'),
          turnServer: any(named: 'turnServer'),
        )).thenAnswer((_) async => callOrder.add('init'));
    when(() => mockPc.createOffer()).thenAnswer((_) async {
      callOrder.add('createOffer');
      return const SessionDescription(sdp: 'fake_sdp', type: 'offer');
    });

    await sut.execute(
      callerId: 'alice',
      remoteId: 'bob',
      turnServer: 'metered',
      initialVolume: 1.0,
    );

    expect(callOrder.indexOf('init'), lessThan(callOrder.indexOf('createOffer')));
  });
}

// ── Stub helpers ──────────────────────────────────────────────────────────────

void _stubHappyPath({
  required MockSignalingService signaling,
  required MockPeerConnectionService pc,
  required MockAudioService audio,
  required MockForegroundService foreground,
  required MockCallLogRepository logRepo,
  required MockCrashReporter crash,
  required StreamController<IceCandidateModel> iceCandidateCtrl,
  String callId = 'alice_bob_1000',
}) {
  when(() => signaling.generateCallId(any(), any())).thenReturn(callId);
  when(() => signaling.writeOffer(
        callId: any(named: 'callId'),
        offer: any(named: 'offer'),
        caller: any(named: 'caller'),
        callee: any(named: 'callee'),
      )).thenAnswer((_) async {});
  when(() => signaling.notifyRemoteUser(any(), any())).thenAnswer((_) async {});
  when(() => signaling.answerStream(any()))
      .thenAnswer((_) => const Stream.empty());
  when(() => signaling.iceCandidates(any(), any()))
      .thenAnswer((_) => const Stream.empty());
  when(() => signaling.writeIceCandidate(
        callId: any(named: 'callId'),
        isCaller: any(named: 'isCaller'),
        candidate: any(named: 'candidate'),
      )).thenAnswer((_) async {});

  when(() => pc.init(
        isCaller: any(named: 'isCaller'),
        turnServer: any(named: 'turnServer'),
      )).thenAnswer((_) async {});
  when(() => pc.setRemoteVolume(any())).thenAnswer((_) async {});
  when(() => pc.createOffer()).thenAnswer(
      (_) async => const SessionDescription(sdp: 'fake_sdp', type: 'offer'));
  when(() => pc.iceCandidate).thenAnswer((_) => iceCandidateCtrl.stream);

  when(() => audio.startAudioSession()).thenAnswer((_) async {});
  when(() => audio.acquireProximityWakeLock()).thenAnswer((_) async {});

  when(() => foreground.updateNotification(
        any(),
        showEndCall: any(named: 'showEndCall'),
        showMute: any(named: 'showMute'),
        isMuted: any(named: 'isMuted'),
      )).thenAnswer((_) async {});

  when(() => logRepo.saveEntry(any())).thenAnswer((_) async {});

  // void methods — no stub needed; mocktail ignores them automatically.
  // crash.log / crash.setCustomKey are void, so they're fine.
  when(() => crash.setUserIdentifier(any())).thenAnswer((_) async {});
  when(() => crash.recordError(any(), any(), reason: any(named: 'reason')))
      .thenAnswer((_) async {});
}
