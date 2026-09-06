import 'dart:io';

import 'models.dart';
import 'native_tls_ports.dart';

NativeCertificateProbe createProbe() => _IoProbe();
PinnedRpcConnector createReconnect() => _IoReconnect();

final class _IoProbe implements NativeCertificateProbe {
  @override
  Future<NativeProbeOutcome> probe({
    required NormalizedAuthority authority,
    required Duration timeout,
    required CancellationToken cancellation,
  }) {
    validateNativeTlsTimeout(timeout);
    // Keep the IO route explicit without performing any Task-5 network work.
    assert(Platform.operatingSystem.isNotEmpty);
    return Future.value(
      cancellation.isCancelled
          ? const NativeProbeFailure(CertificateTrustFailure.cancelled)
          : const NativeProbeBoundaryFailure(
              NativeTlsBoundaryFailure.backendUnavailable,
            ),
    );
  }
}

final class _IoReconnect implements PinnedRpcConnector {
  @override
  Future<NativePinnedOutcome> reconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required Duration timeout,
    required CancellationToken cancellation,
  }) {
    validateNativeTlsTimeout(timeout);
    return Future.value(
      cancellation.isCancelled
          ? const NativePinnedFailure(CertificateTrustFailure.cancelled)
          : const NativePinnedBoundaryFailure(
              NativeTlsBoundaryFailure.backendUnavailable,
            ),
    );
  }
}
