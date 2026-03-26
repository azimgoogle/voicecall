import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/uid_utils.dart';
import '../interfaces/auth_repository.dart';

/// Firebase Auth implementation of [AuthRepository].
///
/// On every successful authentication, writes two RTDB entries so other users
/// can resolve this user's UID from their email:
///   /emailToUid/{encodedEmail}  → uid
///   /userProfiles/{uid}/email   → email
///
/// Dots (.) are replaced with commas (,) in RTDB keys because Firebase
/// Realtime Database does not allow dots in key names.
class FirebaseAuthService implements AuthRepository {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  @override
  AuthUser? get currentUser {
    final user = _auth.currentUser;
    if (user == null) return null;
    return AuthUser(uid: user.uid, email: user.email);
  }

  @override
  Stream<AuthUser?> get authStateChanges => _auth.authStateChanges().map(
        (user) => user == null ? null : AuthUser(uid: user.uid, email: user.email),
      );

  @override
  Future<AuthUser> signInWithGoogle() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) throw Exception('Google sign-in cancelled');

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final result = await _auth.signInWithCredential(credential);
    return _afterAuth(result.user!);
  }

  @override
  Future<AuthUser> signInWithEmail(String email, String password) async {
    final result = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    return _afterAuth(result.user!);
  }

  @override
  Future<AuthUser> registerWithEmail(String email, String password) async {
    final result = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    return _afterAuth(result.user!);
  }

  @override
  Future<AuthUser> signInAnonymously() async {
    final result = await _auth.signInAnonymously();
    return _afterAuth(result.user!);
  }

  @override
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
  }

  @override
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) return;

    final email = user.email;
    final handle = email ?? shortUidHash(user.uid);
    final encodedHandle = handle.replaceAll('.', ',');

    // Remove RTDB entries — best effort, don't block deletion on failure.
    try {
      await Future.wait([
        _db.child('emailToUid/$encodedHandle').remove(),
        _db.child('userProfiles/${user.uid}').remove(),
      ]);
    } catch (_) {}

    await _googleSignIn.signOut();
    await user.delete(); // throws FirebaseAuthException(requires-recent-login) if session is stale
  }

  /// Writes the handle↔UID mapping to RTDB after any successful auth, then
  /// returns an [AuthUser]. Silently ignores RTDB write failures — the user
  /// is still signed in even if the mapping write fails.
  ///
  /// For email users the handle is their email address.
  /// For anonymous users the handle is their UID (no dots, so no encoding needed).
  Future<AuthUser> _afterAuth(User user) async {
    final email = user.email;
    // Use email as handle for registered users; fall back to a short hash for anonymous.
    final handle = email ?? shortUidHash(user.uid);
    final encodedHandle = handle.replaceAll('.', ',');
    try {
      await Future.wait([
        _db.child('emailToUid/$encodedHandle').set(user.uid),
        _db.child('userProfiles/${user.uid}/email').set(handle),
      ]);
    } catch (_) {
      // Non-fatal: RTDB write failed (offline, permissions not yet set up).
    }
    return AuthUser(uid: user.uid, email: email);
  }
}
