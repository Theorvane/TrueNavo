import 'dart:async';

import 'certificate_facts.dart';
import 'models.dart';
import 'native_tls_stub.dart'
    if (dart.library.io) 'native_tls_io.dart'
    if (dart.library.js_interop) 'native_tls_web.dart'
    as platform;

/// Caller-owned, one-way cancellation capability for a bounded TLS operation.
final class CancellationToken {
  CancellationToken._();

  bool _isCancelled = false;
  var _nextListenerId = 0;
  final _listeners = <int, void Function()>{};

  bool get isCancelled => _isCancelled;

  /// Registers work to run once if this token is cancelled.
  ///
  /// If cancellation has already happened, [listener] runs immediately. The
  /// returned registration may always be disposed; disposal is idempotent.
  CancellationRegistration register(void Function() listener) {
    if (_isCancelled) {
      _notify(listener);
      return CancellationRegistration._disposed();
    }
    final id = _nextListenerId++;
    _listeners[id] = listener;
    return CancellationRegistration._(this, id);
  }

  void _cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    final listeners = _listeners.values.toList(growable: false);
    _listeners.clear();
    for (final listener in listeners) {
      _notify(listener);
    }
  }

  void _removeListener(int id) => _listeners.remove(id);

  static void _notify(void Function() listener) {
    try {
      listener();
    } catch (_) {
      // Cancellation must notify every listener even if one is faulty.
    }
  }
}

/// A disposable registration returned by [CancellationToken.register].
final class CancellationRegistration {
  CancellationRegistration._(this._token, this._id);

  CancellationRegistration._disposed() : _token = null, _id = null;

  final CancellationToken? _token;
  final int? _id;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final id = _id;
    if (id != null) _token?._removeListener(id);
  }
}

/// Creates a [CancellationToken] and can only move it to cancellation once.
final class CancellationSource {
  CancellationSource() : token = CancellationToken._();

  final CancellationToken token;

  void cancel() => token._cancel();
}

final class NativeTlsArgumentError implements Exception {
  const NativeTlsArgumentError(this.message);

  final String message;
}

/// Failures at the Task-4 backend boundary, separate from certificate policy.
enum NativeTlsBoundaryFailure {
  backendUnavailable,
  backendFailure,
  cleanupFailed,
}

/// A certificate policy result, browser-managed indication, or typed failure.
sealed class NativeProbeOutcome {
  const NativeProbeOutcome();
}

/// A display-safe certificate presented by an approvable policy result.
final class NativeProbeCertificate extends NativeProbeOutcome {
  const NativeProbeCertificate(this.certificate);

  final PresentedCertificate certificate;
}

final class NativeProbeBrowserManagedTls extends NativeProbeOutcome {
  const NativeProbeBrowserManagedTls();
}

/// A certificate-policy failure.
final class NativeProbeFailure extends NativeProbeOutcome {
  const NativeProbeFailure(this.failure);

  final CertificateTrustFailure failure;
}

/// A non-policy failure at the native TLS boundary.
final class NativeProbeBoundaryFailure extends NativeProbeOutcome {
  const NativeProbeBoundaryFailure(this.failure);

  final NativeTlsBoundaryFailure failure;
}

/// Verification-only outcome for a later pinned reconnect stage.
sealed class NativePinnedOutcome {
  const NativePinnedOutcome();
}

final class NativePinnedVerified extends NativePinnedOutcome {
  const NativePinnedVerified();
}

final class NativePinnedBrowserManagedTls extends NativePinnedOutcome {
  const NativePinnedBrowserManagedTls();
}

/// A certificate-policy failure.
final class NativePinnedFailure extends NativePinnedOutcome {
  const NativePinnedFailure(this.failure);

  final CertificateTrustFailure failure;
}

/// A non-policy failure at the native TLS boundary.
final class NativePinnedBoundaryFailure extends NativePinnedOutcome {
  const NativePinnedBoundaryFailure(this.failure);

  final NativeTlsBoundaryFailure failure;
}

abstract interface class NativeCertificateProbe {
  Future<NativeProbeOutcome> probe({
    required NormalizedAuthority authority,
    required Duration timeout,
    required CancellationToken cancellation,
  });
}

abstract interface class PinnedRpcConnector {
  Future<NativePinnedOutcome> reconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required Duration timeout,
    required CancellationToken cancellation,
  });
}

/// A registered, closeable certificate-probe attempt.
///
/// [close] is idempotent, operation-specific, waits for cleanup, and prevents
/// future activity, releases resources, and settles or releases any pending
/// [outcome].
abstract interface class NativeProbeAttempt {
  Future<CertificateProbeResult> get outcome;

  Future<void> close();
}

/// A registered, closeable pinned-reconnect attempt.
///
/// [close] is idempotent, operation-specific, waits for cleanup, and prevents
/// future activity, releases resources, and settles or releases any pending
/// [outcome].
abstract interface class NativePinnedAttempt {
  Future<NativePinnedOutcome> get outcome;

  Future<void> close();
}

/// Narrow backend seam. It has no application protocol capability.
///
/// A start method must synchronously return a fully registered closeable
/// attempt before it starts asynchronous work, or throw without retaining any
/// resource. This trusted adapter contract lets the caller always close an
/// existing attempt after timeout or cancellation.
abstract interface class NativeTlsAttemptBackend {
  NativeProbeAttempt startProbe({
    required NormalizedAuthority authority,
    required CancellationToken cancellation,
  });

  NativePinnedAttempt startReconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required CancellationToken cancellation,
  });
}

/// Enforces timeout, cancellation, and operation-specific cleanup around a
/// bounded backend.
final class BoundedNativeTlsPorts
    implements NativeCertificateProbe, PinnedRpcConnector {
  factory BoundedNativeTlsPorts({required NativeTlsAttemptBackend backend}) =>
      BoundedNativeTlsPorts._(backend);

  BoundedNativeTlsPorts._(this._backend);

  final NativeTlsAttemptBackend _backend;

  @override
  Future<NativeProbeOutcome> probe({
    required NormalizedAuthority authority,
    required Duration timeout,
    required CancellationToken cancellation,
  }) {
    _validateTimeout(timeout);
    if (cancellation.isCancelled) {
      return Future.value(
        const NativeProbeFailure(CertificateTrustFailure.cancelled),
      );
    }
    return _runProbe(authority, timeout, cancellation);
  }

  @override
  Future<NativePinnedOutcome> reconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required Duration timeout,
    required CancellationToken cancellation,
  }) {
    _validateTimeout(timeout);
    if (cancellation.isCancelled) {
      return Future.value(
        const NativePinnedFailure(CertificateTrustFailure.cancelled),
      );
    }
    return _runReconnect(authority, pin, timeout, cancellation);
  }

  Future<NativeProbeOutcome> _runProbe(
    NormalizedAuthority authority,
    Duration timeout,
    CancellationToken cancellation,
  ) async {
    final NativeProbeAttempt attempt;
    try {
      attempt = _backend.startProbe(
        authority: authority,
        cancellation: cancellation,
      );
    } catch (_) {
      // A throwing start must not retain resources, so no close is possible.
      return const NativeProbeBoundaryFailure(
        NativeTlsBoundaryFailure.backendFailure,
      );
    }
    final winner = Completer<NativeProbeOutcome>();
    var timedOut = false;
    var cancelled = false;
    void complete(NativeProbeOutcome outcome) {
      if (!winner.isCompleted) winner.complete(outcome);
    }

    final timer = Timer(timeout, () {
      timedOut = true;
      complete(const NativeProbeFailure(CertificateTrustFailure.probeTimedOut));
    });
    final registration = cancellation.register(() {
      cancelled = true;
      complete(const NativeProbeFailure(CertificateTrustFailure.cancelled));
    });
    _probeOutcome(attempt).then(complete);
    final outcome = await winner.future;
    try {
      await attempt.close();
    } catch (_) {
      return const NativeProbeBoundaryFailure(
        NativeTlsBoundaryFailure.cleanupFailed,
      );
    } finally {
      timer.cancel();
      registration.dispose();
    }
    // Cancellation invalidates a result even if it races with backend
    // completion while operation-specific cleanup is in progress.
    if (cancelled || cancellation.isCancelled) {
      return const NativeProbeFailure(CertificateTrustFailure.cancelled);
    }
    if (timedOut) {
      return const NativeProbeFailure(CertificateTrustFailure.probeTimedOut);
    }
    return outcome;
  }

  Future<NativeProbeOutcome> _probeOutcome(NativeProbeAttempt attempt) async {
    try {
      final result = await attempt.outcome;
      final certificate = result.presentedCertificate;
      final failure = result.failure;
      if (certificate != null && failure == null) {
        return NativeProbeCertificate(certificate);
      }
      if (certificate == null && failure != null) {
        return NativeProbeFailure(failure);
      }
      return const NativeProbeFailure(
        CertificateTrustFailure.malformedCertificate,
      );
    } catch (_) {
      return const NativeProbeBoundaryFailure(
        NativeTlsBoundaryFailure.backendFailure,
      );
    }
  }

  Future<NativePinnedOutcome> _runReconnect(
    NormalizedAuthority authority,
    PinRecord pin,
    Duration timeout,
    CancellationToken cancellation,
  ) async {
    final NativePinnedAttempt attempt;
    try {
      attempt = _backend.startReconnect(
        authority: authority,
        pin: pin,
        cancellation: cancellation,
      );
    } catch (_) {
      // A throwing start must not retain resources, so no close is possible.
      return const NativePinnedBoundaryFailure(
        NativeTlsBoundaryFailure.backendFailure,
      );
    }
    final winner = Completer<NativePinnedOutcome>();
    var timedOut = false;
    var cancelled = false;
    void complete(NativePinnedOutcome outcome) {
      if (!winner.isCompleted) winner.complete(outcome);
    }

    final timer = Timer(timeout, () {
      timedOut = true;
      complete(
        const NativePinnedFailure(
          CertificateTrustFailure.pinnedReconnectFailed,
        ),
      );
    });
    final registration = cancellation.register(() {
      cancelled = true;
      complete(const NativePinnedFailure(CertificateTrustFailure.cancelled));
    });
    _reconnectOutcome(attempt).then(complete);
    final outcome = await winner.future;
    try {
      await attempt.close();
    } catch (_) {
      return const NativePinnedBoundaryFailure(
        NativeTlsBoundaryFailure.cleanupFailed,
      );
    } finally {
      timer.cancel();
      registration.dispose();
    }
    if (cancelled || cancellation.isCancelled) {
      return const NativePinnedFailure(CertificateTrustFailure.cancelled);
    }
    if (timedOut) {
      return const NativePinnedFailure(
        CertificateTrustFailure.pinnedReconnectFailed,
      );
    }
    return outcome;
  }

  Future<NativePinnedOutcome> _reconnectOutcome(
    NativePinnedAttempt attempt,
  ) async {
    try {
      return await attempt.outcome;
    } catch (_) {
      return const NativePinnedBoundaryFailure(
        NativeTlsBoundaryFailure.backendFailure,
      );
    }
  }

  static void _validateTimeout(Duration timeout) =>
      validateNativeTlsTimeout(timeout);
}

void validateNativeTlsTimeout(Duration timeout) {
  if (timeout <= Duration.zero) {
    throw const NativeTlsArgumentError('Timeout must be positive.');
  }
}

NativeCertificateProbe createNativeCertificateProbe() => platform.createProbe();

PinnedRpcConnector createPinnedRpcConnector() => platform.createReconnect();
