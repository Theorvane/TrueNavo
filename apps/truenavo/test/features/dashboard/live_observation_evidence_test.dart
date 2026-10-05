import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/dashboard/dashboard_capabilities.dart';
import 'package:truenavo/features/dashboard/deferred_observation_contracts.dart';
import 'package:truenavo/features/dashboard/live_observation_evidence.dart';

void main() {
  const supportedFamilies = <DashboardVersionFamily>[
    DashboardVersionFamily.v25_04,
    DashboardVersionFamily.v25_10,
    DashboardVersionFamily.v26Plus,
  ];

  test(
    'makes every supported fixture/domain pair eligible only for approval',
    () {
      for (final family in supportedFamilies) {
        for (final domain in DeferredObservationDomain.values) {
          final decision = LiveObservationEvidenceGate.evaluate(
            versionFamily: family,
            domain: domain,
            redactedFixture: _readFixture(
              'live_evidence_${_familyName(family)}_${domain.name}.json',
            ),
          );

          expect(
            decision.status,
            LiveObservationEvidenceDecisionStatus.eligibleForSeparateApproval,
          );
          expect(decision.requiresSeparateApproval, isTrue);
          expect(decision.apiCapabilityEnabled, isFalse);
          expect(decision.rejectionReason, isNull);
          expect(decision.evidence, isNotNull);
          expect(decision.evidence!.versionFamily, family);
          expect(decision.evidence!.domain, domain);
          expect(
            decision.evidence!.captureClassification,
            LiveObservationEvidenceCaptureClassification.redactedFixture,
          );
          expect(decision.evidence!.observations, isNotEmpty);
        }
      }
    },
  );

  test('fails closed with fixed reasons', () {
    final malformed = LiveObservationEvidenceGate.evaluate(
      versionFamily: DashboardVersionFamily.v25_04,
      domain: DeferredObservationDomain.vdevs,
      redactedFixture: _readFixture('live_evidence_malformed.json'),
    );
    final secretShaped = LiveObservationEvidenceGate.evaluate(
      versionFamily: DashboardVersionFamily.v25_10,
      domain: DeferredObservationDomain.disks,
      redactedFixture: _readFixture('live_evidence_secret_shaped.json'),
    );
    final empty = LiveObservationEvidenceGate.evaluate(
      versionFamily: DashboardVersionFamily.v26Plus,
      domain: DeferredObservationDomain.apps,
      redactedFixture: <String, Object>{'observations': <Object>[]},
    );
    final policyDisabled = LiveObservationEvidenceGate.evaluate(
      versionFamily: DashboardVersionFamily.v25_04,
      domain: DeferredObservationDomain.snapshots,
      fixturePolicyAvailable: false,
      redactedFixture: _readFixture('live_evidence_v25_04_snapshots.json'),
    );
    final unsupported = LiveObservationEvidenceGate.evaluate(
      versionFamily: DashboardVersionFamily.unknownUnsupported,
      domain: DeferredObservationDomain.apps,
      redactedFixture: _readFixture('live_evidence_v26_plus_apps.json'),
    );

    _expectRejected(
      malformed,
      LiveObservationEvidenceRejectionReason.malformed,
    );
    _expectRejected(
      secretShaped,
      LiveObservationEvidenceRejectionReason.malformed,
    );
    _expectRejected(
      empty,
      LiveObservationEvidenceRejectionReason.noSafeObservations,
    );
    _expectRejected(
      policyDisabled,
      LiveObservationEvidenceRejectionReason.fixturePolicyDisabled,
    );
    _expectRejected(
      unsupported,
      LiveObservationEvidenceRejectionReason.unsupportedVersion,
    );
  });
}

void _expectRejected(
  LiveObservationEvidenceDecision decision,
  LiveObservationEvidenceRejectionReason reason,
) {
  expect(decision.status, LiveObservationEvidenceDecisionStatus.rejected);
  expect(decision.rejectionReason, reason);
  expect(decision.evidence, isNull);
  expect(decision.requiresSeparateApproval, isFalse);
  expect(decision.apiCapabilityEnabled, isFalse);
}

Object _readFixture(String name) =>
    jsonDecode(File('test/fixtures/dashboard/$name').readAsStringSync());

String _familyName(DashboardVersionFamily family) => switch (family) {
  DashboardVersionFamily.v25_04 => 'v25_04',
  DashboardVersionFamily.v25_10 => 'v25_10',
  DashboardVersionFamily.v26Plus => 'v26_plus',
  DashboardVersionFamily.unknownUnsupported => 'unknown_unsupported',
};
