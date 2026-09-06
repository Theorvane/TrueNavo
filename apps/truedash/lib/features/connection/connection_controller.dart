import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

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
final sessionRepositoryProvider = Provider<SessionRepository>(
  (ref) => ref.watch(sessionRepositoryFactoryProvider)(
    connector: ref.watch(rpcConnectorProvider),
    credentialVault: ref.watch(credentialVaultProvider),
  ),
);

final connectionControllerProvider =
    NotifierProvider<ConnectionController, ConnectionState>(
      ConnectionController.new,
    );

final class ConnectionController extends Notifier<ConnectionState> {
  SessionRepository? _normalRepository;
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
      final normal = _normalRepository;
      final verified = _verifiedRepository;
      _normalRepository = null;
      _verifiedRepository = null;
      _closeSafely(normal);
      if (verified != null && !identical(verified, normal)) {
        _closeSafely(verified);
      }
    });
    return const ConnectionIdle();
  }

  Future<void> connect({
    required String serverInput,
    required String apiKey,
  }) async {
    if (_busy) return;
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
        _busy = false;
        state = const ConnectionFailed(
          'Unable to reach the server over a secure connection.',
        );
        return;
      }
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
    final int generation = ++_generation;
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
    if (!_current(generation)) return;
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
      _busy = false;
      state = const ConnectionFailed(
        'Unable to reach the server over a secure connection.',
      );
      return;
    }
    if (!_current(generation)) return;
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
      _busy = false;
      state = const ConnectionFailed(
        'Unable to reach the server over a secure connection.',
      );
      return;
    }
    if (!_current(generation)) return;
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
      _busy = false;
      state = const ConnectionFailed(
        'Unable to reach the server over a secure connection.',
      );
      return;
    }
    if (!_current(generation)) return;
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
  }) async {
    try {
      final summary = await repository.connect(
        serverInput: serverInput,
        apiKey: apiKey,
      );
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
      if (!_current(generation)) {
        if (closeOnFailure) await _closeSafely(repository);
        return;
      }
      if (closeOnFailure) {
        final displaced = _verifiedRepository;
        _verifiedRepository = repository;
        if (displaced != null && !identical(displaced, repository)) {
          await _closeSafely(displaced);
        }
      }
      if (!_current(generation)) return;
      ref
          .read(serverProfilesControllerProvider.notifier)
          .registerAndSelect(
            ServerProfile.fromSafeSummary(
              id: 'profile-${++_nextProfileId}',
              summary: summary,
            ),
          );
      _busy = false;
      state = ConnectionSucceeded(summary);
    } catch (error) {
      await discardUnconsumed?.call();
      if (closeOnFailure) await _closeSafely(repository);
      if (!_current(generation)) return;
      _busy = false;
      state = _safeFailure(error);
    }
  }

  Future<void> _authenticateNormal({
    required int generation,
    required String serverInput,
    required String apiKey,
  }) async {
    final SessionRepository repository;
    try {
      repository = _normal();
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
      repository: repository,
      serverInput: serverInput,
      apiKey: apiKey,
      closeOnFailure: false,
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

  bool _current(int generation) => !_disposed && generation == _generation;

  SessionRepository _normal() {
    final existing = _normalRepository;
    if (existing != null) return existing;
    final repository = ref.read(sessionRepositoryProvider);
    _normalRepository = repository;
    return repository;
  }

  Future<void> _closeSafely(SessionRepository? repository) async {
    if (repository == null) return;
    try {
      await repository.close();
    } catch (_) {
      // Lifecycle cleanup must not escape the provider disposal boundary.
    }
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
