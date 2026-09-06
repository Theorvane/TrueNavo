import 'package:truenas_api/truenas_api.dart';

import '../tls_trust/certificate_facts.dart';
import '../tls_trust/certificate_trust_coordinator.dart';
import '../tls_trust/models.dart';

sealed class ConnectionState {
  const ConnectionState();
}

final class ConnectionIdle extends ConnectionState {
  const ConnectionIdle();
}

final class ConnectionInProgress extends ConnectionState {
  const ConnectionInProgress();
}

final class ConnectionSucceeded extends ConnectionState {
  const ConnectionSucceeded(this.summary);
  final ServerSummary summary;
}

final class ConnectionFailed extends ConnectionState {
  const ConnectionFailed(this.message);
  final String message;
}

/// Display-only facts retained while an explicit trust action is pending.
/// Display-safe fingerprint digests are copied here; raw DER certificate bytes
/// remain owned by the coordinator and native-boundary layers.
final class TrustReviewCertificate {
  const TrustReviewCertificate({
    required this.subjectSummary,
    required this.issuerSummary,
    required this.leafDerSha256,
    required this.notValidBefore,
    required this.notValidAfter,
    required this.platformTrust,
  });

  factory TrustReviewCertificate.fromFacts(
    CertificateFacts facts,
    PlatformTrust platformTrust,
  ) => TrustReviewCertificate(
    subjectSummary: facts.subjectSummary,
    issuerSummary: facts.issuerSummary,
    leafDerSha256: facts.leafDerSha256,
    notValidBefore: facts.notValidBefore,
    notValidAfter: facts.notValidAfter,
    platformTrust: platformTrust,
  );

  final String subjectSummary;
  final String issuerSummary;
  final String leafDerSha256;
  final DateTime notValidBefore;
  final DateTime notValidAfter;
  final PlatformTrust platformTrust;
}

sealed class ConnectionTrustReview extends ConnectionState {
  const ConnectionTrustReview({required this.token, required this.authority});
  final TrustOperationToken token;
  final NormalizedAuthority authority;
}

final class ConnectionFirstTrustReview extends ConnectionTrustReview {
  const ConnectionFirstTrustReview({
    required super.token,
    required super.authority,
    required this.certificate,
  });
  final TrustReviewCertificate certificate;
}

final class ConnectionReplacementTrustReview extends ConnectionTrustReview {
  const ConnectionReplacementTrustReview({
    required super.token,
    required super.authority,
    required this.previousPin,
    required this.certificate,
  });
  final TrustReviewPreviousPin previousPin;
  final TrustReviewCertificate certificate;
}

/// Display-safe prior pin information required to explain a replacement.
final class TrustReviewPreviousPin {
  const TrustReviewPreviousPin({
    required this.leafDerSha256,
    required this.createdAt,
  });

  final String leafDerSha256;
  final DateTime createdAt;
}

final class ConnectionTrustBlocked extends ConnectionState {
  const ConnectionTrustBlocked({
    required this.failure,
    required this.token,
    required this.authority,
  });
  final CertificateTrustCoordinatorFailure failure;
  final TrustOperationToken token;
  final NormalizedAuthority authority;
}

final class ConnectionBrowserManagedTls extends ConnectionState {
  const ConnectionBrowserManagedTls();
}
