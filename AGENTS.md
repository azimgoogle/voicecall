# AGENTS.md — Project Context for AI Assistants

## Working Conventions

- **Keep this file current**: After any architectural change, new dependency, renamed symbol, or new file, update the relevant section of this file before closing the task.
- **Tests for every feature**: Any non-trivial feature addition or change to existing behaviour must be accompanied by unit tests. Use the existing `test/` structure and mocking patterns as the template.

## What This Is

Production 1-to-1 audio calling app for families. WebRTC for audio, Firebase Realtime Database for signaling, Android target. Package name: `com.zunova.nestcall`.

## Tech Stack

- Flutter (Dart) — Android only (no iOS yet)
- `flutter_webrtc: ^1.3.1` — WebRTC peer connection + audio
- `firebase_core: ^3.12.1` + `firebase_database: ^11.3.4` — Realtime Database signaling
- `firebase_analytics: ^11.3.3` — product-metric event logging (call funnel, quality)
- `firebase_crashlytics: ^4.3.3` — non-fatal error recording, breadcrumbs, custom keys
- `firebase_auth: ^5.x` — Firebase Authentication (Google, email/password, anonymous)
- `google_sign_in: ^6.x` — Google OAuth for Firebase Auth
- `firebase_remote_config: ^5.x` — runtime feature flags (weekly limit, turn selector, email sign-in toggle)
- `shared_preferences: ^2.5.3` — persist volume, mute, last remote ID, anon usage counter
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
          │  AnalyticsRepository                │
          │  AuthRepository                     │
          │  RemoteConfigRepository             │
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
          │  FirebaseAnalyticsReporter          │
          │  FirebaseAuthService                │
          │  FirebaseRemoteConfigService        │
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

/emailToUid/{encodedHandle}       ← written on every auth; dots replaced with commas
  → "{uid}"

/userProfiles/{uid}/
  email: "{handle}"               ← email for registered users; shortUidHash(uid) for anonymous
```

Call ID format: `{callerId}_{calleeId}_{timestampMs}`

---

## File Map

```
lib/
  main.dart                         ← AppBootstrapper.boot() → PermissionScreen or LoginScreen
  core/
    app_bootstrapper.dart           ← Firebase init, DI, foreground, Remote Config fetch, Auth check
    result.dart                     ← Result<T,E>, Ok, Err, Unit
    app_error.dart                  ← SignalingError, ConnectionError, AudioError
    uid_utils.dart                  ← shortUidHash(): 6-char display handle for anonymous users
  di/
    service_locator.dart            ← get_it registrations (singletons + factory)
  models/
    call_state.dart                 ← Sealed: Idle, IncomingCall, ActiveCall
    call_log_entry.dart             ← CallLogEntry (value object + JSON)
    ice_candidate_model.dart        ← Domain ICE candidate (no flutter_webrtc types)
    session_description.dart        ← Domain SDP wrapper
  interfaces/
    peer_connection_service.dart    ← Abstract WebRTC port (incl. setMicEnabled)
    signaling_service.dart          ← Abstract signaling port
    audio_service.dart              ← Abstract audio session port
    foreground_service.dart         ← Abstract foreground notification port
    call_log_repository.dart        ← Abstract call history port
    settings_repository.dart        ← Abstract settings port (incl. anonGuestMinutesAllowed=100)
    crash_reporter.dart             ← Abstract crash-reporting port (log, recordError, setCustomKey, setUserIdentifier)
    analytics_repository.dart       ← Abstract analytics port (logEvent, setUserId)
    auth_repository.dart            ← Abstract auth port (Google, email, anonymous, signOut)
    remote_config_repository.dart   ← Abstract Remote Config port (weekly limit, turn selector, email sign-in toggle)
  viewmodels/
    home_view_model.dart            ← Call orchestration, state, events, timers
  usecases/
    make_call_usecase.dart          ← Outgoing call setup → Result<CallLogEntry,AppError>
    answer_call_usecase.dart        ← Incoming call answer → Result<CallLogEntry,AppError>
    end_call_usecase.dart           ← Call teardown → Result<Unit,AppError>
  screens/
    login_screen.dart               ← Google / Email / Anonymous sign-in; routes to PermissionScreen
    register_screen.dart            ← Email registration; routes to PermissionScreen
    permission_screen.dart          ← Mic + notification permission request; auto-skips if already granted
    startup_error_screen.dart       ← Shown when AppBootstrapper.boot() throws (Firebase init failure)
    home_screen.dart                ← Pure StreamBuilder observer; no call logic
    call_screen.dart                ← Active call UI (timer, stats, volume, mute)
    settings_screen.dart            ← Call log retention, auto-answer whitelist, usage meters
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
    firebase_analytics_reporter.dart ← FirebaseAnalyticsReporter (implements AnalyticsRepository via firebase_analytics)
    firebase_auth_service.dart      ← FirebaseAuthService (implements AuthRepository); writes /emailToUid + /userProfiles
    firebase_remote_config_service.dart ← FirebaseRemoteConfigService (implements RemoteConfigRepository)

test/
  widget_test.dart                  ← Placeholder (void main {}); no widget tests yet
  mocks.dart                        ← 9 Mock classes + registerFallbackValues()
  usecases/
    make_call_usecase_test.dart     ← 12 unit tests
    answer_call_usecase_test.dart   ← 14 unit tests
    end_call_usecase_test.dart      ← 15 unit tests
  viewmodels/
    home_view_model_test.dart       ← 25 unit tests (incl. fakeAsync timer tests, analytics assertions, mic permission denied, weekly limit, remote config)
  services/
    call_log_service_test.dart      ← 4 unit tests (JSON round-trip, corrupt data recovery)

android/app/build.gradle.kts       ← google-services plugin, minSdk=24
android/settings.gradle.kts        ← google-services classpath
android/app/src/main/
  AndroidManifest.xml               ← Permissions + foreground service declaration
  kotlin/.../MainActivity.kt        ← stock FlutterActivity
.run/
  dev.run.xml                       ← Shared JetBrains Flutter run config for dev flavor
  prod.run.xml                      ← Shared JetBrains Flutter run config for prod flavor
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
flutter test test/                       # run all 75 unit tests
flutter test test/ --reporter=expanded   # verbose per-test output

# Shared JetBrains / Android Studio run configs are committed in .run/.
# Prefer "dev" for emulator/debug work and "prod" for
# production-flavor verification to avoid flavor-selection issues.
# Flutter still requires an explicit flavor for CLI builds when multiple
# product flavors exist, so the shared run configs are the repo-level default.
```

---

## Key Decisions & Current Behavior

- **Identity**: Firebase Auth (Google OAuth, email/password, or anonymous). On every successful auth, `FirebaseAuthService._afterAuth()` writes `/emailToUid/{encodedHandle}` and `/userProfiles/{uid}/email` to RTDB so peers can resolve a UID from a handle. For anonymous users the handle is `shortUidHash(uid)` — a 6-char alphanumeric derived from the UID. `HomeViewModel` reads `FirebaseAuth.instance.currentUser` to determine `_isAnonymous`.
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
- **Analytics abstraction**: `AnalyticsRepository` interface (`lib/interfaces/analytics_repository.dart`) wraps `firebase_analytics`. Injected into `HomeViewModel` only — all 9 event trigger points live there, not in use cases. Events tracked: `call_initiated`, `call_connected` (with `time_to_connect_ms`), `call_ended` (with `duration_s`, `role`, `bytes_sent`, `bytes_received`, `end_reason`), `call_failed`, `call_timed_out`, `incoming_call_received` (with `auto_answer_eligible`), `incoming_call_answered`, `incoming_call_auto_answered`, `incoming_call_missed`, `callee_busy`, `remote_disconnected`. `FirebaseAnalyticsReporter` is the only concrete impl; swapping backends requires only changing the DI registration. `end_reason` values: `user_ended`, `remote_disconnected`, `callee_busy`, `timed_out`.
- **Crashlytics abstraction**: `CrashReporter` interface (`lib/interfaces/crash_reporter.dart`) wraps `firebase_crashlytics`. Injected into `HomeViewModel` and all three use cases. Every `_emit()` call appends a breadcrumb. Custom keys per call: `role` (caller/callee), `turn_server_selected` (caller only), `call_state` (current `CallState` type). `FirebaseCrashReporter` (`lib/services/firebase_crash_reporter.dart`) is the only concrete impl; swapping to another backend (e.g. Sentry) requires changing only the DI registration in `service_locator.dart`.
- **Error handling layers**: Use cases wrap all I/O in a single outer try/catch returning `Err`. Services below the use case layer are intentionally bare — they rely on callers to catch. Exceptions that escape services are caught at the use-case boundary and returned as typed `AppError`. Two exceptions: (1) `CallLogService.loadLogs/saveEntry` wraps its own JSON parsing (corrupted prefs would crash the call history screen if not caught here); (2) `WebRtcService._startStatsPolling` wraps the async timer callback (async errors in `Timer.periodic` escape the zone if uncaught). Firebase signaling uses conditional casts (`raw is Map`) instead of unchecked `as Map` to prevent mid-call crashes from unexpected RTDB data shapes.
- **Startup error recovery**: `main()` wraps `AppBootstrapper.boot()` in try/catch. If Firebase init fails (missing `google-services.json`, no network on first launch), `StartupErrorScreen` is shown with a Retry button instead of a silent crash.
- **Microphone permission UX**: `HomeViewModel.makeCall()` and `answerCall()` check `Permission.microphone.status` before invoking the use case. If denied, `HomeEvent.microphonePermissionDenied` is emitted immediately and the use case is skipped. `HomeScreen` shows "Microphone permission is required. Please enable it in Settings." — a specific, actionable message instead of the generic "Call failed."
- **`turn_server_selected` key (caller only)**: Named to distinguish the caller's *chosen configuration* (metered / expressturn / both) from the *actual relay type* (stun / direct / turn) determined post-call via `resolveActualTurnUsed()` and stored in the call log. Callee logs no equivalent key — `role=callee` already deterministically implies `both`.
- **Auth flow + PermissionScreen**: Every auth path (Google, email, anonymous) routes to `PermissionScreen` before `HomeScreen`. `PermissionScreen.initState()` calls `Permission.microphone.isGranted`; if already granted it navigates straight to `HomeScreen` with no UI shown — returning users pass through transparently. `main()` routes signed-in users directly to `PermissionScreen` (same transparent-skip logic applies).
- **Anonymous guest limits**: `SettingsRepository.anonGuestMinutesAllowed = 100` is a hard lifetime cap on call minutes for anonymous users, tracked via `getAnonSecondsUsed()` / `addAnonSeconds()` in `SettingsRepository`. Additionally, a per-week limit from Remote Config (`getWeeklyCallLimitMinutes()`) applies to all users; `0` disables it. Exceeding either limit fires `HomeEvent.weeklyLimitReached`.
- **Remote Config flags**: `FirebaseRemoteConfigService` wraps `firebase_remote_config`. Three keys: `weekly_call_limit_minutes` (int, default 100 — use 0 to disable), `turn_selector_enabled` (bool, default false — show TURN picker in UI only to internal testers), `email_signin_enabled` (bool, default false — show email/password form on LoginScreen). `fetchAndActivate()` is called once in `AppBootstrapper.boot()`; failures fall back to in-app defaults silently.
- **`setMicEnabled(bool)`**: New method on `PeerConnectionService` interface. Used by the callee side to mute/unmute their own microphone track mid-call. `HomeViewModel.applyMute()` routes per role: caller calls `setRemoteVolume(0/saved)`, callee calls `setMicEnabled(false/true)`.

---

## Production Gaps

Items still needed before full production release:

| Priority | Item | Notes |
|----------|------|-------|
| Critical | Firebase Security Rules | RTDB is open; lock down — all paths now require `auth != null` since every user has a Firebase Auth UID |
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
