/// Authenticated user value object — implementation-agnostic.
class AuthUser {
  final String uid;
  final String? email;
  const AuthUser({required this.uid, this.email});
}

/// Abstract authentication port.
///
/// Implementations may use Firebase Auth, Supabase, a custom backend, etc.
/// Swap the concrete class in [service_locator.dart] without touching screens
/// or the ViewModel.
///
/// All methods throw on failure — callers (screens) wrap in try/catch.
abstract class AuthRepository {
  /// Currently signed-in user, or null if not authenticated.
  AuthUser? get currentUser;

  /// Stream that emits whenever the auth state changes (sign-in / sign-out).
  Stream<AuthUser?> get authStateChanges;

  /// Sign in with Google. Throws if the user cancels or on network errors.
  Future<AuthUser> signInWithGoogle();

  /// Sign in with [email] + [password]. Throws [FirebaseAuthException] on
  /// wrong credentials, unverified email, etc.
  Future<AuthUser> signInWithEmail(String email, String password);

  /// Create a new account with [email] + [password]. Throws on duplicate
  /// email, weak password, etc.
  Future<AuthUser> registerWithEmail(String email, String password);

  /// Sign out from all providers.
  Future<void> signOut();
}
