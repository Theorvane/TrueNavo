import 'dart:async';

export '../credentials/credential_vault_provider.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../credentials/credential_vault_provider.dart';
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

/// A live, authenticated session is memory-only. Profile persistence remains
/// credential-free and cannot restore this capability after an app restart.
final activeAuthenticatedSessionProvider = Provider<AuthenticatedSession?>((
  ref,
) {
  ref.watch(connectionControllerProvider);
  return ref.read(connectionControllerProvider.notifier).activeSession;
});

final class AuthenticatedSession {
  const AuthenticatedSession({
    required this.profileId,
    required this.repository,
    required this.availableMethodNames,
    this.version = 'unknown',
    this.endpoint,
  });

  /// The durable profile selected by the successful registration that created
  /// this live session. It prevents a display-only profile switch from
  /// exposing this connection's data under another server label.
  final String profileId;
  final SessionRepository repository;
  final Set<String> availableMethodNames;

  /// Memory-only compatibility context for the active authenticated session.
  final String version;

  /// The authenticated connection's address, not a subsequently edited profile.
  /// Null legacy fixtures cannot authorize the dedicated network editor.
  final String? endpoint;
}

class ConnectionController extends Notifier<ConnectionState> {
  SessionRepository? _verifiedRepository;
  SessionRepository? _activeNormalRepository;
  AuthenticatedSession? _activeSession;
  var _nextProfileId = 0;
  var _generation = 0;
  var _busy = false;
  var _disposed = false;
  Completer<String?>? _otpReply;
  PasswordOtpChallenge? _otpChallenge;
  SessionRepository? _passwordAttemptRepository;
  int? _passwordAttemptGeneration;

  AuthenticatedSession? get activeSession => _activeSession;

  @override
  ConnectionState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      _cancelPendingOtp();
      _closeSafely(_passwordAttemptRepository);
      _passwordAttemptRepository = null;
      final verified = _verifiedRepository;
      _verifiedRepository = null;
      _activeNormalRepository = null;
      _activeSession = null;
      _closeSafely(verified);
    });
    return const ConnectionIdle();
  }

  Future<String?> _requestOtp(
    PasswordOtpChallenge challenge,
    bool Function() current,
  ) async {
    if (!current()) return null;
    _cancelPendingOtp();
    final reply = Completer<String?>();
    _otpReply = reply;
    _otpChallenge = challenge;
    state = ConnectionOtpRequired(challenge);
    try {
      final token = await reply.future;
      return current() ? token : null;
    } finally {
      if (identical(_otpReply, reply)) {
        _otpReply = null;
        _otpChallenge = null;
      }
    }
  }

  bool submitOtp(PasswordOtpChallenge challenge, String token) {
    final reply = _otpReply;
    if (state is! ConnectionOtpRequired ||
        !identical(challenge, _otpChallenge) ||
        reply == null ||
        reply.isCompleted ||
        !validTrueNasOtp(token)) {
      return false;
    }
    state = const ConnectionInProgress();
    reply.complete(token);
    return true;
  }

  void cancelPasswordSignIn({bool deferState = false}) {
    if (_disposed || !_busy || _passwordAttemptGeneration != _generation) {
      return;
    }
    final cancelledGeneration = ++_generation;
    _passwordAttemptGeneration = null;
    _cancelPendingOtp();
    final attempt = _passwordAttemptRepository;
    _passwordAttemptRepository = null;
    _closeSafely(attempt);
    _busy = false;
    _activeSession = null;
    void publish() {
      if (!_current(cancelledGeneration)) return;
      state = const ConnectionFailed(
        'Password sign-in was cancelled. No authenticated session was published.',
      );
    }

    // Route disposal must invalidate the credential handoff immediately, but
    // Riverpod state cannot be published during widget-tree finalization.
    if (deferState) {
      unawaited(Future<void>(publish));
    } else {
      publish();
    }
  }

  void _cancelPendingOtp() {
    final reply = _otpReply;
    _otpReply = null;
    _otpChallenge = null;
    if (reply != null && !reply.isCompleted) reply.complete(null);
  }

  Future<void> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    String? password,
  }) async {
    if (_busy) return;
    // A new attempt cannot share the session capability published by a prior
    // connection. In particular, a provider-owned normal repository mutates
    // its client while connecting, so leaving it visible would let dashboard
    // reads reach the new, unauthenticated transport.
    _activeSession = null;
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
    // Refuse an unusable account name before any TLS work: the trust flow would
    // otherwise probe, prompt, and pin for a login that cannot be attempted.
    try {
      validateTrueNasAccountName(username);
      if (password != null) validateTrueNasPassword(password);
    } on AccountNameValidationException catch (error) {
      _busy = false;
      state = ConnectionFailed(error.message);
      return;
    } on PasswordLoginException catch (error) {
      _busy = false;
      state = ConnectionFailed(error.userMessage);
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
    _passwordAttemptGeneration = password == null ? null : generation;
    if (route == TlsTrustRoute.platformValidated) {
      _activeNormalRepository = null;
      await _authenticateNormal(
        generation: generation,
        serverInput: serverInput,
        apiKey: apiKey,
        username: username,
        rememberApiKey: rememberApiKey,
        password: password,
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
      _activeNormalRepository = null;
      await _authenticateNormal(
        generation: generation,
        serverInput: serverInput,
        apiKey: apiKey,
        username: username,
        rememberApiKey: rememberApiKey,
        password: password,
      );
      return;
    }
    await _afterTrust(
      generation: generation,
      authority: authority,
      apiKey: apiKey,
      username: username,
      rememberApiKey: rememberApiKey,
      password: password,
      trust: trust,
      fallbackToken: handle.token,
    );
  }

  Future<void> approveTrust({
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    String? password,
  }) async {
    final review = state;
    if (review is! ConnectionTrustReview || _busy) return;
    final generation = ++_generation;
    _passwordAttemptGeneration = password == null ? null : generation;
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
      username: username,
      rememberApiKey: rememberApiKey,
      password: password,
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

  Future<void> retryTrust({
    String? apiKey,
    String? username,
    bool rememberApiKey = false,
    String? password,
  }) async {
    final blocked = state;
    if (blocked is! ConnectionTrustBlocked || _busy) return;
    final generation = ++_generation;
    _passwordAttemptGeneration = password == null ? null : generation;
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
    if (trust is VerifiedTrustTransport) {
      await _afterTrust(
        generation: generation,
        authority: blocked.authority,
        apiKey: apiKey,
        username: username,
        rememberApiKey: rememberApiKey,
        password: password,
        trust: trust,
        fallbackToken: blocked.token,
      );
      return;
    }
    _publishTrust(generation, trust, blocked.token, blocked.authority);
  }

  Future<void> _afterTrust({
    required int generation,
    required NormalizedAuthority authority,
    required String? apiKey,
    required String? username,
    required bool rememberApiKey,
    String? password,
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
        username: username,
        rememberApiKey: rememberApiKey,
        password: password,
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
    required String? apiKey,
    required String? username,
    required bool rememberApiKey,
    String? password,
    required bool closeOnFailure,
    Future<void> Function()? discardUnconsumed,
    _OneShotVerifiedConnector? verifiedConnector,
    bool Function()? isRepositoryCurrent,
    void Function()? invalidateProviderOwnedRepositoryOnPersistenceFailure,
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
      bool current() =>
          _authenticationValidity(generation, isRepositoryCurrent) ==
          _AuthenticationValidity.current;
      final ServerSummary summary;
      if (password == null) {
        summary = await repository.connect(
          serverInput: serverInput,
          apiKey: apiKey,
          username: username,
          rememberApiKey: rememberApiKey,
          isConnectionCurrent: current,
        );
      } else {
        if (repository is! PasswordSessionRepository) {
          throw const PasswordLoginException(PasswordLoginFailure.unsupported);
        }
        _passwordAttemptRepository = repository;
        summary = await (repository as PasswordSessionRepository)
            .connectWithPassword(
              serverInput: serverInput,
              username: validateTrueNasAccountName(username),
              password: password,
              onOtpRequired: (challenge) => _requestOtp(challenge, current),
              isConnectionCurrent: current,
            );
      }
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
      final registration = await profiles.registerAndSelectWithCapabilities(
        profile: ServerProfile.fromSafeSummary(
          id: _nextAvailableProfileId(),
          summary: summary,
        ),
        methodNames: summary.availableMethodNames,
        observedAt: observedAt,
        expiresAt: observedAt.add(_capabilityLifetime),
        isConnectionCurrent: () =>
            _authenticationValidity(generation, isRepositoryCurrent) ==
            _AuthenticationValidity.current,
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
      // A normal TLS repository remains provider-owned, while a pinned-route
      // repository is controller-owned. A later normal success must still
      // release any previous controller-owned pinned session.
      if (!closeOnFailure) {
        final displaced = _verifiedRepository;
        _verifiedRepository = null;
        if (displaced != null && !identical(displaced, repository)) {
          await _closeSafely(displaced);
        }
        _activeNormalRepository = repository;
      } else if (_activeNormalRepository != null) {
        // A verified route now supersedes the provider-owned normal session.
        // Invalidate only after pinned authentication and persistence succeed,
        // so a failed pinned attempt leaves the normal repository untouched.
        _activeNormalRepository = null;
        ref.invalidate(sessionRepositoryProvider);
      }
      _busy = false;
      _activeSession = AuthenticatedSession(
        profileId: registration.snapshot.selectedProfileId!,
        repository: repository,
        availableMethodNames: Set.unmodifiable(summary.availableMethodNames),
        version: summary.version,
        endpoint: summary.endpointUri.toString(),
      );
      state = ConnectionSucceeded(summary);
    } catch (error) {
      if (_current(generation)) _cancelPendingOtp();
      await discardUnconsumed?.call();
      if (!repositoryTransferred &&
          !closeOnFailure &&
          error is PersistenceFailure) {
        invalidateProviderOwnedRepositoryOnPersistenceFailure?.call();
      }
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
    } finally {
      if (_passwordAttemptGeneration == generation &&
          identical(_passwordAttemptRepository, repository)) {
        _passwordAttemptGeneration = null;
        _passwordAttemptRepository = null;
        _cancelPendingOtp();
      }
    }
  }

  Future<void> _authenticateNormal({
    required int generation,
    required String serverInput,
    required String? apiKey,
    required String? username,
    required bool rememberApiKey,
    String? password,
  }) async {
    final _SessionRepositoryLease lease;
    try {
      // A normal connection attempt owns a new provider repository. Invalidating
      // it lets Riverpod dispose the previous provider value exactly once,
      // including its transport, before this attempt obtains its lease.
      ref.invalidate(sessionRepositoryProvider);
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
      username: username,
      rememberApiKey: rememberApiKey,
      password: password,
      closeOnFailure: false,
      invalidateProviderOwnedRepositoryOnPersistenceFailure: () {
        ref.invalidate(sessionRepositoryProvider);
      },
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
          certificate: _display(review.certificate),
        );
      case ReplacementTrustReview review:
        state = ConnectionReplacementTrustReview(
          token: review.token,
          authority: review.authority,
          previousPin: TrustReviewPreviousPin(
            leafDerSha256: review.previousPin.leafDerSha256,
            createdAt: review.previousPin.createdAt,
          ),
          certificate: _display(review.certificate),
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

  TrustReviewCertificate _display(PresentedCertificate certificate) =>
      TrustReviewCertificate.fromCertificate(certificate);

  ConnectionFailed _safeFailure(Object error) => switch (error) {
    PasswordLoginException(:final userMessage) => ConnectionFailed(userMessage),
    EndpointValidationException(:final message) => ConnectionFailed(message),
    AccountNameValidationException(:final message) => ConnectionFailed(message),
    TlsCertificateException(:final userMessage) => ConnectionFailed(
      userMessage,
    ),
    AuthenticationStateException(:final userMessage) => ConnectionFailed(
      userMessage,
    ),
    CredentialUnavailableException(:final userMessage) => ConnectionFailed(
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
    PersistenceFailure(:final message) => ConnectionFailed(message),
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
