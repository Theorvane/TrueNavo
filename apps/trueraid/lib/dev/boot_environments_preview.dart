import 'package:truenas_api/truenas_api.dart';

/// Synthetic presentation fixtures only. No transport, credentials or server
/// mutation is available. SDK-issued reviews cannot be forged by the preview.
mixin BootEnvironmentsPreviewAdapter
    implements AuthenticatedBootEnvironmentsSession {
  @override
  BootEnvironmentsCapabilities get bootEnvironmentsCapabilities =>
      const BootEnvironmentsCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        actions: {
          BootEnvironmentAction.clone,
          BootEnvironmentAction.keep,
          BootEnvironmentAction.activate,
          BootEnvironmentAction.delete,
        },
      );

  @override
  Future<BootEnvironmentInventory> loadBootEnvironments() async =>
      BootEnvironmentInventory(
        failoverLicensed: false,
        environments: const [
          BootEnvironmentSnapshot(
            id: '25.10.1',
            dataset: 'boot-pool/ROOT/25.10.1',
            created: '2026-09-10T12:00:00',
            usedBytes: 1879048192,
            active: true,
            activated: true,
            keep: true,
            canActivate: true,
          ),
          BootEnvironmentSnapshot(
            id: 'before-storage-maintenance',
            dataset: 'boot-pool/ROOT/before-storage-maintenance',
            created: '2026-09-09T08:30:00',
            usedBytes: 805306368,
            active: false,
            activated: false,
            keep: true,
            canActivate: true,
          ),
          BootEnvironmentSnapshot(
            id: '25.10.0',
            dataset: 'boot-pool/ROOT/25.10.0',
            created: '2026-08-21T16:45:00',
            usedBytes: 536870912,
            active: false,
            activated: false,
            keep: false,
            canActivate: true,
          ),
        ],
      );

  @override
  Future<BootEnvironmentReview> reviewBootEnvironment(
    BootEnvironmentRequest request,
  ) => Future.error(
    StateError('Synthetic preview cannot authorize boot environment changes.'),
  );

  @override
  Future<BootEnvironmentResult> executeBootEnvironment(
    BootEnvironmentReview review,
  ) async => const BootEnvironmentResult(
    outcome: BootEnvironmentOutcome.rejected,
    message: 'Synthetic preview cannot change boot environments.',
  );
}
