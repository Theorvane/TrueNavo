import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/dashboard/dashboard_capabilities.dart';
import 'package:truedash/features/dashboard/deferred_admission_record.dart';
import 'package:truedash/features/dashboard/deferred_observation_contracts.dart';

void main() {
  test('admits an explicitly approved complete 25.04 VDEV tuple as typed metadata only', () {
    final record = DeferredAdmissionRecord.admit(
      tuple: const DeferredAdmissionTuple(
        versionFamily: DashboardVersionFamily.v25_04,
        domain: DeferredObservationDomain.vdevs,
        sourceDigest: DeferredAdmissionSourceDigest(
          'sha256:0f3e4d5c6b7a80910f3e4d5c6b7a80910f3e4d5c6b7a80910f3e4d5c6b7a8091',
        ),
        requestDigest: DeferredAdmissionRequestDigest(
          'sha256:1a2b3c4d5e6f70811a2b3c4d5e6f70811a2b3c4d5e6f70811a2b3c4d5e6f7081',
        ),
        responseDigest: DeferredAdmissionResponseDigest(
          'sha256:9f8e7d6c5b4a32109f8e7d6c5b4a32109f8e7d6c5b4a32109f8e7d6c5b4a3210',
        ),
      ),
      gates: const DeferredAdmissionGates(
        rbacPassed: true,
        fixturePassed: true,
        evidencePassed: true,
        aexPassed: true,
      ),
      approval: const DeferredAdmissionApproval(explicitlyApproved: true),
    );

    expect(record.status, DeferredAdmissionStatus.approved);
    expect(record.metadata, isA<DeferredAdmissionMetadata>());
    expect(record.metadata!.versionFamily, DashboardVersionFamily.v25_04);
    expect(record.metadata!.domain, DeferredObservationDomain.vdevs);
    expect(
      record.metadata!.sourceDigest,
      const DeferredAdmissionSourceDigest(
        'sha256:0f3e4d5c6b7a80910f3e4d5c6b7a80910f3e4d5c6b7a80910f3e4d5c6b7a8091',
      ),
    );
    expect(
      record.metadata!.requestDigest,
      const DeferredAdmissionRequestDigest(
        'sha256:1a2b3c4d5e6f70811a2b3c4d5e6f70811a2b3c4d5e6f70811a2b3c4d5e6f7081',
      ),
    );
    expect(
      record.metadata!.responseDigest,
      const DeferredAdmissionResponseDigest(
        'sha256:9f8e7d6c5b4a32109f8e7d6c5b4a32109f8e7d6c5b4a32109f8e7d6c5b4a3210',
      ),
    );
    expect(record.apiCapabilityEnabled, isFalse);
  });

  test('rejects an invalid digest with the fixed rejection reason', () {
    final record = DeferredAdmissionRecord.admit(
      tuple: const DeferredAdmissionTuple(
        versionFamily: DashboardVersionFamily.v25_04,
        domain: DeferredObservationDomain.vdevs,
        sourceDigest: DeferredAdmissionSourceDigest('sha256:not-a-digest'),
        requestDigest: DeferredAdmissionRequestDigest(
          'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        responseDigest: DeferredAdmissionResponseDigest(
          'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      ),
      gates: const DeferredAdmissionGates(
        rbacPassed: true,
        fixturePassed: true,
        evidencePassed: true,
        aexPassed: true,
      ),
      approval: const DeferredAdmissionApproval(explicitlyApproved: true),
    );

    expect(record.status, DeferredAdmissionStatus.rejected);
    expect(
      record.rejectionReason,
      DeferredAdmissionRejectionReason.admissionRejected,
    );
    expect(record.metadata, isNull);
    expect(record.apiCapabilityEnabled, isFalse);
  });

  test(
    'rejects an incomplete set of gates with the fixed rejection reason',
    () {
      final record = DeferredAdmissionRecord.admit(
        tuple: const DeferredAdmissionTuple(
          versionFamily: DashboardVersionFamily.v25_04,
          domain: DeferredObservationDomain.vdevs,
          sourceDigest: DeferredAdmissionSourceDigest(
            'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          ),
          requestDigest: DeferredAdmissionRequestDigest(
            'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          ),
          responseDigest: DeferredAdmissionResponseDigest(
            'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
          ),
        ),
        gates: const DeferredAdmissionGates(
          rbacPassed: true,
          fixturePassed: false,
          evidencePassed: true,
          aexPassed: true,
        ),
        approval: const DeferredAdmissionApproval(explicitlyApproved: true),
      );

      expect(record.status, DeferredAdmissionStatus.rejected);
      expect(
        record.rejectionReason,
        DeferredAdmissionRejectionReason.admissionRejected,
      );
      expect(record.apiCapabilityEnabled, isFalse);
    },
  );

  void expectDefaultDenyInputToBeRejected({
    DashboardVersionFamily versionFamily = DashboardVersionFamily.v25_04,
    bool rbacPassed = true,
    bool fixturePassed = true,
    bool evidencePassed = true,
    bool aexPassed = true,
    bool explicitlyApproved = true,
  }) {
    final record = DeferredAdmissionRecord.admit(
      tuple: DeferredAdmissionTuple(
        versionFamily: versionFamily,
        domain: DeferredObservationDomain.vdevs,
        sourceDigest: const DeferredAdmissionSourceDigest(
          'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        requestDigest: const DeferredAdmissionRequestDigest(
          'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
        responseDigest: const DeferredAdmissionResponseDigest(
          'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        ),
      ),
      gates: DeferredAdmissionGates(
        rbacPassed: rbacPassed,
        fixturePassed: fixturePassed,
        evidencePassed: evidencePassed,
        aexPassed: aexPassed,
      ),
      approval: DeferredAdmissionApproval(
        explicitlyApproved: explicitlyApproved,
      ),
    );

    expect(record.status, DeferredAdmissionStatus.rejected);
    expect(
      record.rejectionReason,
      DeferredAdmissionRejectionReason.admissionRejected,
    );
    expect(record.metadata, isNull);
    expect(record.apiCapabilityEnabled, isFalse);
  }

  test('rejects an unknown unsupported version family', () {
    expectDefaultDenyInputToBeRejected(
      versionFamily: DashboardVersionFamily.unknownUnsupported,
    );
  });

  test('rejects when RBAC does not pass', () {
    expectDefaultDenyInputToBeRejected(rbacPassed: false);
  });

  test('rejects when the fixture gate does not pass', () {
    expectDefaultDenyInputToBeRejected(fixturePassed: false);
  });

  test('rejects when the evidence gate does not pass', () {
    expectDefaultDenyInputToBeRejected(evidencePassed: false);
  });

  test('rejects when the AEX gate does not pass', () {
    expectDefaultDenyInputToBeRejected(aexPassed: false);
  });

  test('rejects when approval is not explicit', () {
    expectDefaultDenyInputToBeRejected(explicitlyApproved: false);
  });
}
