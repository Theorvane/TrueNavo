import 'certificate_facts.dart';
import 'models.dart';
import 'native_tls_ports.dart';
import 'pin_store.dart';

import 'package:truenas_api/truenas_api.dart';

/// The only capability that represents a completed TLS trust decision.
///
/// A caller cannot turn a review or an approval into permission to use RPC:
/// it must receive this object, which owns the verified transport.
final class VerifiedTrustTransport extends CertificateTrustState {
  VerifiedTrustTransport._(this.transport);
  final RpcTransport transport;
  @override
  String toString() => 'VerifiedTrustTransport';
}

/// An opaque, coordinator-issued identity for one authority operation.
final class TrustOperationToken {
  TrustOperationToken._();
  @override
  String toString() => 'TrustOperationToken';
}

/// A cancellable view of a single owned trust operation.
///
/// The token is available while the initial pin read/probe is still pending;
/// this is essential because cancellation is valid at every await boundary.
final class TrustOperationHandle {
  const TrustOperationHandle._(this.token, this.state);
  final TrustOperationToken token;
  final Future<CertificateTrustState> state;
}

sealed class CertificateTrustState {
  const CertificateTrustState();
}

final class FirstTrustReview extends CertificateTrustState {
  const FirstTrustReview._({
    required this.token,
    required this.authority,
    required this.certificate,
  });
  final TrustOperationToken token;
  final NormalizedAuthority authority;
  final PresentedCertificate certificate;
  @override
  String toString() => 'FirstTrustReview';
}

final class ReplacementTrustReview extends CertificateTrustState {
  const ReplacementTrustReview._({
    required this.token,
    required this.authority,
    required this.previousPin,
    required this.certificate,
  });
  final TrustOperationToken token;
  final NormalizedAuthority authority;
  final PinRecord previousPin;
  final PresentedCertificate certificate;
  @override
  String toString() => 'ReplacementTrustReview';
}

final class BrowserManagedTrust extends CertificateTrustState {
  const BrowserManagedTrust();
  @override
  String toString() => 'BrowserManagedTrust';
}

enum CertificateTrustCoordinatorFailure {
  pinStore,
  nativeBoundary,
  invalidOperation,
  staleOperation,
  candidateChanged,
  cleanup,
  cancelled,
  malformedCertificate,
  hostnameMismatch,
  expiredCertificate,
  notYetValidCertificate,
  pinMismatch,
  probeTimedOut,
  pinnedReconnectFailed,
}

final class BlockedTrust extends CertificateTrustState {
  const BlockedTrust(this.failure);
  final CertificateTrustCoordinatorFailure failure;
  @override
  String toString() => 'BlockedTrust(${failure.name})';
}

/// Per-authority, race-safe coordinator for TOFU pin review and reconnect.
final class CertificateTrustCoordinator {
  CertificateTrustCoordinator({
    required this._pinStore,
    required this._probe,
    required this._connector,
    required this._now,
    required Duration probeTimeout,
    required Duration reconnectTimeout,
  }) : _probeTimeout = probeTimeout,
       _reconnectTimeout = reconnectTimeout {
    if (probeTimeout <= Duration.zero) {
      throw ArgumentError.value(
        probeTimeout,
        'probeTimeout',
        'must be positive',
      );
    }
    if (reconnectTimeout <= Duration.zero) {
      throw ArgumentError.value(
        reconnectTimeout,
        'reconnectTimeout',
        'must be positive',
      );
    }
  }

  final PinStore _pinStore;
  final NativeCertificateProbe _probe;
  final PinnedRpcConnector _connector;
  final DateTime Function() _now;
  final Duration _probeTimeout;
  final Duration _reconnectTimeout;
  final _byAuthority = <NormalizedAuthority, _Operation>{};
  final _byToken = <TrustOperationToken, _Operation>{};
  // Terminal states normally contain no transport capability. Keep only a
  // small result cache for those typed outcomes; a verified transport is a
  // one-shot capability and must never be retained here.
  final _terminalResults = <TrustOperationToken, CertificateTrustState>{};
  final _terminalAuthorities = <TrustOperationToken, NormalizedAuthority>{};
  static const _terminalCacheLimit = 32;

  /// Starts (or joins) the one visible operation for [authority].
  Future<CertificateTrustState> begin(NormalizedAuthority authority) {
    return start(authority).state;
  }

  /// Starts (or joins) one operation and exposes its cancellation token now.
  TrustOperationHandle start(NormalizedAuthority authority) {
    final existing = _byAuthority[authority];
    if (existing != null && existing.terminal == null) {
      return TrustOperationHandle._(existing.token, existing.future);
    }
    final operation = _newOperation(authority);
    operation.future = _begin(operation);
    return TrustOperationHandle._(operation.token, operation.future);
  }

  /// Credential-free replacement discovery. It is deliberately separate from
  /// [begin], whose stored-pin path must never probe or rewrite that pin.
  Future<CertificateTrustState> checkForReplacement(
    NormalizedAuthority authority,
  ) => startReplacement(authority).state;

  /// Starts replacement discovery and exposes a token immediately, including
  /// while its read and credential-free probe are pending.
  TrustOperationHandle startReplacement(NormalizedAuthority authority) {
    final existing = _byAuthority[authority];
    if (existing != null && existing.terminal == null) {
      return TrustOperationHandle._(existing.token, existing.future);
    }
    final operation = _newOperation(authority);
    operation.future = _replacementProbe(operation);
    return TrustOperationHandle._(operation.token, operation.future);
  }

  Future<CertificateTrustState> approve(TrustOperationToken token) {
    final operation = _byToken[token];
    if (operation == null) {
      final terminal = _terminalResults[token];
      if (terminal != null) return Future.value(terminal);
      return Future.value(
        const BlockedTrust(CertificateTrustCoordinatorFailure.invalidOperation),
      );
    }
    final review = operation.review;
    if (operation.approving) return operation.approvalFuture!;
    if (review == null || !_isCurrent(operation)) {
      return Future.value(
        const BlockedTrust(CertificateTrustCoordinatorFailure.staleOperation),
      );
    }
    operation.approving =
        true; // Duplicate approvals cannot race the transaction.
    return operation.approvalFuture = _approve(operation, review);
  }

  Future<CertificateTrustState> _approve(
    _Operation operation,
    _Review review,
  ) async {
    final candidate = review.certificate.facts.leafDerSha256;
    final record = PinRecord(
      leafDerSha256: candidate,
      createdAt: _now().toUtc(),
    );
    PinStoreTransaction? transaction;
    RpcTransport? verifiedTransport;
    try {
      // The review authorizes exactly the active state the user saw, not just
      // the newly presented digest.  Check immediately before creating the
      // durable pending record, then again after it was created.
      final beforeStage = await _reviewedActive(operation, review);
      if (beforeStage != _ActiveReviewResult.matches) {
        return _terminal(
          operation,
          BlockedTrust(_activeReviewFailure(beforeStage)),
        );
      }
      final stage = await _pinStore.stageReplacement(
        operation.authority,
        record,
      );
      if (stage is PinStageSuccess) {
        transaction = stage.transaction;
      } else {
        return _terminal(
          operation,
          const BlockedTrust(CertificateTrustCoordinatorFailure.pinStore),
        );
      }
      final afterStage = await _reviewedActive(operation, review);
      if (afterStage != _ActiveReviewResult.matches) {
        return await _abort(
          operation,
          transaction,
          _activeReviewFailure(afterStage),
        );
      }
      NativePinnedOutcome outcome;
      try {
        outcome = await _connector.reconnect(
          authority: operation.authority,
          pin: record,
          timeout: _reconnectTimeout,
          cancellation: operation.cancellation.token,
        );
      } catch (_) {
        return await _abort(
          operation,
          transaction,
          CertificateTrustCoordinatorFailure.nativeBoundary,
        );
      }
      if (outcome is! NativePinnedVerified) {
        return await _abort(operation, transaction, _pinnedFailure(outcome));
      }
      final transport = verifiedTransport = outcome.transport;
      final afterReconnect = await _reviewedActive(operation, review);
      if (afterReconnect != _ActiveReviewResult.matches) {
        final cleanup = await _closeUnhanded(transport);
        final failure = cleanup
            ? CertificateTrustCoordinatorFailure.cleanup
            : _activeReviewFailure(afterReconnect);
        return await _abort(operation, transaction, failure);
      }
      // This is the point of no return.  A cancellation from now until the
      // store settles waits for this terminal durable outcome; it cannot be
      // reported as cancelled while a pin is being committed.
      operation.committing = true;
      operation.commitStarted = true;
      final committed = await transaction.commit();
      operation.committing = false;
      if (committed is! PinStoreSuccess) {
        final cleanup = await _closeUnhanded(transport);
        if (!cleanup && committed is PinStorePreActiveWriteFailure) {
          // This outcome is explicitly pre-active-write, so the transaction
          // still owns only its pending record and can safely release it.
          // Ambiguous and post-write failures retain point-of-no-return
          // semantics and are deliberately never aborted here.
          return await _abort(
            operation,
            transaction,
            CertificateTrustCoordinatorFailure.pinStore,
          );
        }
        return _terminal(
          operation,
          BlockedTrust(
            cleanup
                ? CertificateTrustCoordinatorFailure.cleanup
                : CertificateTrustCoordinatorFailure.pinStore,
          ),
        );
      }
      return _terminal(operation, VerifiedTrustTransport._(transport));
    } catch (_) {
      operation.committing = false;
      if (verifiedTransport != null) {
        final cleanup = await _closeUnhanded(verifiedTransport);
        // Commit may have durably changed active before reporting a cleanup
        // failure.  Never abort after commit has begun.
        if (operation.commitStarted) {
          return _terminal(
            operation,
            BlockedTrust(
              cleanup
                  ? CertificateTrustCoordinatorFailure.cleanup
                  : CertificateTrustCoordinatorFailure.pinStore,
            ),
          );
        }
      }
      if (transaction != null) {
        return _abort(
          operation,
          transaction,
          CertificateTrustCoordinatorFailure.pinStore,
        );
      }
      return _terminal(
        operation,
        const BlockedTrust(CertificateTrustCoordinatorFailure.pinStore),
      );
    }
  }

  /// Cancels a live operation and joins the single authoritative phase future.
  /// It never publishes cancellation before its owned cleanup has settled.
  Future<CertificateTrustState> cancel(TrustOperationToken token) async {
    final operation = _byToken[token];
    if (operation == null) {
      final terminal = _terminalResults[token];
      if (terminal != null) return terminal;
      return const BlockedTrust(
        CertificateTrustCoordinatorFailure.invalidOperation,
      );
    }
    if (operation.committing) {
      // The approve future is the authoritative completion; callers cannot
      // observe a cancelled result ahead of a durable commit.
      return operation.approvalFuture!;
    }
    operation.cancelRequested = true;
    operation.cancellation.cancel();
    // A visible review has no outstanding native resource. Its original
    // future is already complete with the review, so terminalize explicitly.
    if (!operation.approving && operation.review != null) {
      return _cancelled(operation);
    }
    return operation.approvalFuture ?? operation.future;
  }

  /// Starts a fresh attempt only after a retryable terminal result.
  Future<CertificateTrustState> retry(TrustOperationToken token) {
    final operation = _byToken[token];
    final terminal = operation?.terminal ?? _terminalResults[token];
    if (terminal is! BlockedTrust) {
      return Future.value(
        const BlockedTrust(CertificateTrustCoordinatorFailure.invalidOperation),
      );
    }
    final authority = operation?.authority ?? _terminalAuthorities[token];
    // A removed token deliberately cannot learn or join a newer owner.
    if (authority == null || _byAuthority.containsKey(authority)) {
      return Future.value(
        const BlockedTrust(CertificateTrustCoordinatorFailure.staleOperation),
      );
    }
    return begin(authority);
  }

  _Operation _newOperation(NormalizedAuthority authority) {
    final op = _Operation(authority, TrustOperationToken._());
    _byAuthority[authority] = op;
    _byToken[op.token] = op;
    return op;
  }

  Future<CertificateTrustState> _begin(_Operation operation) async {
    if (!await _recover(operation)) return operation.terminal!;
    final read = await _read(operation);
    if (read is! PinRecordRead) {
      if (read is PinAbsent) return _probeForReview(operation, null);
      if (operation.cancelRequested) return _cancelled(operation);
      return _terminal(
        operation,
        const BlockedTrust(CertificateTrustCoordinatorFailure.pinStore),
      );
    }
    if (!_isCurrent(operation)) return _cancelled(operation);
    final beforeReconnect = await _activeMatches(operation, read.record);
    if (beforeReconnect != _ActiveReviewResult.matches) {
      return _terminal(
        operation,
        BlockedTrust(_activeReviewFailure(beforeReconnect)),
      );
    }
    final outcome = await _reconnect(operation, read.record);
    if (outcome is NativePinnedVerified) {
      if (_isCurrent(operation)) {
        final afterReconnect = await _activeMatches(operation, read.record);
        if (afterReconnect != _ActiveReviewResult.matches) {
          final cleanup = await _closeUnhanded(outcome.transport);
          return _terminal(
            operation,
            BlockedTrust(
              cleanup
                  ? CertificateTrustCoordinatorFailure.cleanup
                  : _activeReviewFailure(afterReconnect),
            ),
          );
        }
        return _terminal(
          operation,
          VerifiedTrustTransport._(outcome.transport),
        );
      }
      final cleanup = await _closeUnhanded(outcome.transport);
      return _terminal(
        operation,
        BlockedTrust(
          cleanup
              ? CertificateTrustCoordinatorFailure.cleanup
              : CertificateTrustCoordinatorFailure.cancelled,
        ),
      );
    }
    if (outcome is NativePinnedFailure &&
        outcome.failure == CertificateTrustFailure.pinMismatch) {
      final stillOld = await _activeMatches(operation, read.record);
      if (stillOld != _ActiveReviewResult.matches) {
        return _terminal(
          operation,
          BlockedTrust(_activeReviewFailure(stillOld)),
        );
      }
      return _probeForReview(operation, read.record);
    }
    return _terminal(operation, BlockedTrust(_pinnedFailure(outcome)));
  }

  Future<CertificateTrustState> _replacementProbe(_Operation operation) async {
    if (!await _recover(operation)) return operation.terminal!;
    final read = await _read(operation);
    if (read is! PinRecordRead) {
      if (operation.cancelRequested) return _cancelled(operation);
      return _terminal(
        operation,
        const BlockedTrust(CertificateTrustCoordinatorFailure.pinStore),
      );
    }
    return _probeForReview(operation, read.record);
  }

  Future<CertificateTrustState> _probeForReview(
    _Operation operation,
    PinRecord? old,
  ) async {
    if (!_isCurrent(operation)) return _cancelled(operation);
    NativeProbeOutcome outcome;
    try {
      outcome = await _probe.probe(
        authority: operation.authority,
        timeout: _probeTimeout,
        cancellation: operation.cancellation.token,
      );
    } catch (_) {
      if (operation.cancelRequested) return _cancelled(operation);
      return _terminal(
        operation,
        const BlockedTrust(CertificateTrustCoordinatorFailure.nativeBoundary),
      );
    }
    if (outcome is NativeProbeBoundaryFailure &&
        outcome.failure == NativeTlsBoundaryFailure.cleanupFailed) {
      return _terminal(
        operation,
        const BlockedTrust(CertificateTrustCoordinatorFailure.cleanup),
      );
    }
    if (!_isCurrent(operation)) return _cancelled(operation);
    if (outcome is NativeProbeCertificate) {
      if (outcome.certificate.authority != operation.authority) {
        return _terminal(
          operation,
          const BlockedTrust(
            CertificateTrustCoordinatorFailure.malformedCertificate,
          ),
        );
      }
      // Native review must carry an observed platform-trust result.  The pure
      // certificate policy deliberately permits notAvailable for non-native
      // unit use, but a review UI must not claim that this fact was measured.
      if (outcome.certificate.platformTrust == PlatformTrust.notAvailable) {
        return _terminal(
          operation,
          const BlockedTrust(
            CertificateTrustCoordinatorFailure.malformedCertificate,
          ),
        );
      }
      final current = await _activeMatches(operation, old);
      if (current != _ActiveReviewResult.matches) {
        return _terminal(
          operation,
          BlockedTrust(_activeReviewFailure(current)),
        );
      }
      if (old != null &&
          old.leafDerSha256 == outcome.certificate.facts.leafDerSha256) {
        // This explicit check has no rewrite path; use the trusted active pin.
        final beforeReconnect = await _activeMatches(operation, old);
        if (beforeReconnect != _ActiveReviewResult.matches) {
          return _terminal(
            operation,
            BlockedTrust(_activeReviewFailure(beforeReconnect)),
          );
        }
        final reconnect = await _reconnect(operation, old);
        if (reconnect is NativePinnedVerified && _isCurrent(operation)) {
          final afterReconnect = await _activeMatches(operation, old);
          if (afterReconnect != _ActiveReviewResult.matches) {
            final cleanup = await _closeUnhanded(reconnect.transport);
            return _terminal(
              operation,
              BlockedTrust(
                cleanup
                    ? CertificateTrustCoordinatorFailure.cleanup
                    : _activeReviewFailure(afterReconnect),
              ),
            );
          }
          return _terminal(
            operation,
            VerifiedTrustTransport._(reconnect.transport),
          );
        }
        if (reconnect is NativePinnedVerified) {
          final cleanup = await _closeUnhanded(reconnect.transport);
          if (cleanup) {
            return _terminal(
              operation,
              const BlockedTrust(CertificateTrustCoordinatorFailure.cleanup),
            );
          }
          return _cancelled(operation);
        }
        return _terminal(operation, BlockedTrust(_pinnedFailure(reconnect)));
      }
      final review = _Review(outcome.certificate, old);
      operation.review = review;
      return old == null
          ? FirstTrustReview._(
              token: operation.token,
              authority: operation.authority,
              certificate: outcome.certificate,
            )
          : ReplacementTrustReview._(
              token: operation.token,
              authority: operation.authority,
              previousPin: old,
              certificate: outcome.certificate,
            );
    }
    if (outcome is NativeProbeBrowserManagedTls) {
      return _terminal(operation, const BrowserManagedTrust());
    }
    return _terminal(operation, BlockedTrust(_probeFailure(outcome)));
  }

  Future<PinReadResult> _read(_Operation operation) async {
    try {
      final read = await _pinStore.read(operation.authority);
      return _isCurrent(operation)
          ? read
          : const PinReadResult.failure(PinStoreFailure.readFailed);
    } catch (_) {
      return const PinReadResult.failure(PinStoreFailure.readFailed);
    }
  }

  Future<bool> _recover(_Operation operation) async {
    PinRecoveryResult recovery;
    try {
      recovery = await _pinStore.recoverReplacement(operation.authority);
    } catch (_) {
      _terminal(
        operation,
        const BlockedTrust(CertificateTrustCoordinatorFailure.pinStore),
      );
      return false;
    }
    if (recovery is PinRecoveryNone) {
      if (operation.cancelRequested) {
        _cancelled(operation);
        return false;
      }
      return true;
    }
    if (recovery is PinRecoveryFailure) {
      _terminal(
        operation,
        const BlockedTrust(CertificateTrustCoordinatorFailure.pinStore),
      );
      return false;
    }
    if (recovery is PinRecoverySuccess) {
      try {
        final result = await recovery.transaction.abort();
        if (result is! PinStoreSuccess) {
          _terminal(
            operation,
            const BlockedTrust(CertificateTrustCoordinatorFailure.cleanup),
          );
          return false;
        }
      } catch (_) {
        _terminal(
          operation,
          const BlockedTrust(CertificateTrustCoordinatorFailure.cleanup),
        );
        return false;
      }
      // The recovered transaction was never authorized for reconnect or
      // commit.  Once removed, obtain a fresh durable active snapshot.
      if (operation.cancelRequested) {
        _cancelled(operation);
        return false;
      }
      return true;
    }
    _terminal(
      operation,
      const BlockedTrust(CertificateTrustCoordinatorFailure.pinStore),
    );
    return false;
  }

  Future<_ActiveReviewResult> _reviewedActive(
    _Operation operation,
    _Review review,
  ) async {
    if (!_matchesReview(
      operation,
      review,
      review.certificate.facts.leafDerSha256,
    )) {
      return operation.cancelRequested
          ? _ActiveReviewResult.cancelled
          : _ActiveReviewResult.changed;
    }
    return _activeMatches(operation, review.previous, review: review);
  }

  Future<_ActiveReviewResult> _activeMatches(
    _Operation operation,
    PinRecord? expected, {
    _Review? review,
  }) async {
    if (operation.cancelRequested || !_isCurrent(operation)) {
      return _ActiveReviewResult.cancelled;
    }
    try {
      final current = await _pinStore.read(operation.authority);
      if (operation.cancelRequested ||
          !_isCurrent(operation) ||
          (review != null &&
              !_matchesReview(
                operation,
                review,
                review.certificate.facts.leafDerSha256,
              ))) {
        return _ActiveReviewResult.cancelled;
      }
      return switch ((expected, current)) {
        (null, PinAbsent()) => _ActiveReviewResult.matches,
        (final PinRecord expected, PinRecordRead(:final record))
            when expected == record =>
          _ActiveReviewResult.matches,
        (_, PinReadFailure()) => _ActiveReviewResult.pinStore,
        _ => _ActiveReviewResult.changed,
      };
    } catch (_) {
      return _ActiveReviewResult.pinStore;
    }
  }

  CertificateTrustCoordinatorFailure _activeReviewFailure(
    _ActiveReviewResult result,
  ) => switch (result) {
    _ActiveReviewResult.matches =>
      CertificateTrustCoordinatorFailure.staleOperation,
    _ActiveReviewResult.cancelled =>
      CertificateTrustCoordinatorFailure.cancelled,
    _ActiveReviewResult.pinStore => CertificateTrustCoordinatorFailure.pinStore,
    _ActiveReviewResult.changed =>
      CertificateTrustCoordinatorFailure.candidateChanged,
  };

  CertificateTrustState _cancelled(_Operation operation) => _terminal(
    operation,
    const BlockedTrust(CertificateTrustCoordinatorFailure.cancelled),
  );

  Future<NativePinnedOutcome> _reconnect(
    _Operation operation,
    PinRecord pin,
  ) async {
    try {
      return await _connector.reconnect(
        authority: operation.authority,
        pin: pin,
        timeout: _reconnectTimeout,
        cancellation: operation.cancellation.token,
      );
    } catch (_) {
      return const NativePinnedBoundaryFailure(
        NativeTlsBoundaryFailure.backendFailure,
      );
    }
  }

  bool _isCurrent(_Operation operation) =>
      !operation.cancellation.token.isCancelled &&
      _byAuthority[operation.authority] == operation &&
      operation.terminal == null;
  bool _matchesReview(_Operation operation, _Review review, String digest) =>
      _isCurrent(operation) &&
      identical(operation.review, review) &&
      review.certificate.facts.leafDerSha256 == digest;

  CertificateTrustState _terminal(
    _Operation operation,
    CertificateTrustState state,
  ) {
    operation.terminal ??= state;
    if (operation.terminal != null &&
        _byAuthority[operation.authority] == operation) {
      _byAuthority.remove(operation.authority);
    }
    _byToken.remove(operation.token);
    _terminalResults.remove(operation.token);
    _terminalAuthorities.remove(operation.token);
    // Do not cache a transport-bearing result. A token that has handed off a
    // transport is permanently inert, including for approve/cancel/retry.
    if (operation.terminal is! VerifiedTrustTransport) {
      _terminalResults[operation.token] = operation.terminal!;
      _terminalAuthorities[operation.token] = operation.authority;
      if (_terminalResults.length > _terminalCacheLimit) {
        final expired = _terminalResults.keys.first;
        _terminalResults.remove(expired);
        _terminalAuthorities.remove(expired);
      }
    }
    return operation.terminal!;
  }

  Future<CertificateTrustState> _abort(
    _Operation operation,
    PinStoreTransaction transaction,
    CertificateTrustCoordinatorFailure reason,
  ) async {
    try {
      final result = await transaction.abort();
      if (result is! PinStoreSuccess) {
        return _terminal(
          operation,
          const BlockedTrust(CertificateTrustCoordinatorFailure.cleanup),
        );
      }
    } catch (_) {
      return _terminal(
        operation,
        const BlockedTrust(CertificateTrustCoordinatorFailure.cleanup),
      );
    }
    return _terminal(
      operation,
      BlockedTrust(
        reason == CertificateTrustCoordinatorFailure.cleanup
            ? CertificateTrustCoordinatorFailure.cleanup
            : operation.cancelRequested
            ? CertificateTrustCoordinatorFailure.cancelled
            : reason,
      ),
    );
  }

  /// Returns true only when the unhanded transport could not be closed.
  Future<bool> _closeUnhanded(RpcTransport transport) async {
    try {
      await transport.close();
      return false;
    } catch (_) {
      return true;
    }
  }

  CertificateTrustCoordinatorFailure _probeFailure(
    NativeProbeOutcome outcome,
  ) => switch (outcome) {
    NativeProbeFailure(:final failure) => _policyFailure(failure),
    NativeProbeBoundaryFailure(:final failure) =>
      failure == NativeTlsBoundaryFailure.cleanupFailed
          ? CertificateTrustCoordinatorFailure.cleanup
          : CertificateTrustCoordinatorFailure.nativeBoundary,
    _ => CertificateTrustCoordinatorFailure.nativeBoundary,
  };
  CertificateTrustCoordinatorFailure _pinnedFailure(
    NativePinnedOutcome outcome,
  ) => switch (outcome) {
    NativePinnedFailure(:final failure) => _policyFailure(failure),
    NativePinnedBoundaryFailure(:final failure) =>
      failure == NativeTlsBoundaryFailure.cleanupFailed
          ? CertificateTrustCoordinatorFailure.cleanup
          : CertificateTrustCoordinatorFailure.nativeBoundary,
    NativePinnedBrowserManagedTls() =>
      CertificateTrustCoordinatorFailure.nativeBoundary,
    _ => CertificateTrustCoordinatorFailure.nativeBoundary,
  };
  CertificateTrustCoordinatorFailure _policyFailure(
    CertificateTrustFailure failure,
  ) => switch (failure) {
    CertificateTrustFailure.cancelled =>
      CertificateTrustCoordinatorFailure.cancelled,
    CertificateTrustFailure.malformedCertificate =>
      CertificateTrustCoordinatorFailure.malformedCertificate,
    CertificateTrustFailure.hostnameMismatch =>
      CertificateTrustCoordinatorFailure.hostnameMismatch,
    CertificateTrustFailure.expiredCertificate =>
      CertificateTrustCoordinatorFailure.expiredCertificate,
    CertificateTrustFailure.notYetValidCertificate =>
      CertificateTrustCoordinatorFailure.notYetValidCertificate,
    CertificateTrustFailure.pinMismatch =>
      CertificateTrustCoordinatorFailure.pinMismatch,
    CertificateTrustFailure.probeTimedOut =>
      CertificateTrustCoordinatorFailure.probeTimedOut,
    CertificateTrustFailure.pinStoreFailure =>
      CertificateTrustCoordinatorFailure.pinStore,
    CertificateTrustFailure.browserManagedTls =>
      CertificateTrustCoordinatorFailure.nativeBoundary,
    _ => CertificateTrustCoordinatorFailure.pinnedReconnectFailed,
  };
}

final class _Operation {
  _Operation(this.authority, this.token);
  final NormalizedAuthority authority;
  final TrustOperationToken token;
  final cancellation = CancellationSource();
  late Future<CertificateTrustState> future;
  _Review? review;
  bool approving = false;
  bool cancelRequested = false;
  bool committing = false;
  bool commitStarted = false;
  Future<CertificateTrustState>? approvalFuture;
  CertificateTrustState? terminal;
}

final class _Review {
  const _Review(this.certificate, this.previous);
  final PresentedCertificate certificate;
  final PinRecord? previous;
}

enum _ActiveReviewResult { matches, changed, pinStore, cancelled }
