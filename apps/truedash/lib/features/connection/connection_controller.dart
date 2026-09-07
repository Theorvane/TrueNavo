import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../local_persistence/persistence_failure.dart';
import '../server_profiles/server_profile.dart';
import '../server_profiles/server_profiles_controller.dart';
import '../tls_trust/certificate_facts.dart';
import '../tls_trust/certificate_trust_coordinator.dart';
import '../tls_trust/models.dart';
import '../tls_trust/tls_trust_providers.dart';
import 'connection_state.dart';

final rpcConnectorProvider = Provider<RpcConnector>(
  (ref) => const WebSocketRpcConnector(),
);

final credentialVaultProvider = Provider<CredentialVault>(
  (ref) => const NoopCredentialVault(),
);

/// UTC seam for capability-cache expiry. Bootstrap uses the real UTC clock.
final serverProfileClockProvider = Provider<DateTime Function()>(
  (ref) =>
      () => DateTime.now().toUtc(),
);

const _capabilityLifetime = Duration(hours: 24);

typedef SessionRepositoryFactory = SessionRepository Function({
  required RpcConnector connector,
  required CredentialVault credentialVault,
});

final sessionRepositoryFactoryProvider = Provider<SessionRepositoryFactory>(
  (ref) =>
      ({required connector, required credentialVault}) =>
          TrueNasSessionRepository(
            connector: connector,
            credentialVault: credentialVault,
          ),
);

/// Retained as the normal public-certificate repository seam used by M0.
final sessionRepositoryProvider = Provider<SessionRepository>((ref) {
  final repository = ref.watch(sessionRepositoryFactoryProvider)(
    connector: ref.watch(rpcConnectorProvider),
    credentialVault: ref.watch(credentialVaultProvider),
  );
  ref.onDispose(() {
    unawaited(_closeRepositorySafely(repository));
  });
  return repository;
});

/// Couples a provider-owned repository to the lifetime of its provider value.
/// The controller never caches this repository; it only retains this lease for
/// the duration of one authentication operation.
final _sessionRepositoryLeaseProvider = Provider<_SessionRepositoryLease>((
  ref,
) {
  final lease = _SessionRepositoryLease(ref.watch(sessionRepositoryProvider));
  ref.onDispose(lease.invalidate);
  return lease;
});

final class _SessionRepositoryLease {
  _SessionRepositoryLease(this.repository);

  final SessionRepository repository;
  var _isCurrent = true;

  bool get isCurrent => _isCurrent;

  void invalidate() => _isCurrent = false;
}

enum _AuthenticationValidity { current, stale, repositoryUnavailable }

Future<void> _closeRepositorySafely(SessionRepository repository) async {
  try {
    await repository.close();
  } catch (_) {
    // Provider disposal cannot await cleanup or surface cleanup failures.
  }
}

final connectionControllerProvider =
    NotifierProvider<ConnectionController, ConnectionState>(
      ConnectionController.new,
    );

final class ConnectionController extends Notifier<ConnectionState> {
  SessionRepository? _verifiedRepository;
  var _nextProfileId = 0;
  var _generation = 0;
  var _busy = false;
  var _disposed = false;

  @override
  ConnectionState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      final verified = _verifiedRepository;
      _verifiedRepository = null;
      _closeSafely(verified);
    });
    return const ConnectionIdle();
  }

  Future<void> connect({
    required String serverInput,
    required String apiKey,
  }) async {
    if (_busy) return;
    final int generation = ++_generation;
    final visibleReview = state;
    if (visibleReview is ConnectionTrustReview) {
      _busy = true;
      state = const ConnectionInProgress();
      CertificateTrustState cancelled;
      try {
        cancelled = await ref
            .read(certificateTrustCoordinatorProvider)
            .cancel(visibleReview.token);
      } catch (_) {
        if (_current(generation)) {
          _busy = false;
          state = const ConnectionFailed(
            'Unable to reach the server over a secure connection.',
          );
        }
        return;
      }
      if (!_current(generation)) return;
      if (cancelled is! BlockedTrust ||
          cancelled.failure != CertificateTrustCoordinatorFailure.cancelled) {
        _busy = false;
        state = ConnectionTrustBlocked(
          failure: cancelled is BlockedTrust
              ? cancelled.failure
              : CertificateTrustCoordinatorFailure.cleanup,
          token: visibleReview.token,
          authority: visibleReview.authority,
        );
        return;
      }
    }
    final NormalizedAuthority authority;
    try {
      authority = NormalizedAuthority.parse(serverInput);
    } on AuthorityValidationException catch (error) {
      _busy = false;
      state = ConnectionFailed(error.message);
      return;
    }
    final TlsTrustRoute route;
    try {
      route = ref.read(tlsTrustRouteProvider);
    } catch (_) {
      _busy = false;
      state = const ConnectionFailed(
        'Unable to reach the server over a secure connection.',
      );
      return;
    }
    if (route == TlsTrustRoute.browserManaged) {
      _busy = false;
      state = const ConnectionBrowserManagedTls();
      return;
    }
    _busy = true;
    state = const ConnectionInProgress();
    if (route == TlsTrustRoute.platformValidated) {
      await _authenticateNormal(
        generation: generation,
        serverInput: serverInput,
        apiKey: apiKey,
      );
      return;
    }
    final CertificateTrustCoordinator coordinator;
    final TrustOperationHandle handle;
    final CertificateTrustState trust;
    try {
      coordinator = ref.read(certificateTrustCoordinatorProvider);
      handle = coordinator.start(authority);
      trust = await handle.state;
    } catch (_) {
      if (_current(generation)) {
        _busy = false;
        state = const ConnectionFailed(
          'Unable to reach the server over a secure connection.',
        );
      }
      return;
    }
    if (await _staleCoordinatorResult(generation, trust)) return;
    if (trust is FirstTrustReview &&
        trust.certificate.platformTrust == PlatformTrust.passed) {
      // A normally trusted public certificate keeps the existing connector;
      // the credential-free review is released before authentication.
      CertificateTrustState cancelled;
      try {
        cancelled = await coordinator.cancel(handle.token);
      } catch (_) {
        if (_current(generation)) {
          _busy = false;
          state = const ConnectionFailed(
            'Unable to reach the server over a secure connection.',
          );
        }
        return;
      }
      if (!_current(generation)) return;
      if (cancelled is! BlockedTrust ||
          cancelled.failure != CertificateTrustCoordinatorFailure.cancelled) {
        _publishTrust(generation, cancelled, handle.token, authority);
        return;
      }
      await _authenticateNormal(
        generation: generation,
        serverInput: serverInput,
        apiKey: apiKey,
      );
      return;
    }
    await _afterTrust(
      generation: generation,
      authority: authority,
      apiKey: apiKey,
      trust: trust,
      fallbackToken: handle.token,
    );
  }

  Future<void> approveTrust({required String apiKey}) async {
    final review = state;
    if (review is! ConnectionTrustReview || _busy) return;
    final generation = ++_generation;
    _busy = true;
    state = const ConnectionInProgress();
    CertificateTrustState trust;
    try {
      trust = await ref
          .read(certificateTrustCoordinatorProvider)
          .approve(review.token);
    } catch (_) {
      if (_current(generation)) {
        _busy = false;
        state = const ConnectionFailed(
          'Unable to reach the server over a secure connection.',
        );
      }
      return;
    }
    if (await _staleCoordinatorResult(generation, trust)) return;
    await _afterTrust(
      generation: generation,
      authority: review.authority,
      apiKey: apiKey,
      trust: trust,
      fallbackToken: review.token,
    );
  }

  Future<void> cancelTrust() async {
    final review = state;
    if (review is! ConnectionTrustReview || _busy) return;
    final generation = ++_generation;
    _busy = true;
    state = const ConnectionInProgress();
    CertificateTrustState trust;
    try {
      trust = await ref
          .read(certificateTrustCoordinatorProvider)
          .cancel(review.token);
    } catch (_) {
      if (_current(generation)) {
        _busy = false;
        state = const ConnectionFailed(
          'Unable to reach the server over a secure connection.',
        );
      }
      return;
    }
    if (await _staleCoordinatorResult(generation, trust)) return;
    _publishTrust(generation, trust, review.token, review.authority);
  }

  Future<void> retryTrust({String? apiKey}) async {
    final blocked = state;
    if (blocked is! ConnectionTrustBlocked || _busy) return;
    final generation = ++_generation;
    _busy = true;
    state = const ConnectionInProgress();
    CertificateTrustState trust;
    try {
      trust = await ref
          .read(certificateTrustCoordinatorProvider)
          .retry(blocked.token);
    } catch (_) {
      if (_current(generation)) {
        _busy = false;
        state = const ConnectionFailed(
          'Unable to reach the server over a secure connection.',
        );
      }
      return;
    }
    if (await _staleCoordinatorResult(generation, trust)) return;
    if (trust is VerifiedTrustTransport && apiKey != null) {
      await _afterTrust(
        generation: generation,
        authority: blocked.authority,
        apiKey: apiKey,
        trust: trust,
        fallbackToken: blocked.token,
      );
      return;
    }
    if (trust is VerifiedTrustTransport) {
      final cleanupFailed = !await _closeTransport(trust.transport);
      _publishTrust(
        generation,
        BlockedTrust(
          cleanupFailed
              ? CertificateTrustCoordinatorFailure.cleanup
              : CertificateTrustCoordinatorFailure.invalidOperation,
        ),
        blocked.token,
        blocked.authority,
      );
      return;
    }
    _publishTrust(generation, trust, blocked.token, blocked.authority);
  }

  Future<void> _afterTrust({
    required int generation,
    required NormalizedAuthority authority,
    required String apiKey,
    required CertificateTrustState trust,
    required TrustOperationToken fallbackToken,
  }) async {
    if (trust is VerifiedTrustTransport) {
      final connector = _OneShotVerifiedConnector(
        expectedEndpoint: authority.rpcConnectionUri,
        transport: trust.transport,
      );
      final SessionRepository repository;
      try {
        repository = ref.read(sessionRepositoryFactoryProvider)(
          connector: connector,
          credentialVault: ref.read(credentialVaultProvider),
        );
      } catch (_) {
        await connector.discard();
        if (_current(generation)) {
          _busy = false;
          state = const ConnectionFailed(
            'Unable to reach the server over a secure connection.',
          );
        }
        return;
      }
      await _authenticate(
        generation: generation,
        repository: repository,
        serverInput: authority.rpcConnectionUri.toString(),
        apiKey: apiKey,
        closeOnFailure: true,
        discardUnconsumed: connector.discard,
        verifiedConnector: connector,
      );
      return;
    }
    _publishTrust(generation, trust, fallbackToken, authority);
  }

  Future<void> _authenticate({
    required int generation,
    required SessionRepository repository,
    required String serverInput,
    required String apiKey,
    required bool closeOnFailure,
    Future<void> Function()? discardUnconsumed,
    _OneShotVerifiedConnector? verifiedConnector,
    bool Function()? isRepositoryCurrent,
  }) async {
    // A verified repository starts caller-owned. Assigning it below transfers
    // that ownership to the controller, including across awaits while a prior
    // verified repository is being displaced.
    var repositoryTransferred = false;
    // Factory/provider reads may synchronously dispose this controller. Keep
    // this immediately before the key handoff so every authentication path is
    // protected after its final synchronous dependency read.
    if (await _abandonAuthenticationIfNeeded(
      generation: generation,
      validity: _authenticationValidity(generation, isRepositoryCurrent),
      repository: repository,
      closeOnFailure: closeOnFailure,
      callerOwnsRepository: !repositoryTransferred,
      discardUnconsumed: discardUnconsumed,
    )) {
      return;
    }
    try {
      final summary = await repository.connect(
        serverInput: serverInput,
        apiKey: apiKey,
      );
      if (await _abandonAuthenticationIfNeeded(
        generation: generation,
        validity: _authenticationValidity(generation, isRepositoryCurrent),
        repository: repository,
        closeOnFailure: closeOnFailure,
        callerOwnsRepository: !repositoryTransferred,
        discardUnconsumed: discardUnconsumed,
      )) {
        return;
      }
      if (verifiedConnector != null &&
          !verifiedConnector.wasConsumedForExpectedEndpoint) {
        await discardUnconsumed?.call();
        await _closeSafely(repository);
        if (_current(generation)) {
          _busy = false;
          state = const ConnectionFailed(
            'Unable to reach the server over a secure connection.',
          );
        }
        return;
      }
      await discardUnconsumed?.call();
      if (await _abandonAuthenticationIfNeeded(
        generation: generation,
        validity: _authenticationValidity(generation, isRepositoryCurrent),
        repository: repository,
        closeOnFailure: closeOnFailure,
        callerOwnsRepository: !repositoryTransferred,
      )) {
        return;
      }
      if (closeOnFailure) {
        final displaced = _verifiedRepository;
        _verifiedRepository = repository;
        repositoryTransferred = true;
        if (displaced != null && !identical(displaced, repository)) {
          await _closeSafely(displaced);
        }
      }
      final profiles = ref.read(serverProfilesControllerProvider.notifier);
      if (await _abandonAuthenticationIfNeeded(
        generation: generation,
        validity: _authenticationValidity(generation, isRepositoryCurrent),
        repository: repository,
        closeOnFailure: closeOnFailure,
        callerOwnsRepository: !repositoryTransferred,
      )) {
        return;
      }
      final registration = await profiles.registerAndSelect(
        ServerProfile.fromSafeSummary(
          id: _nextAvailableProfileId(),
          summary: summary,
        ),
      );
      if (await _abandonAuthenticationIfNeeded(
        generation: generation,
        validity: _authenticationValidity(generation, isRepositoryCurrent),
        repository: repository,
        closeOnFailure: closeOnFailure,
        callerOwnsRepository: !repositoryTransferred,
      )) {
        return;
      }
      if (!registration.succeeded ||
          registration.snapshot.selectedProfileId == null) {
        throw const PersistenceFailure(PersistenceFailureKind.unavailable);
      }
      final observedAt = ref.read(serverProfileClockProvider)().toUtc();
      if (await _abandonAuthenticationIfNeeded(
        generation: generation,
        validity: _authenticationValidity(generation, isRepositoryCurrent),
        repository: repository,
        closeOnFailure: closeOnFailure,
        callerOwnsRepository: !repositoryTransferred,
      )) {
        return;
      }
      await ref
          .read(serverProfileStoreProvider)
          .replaceCapabilities(
            profileId: registration.snapshot.selectedProfileId!,
            methodNames: summary.availableMethodNames,
            observedAt: observedAt,
            expiresAt: observedAt.add(_capabilityLifetime),
          );
      if (await _abandonAuthenticationIfNeeded(
        generation: generation,
        validity: _authenticationValidity(generation, isRepositoryCurrent),
        repository: repository,
        closeOnFailure: closeOnFailure,
        callerOwnsRepository: !repositoryTransferred,
      )) {
        return;
      }
      _busy = false;
      state = ConnectionSucceeded(summary);
    } catch (error) {
      await discardUnconsumed?.call();
      final validity = _authenticationValidity(generation, isRepositoryCurrent);
      if (repositoryTransferred &&
          validity == _AuthenticationValidity.current) {
        await _detachAndCloseVerifiedRepository(repository);
      } else if (!repositoryTransferred && closeOnFailure) {
        await _closeSafely(repository);
      }
      if (validity != _AuthenticationValidity.current) {
        _publishUnavailableRepositoryFailure(generation, validity);
        return;
      }
      _busy = false;
      state = _safeFailure(error);
    }
  }

  Future<void> _authenticateNormal({
    required int generation,
    required String serverInput,
    required String apiKey,
  }) async {
    final _SessionRepositoryLease lease;
    try {
      lease = ref.read(_sessionRepositoryLeaseProvider);
    } catch (_) {
      if (_current(generation)) {
        _busy = false;
        state = const ConnectionFailed(
          'Unable to reach the server over a secure connection.',
        );
      }
      return;
    }
    await _authenticate(
      generation: generation,
      repository: lease.repository,
      serverInput: serverInput,
      apiKey: apiKey,
      closeOnFailure: false,
      isRepositoryCurrent: () =>
          identical(ref.read(_sessionRepositoryLeaseProvider), lease) &&
          lease.isCurrent,
    );
  }

  void _publishTrust(
    int generation,
    CertificateTrustState trust,
    TrustOperationToken? fallbackToken,
    NormalizedAuthority fallbackAuthority,
  ) {
    if (!_current(generation)) return;
    _busy = false;
    switch (trust) {
      case FirstTrustReview review:
        state = ConnectionFirstTrustReview(
          token: review.token,
          authority: review.authority,
          certificate: _display(
            review.certificate.facts,
            review.certificate.platformTrust,
          ),
        );
      case ReplacementTrustReview review:
        state = ConnectionReplacementTrustReview(
          token: review.token,
          authority: review.authority,
          previousPin: TrustReviewPreviousPin(
            leafDerSha256: review.previousPin.leafDerSha256,
            createdAt: review.previousPin.createdAt,
          ),
          certificate: _display(
            review.certificate.facts,
            review.certificate.platformTrust,
          ),
        );
      case BlockedTrust blocked:
        if (fallbackToken == null) {
          state = ConnectionFailed(
            'Unable to reach the server over a secure connection.',
          );
        } else {
          state = ConnectionTrustBlocked(
            failure: blocked.failure,
            token: fallbackToken,
            authority: fallbackAuthority,
          );
        }
      case BrowserManagedTrust():
        state = const ConnectionBrowserManagedTls();
      case VerifiedTrustTransport():
        if (fallbackToken == null) {
          state = ConnectionFailed(
            'Unable to reach the server over a secure connection.',
          );
        } else {
          state = ConnectionTrustBlocked(
            failure: CertificateTrustCoordinatorFailure.invalidOperation,
            token: fallbackToken,
            authority: fallbackAuthority,
          );
        }
    }
  }

  TrustReviewCertificate _display(
    CertificateFacts facts,
    PlatformTrust trust,
  ) => TrustReviewCertificate.fromFacts(facts, trust);

  ConnectionFailed _safeFailure(Object error) => switch (error) {
    EndpointValidationException(:final message) => ConnectionFailed(message),
    TlsCertificateException(:final userMessage) => ConnectionFailed(
      userMessage,
    ),
    AuthenticationStateException(:final userMessage) => ConnectionFailed(
      userMessage,
    ),
    JsonRpcRemoteException() => const ConnectionFailed(
      'The server returned an RPC error. Check access and try again.',
    ),
    JsonRpcProtocolException() => const ConnectionFailed(
      'The server sent an invalid RPC response.',
    ),
    RpcTransportClosedException() => const ConnectionFailed(
      'The secure connection closed before setup finished.',
    ),
    _ => const ConnectionFailed(
      'Unable to reach the server over a secure connection.',
    ),
  };

  String _nextAvailableProfileId() {
    final profiles = ref.read(serverProfilesControllerProvider).profiles;
    String id;
    do {
      id = 'profile-${++_nextProfileId}';
    } while (profiles.any((profile) => profile.id == id));
    return id;
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  _AuthenticationValidity _authenticationValidity(
    int generation,
    bool Function()? isRepositoryCurrent,
  ) {
    if (!_current(generation)) return _AuthenticationValidity.stale;
    try {
      if (!(isRepositoryCurrent?.call() ?? true)) {
        return _current(generation)
            ? _AuthenticationValidity.repositoryUnavailable
            : _AuthenticationValidity.stale;
      }
    } catch (_) {
      return _current(generation)
          ? _AuthenticationValidity.repositoryUnavailable
          : _AuthenticationValidity.stale;
    }
    // The repository-validity callback may synchronously refresh providers,
    // which can dispose or supersede this controller.
    return _current(generation)
        ? _AuthenticationValidity.current
        : _AuthenticationValidity.stale;
  }

  Future<bool> _abandonAuthenticationIfNeeded({
    required int generation,
    required _AuthenticationValidity validity,
    required SessionRepository repository,
    required bool closeOnFailure,
    required bool callerOwnsRepository,
    Future<void> Function()? discardUnconsumed,
  }) async {
    if (validity == _AuthenticationValidity.current) return false;
    await discardUnconsumed?.call();
    if (closeOnFailure && callerOwnsRepository) {
      await _closeSafely(repository);
    }
    _publishUnavailableRepositoryFailure(generation, validity);
    return true;
  }

  void _publishUnavailableRepositoryFailure(
    int generation,
    _AuthenticationValidity validity,
  ) {
    if (validity != _AuthenticationValidity.repositoryUnavailable ||
        !_current(generation)) {
      return;
    }
    _busy = false;
    state = const ConnectionFailed(
      'Unable to reach the server over a secure connection.',
    );
  }

  /// A verified coordinator result transfers exclusive transport ownership to
  /// this controller. A stale continuation must release that ownership before
  /// returning, while all other stale results have no controller side effect.
  Future<bool> _staleCoordinatorResult(
    int generation,
    CertificateTrustState result,
  ) async {
    if (_current(generation)) return false;
    if (result case VerifiedTrustTransport(:final transport)) {
      await _closeTransport(transport);
    }
    return true;
  }

  Future<void> _closeSafely(SessionRepository? repository) async {
    if (repository == null) return;
    try {
      await repository.close();
    } catch (_) {
      // Lifecycle cleanup must not escape the provider disposal boundary.
    }
  }

  Future<void> _detachAndCloseVerifiedRepository(
    SessionRepository repository,
  ) async {
    if (!identical(_verifiedRepository, repository)) return;
    _verifiedRepository = null;
    await _closeSafely(repository);
  }

  Future<bool> _closeTransport(RpcTransport transport) async {
    try {
      await transport.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// This adapter cannot be cached or reused to make a trust decision portable.
final class _OneShotVerifiedConnector implements RpcConnector {
  _OneShotVerifiedConnector({
    required this.expectedEndpoint,
    required this._transport,
  });
  final Uri expectedEndpoint;
  RpcTransport? _transport;
  var _wasConsumed = false;
  Uri? _consumedEndpoint;
  static final _failure = StateError(
    'Verified transport may only connect once to its expected endpoint.',
  );

  @override
  Future<RpcTransport> connect(Uri endpoint) async {
    final transport = _transport;
    if (transport == null) throw _failure;
    _transport = null;
    _wasConsumed = true;
    _consumedEndpoint = endpoint;
    if (endpoint != expectedEndpoint) {
      await _closeSafely(transport);
      throw _failure;
    }
    return transport;
  }

  Future<void> discard() async {
    final transport = _transport;
    if (transport == null) return;
    _transport = null;
    await _closeSafely(transport);
  }

  bool get wasConsumedForExpectedEndpoint =>
      _wasConsumed && _consumedEndpoint == expectedEndpoint;

  Future<void> _closeSafely(RpcTransport transport) async {
    try {
      await transport.close();
    } catch (_) {}
  }
}
