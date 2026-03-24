/// Derives a short 6-character alphanumeric identifier from a Firebase UID.
///
/// Used as the display handle for anonymous (guest) users who have no email.
/// The result is deterministic — the same UID always produces the same code.
/// Example output: "A3KF9Z"
String shortUidHash(String uid) {
  var hash = 0;
  for (final c in uid.codeUnits) {
    hash = (hash * 31 + c) & 0x7FFFFFFF; // keep positive
  }
  return hash.toRadixString(36).padLeft(6, '0').substring(0, 6).toUpperCase();
}
