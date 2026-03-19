# CLAUDE.md — Project Context for AI Assistants

## Working Conventions

- **Keep this file current**: After any architectural change, new dependency, renamed symbol, or new file, update the relevant section of this file before closing the task.
- **Tests for every feature**: Any non-trivial feature addition or change to existing behaviour must be accompanied by unit tests. Use the existing `test/` structure and mocking patterns as the template.

## What This Is

Production 1-to-1 audio calling app for families. WebRTC for audio, Firebase Realtime Database for signaling, Android target. Package name: `com.familycall.children_voice_call`.

## Tech Stack

- Flutter (Dart) — Android only (no iOS yet)
- `flutter_webrtc: ^1.3.1` — WebRTC peer connection + audio
- `firebase_core: ^3.12.1` + `firebase_database: ^11.3.4` — Realtime Database signaling
- `firebase_crashlytics: ^4.3.3` — non-fatal error recording, breadcrumbs, custom keys
- `shared_preferences: ^2.5.3` — persist userId, volume, mute, last remote ID
- `permission_handler: ^11.4.0` — runtime microphone permission
- `flutter_foreground_task: ^9.2.0` — Android foreground service (keeps process alive)
- `http: ^1.2.2` — fetch Metered TURN credentials
- `get_it` — dependency injection (service locator)
- STUN: `stun:stun.l.google.com:19302` (+ stun1, stun2)
- TURN: Metered.ca (dynamic credentials via API) + ExpressTURN (static fallback)
- Min SDK: 24

**Dev dependencies (tests only)**
- `mocktail: ^1.0.4` — mock library (no code-gen); used in all unit tests
- `fake_async: ^1.3.1` — fake Timer/clock; used for 30 s timeout + 40 s incoming-call timeout tests

## Architecture

The codebase follows **Ports & Adapters (Hexagonal Architecture)** with **MVVM**:

```
┌─────────────────────────────────────────────────────────────────────┐
│  AppBootstrapper (core/app_bootstrapper.dart)                        │
│  - Firebase init, DI setup, foreground channel, userId check        │
│  Called once from main() before runApp()                            │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ boot() → hasUserId
┌──────────────────────────────▼──────────────────────────────────────┐
│  HomeScreen (screens/home_screen.dart)                               │
│  - Pure StreamBuilder observer: CallState + HomeEvent               │
│  - No call logic; forwards user taps to HomeViewModel               │
│  - Delegates to CallScreen when state is ActiveCall                 │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ observes / calls
┌──────────────────────────────▼──────────────────────────────────────┐
│  HomeViewModel (viewmodels/home_view_model.dart)                     │
│  - Owns all call-lifecycle state via Stream<CallState>              │
│  - Emits one-shot HomeEvent (calleeBusy, timeout, disconnected, …)  │
│  - Subscribes to PeerConnectionService streams after each call:     │
│      connectionLost / connectionEstablished / iceCandidate          │
│  - Subscribes to SignalingService streams: busySignal / incomingCall│
│  - Manages timers: 30s call-connect timeout, 40s incoming timeout   │
│  - Delegates I/O to the three use cases below                       │
└────┬──────────────────────┬────────────────────────┬────────────────┘
     │                      │                        │
┌────▼────────────┐  ┌──────▼─────────────┐  ┌──────▼──────────────┐
│ MakeCallUseCase │  │ AnswerCallUseCase   │  │  EndCallUseCase     │
│ (usecases/)     │  │ (usecases/)         │  │  (usecases/)        │
│ Returns         │  │ Returns             │  │  Returns            │
│ Result<         │  │ Result<             │  │  Result<Unit,       │
│   CallLogEntry, │  │   CallLogEntry,     │  │    AppError>        │
│   AppError>     │  │   AppError>         │  │                     │
└────┬────────────┘  └──────┬─────────────┘  └──────┬──────────────┘
     │                      │                        │
     └──────────────────────┴────────────────────────┘
                            │ inject / call
          ┌─────────────────┴──────────────────┐
          │         Abstract Interfaces         │
          │  (lib/interfaces/)                  │
          │  PeerConnectionService              │
          │  SignalingService                   │
          │  AudioService                       │
          │  ForegroundService                  │
          │  CallLogRepository                  │
          │  SettingsRepository                 │
          │  CrashReporter                      │
          └─────────────────┬──────────────────┘
                            │ implemented by
          ┌─────────────────┴──────────────────┐
          │         Concrete Adapters           │
          │  WebRtcService                      │
          │  FirebaseSignaling                  │
          │  PlatformAudioService               │
          │  ForegroundServiceImpl              │
          │  CallLogService (+ in-memory cache) │
          │  SettingsService                    │
          │  FirebaseCrashReporter              │
          └─────────────────────────────────────┘
```

### Stream-based event API

All async events use Dart `Stream`s — no mutable callback properties:

- **`PeerConnectionService`** exposes `connectionLost`, `connectionEstablished`, and `iceCandidate` as per-call broadcast streams. Controllers are created in `init()` and **closed** in `close()`, so subscribers automatically receive a done event at teardown.
- **`SignalingService`** exposes `iceCandidates()`, `answerStream()`, and `busySignal()` as call-scoped streams (backed by StreamControllers closed by `cancelListeners()`), and `incomingCall()` / `callCancelled()` as direct Firebase streams (ViewModel manages subscriptions).

### CallState sealed hierarchy

```dart
sealed class CallState { … }
final class Idle             extends CallState { … }
final class IncomingCall     extends CallState { callId, callerId }
final class ActiveCall       extends CallState { isCaller, remoteUserId, callId,
                                                 startedAt, turnServer, volume, muted }
```

HomeScreen switches exhaustively on `CallState` — no `isInCall` booleans.

### Result type

```dart
sealed class Result<T, E> { … }
final class Ok<T, E>  extends Result<T, E> { final T value; }
final class Err<T, E> extends Result<T, E> { final E error; }
final class Unit { … }   // used for void-valued Ok results

sealed class AppError { … }
final class SignalingError  extends AppError { final Object cause; }
final class ConnectionError extends AppError { final Object cause; }
final class AudioError      extends AppError { final Object cause; }
```

Use cases return `Result<CallLogEntry, AppError>` or `Result<Unit, AppError>`. The ViewModel switches on the result and emits `HomeEvent.callSetupFailed` on `Err`.

---

## Call Flow

```
Device A (caller)               Firebase RTDB              Device B (callee)
      │                              │                           │
      │ makeCall()                   │                           │
      ├─► MakeCallUseCase ──────────►│                           │
      │   writeOffer + metadata ────►│                           │
      │   notifyRemoteUser ─────────►│──── incomingCall stream ─►│
      │                             │         whitelisted?       │
      │                             │         → answerCall()     │
      │                             │         no → show button   │
      │   answerStream(callId) ─────►│◄─── writeAnswer ──────────│
      │◄────────────── iceCandidate stream / iceCandidates() ───►│
      │◄═══════════ WebRTC audio (one-way: callee→caller) ══════►│
      │                             │                           │
      │ endCall()                   │                           │
      ├─► EndCallUseCase ───────────►│                           │
      │   writeCancelledSignal ─────►│──── callCancelled() ─────►│
      │   cancelListeners + close   │     cancelListeners+close  │
      │                             │                           │
      │ OR: either side taps        │                           │
      │ notification "End Call" ──► HomeViewModel._onForegroundData
      │                 → endCall() │                           │
```

---

## Firebase Realtime Database Schema

```
/users/{userId}/
  incomingCall: "{callId}"        ← set by caller, cleared on receipt
  busySignal: true                ← set by callee when busy, cleared after read

/calls/{callId}/
  offer:  { sdp, type }
  answer: { sdp, type }
  offerCandidates/{pushId}:  { candidate, sdpMid, sdpMLineIndex }
  answerCandidates/{pushId}: { candidate, sdpMid, sdpMLineIndex }
  caller: "{userId}"
  callee: "{userId}"
  cancelled: true                 ← set by caller on hang-up before answer
```

Call ID format: `{callerId}_{calleeId}_{timestampMs}`

---

## File Map

```
lib/
  main.dart                         ← 2-liner: AppBootstrapper.boot() + runApp()
  core/
    app_bootstrapper.dart           ← Firebase init, DI, foreground, userId check
    result.dart                     ← Result<T,E>, Ok, Err, Unit
    app_error.dart                  ← SignalingError, ConnectionError, AudioError
  di/
    service_locator.dart            ← get_it registrations (singletons + factory)
  models/
    call_state.dart                 ← Sealed: Idle, IncomingCall, ActiveCall
    call_log_entry.dart             ← CallLogEntry (value object + JSON)
    ice_candidate_model.dart        ← Domain ICE candidate (no flutter_webrtc types)
    session_description.dart        ← Domain SDP wrapper
  interfaces/
    peer_connection_service.dart    ← Abstract WebRTC port
    signaling_service.dart          ← Abstract signaling port
    audio_service.dart              ← Abstract audio session port
    foreground_service.dart         ← Abstract foreground notification port
    call_log_repository.dart        ← Abstract call history port
    settings_repository.dart        ← Abstract settings port
    crash_reporter.dart             ← Abstract crash-reporting port (log, recordError, setCustomKey, setUserIdentifier)
  viewmodels/
    home_view_model.dart            ← Call orchestration, state, events, timers
  usecases/
    make_call_usecase.dart          ← Outgoing call setup → Result<CallLogEntry,AppError>
    answer_call_usecase.dart        ← Incoming call answer → Result<CallLogEntry,AppError>
    end_call_usecase.dart           ← Call teardown → Result<Unit,AppError>
  screens/
    onboarding_screen.dart          ← First-launch: pick unique userId, check RTDB
    home_screen.dart                ← Pure StreamBuilder observer; no call logic
    call_screen.dart                ← Active call UI (timer, stats, volume, mute)
    settings_screen.dart            ← Call log retention, auto-answer whitelist
    call_logs_screen.dart           ← Call history: duration, bytes, TURN used
  services/
    firebase_signaling.dart         ← SignalingService impl; Stream-based, _subs tracking
    webrtc_service.dart             ← PeerConnectionService impl; per-call StreamControllers
    foreground_service.dart         ← Free functions (initForegroundService etc.) +
                                       ForegroundServiceImpl class
    audio_service.dart              ← PlatformAudioService (implements AudioService)
    call_log_service.dart           ← CallLogService; SharedPrefs + in-memory write-through cache
    settings_service.dart           ← SettingsService (implements SettingsRepository)
    firebase_crash_reporter.dart    ← FirebaseCrashReporter (implements CrashReporter via firebase_crashlytics)

test/
  widget_test.dart                  ← Placeholder (void main {}); no widget tests yet
  mocks.dart                        ← 7 Mock classes + registerFallbackValues()
  usecases/
    make_call_usecase_test.dart     ← 12 unit tests
    answer_call_usecase_test.dart   ← 14 unit tests
    end_call_usecase_test.dart      ← 15 unit tests
  viewmodels/
    home_view_model_test.dart       ← 18 unit tests (incl. fakeAsync timer tests)

android/app/build.gradle.kts       ← google-services plugin, minSdk=24
android/settings.gradle.kts        ← google-services classpath
android/app/src/main/
  AndroidManifest.xml               ← Permissions + foreground service declaration
  kotlin/.../MainActivity.kt        ← stock FlutterActivity
pubspec.yaml
```

**Not in repo (must be added manually):** `android/app/google-services.json`

---

## Commands

```bash
flutter pub get                          # install dependencies
flutter analyze                          # static analysis
flutter run                              # run on connected Android device/emulator
flutter build apk                        # build release APK
flutter test test/                       # run all 62 unit tests
flutter test test/ --reporter=expanded   # verbose per-test output
```

---

## Key Decisions & Current Behavior

- **Identity**: User picks a unique ID on first launch (OnboardingScreen checks RTDB). Stored in SharedPreferences. No Firebase Auth.
- **MVVM + use cases**: `HomeViewModel` owns all call orchestration. `HomeScreen` is a pure `StreamBuilder` observer. Three use cases (`MakeCallUseCase`, `AnswerCallUseCase`, `EndCallUseCase`) handle all I/O. All wired together via get_it DI.
- **Sealed CallState**: `Idle | IncomingCall | ActiveCall`. The ViewModel emits state transitions; HomeScreen switches exhaustively. One-shot side-effects (snackbars, banners) go through `Stream<HomeEvent>`.
- **Result type**: Use cases return `Result<T, AppError>` (sealed Ok/Err). Use cases wrap their bodies in try/catch. HomeViewModel pattern-matches and emits `HomeEvent.callSetupFailed` on `Err`.
- **Stream-based events**: No mutable callback properties on services. `PeerConnectionService` exposes per-call `connectionLost`, `connectionEstablished`, `iceCandidate` broadcast streams (closed in `close()`). `SignalingService` exposes stream-returning methods; call-scoped streams are closed by `cancelListeners()`.
- **Incoming call**: Whitelisted callers auto-connect. Non-whitelisted callers show an Answer button (40s timeout, then dismissed).
- **Auto-answer whitelist**: Managed in Settings. Checked by `SettingsService` on incoming call. Persisted in SharedPreferences.
- **Call ending**: Both sides can end via the notification "End Call" button. Only the caller has an in-app End Call button. Callee UI shows "Waiting…" — but can end via notification.
- **One-way audio**: Callee mic ON → sends to caller. Caller mic OFF (`track.enabled = false`). Caller hears callee; callee hears nothing. By design for child-monitoring use case.
- **Volume control**: Per-call WebRTC gain (0.0–1.0) via `Helper.setVolume()`. Does not touch system volume. Persisted across calls. Disabled while muted.
- **Mute**: Sets remote volume to 0.0 (caller side). Synced between in-app slider, foreground notification button, and CallScreen UI.
- **TURN selection**: Caller picks Metered / ExpressTURN / Both from segmented button. Callee always uses 'both'. Actual relay used is detected post-call via `resolveActualTurnUsed()` and stored in call log.
- **Call logs**: Every call (caller and callee) is logged: role, remote userId, start/end time, bytes sent/received, TURN selected vs actually used. Retention configurable (1–30 days, default 7). `CallLogService` uses a write-through in-memory cache to avoid redundant disk reads within a session.
- **Proximity sensor**: `PlatformAudioService` acquires a proximity wake lock during the caller's call — screen turns off when held to ear.
- **Foreground service**: Keeps process alive in background. Notification shows "Waiting for calls…" or "In call…" with action buttons. Does NOT survive force-close (FCM push needed for that). The free functions in `foreground_service.dart` are used from `AppBootstrapper`; the `ForegroundServiceImpl` class is injected into use cases.
- **Busy signal**: If callee is already in a call (or has a pending incoming call), it writes `/users/{callerId}/busySignal`. Caller's `busySignal()` stream fires → snackbar + auto-end.
- **Connection timeout**: Caller auto-hangs up after 30s if WebRTC never reaches connected state (`connectionEstablished` stream never emits).
- **Remote disconnect detection**: `connectionLost` stream emits once on failure/closed/disconnected. Caller sees a 2s banner then calls `endCall()`. Callee's `connectionLost` stream fires `_onCallEnded()`.
- **No cleanup**: Old call records in Firebase RTDB persist indefinitely. No TTL, no Cloud Function pruning.
- **Crashlytics abstraction**: `CrashReporter` interface (`lib/interfaces/crash_reporter.dart`) wraps `firebase_crashlytics`. Injected into `HomeViewModel` and all three use cases. Every `_emit()` call appends a breadcrumb. Custom keys per call: `role` (caller/callee), `turn_server_selected` (caller only), `call_state` (current `CallState` type). `FirebaseCrashReporter` (`lib/services/firebase_crash_reporter.dart`) is the only concrete impl; swapping to another backend (e.g. Sentry) requires changing only the DI registration in `service_locator.dart`.
- **`turn_server_selected` key (caller only)**: Named to distinguish the caller's *chosen configuration* (metered / expressturn / both) from the *actual relay type* (stun / direct / turn) determined post-call via `resolveActualTurnUsed()` and stored in the call log. Callee logs no equivalent key — `role=callee` already deterministically implies `both`.

---

## Production Gaps

Items still needed before full production release:

| Priority | Item | Notes |
|----------|------|-------|
| Critical | Firebase Security Rules | RTDB is likely open; lock down to authenticated users |
| Critical | Firebase Auth | Replace custom ID system with proper auth (phone/anonymous) |
| Critical | TURN credential proxy | Firebase Cloud Function to proxy Metered API; API key never in client |
| High | FCM push notifications | App can't receive calls when force-closed |
| High | Remaining `!` unwraps | Use cases have try/catch; raw service code still uses force-unwraps |
| High | iOS support | Add iOS target, permissions, background audio entitlement |
| Medium | Firebase data cleanup | Cloud Function or TTL to prune stale call records |
| Medium | Two-way audio | Enable both sides to speak/hear (currently callee→caller only) |
| Medium | Reconnection logic | Auto-retry on transient network failures |
| Medium | CallKit integration | iOS native incoming call screen |
| Low | Bluetooth audio | Handle headset connection/disconnection |
| Low | Cellular interruption | Pause/resume on incoming cellular call |
| Low | Battery optimization | Request battery optimization exemption |
