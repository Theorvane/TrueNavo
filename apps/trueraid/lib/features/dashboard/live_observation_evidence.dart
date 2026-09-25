import 'dashboard_capabilities.dart';
import 'deferred_observation_contracts.dart';

/// The only accepted provenance for this display-only evidence.
enum LiveObservationEvidenceCaptureClassification { redactedFixture }

/// The outcome of evaluating redacted fixture evidence.
enum LiveObservationEvidenceDecisionStatus {
  eligibleForSeparateApproval,
  rejected,
}

/// A fixed, non-sensitive reason for rejecting evidence.
enum LiveObservationEvidenceRejectionReason {
  unsupportedVersion,
  fixturePolicyDisabled,
  malformed,
  noSafeObservations,
}

/// Bounded, display-only evidence derived from a redacted static fixture.
///
/// This object retains no fixture payload, connection details, identifiers, or
/// runtime API metadata.
final class LiveObservationEvidence {
  LiveObservationEvidence._({
    required this.versionFamily,
    required this.domain,
    required this.captureClassification,
    required List<DeferredObservation> observations,
  }) : observations = List.unmodifiable(observations);

  final DashboardVersionFamily versionFamily;
  final DeferredObservationDomain domain;
  final LiveObservationEvidenceCaptureClassification captureClassification;
  final List<DeferredObservation> observations;
}

/// A fail-closed decision from redacted fixture evidence.
final class LiveObservationEvidenceDecision {
  const LiveObservationEvidenceDecision._({
    required this.status,
    required this.rejectionReason,
    required this.evidence,
  });

  final LiveObservationEvidenceDecisionStatus status;
  final LiveObservationEvidenceRejectionReason? rejectionReason;
  final LiveObservationEvidence? evidence;

  /// Eligibility is evidence for a future, separate approval only.
  bool get requiresSeparateApproval =>
      status ==
      LiveObservationEvidenceDecisionStatus.eligibleForSeparateApproval;

  /// Evidence evaluation never activates a live API capability.
  bool get apiCapabilityEnabled => false;
}

/// Evaluates only redacted fixture-shaped values; it has no runtime transport.
final class LiveObservationEvidenceGate {
  const LiveObservationEvidenceGate._();

  static LiveObservationEvidenceDecision evaluate({
    required DashboardVersionFamily versionFamily,
    required DeferredObservationDomain domain,
    required Object? redactedFixture,
    bool fixturePolicyAvailable = true,
  }) {
    final contract = DeferredObservationContract.select(
      versionFamily: versionFamily,
      domain: domain,
      fixturePolicyAvailable: fixturePolicyAvailable,
    );
    final rejectionReason = switch (contract.state) {
      DeferredObservationContractState.unknownVersion =>
        LiveObservationEvidenceRejectionReason.unsupportedVersion,
      DeferredObservationContractState.policyUnavailable =>
        LiveObservationEvidenceRejectionReason.fixturePolicyDisabled,
      DeferredObservationContractState.fixtureOnly => null,
    };
    if (rejectionReason != null) {
      return _rejected(rejectionReason);
    }

    try {
      final observations = contract.parseFixture(redactedFixture).observations;
      if (observations.isEmpty) {
        return _rejected(
          LiveObservationEvidenceRejectionReason.noSafeObservations,
        );
      }
      return LiveObservationEvidenceDecision._(
        status:
            LiveObservationEvidenceDecisionStatus.eligibleForSeparateApproval,
        rejectionReason: null,
        evidence: LiveObservationEvidence._(
          versionFamily: versionFamily,
          domain: domain,
          captureClassification:
              LiveObservationEvidenceCaptureClassification.redactedFixture,
          observations: observations,
        ),
      );
    } catch (_) {
      return _rejected(LiveObservationEvidenceRejectionReason.malformed);
    }
  }

  static LiveObservationEvidenceDecision _rejected(
    LiveObservationEvidenceRejectionReason reason,
  ) => LiveObservationEvidenceDecision._(
    status: LiveObservationEvidenceDecisionStatus.rejected,
    rejectionReason: reason,
    evidence: null,
  );
}
