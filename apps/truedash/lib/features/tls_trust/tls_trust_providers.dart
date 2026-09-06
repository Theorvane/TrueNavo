import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'certificate_trust_coordinator.dart';
import 'native_tls_ports.dart';
import 'pin_store.dart';
import 'tls_trust_route_platform_stub.dart'
    if (dart.library.io) 'tls_trust_route_platform_io.dart'
    as platform;

/// The app-owned routing seam keeps browser platform handling out of the
/// controller and is deliberately easy to override in deterministic tests.
enum TlsTrustRoute { native, platformValidated, browserManaged }

final tlsTrustRouteProvider = Provider<TlsTrustRoute>(
  (ref) => kIsWeb
      ? TlsTrustRoute.browserManaged
      : platform.supportsNativeTofuTrust()
      ? TlsTrustRoute.native
      : TlsTrustRoute.platformValidated,
);

final pinStoreProvider = Provider<PinStore>((ref) => createPlatformPinStore());

final nativeCertificateProbeProvider = Provider<NativeCertificateProbe>(
  (ref) => createNativeCertificateProbe(),
);

final pinnedRpcConnectorProvider = Provider<PinnedRpcConnector>(
  (ref) => createPinnedRpcConnector(),
);

final certificateTrustCoordinatorProvider =
    Provider<CertificateTrustCoordinator>(
      (ref) => CertificateTrustCoordinator(
        pinStore: ref.watch(pinStoreProvider),
        probe: ref.watch(nativeCertificateProbeProvider),
        connector: ref.watch(pinnedRpcConnectorProvider),
        now: DateTime.now,
        probeTimeout: const Duration(seconds: 15),
        reconnectTimeout: const Duration(seconds: 15),
      ),
    );
