# Voice Call POC

Minimal 1-to-1 audio calling app using WebRTC + Firebase Realtime Database for signaling. Android only.

## Setup

### 1. Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com/) and create a new project (or use existing)
2. Add an **Android app** with package name `com.familycall.children_voice_call`
3. Download `google-services.json` and place it in `android/app/`
4. Enable **Realtime Database** (not Firestore) in the Firebase console
5. Set database rules to allow read/write for testing:

```json
{
  "rules": {
    ".read": true,
    ".write": true
  }
}
```

### 2. Run

```bash
flutter pub get
flutter run
```

### 3. Test a Call

1. Install on two Android devices (or one device + one emulator)
2. Each device auto-generates a user ID shown at the top
3. On Device A: enter Device B's user ID and tap **Call**
4. Device B auto-accepts the call — audio should flow
5. Either device can tap **End Call** to hang up

## Architecture

- **Signaling**: Firebase Realtime Database exchanges SDP offers/answers and ICE candidates
- **WebRTC**: `flutter_webrtc` handles peer connection and audio streaming
- **Auto-answer**: Callee listens on `/users/{myId}/incomingCall` and immediately establishes the connection when a call ID appears

## Firebase Data Structure

```
/users/{userId}/online: true
/users/{userId}/incomingCall: "{callId}"
/calls/{callId}/
  offer: { sdp, type }
  answer: { sdp, type }
  offerCandidates/{id}: { candidate, sdpMid, sdpMLineIndex }
  answerCandidates/{id}: { candidate, sdpMid, sdpMLineIndex }
  status: "waiting" | "active" | "ended"
```
