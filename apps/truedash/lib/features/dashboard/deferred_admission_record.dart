import 'dashboard_capabilities.dart';
import 'deferred_observation_contracts.dart';

/// A digest of the documented source material used for an admission decision.
final class DeferredAdmissionSourceDigest extends DeferredAdmissionDigest {
  const DeferredAdmissionSourceDigest(super.value);
}

/// A digest of the documented request shape used for an admission decision.
final class DeferredAdmissionRequestDigest extends DeferredAdmissionDigest {
  const DeferredAdmissionRequestDigest(super.value);
}

/// A digest of the documented response shape used for an admission decision.
final class DeferredAdmissionResponseDigest extends DeferredAdmissionDigest {
  const DeferredAdmissionResponseDigest(super.value);
}

/// A typed, bounded SHA-256 identifier.
sealed class DeferredAdmissionDigest {
  const DeferredAdmissionDigest(this.value);

  static final RegExp _sha256 = RegExp(r'^sha256:[0-9a-f]{64}$');

  final String value;

  bool get isValid => _sha256.hasMatch(value);

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is DeferredAdmissionDigest &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);
}

/// The complete typed input required to evaluate one deferred admission.
final class DeferredAdmissionTuple {
  const DeferredAdmissionTuple({
    required this.versionFamily,
    required this.domain,
    required this.sourceDigest,
    required this.requestDigest,
    required this.responseDigest,
  });

  final DashboardVersionFamily versionFamily;
  final DeferredObservationDomain domain;
  final DeferredAdmissionSourceDigest sourceDigest;
  final DeferredAdmissionRequestDigest requestDigest;
  final DeferredAdmissionResponseDigest responseDigest;

  bool get hasValidDigests =>
      sourceDigest.isValid && requestDigest.isValid && responseDigest.isValid;
}

/// The independent checks required before an admission may be approved.
final class DeferredAdmissionGates {
  const DeferredAdmissionGates({
    required this.rbacPassed,
    required this.fixturePassed,
    required this.evidencePassed,
    required this.aexPassed,
  });

  final bool rbacPassed;
  final bool fixturePassed;
  final bool evidencePassed;
  final bool aexPassed;

  bool get allPassed =>
      rbacPassed && fixturePassed && evidencePassed && aexPassed;
}

/// The separate, explicit human approval input.
final class DeferredAdmissionApproval {
  const DeferredAdmissionApproval({required this.explicitlyApproved});

  final bool explicitlyApproved;
}

enum DeferredAdmissionStatus { approved, rejected }

/// A single fixed reason prevents rejection records from exposing input detail.
enum DeferredAdmissionRejectionReason { admissionRejected }

/// The bounded, typed metadata retained with an admission decision.
final class DeferredAdmissionMetadata {
  const DeferredAdmissionMetadata({
    required this.versionFamily,
    required this.domain,
    required this.sourceDigest,
    required this.requestDigest,
    required this.responseDigest,
  });

  final DashboardVersionFamily versionFamily;
  final DeferredObservationDomain domain;
  final DeferredAdmissionSourceDigest sourceDigest;
  final DeferredAdmissionRequestDigest requestDigest;
  final DeferredAdmissionResponseDigest responseDigest;
}

/// A local-only admission outcome for a deferred dashboard observation.
final class DeferredAdmissionRecord {
  const DeferredAdmissionRecord._({
    required this.status,
    required this.metadata,
    this.rejectionReason,
  });

  /// Evaluates typed, local inputs only.
  factory DeferredAdmissionRecord.admit({
    required DeferredAdmissionTuple tuple,
    required DeferredAdmissionGates gates,
    required DeferredAdmissionApproval approval,
  }) {
    final approved =
        tuple.versionFamily != DashboardVersionFamily.unknownUnsupported &&
        tuple.hasValidDigests &&
        gates.allPassed &&
        approval.explicitlyApproved;
    return DeferredAdmissionRecord._(
      status: approved
          ? DeferredAdmissionStatus.approved
          : DeferredAdmissionStatus.rejected,
      metadata: approved
          ? DeferredAdmissionMetadata(
              versionFamily: tuple.versionFamily,
              domain: tuple.domain,
              sourceDigest: tuple.sourceDigest,
              requestDigest: tuple.requestDigest,
              responseDigest: tuple.responseDigest,
            )
          : null,
      rejectionReason: approved
          ? null
          : DeferredAdmissionRejectionReason.admissionRejected,
    );
  }

  final DeferredAdmissionStatus status;
  final DeferredAdmissionMetadata? metadata;
  final DeferredAdmissionRejectionReason? rejectionReason;

  /// Deferred admissions never enable a runtime API capability.
  bool get apiCapabilityEnabled => false;
}
