# CLAUDE.md — Project Context for AI Assistants

## What This Is

Production 1-to-1 audio calling app for families. WebRTC for audio, Firebase Realtime Database for signaling, Android target. Package name: `com.familycall.children_voice_call`.

## Tech Stack

- Flutter (Dart) — Android only (no iOS yet)
- `flutter_webrtc: ^1.3.1` — WebRTC peer connection + audio
- `firebase_core: ^3.12.1` + `firebase_database: ^11.3.4` — Realtime Database signaling
- `shared_preferences: ^2.5.3` — persist userId, volume, mute, last remote ID
- `permission_handler: ^11.4.0` — runtime microphone permission
- `flutter_foreground_task: ^9.2.0` — Android foreground service (keeps process alive)
- `http: ^1.2.2` — fetch Metered TURN credentials
- STUN: `stun:stun.l.google.com:19302` (+ stun1, stun2)
- TURN: Metered.ca (dynamic credentials via API) + ExpressTURN (static fallback)
- Min SDK: 24

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  HomeScreen (screens/home_screen.dart)                       │
│  - Loads/persists userId (guaranteed by OnboardingScreen)    │
│  - Orchestrates call setup, teardown, and state              │
│  - Listens: /users/{myId}/incomingCall                       │
│    → auto-answer if callerId is whitelisted                  │
│    → show Answer button (40s timeout) otherwise              │
│  - Delegates to CallScreen when _inCall = true               │
│  - Handles: busy signal, call timeout (30s), mute state      │
│  - Tracks call logs + stats (bytesSent/Received)             │
└───────────┬─────────────────────────┬────────────────────────┘
            │ uses                    │ uses
┌───────────▼───────────┐ ┌──────────▼───────────────────────┐
│  FirebaseSignaling    │ │  WebRtcService                   │
│  (services/           │ │  (services/webrtc_service.dart)  │
│  firebase_signaling   │ │                                  │
│  .dart)               │ │  - init(isCaller, turnServer)    │
│                       │ │  - createOffer / createAnswer    │
│  - writeOffer/Answer  │ │  - setRemoteDescription          │
│  - writeIceCandidate  │ │  - addIceCandidate               │
│  - notifyRemoteUser   │ │  - setRemoteVolume(0.0–1.0)      │
│  - listenForAnswer    │ │  - resolveActualTurnUsed()       │
│  - listenForICE       │ │  - statsStream (1 Hz)            │
│  - listenForIncoming  │ │  - onConnectionLost/Established  │
│  - writeBusySignal    │ │  - close()                       │
│  - writeCancelled     │ └──────────────────────────────────┘
│  - listenForCancelled │
│  - isUserIdTaken      │ ┌──────────────────────────────────┐
│  - cancelListeners    │ │  CallScreen                      │
└───────────────────────┘ │  (screens/call_screen.dart)      │
                          │  - Elapsed timer (caller)        │
                          │  - Data usage stats (caller)     │
                          │  - Volume slider (caller)        │
                          │  - Mute/Unmute button            │
                          │  - End Call button (caller)      │
                          │  - "Waiting…" label (callee)     │
                          │  - Remote disconnect banner      │
                          └──────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  ForegroundService (services/foreground_service.dart)        │
│  - Persistent notification: "Waiting for calls…"            │
│  - In-call notification: "In call…" + buttons               │
│  - Notification buttons: End Call (both), Mute/Unmute(caller)│
│  - Forwards button taps → main isolate via sendDataToMain    │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  AudioService (services/audio_service.dart)                  │
│  - MODE_IN_COMMUNICATION, audio focus                        │
│  - Proximity wake lock (screen off when phone at ear)        │
│  - Earpiece/speaker routing based on proximity               │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  Supporting Services                                         │
│  CallLogService  — persist/query call history (SharedPrefs)  │
│  SettingsService — call log retention, auto-answer whitelist │
└──────────────────────────────────────────────────────────────┘
```

## Call Flow

```
Device A (caller)               Firebase RTDB              Device B (callee)
      │                              │                           │
      │ _makeCall()                  │                           │
      ├─► writeOffer + metadata ────►│                           │
      ├─► notifyRemoteUser ─────────►│──── incomingCall fires ──►│
      │                             │         whitelisted?       │
      │                             │         → _answerCall()    │
      │                             │         no → show button   │
      │                             │◄─── writeAnswer ──────────│
      │◄── listenForAnswer ─────────│                           │
      │◄────────────── ICE candidates exchanged ───────────────►│
      │◄═══════════ WebRTC audio (one-way: callee→caller) ══════►│
      │                             │                           │
      │ _endCall()                  │                           │
      ├─► writeCancelledSignal ────►│──── onCancelled ─────────►│
      │ cancelListeners + close     │     cancelListeners+close  │
      │                             │                           │
      │ OR: either side taps        │                           │
      │ notification "End Call" ──► HomeScreen._onForegroundData │
      │                 → _endCall()│                           │
```

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

## File Map

```
lib/
  main.dart                       ← Firebase init, userId check → Onboarding or Home
  screens/
    onboarding_screen.dart        ← First-launch: pick unique userId, check RTDB
    home_screen.dart              ← Main orchestrator: call setup, state, UI
    call_screen.dart              ← Active call UI
    settings_screen.dart          ← Call log retention, auto-answer whitelist
    call_logs_screen.dart         ← Call history: duration, bytes, TURN used
  services/
    firebase_signaling.dart       ← All Firebase RTDB operations (signaling)
    webrtc_service.dart           ← RTCPeerConnection, TURN fetch, audio, stats
    foreground_service.dart       ← Android foreground service wrapper
    audio_service.dart            ← MethodChannel: audio mode, proximity wake lock
    call_log_service.dart         ← CallLogEntry model + SharedPrefs persistence
    settings_service.dart         ← Call log retention + auto-answer whitelist

android/app/build.gradle.kts     ← google-services plugin, minSdk=24
android/settings.gradle.kts      ← google-services classpath
android/app/src/main/
  AndroidManifest.xml             ← Permissions + foreground service declaration
  kotlin/.../MainActivity.kt      ← stock FlutterActivity
pubspec.yaml
```

**Not in repo (must be added manually):** `android/app/google-services.json`

## Commands

```bash
flutter pub get      # install dependencies
flutter analyze      # static analysis
flutter run          # run on connected Android device/emulator
flutter build apk    # build release APK
```

## Key Decisions & Current Behavior

- **Identity**: User picks a unique ID on first launch (OnboardingScreen checks RTDB). Stored in SharedPreferences. No Firebase Auth.
- **Incoming call**: Whitelisted callers auto-connect. Non-whitelisted callers show an Answer button (40s timeout, then dismissed).
- **Auto-answer whitelist**: Managed in Settings. Checked by SettingsService on incoming call. Persisted in SharedPreferences.
- **Call ending**: Both sides can end the call via the notification "End Call" button. Only the caller has an in-app End Call button. Callee UI shows "Waiting for caller to end" — but can end via notification.
- **One-way audio**: Callee mic ON → sends to caller. Caller mic OFF (track.enabled = false). Caller hears callee; callee hears nothing. By design for child-monitoring use case.
- **Volume control**: Per-call WebRTC gain (0.0–1.0) via `Helper.setVolume()`. Does not touch system volume. Persisted across calls. Disabled while muted.
- **Mute**: Sets remote volume to 0.0 (caller side). Synced between in-app slider, foreground notification button, and CallScreen UI.
- **TURN selection**: Caller picks Metered / ExpressTURN / Both from segmented button. Callee always uses 'both'. Actual relay used is detected post-call via `resolveActualTurnUsed()` and stored in call log.
- **Call logs**: Every call (caller and callee) is logged: role, remote userId, start/end time, bytes sent/received, TURN selected vs actually used. Retention configurable (1–30 days, default 7).
- **Proximity sensor**: AudioService acquires proximity wake lock during caller's call — screen turns off when held to ear.
- **Foreground service**: Keeps process alive in background. Notification shows "Waiting for calls…" or "In call…" with action buttons. Does NOT survive force-close (FCM push needed for that).
- **Busy signal**: If callee is already in a call (or has a pending incoming call), it writes `/users/{callerId}/busySignal`. Caller gets a snackbar and auto-ends.
- **Connection timeout**: Caller auto-hangs up after 30s if WebRTC never reaches connected state.
- **Remote disconnect detection**: WebRTC `onConnectionState` fires `onConnectionLost` once on failure/closed/disconnected. Caller sees a 2s banner then call ends. Callee also fires `_onCallEnded`.
- **No cleanup**: Old call records in Firebase RTDB persist indefinitely. No TTL, no Cloud Function pruning.
- **No error handling**: Core WebRTC and Firebase calls use `!` force-unwraps and no try/catch (except TURN credential fetch).

## Production Gaps

Items still needed before full production release:

| Priority | Item | Notes |
|----------|------|-------|
| Critical | Firebase Security Rules | RTDB is likely open; lock down to authenticated users |
| Critical | Firebase Auth | Replace custom ID system with proper auth (phone/anonymous) |
| Critical | TURN credential proxy | Firebase Cloud Function to proxy Metered API; API key never in client |
| High | FCM push notifications | App can't receive calls when force-closed |
| High | Error handling | Add try/catch around WebRTC + Firebase ops; remove `!` unwraps |
| High | iOS support | Add iOS target, permissions, background audio entitlement |
| Medium | Firebase data cleanup | Cloud Function or TTL to prune stale call records |
| Medium | Two-way audio | Enable both sides to speak/hear (currently callee→caller only) |
| Medium | Reconnection logic | Auto-retry on transient network failures |
| Medium | CallKit integration | iOS native incoming call screen |
| Low | Bluetooth audio | Handle headset connection/disconnection |
| Low | Cellular interruption | Pause/resume on incoming cellular call |
| Low | Battery optimization | Request battery optimization exemption |
