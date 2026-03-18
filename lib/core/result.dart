/// Represents the absence of a meaningful return value (unit type).
///
/// Use as the [T] parameter of [Result] for operations that succeed
/// with no data to return (e.g. `Result<Unit, AppError>`).
final class Unit {
  const Unit._();

  /// The singleton instance. Use `const Ok(Unit.instance)` for success.
  static const instance = Unit._();
}

/// Lightweight discriminated union returned by operations that may fail.
///
/// Pattern-match exhaustively with a `switch`:
/// ```dart
/// switch (result) {
///   case Ok(:final value) => use(value);
///   case Err(:final error) => handle(error);
/// }
/// ```
sealed class Result<T, E> {
  const Result();
}

/// A successful outcome carrying [value].
final class Ok<T, E> extends Result<T, E> {
  final T value;
  const Ok(this.value);
}

/// A failed outcome carrying [error].
final class Err<T, E> extends Result<T, E> {
  final E error;
  const Err(this.error);
}
