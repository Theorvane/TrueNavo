/// Stable, credential-free failures exposed by local persistence.
enum PersistenceFailureKind { validation, conflict, notFound, unavailable }

final class PersistenceFailure implements Exception {
  const PersistenceFailure(this.kind);

  final PersistenceFailureKind kind;

  String get message => switch (kind) {
    PersistenceFailureKind.validation => 'This saved server data is invalid.',
    PersistenceFailureKind.conflict =>
      'A saved server already uses that identifier.',
    PersistenceFailureKind.notFound => 'The saved server was not found.',
    PersistenceFailureKind.unavailable =>
      'Local storage is temporarily unavailable.',
  };

  @override
  String toString() => message;
}
