# CLAUDE.md — Project Context for AI Assistants

## What This Is

1-to-1 audio calling POC app. WebRTC for audio, Firebase Realtime Database for signaling. Android only. Throwaway prototype — no polish, no production concerns.

## Tech Stack

- Flutter (Dart) — Android target only, no iOS
- `flutter_webrtc: ^0.12.9` — WebRTC peer connection + audio
- `firebase_core: ^3.12.1` + `firebase_database: ^11.3.4` — Realtime Database signaling
- `shared_preferences: ^2.5.3` — persist user ID
- `permission_handler: ^11.4.0` — runtime microphone permission
- STUN server: `stun:stun.l.google.com:19302`
- Package: `com.familycall.children_voice_call`
- Min SDK: 24

## Architecture

Modular structure with separated services:

```
┌──────────────────────────────────────────────────────────────┐
│  HomeScreen (screens/home_screen.dart)                       │
│  - Generates/persists userId via SharedPreferences           │
│  - Orchestrates both services for call setup                 │
│  - Listens: /users/{myId}/incomingCall → auto-accept         │
│  - Delegates to CallScreen when _inCall = true               │
└────────────┬──────────────────────────┬──────────────────────┘
             │ uses                     │ uses
┌────────────▼──────────────┐ ┌────────▼──────────────────────┐
│  FirebaseSignaling        │ │  WebRtcService                │
│  (services/               │ │  (services/                   │
│   firebase_signaling.dart)│ │   webrtc_service.dart)        │
│                           │ │                               │
│  - writeOffer/readOffer   │ │  - createPeerConnection()     │
│  - writeAnswer            │ │  - createOffer/createAnswer   │
│  - writeIceCandidate      │ │  - setRemoteDescription()    │
│  - setStatus              │ │  - addIceCandidate()         │
│  - notifyRemoteUser       │ │  - onIceCandidate setter     │
│  - listenForAnswer        │ │  - close()                   │
│  - listenForIceCandidates │ └───────────────────────────────┘
│  - listenForStatus        │
│  - listenForIncomingCall  │ ┌───────────────────────────────┐
│  - setUserOnline          │ │  CallScreen                   │
│  - cancelListeners        │ │  (screens/call_screen.dart)   │
└───────────────────────────┘ │  - End Call button            │
                              └───────────────────────────────┘
```

## Call Flow

```
Device A (caller)                Firebase RTDB              Device B (callee)
      │                               │                          │
      │ _makeCall()                    │                          │
      ├──► write /calls/{id}/offer ───►│                          │
      ├──► write /calls/{id}/status=waiting                       │
      ├──► write /users/B/incomingCall={id} ─────────────────────►│
      │                               │              onValue fires│
      │                               │             _answerCall() │
      │                               │◄── read offer             │
      │                               │◄── write /calls/{id}/answer
      │◄── onValue(answer) ───────────│                          │
      │                               │                          │
      │◄──── ICE candidates exchanged via ────────────────────────►│
      │    /offerCandidates + /answerCandidates                   │
      │                               │                          │
      │◄═══════════ WebRTC audio stream established ═════════════►│
      │                               │                          │
      │ _endCall()                     │                          │
      ├──► set status="ended" ────────►│──── onValue(ended) ─────►│
      │ cancelListeners + close        │      cancelListeners     │
      │                               │      + close              │
```

## Firebase Realtime Database Schema

```
/users/{userId}/
  online: true                          ← presence, auto-cleared on disconnect
  incomingCall: "{callId}"              ← written by caller, cleared by callee

/calls/{callId}/
  offer: { sdp: String, type: String }
  answer: { sdp: String, type: String }
  offerCandidates/{pushId}: { candidate, sdpMid, sdpMLineIndex }
  answerCandidates/{pushId}: { candidate, sdpMid, sdpMLineIndex }
  status: "waiting" | "active" | "ended"
  caller: "{userId}"
  callee: "{userId}"
```

Call ID format: `{callerId}_{calleeId}_{timestampMs}`

## File Map

```
lib/
  main.dart                          ← Entry point: Firebase init + runApp
  services/
    firebase_signaling.dart          ← All Firebase RTDB operations (signaling)
    webrtc_service.dart              ← RTCPeerConnection lifecycle + audio
  screens/
    home_screen.dart                 ← HomeScreen: orchestrates services, UI
    call_screen.dart                 ← Active call UI (End Call button)

android/app/build.gradle.kts        ← google-services plugin, minSdk=24
android/settings.gradle.kts         ← google-services classpath
android/app/src/main/
  AndroidManifest.xml                ← INTERNET, RECORD_AUDIO, MODIFY_AUDIO_SETTINGS
  kotlin/.../MainActivity.kt        ← stock FlutterActivity, untouched
pubspec.yaml                         ← 5 dependencies total
```

**Not in repo (must be added manually):** `android/app/google-services.json`

## Commands

```bash
flutter pub get          # install dependencies
flutter analyze          # static analysis (should be 0 issues)
flutter run              # run on connected Android device/emulator
```

## Key Decisions & Constraints

- **Auto-accept**: No ringing UI. Callee detects `/users/{myId}/incomingCall` via `onValue` listener and immediately answers.
- **Caller-only end call**: Only the caller sees the "End Call" button. Callee stays in call until the caller hangs up.
- **Separated services**: Firebase signaling and WebRTC are independent services. HomeScreen orchestrates them.
- **No video**: getUserMedia called with `audio: true, video: false`.
- **No TURN server**: Only STUN (Google's public one). Will fail behind symmetric NATs.
- **No cleanup of stale Firebase data**: Old call records persist. No TTL or cloud function to prune.
- **No error handling**: All `!` force-unwraps, no try/catch around WebRTC or Firebase ops.
- **No background support**: App must be in foreground to receive calls.

## Intentionally Skipped (do NOT add unless asked)

iOS support, foreground service, CallKit, notifications, wake lock, call timer, mute/speaker toggles, network quality indicator, reconnection logic, dark mode, error retry, sound effects, Bluetooth handling, cellular interruption handling, battery optimization, persistent notification, ringing UI.
