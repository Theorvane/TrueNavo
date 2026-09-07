import 'dart:async';

abstract interface class CredentialVault {
  /// The identifier is a validated canonical connection URI, never display input.
  Future<String?> readApiKey(String endpointIdentifier);

  /// Persists [apiKey] only while [isCurrent] remains true.
  ///
  /// Implementations which persist values must snapshot and restore the prior
  /// value if currentness changes during their asynchronous write.
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  });
  Future<void> deleteApiKey(String endpointIdentifier);
}

/// A vault write completed after its owning connection was invalidated.
final class CredentialWriteCancelledException implements Exception {
  const CredentialWriteCancelledException();

  @override
  String toString() => 'Credential write was cancelled.';
}

enum CredentialUnavailableReason { missing, unavailable, cancelled }

/// Fixed public-safe credential resolution failure.
final class CredentialUnavailableException implements Exception {
  const CredentialUnavailableException(this.reason);

  final CredentialUnavailableReason reason;

  String get userMessage => switch (reason) {
    CredentialUnavailableReason.missing =>
      'An API key is required to connect to this server.',
    CredentialUnavailableReason.unavailable =>
      'Remembered credentials are unavailable. Enter an API key and try again.',
    CredentialUnavailableReason.cancelled =>
      'The connection was cancelled before credentials could be used.',
  };

  @override
  String toString() => userMessage;
}

final class NoopCredentialVault implements CredentialVault {
  const NoopCredentialVault();
  @override
  Future<void> deleteApiKey(String endpointIdentifier) async {}
  @override
  Future<String?> readApiKey(String endpointIdentifier) async => null;
  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async {
    if (!(isCurrent?.call() ?? true)) {
      throw const CredentialWriteCancelledException();
    }
  }
}

/// Test/future-adapter boundary only; no M0 UI writes to this vault.
final class InMemoryCredentialVault implements CredentialVault {
  final _keys = <String, String>{};
  Future<void> _operationTail = Future<void>.value();
  @override
  Future<void> deleteApiKey(String endpointIdentifier) =>
      _serialize(() => _keys.remove(endpointIdentifier));
  @override
  Future<String?> readApiKey(String endpointIdentifier) =>
      _serialize(() => _keys[endpointIdentifier]);
  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) => _serialize(() {
    _requireCurrent(isCurrent);
    final previous = _keys[endpointIdentifier];
    _requireCurrent(isCurrent);
    _keys[endpointIdentifier] = apiKey;
    if (isCurrent?.call() ?? true) return;
    if (previous == null) {
      _keys.remove(endpointIdentifier);
    } else {
      _keys[endpointIdentifier] = previous;
    }
    throw const CredentialWriteCancelledException();
  });

  Future<T> _serialize<T>(FutureOr<T> Function() operation) {
    final Future<T> result = _operationTail.then<T>((_) => operation());
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  void _requireCurrent(bool Function()? isCurrent) {
    if (!(isCurrent?.call() ?? true)) {
      throw const CredentialWriteCancelledException();
    }
  }
}
