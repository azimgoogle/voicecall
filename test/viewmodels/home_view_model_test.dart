import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:family_call/models/call_state.dart';
import 'package:family_call/models/ice_candidate_model.dart';
import 'package:family_call/models/session_description.dart';
import 'package:family_call/viewmodels/home_view_model.dart';

import '../mocks.dart';

// ──────────────────────────────────────────────────────────────────────────────
// HomeViewModel tests
//
// Tests are split into two groups:
//   1. Direct API tests (makeCall, answerCall, endCall, events) — no init() needed
//   2. Incoming call tests — require init(), which triggers Permission.microphone.request()
// ──────────────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValues();
    _mockPermissionChannel(); // grant mic permission for all tests by default
  });

  // ── Shared fixtures ──────────────────────────────────────────────────────

  late MockSignalingService mockSignaling;
  late MockPeerConnectionService mockPc;
  late MockAudioService mockAudio;
  late MockForegroundService mockForeground;
  late MockCallLogRepository mockLogRepo;
  late MockSettingsRepository mockSettings;
  late MockCrashReporter mockCrash;
  late MockAnalyticsRepository mockAnalytics;

  // Per-test broadcast stream controllers — recreated in setUp.
  late StreamController<void> connectionLostCtrl;
  late StreamController<void> connectionEstablishedCtrl;
  late StreamController<IceCandidateModel> iceCandidateCtrl;
  late StreamController<Map<String, dynamic>> statsCtrl;
  late StreamController<String> incomingCallCtrl;
  late StreamController<void> busySignalCtrl;
  late StreamController<void> callCancelledCtrl;

  late HomeViewModel vm;

  setUp(() {
    SharedPreferences.setMockInitialValues({});

    mockSignaling = MockSignalingService();
    mockPc = MockPeerConnectionService();
    mockAudio = MockAudioService();
    mockForeground = MockForegroundService();
    mockLogRepo = MockCallLogRepository();
    mockSettings = MockSettingsRepository();
    mockCrash = MockCrashReporter();
    mockAnalytics = MockAnalyticsRepository();

    connectionLostCtrl = StreamController<void>.broadcast();
    connectionEstablishedCtrl = StreamController<void>.broadcast();
    iceCandidateCtrl = StreamController<IceCandidateModel>.broadcast();
    statsCtrl = StreamController<Map<String, dynamic>>.broadcast();
    incomingCallCtrl = StreamController<String>.broadcast();
    busySignalCtrl = StreamController<void>.broadcast();
    callCancelledCtrl = StreamController<void>.broadcast();

    _stubAll(
      signaling: mockSignaling,
      pc: mockPc,
      audio: mockAudio,
      foreground: mockForeground,
      logRepo: mockLogRepo,
      settings: mockSettings,
      crash: mockCrash,
      analytics: mockAnalytics,
      connectionLostCtrl: connectionLostCtrl,
      connectionEstablishedCtrl: connectionEstablishedCtrl,
      iceCandidateCtrl: iceCandidateCtrl,
      statsCtrl: statsCtrl,
      incomingCallCtrl: incomingCallCtrl,
      busySignalCtrl: busySignalCtrl,
      callCancelledCtrl: callCancelledCtrl,
    );

    vm = HomeViewModel(
      signaling: mockSignaling,
      peerConnection: mockPc,
      logRepository: mockLogRepo,
      settings: mockSettings,
      audioService: mockAudio,
      foregroundService: mockForeground,
      crashReporter: mockCrash,
      analytics: mockAnalytics,
    );
  });

  tearDown(() {
    vm.dispose();
    connectionLostCtrl.close();
    connectionEstablishedCtrl.close();
    iceCandidateCtrl.close();
    statsCtrl.close();
    incomingCallCtrl.close();
    busySignalCtrl.close();
    callCancelledCtrl.close();
  });

  // ── Initial state ─────────────────────────────────────────────────────────

  group('initial state', () {
    test('state is Idle before any call is made', () {
      expect(vm.state, isA<Idle>());
    });
  });

  // ── makeCall ──────────────────────────────────────────────────────────────

  group('makeCall', () {
    test('transitions state to ActiveCall with isCaller=true', () async {
      await vm.makeCall('bob', 'metered');

      expect(vm.state, isA<ActiveCall>());
      final active = vm.state as ActiveCall;
      expect(active.isCaller, isTrue);
      expect(active.remoteUserId, 'bob');
      expect(active.turnServer, 'metered');
      verify(() => mockAnalytics.logEvent('call_initiated',
          parameters: any(named: 'parameters'))).called(1);
    });

    test('does nothing when remoteId is empty', () async {
      await vm.makeCall('', 'metered');

      expect(vm.state, isA<Idle>());
      verifyNever(() => mockPc.init(
            isCaller: any(named: 'isCaller'),
            turnServer: any(named: 'turnServer'),
          ));
    });

    test('emits callSetupFailed event and stays Idle on use case Err',
        () async {
      when(() => mockPc.init(
            isCaller: any(named: 'isCaller'),
            turnServer: any(named: 'turnServer'),
          )).thenThrow(Exception('WebRTC init failed'));

      final events = <HomeEvent>[];
      vm.events.listen(events.add);

      await vm.makeCall('bob', 'metered');
      await Future.microtask(() {}); // allow broadcast-stream delivery microtask to fire

      expect(vm.state, isA<Idle>());
      expect(events, contains(HomeEvent.callSetupFailed));
      verify(() => mockAnalytics.logEvent('call_failed',
          parameters: any(named: 'parameters'))).called(1);
    });

    test('stateStream emits ActiveCall after successful makeCall', () async {
      final states = <CallState>[];
      vm.stateStream.listen(states.add);

      await vm.makeCall('bob', 'metered');
      await Future.microtask(() {}); // allow broadcast-stream delivery microtask to fire

      expect(states.whereType<ActiveCall>(), isNotEmpty);
    });
  });

  // ── microphone permission denied ──────────────────────────────────────────

  group('microphone permission denied', () {
    test('makeCall emits microphonePermissionDenied and does not invoke use case',
        () async {
      _mockPermissionDenied();
      addTearDown(_mockPermissionChannel);

      final events = <HomeEvent>[];
      vm.events.listen(events.add);

      await vm.makeCall('bob', 'metered');
      await Future.microtask(() {});

      expect(events, contains(HomeEvent.microphonePermissionDenied));
      expect(vm.state, isA<Idle>());
      verifyNever(() => mockPc.init(
            isCaller: any(named: 'isCaller'),
            turnServer: any(named: 'turnServer'),
          ));
    });
  });

  // ── answerCall ────────────────────────────────────────────────────────────

  group('answerCall', () {
    test('transitions state to ActiveCall with isCaller=false', () async {
      await vm.answerCall('alice_bob_1000');

      expect(vm.state, isA<ActiveCall>());
      final active = vm.state as ActiveCall;
      expect(active.isCaller, isFalse);
    });

    test('parses caller id from callId as remoteUserId', () async {
      await vm.answerCall('alice_bob_1000');

      final active = vm.state as ActiveCall;
      expect(active.remoteUserId, 'alice');
    });

    test('emits callSetupFailed and stays Idle on use case Err', () async {
      when(() => mockPc.init(isCaller: any(named: 'isCaller')))
          .thenThrow(Exception('WebRTC unavailable'));

      final events = <HomeEvent>[];
      vm.events.listen(events.add);

      await vm.answerCall('alice_bob_1000');
      await Future.microtask(() {}); // allow broadcast-stream delivery microtask to fire

      expect(vm.state, isA<Idle>());
      expect(events, contains(HomeEvent.callSetupFailed));
    });
  });

  // ── endCall ───────────────────────────────────────────────────────────────

  group('endCall', () {
    test('transitions state back to Idle from ActiveCall', () async {
      await vm.makeCall('bob', 'metered');
      expect(vm.state, isA<ActiveCall>());

      await vm.endCall();

      expect(vm.state, isA<Idle>());
    });

    test('calls signaling.cancelListeners', () async {
      await vm.makeCall('bob', 'metered');
      await vm.endCall();

      verify(() => mockSignaling.cancelListeners()).called(1);
    });

    test('calls peerConnection.close', () async {
      await vm.makeCall('bob', 'metered');
      await vm.endCall();

      verify(() => mockPc.close()).called(greaterThanOrEqualTo(1));
    });
  });

  // ── connectionLost — caller side ──────────────────────────────────────────

  group('caller connectionLost', () {
    test('emits remoteDisconnected event', () async {
      final events = <HomeEvent>[];
      vm.events.listen(events.add);

      await vm.makeCall('bob', 'metered');
      expect(vm.state, isA<ActiveCall>());

      // Simulate remote drop from caller's perspective.
      connectionLostCtrl.add(null);
      await Future.microtask(() {}); // flush connectionLost stream delivery
      await Future.delayed(Duration.zero); // flush _eventsController delivery

      expect(events, contains(HomeEvent.remoteDisconnected));
    });
  });

  // ── connectionLost — callee side ──────────────────────────────────────────

  group('callee connectionLost', () {
    test('returns state to Idle when callee loses connection', () async {
      await vm.answerCall('alice_bob_1000');
      expect(vm.state, isA<ActiveCall>());

      connectionLostCtrl.add(null);

      // _onCallEnded() calls endCall().execute() which is async; pump it.
      await Future.delayed(Duration.zero);
      await Future.microtask(() {});

      expect(vm.state, isA<Idle>());
    });
  });

  // ── Busy signal ───────────────────────────────────────────────────────────

  group('busy signal', () {
    test('emits calleeBusy event and ends call', () async {
      final events = <HomeEvent>[];
      vm.events.listen(events.add);

      await vm.makeCall('bob', 'metered');
      expect(vm.state, isA<ActiveCall>());

      busySignalCtrl.add(null);
      await Future.microtask(() {});
      await Future.delayed(Duration.zero);

      expect(events, contains(HomeEvent.calleeBusy));
      verify(() => mockAnalytics.logEvent('callee_busy',
          parameters: any(named: 'parameters'))).called(1);
    });
  });

  // ── applyMute ─────────────────────────────────────────────────────────────

  group('applyMute', () {
    test('sets muted=true on ActiveCall state', () async {
      await vm.makeCall('bob', 'metered');

      await vm.applyMute(true);

      final active = vm.state as ActiveCall;
      expect(active.muted, isTrue);
    });

    test('sets remote volume to 0.0 when muting', () async {
      await vm.makeCall('bob', 'metered');
      await vm.applyMute(true);

      verify(() => mockPc.setRemoteVolume(0.0)).called(1);
    });

    test('does nothing when not in ActiveCall', () async {
      await vm.applyMute(true); // state is Idle

      verifyNever(() => mockPc.setRemoteVolume(any()));
    });
  });

  // ── 30-second connection timeout ──────────────────────────────────────────

  group('30s connection timeout', () {
    test('emits callTimeout event and returns to Idle if never connected',
        () {
      fakeAsync((fake) {
        final events = <HomeEvent>[];
        vm.events.listen(events.add);

        // Start call — connectionEstablished stream never emits.
        vm.makeCall('bob', 'metered');
        fake.flushMicrotasks(); // complete all awaited futures inside makeCall

        expect(vm.state, isA<ActiveCall>());

        // Advance past the 30s timer.
        fake.elapse(const Duration(seconds: 31));
        fake.flushMicrotasks(); // complete endCall() async chain

        expect(events, contains(HomeEvent.callTimeout));
        expect(vm.state, isA<Idle>());
        verify(() => mockAnalytics.logEvent('call_timed_out',
            parameters: any(named: 'parameters'))).called(1);
      });
    });

    test('does NOT fire callTimeout when connectionEstablished emits first',
        () {
      fakeAsync((fake) {
        final events = <HomeEvent>[];
        vm.events.listen(events.add);

        vm.makeCall('bob', 'metered');
        fake.flushMicrotasks();

        // Signal that connection is established — cancels the 30s timer.
        connectionEstablishedCtrl.add(null);
        fake.flushMicrotasks();

        fake.elapse(const Duration(seconds: 31));
        fake.flushMicrotasks();

        expect(events, isNot(contains(HomeEvent.callTimeout)));
      });
    });
  });

  // ── Incoming call (requires init) ─────────────────────────────────────────

  group('incoming call — requires init()', () {
    setUp(() async {
      when(() => mockForeground.start()).thenAnswer((_) async {});
      await vm.init('testUser');
    });

    test('auto-answers when caller is whitelisted → state is ActiveCall',
        () async {
      when(() => mockSettings.isAutoAnswer(any()))
          .thenAnswer((_) async => true);

      incomingCallCtrl.add('alice_testUser_1000');
      await Future.delayed(Duration.zero);

      expect(vm.state, isA<ActiveCall>());
    });

    test('shows IncomingCall state for non-whitelisted caller', () async {
      when(() => mockSettings.isAutoAnswer(any()))
          .thenAnswer((_) async => false);

      incomingCallCtrl.add('alice_testUser_1000');
      await Future.delayed(Duration.zero);

      expect(vm.state, isA<IncomingCall>());
      final incoming = vm.state as IncomingCall;
      expect(incoming.callerId, 'alice');
    });

    test('acceptIncomingCall transitions to ActiveCall', () async {
      when(() => mockSettings.isAutoAnswer(any()))
          .thenAnswer((_) async => false);

      incomingCallCtrl.add('alice_testUser_1000');
      await Future.delayed(Duration.zero);
      expect(vm.state, isA<IncomingCall>());

      await vm.acceptIncomingCall('alice_testUser_1000');

      expect(vm.state, isA<ActiveCall>());
    });

    test('writes busy signal when already in ActiveCall and another call arrives',
        () async {
      // First, make a call so state is ActiveCall.
      await vm.makeCall('bob', 'metered');
      expect(vm.state, isA<ActiveCall>());

      when(() => mockSignaling.writeBusySignal(any()))
          .thenAnswer((_) async {});

      // Simulate a second incoming call.
      incomingCallCtrl.add('charlie_testUser_2000');
      await Future.delayed(Duration.zero);

      verify(() => mockSignaling.writeBusySignal('charlie')).called(1);
    });

    test('callCancelled from caller dismisses IncomingCall → back to Idle',
        () async {
      when(() => mockSettings.isAutoAnswer(any()))
          .thenAnswer((_) async => false);

      incomingCallCtrl.add('alice_testUser_1000');
      await Future.delayed(Duration.zero);
      expect(vm.state, isA<IncomingCall>());

      callCancelledCtrl.add(null);
      await Future.microtask(() {});

      expect(vm.state, isA<Idle>());
    });
  });
}

// ── Stub helpers ──────────────────────────────────────────────────────────────

void _stubAll({
  required MockSignalingService signaling,
  required MockPeerConnectionService pc,
  required MockAudioService audio,
  required MockForegroundService foreground,
  required MockCallLogRepository logRepo,
  required MockSettingsRepository settings,
  required MockCrashReporter crash,
  required MockAnalyticsRepository analytics,
  required StreamController<void> connectionLostCtrl,
  required StreamController<void> connectionEstablishedCtrl,
  required StreamController<IceCandidateModel> iceCandidateCtrl,
  required StreamController<Map<String, dynamic>> statsCtrl,
  required StreamController<String> incomingCallCtrl,
  required StreamController<void> busySignalCtrl,
  required StreamController<void> callCancelledCtrl,
}) {
  // ── SignalingService ──────────────────────────────────────────────────────
  when(() => signaling.generateCallId(any(), any()))
      .thenReturn('testCaller_bob_1000');
  when(() => signaling.writeOffer(
        callId: any(named: 'callId'),
        offer: any(named: 'offer'),
        caller: any(named: 'caller'),
        callee: any(named: 'callee'),
      )).thenAnswer((_) async {});
  when(() => signaling.notifyRemoteUser(any(), any()))
      .thenAnswer((_) async {});
  when(() => signaling.answerStream(any()))
      .thenAnswer((_) => const Stream.empty());
  when(() => signaling.iceCandidates(any(), any()))
      .thenAnswer((_) => const Stream.empty());
  when(() => signaling.writeIceCandidate(
        callId: any(named: 'callId'),
        isCaller: any(named: 'isCaller'),
        candidate: any(named: 'candidate'),
      )).thenAnswer((_) async {});
  when(() => signaling.cancelListeners()).thenAnswer((_) async {});
  when(() => signaling.writeCancelledSignal(any())).thenAnswer((_) async {});
  when(() => signaling.incomingCall(any()))
      .thenAnswer((_) => incomingCallCtrl.stream);
  when(() => signaling.busySignal(any()))
      .thenAnswer((_) => busySignalCtrl.stream);
  when(() => signaling.callCancelled(any()))
      .thenAnswer((_) => callCancelledCtrl.stream);
  when(() => signaling.readOffer(any())).thenAnswer(
      (_) async => const SessionDescription(sdp: 'offer_sdp', type: 'offer'));
  when(() => signaling.writeAnswer(
        callId: any(named: 'callId'),
        answer: any(named: 'answer'),
      )).thenAnswer((_) async {});
  when(() => signaling.writeBusySignal(any())).thenAnswer((_) async {});

  // ── PeerConnectionService ─────────────────────────────────────────────────
  when(() => pc.init(
        isCaller: any(named: 'isCaller'),
        turnServer: any(named: 'turnServer'),
      )).thenAnswer((_) async {});
  when(() => pc.init(isCaller: any(named: 'isCaller')))
      .thenAnswer((_) async {});
  when(() => pc.setRemoteVolume(any())).thenAnswer((_) async {});
  when(() => pc.createOffer()).thenAnswer(
      (_) async => const SessionDescription(sdp: 'offer_sdp', type: 'offer'));
  when(() => pc.createAnswer()).thenAnswer(
      (_) async =>
          const SessionDescription(sdp: 'answer_sdp', type: 'answer'));
  when(() => pc.setRemoteDescription(any())).thenAnswer((_) async {});
  when(() => pc.addIceCandidate(any())).thenAnswer((_) async {});
  when(() => pc.close()).thenAnswer((_) async {});
  when(() => pc.resolveActualTurnUsed()).thenAnswer((_) async => 'stun');
  when(() => pc.connectionLost)
      .thenAnswer((_) => connectionLostCtrl.stream);
  when(() => pc.connectionEstablished)
      .thenAnswer((_) => connectionEstablishedCtrl.stream);
  when(() => pc.iceCandidate).thenAnswer((_) => iceCandidateCtrl.stream);
  when(() => pc.statsStream).thenAnswer((_) => statsCtrl.stream);

  // ── AudioService ──────────────────────────────────────────────────────────
  when(() => audio.startAudioSession()).thenAnswer((_) async {});
  when(() => audio.acquireProximityWakeLock()).thenAnswer((_) async {});
  when(() => audio.stopAudioSession()).thenAnswer((_) async {});
  when(() => audio.releaseProximityWakeLock()).thenAnswer((_) async {});

  // ── ForegroundService ─────────────────────────────────────────────────────
  when(() => foreground.start()).thenAnswer((_) async {});
  when(() => foreground.updateNotification(
        any(),
        showEndCall: any(named: 'showEndCall'),
        showMute: any(named: 'showMute'),
        isMuted: any(named: 'isMuted'),
      )).thenAnswer((_) async {});
  when(() => foreground.stop()).thenAnswer((_) async {});

  // ── CallLogRepository ─────────────────────────────────────────────────────
  when(() => logRepo.saveEntry(any())).thenAnswer((_) async {});
  when(() => logRepo.loadLogs()).thenAnswer((_) async => []);

  // ── SettingsRepository ────────────────────────────────────────────────────
  when(() => settings.isAutoAnswer(any())).thenAnswer((_) async => false);
  when(() => settings.getWhitelist()).thenAnswer((_) async => []);

  // ── CrashReporter — Future<void> methods only (void methods need no stub) ─
  when(() => crash.setUserIdentifier(any())).thenAnswer((_) async {});
  when(() => crash.recordError(any(), any(), reason: any(named: 'reason')))
      .thenAnswer((_) async {});

  // ── AnalyticsRepository ───────────────────────────────────────────────────
  when(() => analytics.logEvent(any(), parameters: any(named: 'parameters')))
      .thenAnswer((_) async {});
  when(() => analytics.setUserId(any())).thenAnswer((_) async {});
}

/// Mocks the permissions channel so that microphone permission is granted.
void _mockPermissionChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('flutter.baseflow.com/permissions/methods'),
    (MethodCall call) async {
      if (call.method == 'requestPermissions') {
        final perms = (call.arguments as List).cast<int>();
        return {for (final p in perms) p: 1};
      }
      if (call.method == 'checkPermissionStatus') return 1; // granted
      return null;
    },
  );
}

/// Mocks the permissions channel so that microphone permission is denied.
void _mockPermissionDenied() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('flutter.baseflow.com/permissions/methods'),
    (MethodCall call) async {
      if (call.method == 'checkPermissionStatus') return 0; // denied
      return null;
    },
  );
}
