import 'models.dart';
import 'native_tls_ports.dart';

NativeCertificateProbe createProbe() => _WebProbe();
PinnedRpcConnector createReconnect() => _WebReconnect();

final class _WebProbe implements NativeCertificateProbe {
  @override
  Future<NativeProbeOutcome> probe({
    required NormalizedAuthority authority,
    required Duration timeout,
    required CancellationToken cancellation,
  }) {
    validateNativeTlsTimeout(timeout);
    return Future.value(
      cancellation.isCancelled
          ? const NativeProbeFailure(CertificateTrustFailure.cancelled)
          : const NativeProbeBrowserManagedTls(),
    );
  }
}

final class _WebReconnect implements PinnedRpcConnector {
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
          : const NativePinnedBrowserManagedTls(),
    );
  }
}
