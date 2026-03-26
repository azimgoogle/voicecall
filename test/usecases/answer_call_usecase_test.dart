import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nest_call/core/result.dart';
import 'package:nest_call/models/ice_candidate_model.dart';
import 'package:nest_call/models/session_description.dart';
import 'package:nest_call/usecases/answer_call_usecase.dart';

import '../mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(registerFallbackValues);

  late MockSignalingService mockSignaling;
  late MockPeerConnectionService mockPc;
  late MockForegroundService mockForeground;
  late MockCallLogRepository mockLogRepo;
  late MockCrashReporter mockCrash;
  late StreamController<IceCandidateModel> iceCandidateCtrl;
  late AnswerCallUseCase sut;

  // callId format: {callerId}_{calleeId}_{ts}
  const callId = 'alice_bob_1000';

  setUp(() {
    SharedPreferences.setMockInitialValues({});

    mockSignaling = MockSignalingService();
    mockPc = MockPeerConnectionService();
    mockForeground = MockForegroundService();
    mockLogRepo = MockCallLogRepository();
    mockCrash = MockCrashReporter();
    iceCandidateCtrl = StreamController<IceCandidateModel>.broadcast();

    _stubHappyPath(
      signaling: mockSignaling,
      pc: mockPc,
      foreground: mockForeground,
      logRepo: mockLogRepo,
      crash: mockCrash,
      iceCandidateCtrl: iceCandidateCtrl,
    );

    sut = AnswerCallUseCase(
      signaling: mockSignaling,
      peerConnection: mockPc,
      logRepository: mockLogRepo,
      foregroundService: mockForeground,
      crashReporter: mockCrash,
    );
  });

  tearDown(() => iceCandidateCtrl.close());

  // ── Happy path ─────────────────────────────────────────────────────────────

  test('execute returns Ok<CallLogEntry> with role callee', () async {
    final result = await sut.execute(callId: callId);

    expect(result, isA<Ok>());
    final entry = (result as Ok).value;
    expect(entry.role, 'callee');
    expect(entry.callId, callId);
    expect(entry.turnServer, 'both');
    expect(entry.endedAt, isNull);
  });

  test('execute stores callerHandle as remoteUserId when available', () async {
    when(() => mockSignaling.readCallerHandle(callId))
        .thenAnswer((_) async => 'alice@example.com');

    final result = await sut.execute(callId: callId);

    final entry = (result as Ok).value;
    expect(entry.remoteUserId, 'alice@example.com');
  });

  test('execute falls back to UID parsed from callId when callerHandle is null',
      () async {
    when(() => mockSignaling.readCallerHandle(callId))
        .thenAnswer((_) async => null);

    final result = await sut.execute(callId: callId);

    final entry = (result as Ok).value;
    expect(entry.remoteUserId, 'alice'); // first segment of callId
  });

  test('execute calls peerConnection.init with isCaller=false', () async {
    await sut.execute(callId: callId);

    verify(() => mockPc.init(isCaller: false)).called(1);
  });

  test('execute reads offer from signaling', () async {
    await sut.execute(callId: callId);

    verify(() => mockSignaling.readOffer(callId)).called(1);
  });

  test('execute sets remote description from offer', () async {
    await sut.execute(callId: callId);

    verify(() => mockPc.setRemoteDescription(any())).called(1);
  });

  test('execute creates answer and writes it to signaling', () async {
    await sut.execute(callId: callId);

    verify(() => mockPc.createAnswer()).called(1);
    verify(() => mockSignaling.writeAnswer(
          callId: callId,
          answer: any(named: 'answer'),
        )).called(1);
  });

  test('execute saves a log entry', () async {
    await sut.execute(callId: callId);

    verify(() => mockLogRepo.saveEntry(any())).called(1);
  });

  test('execute updates foreground notification to In call...', () async {
    await sut.execute(callId: callId);

    verify(() => mockForeground.updateNotification(
          'In call...',
          showEndCall: true,
        )).called(1);
  });

  // ── Service call order ─────────────────────────────────────────────────────

  test('readOffer is called before setRemoteDescription', () async {
    final callOrder = <String>[];

    when(() => mockSignaling.readOffer(any())).thenAnswer((_) async {
      callOrder.add('readOffer');
      return const SessionDescription(sdp: 'offer_sdp', type: 'offer');
    });
    when(() => mockPc.setRemoteDescription(any())).thenAnswer((_) async {
      callOrder.add('setRemoteDescription');
    });

    await sut.execute(callId: callId);

    expect(callOrder.indexOf('readOffer'),
        lessThan(callOrder.indexOf('setRemoteDescription')));
  });

  test('createAnswer is called after setRemoteDescription', () async {
    final callOrder = <String>[];

    when(() => mockPc.setRemoteDescription(any())).thenAnswer((_) async {
      callOrder.add('setRemoteDescription');
    });
    when(() => mockPc.createAnswer()).thenAnswer((_) async {
      callOrder.add('createAnswer');
      return const SessionDescription(sdp: 'answer_sdp', type: 'answer');
    });

    await sut.execute(callId: callId);

    expect(callOrder.indexOf('setRemoteDescription'),
        lessThan(callOrder.indexOf('createAnswer')));
  });

  // ── Error paths ────────────────────────────────────────────────────────────

  test('execute returns Err when peerConnection.init throws', () async {
    when(() => mockPc.init(isCaller: any(named: 'isCaller')))
        .thenThrow(Exception('WebRTC unavailable'));

    final result = await sut.execute(callId: callId);

    expect(result, isA<Err>());
  });

  test('execute returns Err when readOffer throws', () async {
    when(() => mockSignaling.readOffer(any()))
        .thenThrow(Exception('Firebase error'));

    final result = await sut.execute(callId: callId);

    expect(result, isA<Err>());
  });

  test('execute returns Err when writeAnswer throws', () async {
    when(() => mockSignaling.writeAnswer(
          callId: any(named: 'callId'),
          answer: any(named: 'answer'),
        )).thenThrow(Exception('Firebase write error'));

    final result = await sut.execute(callId: callId);

    expect(result, isA<Err>());
  });
}

// ── Stub helpers ──────────────────────────────────────────────────────────────

void _stubHappyPath({
  required MockSignalingService signaling,
  required MockPeerConnectionService pc,
  required MockForegroundService foreground,
  required MockCallLogRepository logRepo,
  required MockCrashReporter crash,
  required StreamController<IceCandidateModel> iceCandidateCtrl,
}) {
  when(() => pc.init(isCaller: any(named: 'isCaller')))
      .thenAnswer((_) async {});
  when(() => pc.createAnswer()).thenAnswer(
      (_) async => const SessionDescription(sdp: 'answer_sdp', type: 'answer'));
  when(() => pc.setRemoteDescription(any())).thenAnswer((_) async {});
  when(() => pc.addIceCandidate(any())).thenAnswer((_) async {});
  when(() => pc.iceCandidate).thenAnswer((_) => iceCandidateCtrl.stream);

  when(() => signaling.readOffer(any())).thenAnswer(
      (_) async => const SessionDescription(sdp: 'offer_sdp', type: 'offer'));
  when(() => signaling.readCallerHandle(any())).thenAnswer((_) async => null);
  when(() => signaling.writeAnswer(
        callId: any(named: 'callId'),
        answer: any(named: 'answer'),
      )).thenAnswer((_) async {});
  when(() => signaling.iceCandidates(any(), any()))
      .thenAnswer((_) => const Stream.empty());
  when(() => signaling.writeIceCandidate(
        callId: any(named: 'callId'),
        isCaller: any(named: 'isCaller'),
        candidate: any(named: 'candidate'),
      )).thenAnswer((_) async {});

  when(() => foreground.updateNotification(
        any(),
        showEndCall: any(named: 'showEndCall'),
        showMute: any(named: 'showMute'),
        isMuted: any(named: 'isMuted'),
      )).thenAnswer((_) async {});

  when(() => logRepo.saveEntry(any())).thenAnswer((_) async {});

  when(() => crash.setUserIdentifier(any())).thenAnswer((_) async {});
  when(() => crash.recordError(any(), any(), reason: any(named: 'reason')))
      .thenAnswer((_) async {});
}
