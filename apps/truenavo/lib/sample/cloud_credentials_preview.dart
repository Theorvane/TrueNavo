// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Connector-free sample. Never contains or submits authentication material.
mixin CloudCredentialsPreviewAdapter
    implements AuthenticatedCloudCredentialsSession {
  static final inventory = CloudCredentialInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    credentials: const [
      CloudCredentialEntry(id: 1, name: 'Archive S3', provider: 'S3'),
      CloudCredentialEntry(id: 2, name: 'Design Dropbox', provider: 'DROPBOX'),
      CloudCredentialEntry(
        id: 3,
        name: 'Legacy OneDrive',
        provider: 'ONEDRIVE',
      ),
      CloudCredentialEntry(id: 4, name: 'Spare S3', provider: 'S3'),
    ],
    references: const [
      CloudCredentialReference(
        kind: 'cloudsync',
        id: 1,
        credentialId: 1,
        enabled: true,
      ),
      CloudCredentialReference(
        kind: 'cloud_backup',
        id: 2,
        credentialId: 1,
        enabled: false,
      ),
      CloudCredentialReference(
        kind: 'cloudsync',
        id: 3,
        credentialId: 2,
        enabled: false,
      ),
    ],
  );
  @override
  CloudCredentialsCapabilities get cloudCredentialsCapabilities =>
      const CloudCredentialsCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canCreate: true,
        canUpdate: true,
        canDelete: true,
      );
  @override
  Future<CloudCredentialInventory> loadCloudCredentials() async => inventory;
  @override
  Future<CloudCredentialReview> reviewCloudCredential(
    CloudCredentialRequest request,
  ) async {
    if (!identical(request.inventory, inventory) ||
        request.validationError != null) {
      throw const CloudCredentialsException(
        CloudCredentialsExceptionReason.invalidRequest,
      );
    }
    return CloudCredentialReview(
      request: request,
      endpoint: inventory.endpoint,
      warnings: [
        'SAMPLE DATA — no NAS connection or credential write is possible.',
        'Only names, provider types and task references are loaded. Current secrets remain hidden.',
        'Rename preserves the provider record. Replace overwrites every provider field, including intentional blank optional values.',
        'Replacement changes every dependent task; schedules must first be disabled. Delete requires no cloud sync or cloud backup references.',
        'No automatic cloud verification, file listing, OAuth flow, or retry.',
      ],
    );
  }

  @override
  Future<CloudCredentialResult> executeCloudCredential(
    CloudCredentialReview review,
    String confirmation, {
    CloudCredentialWriteOnlyInput? input,
  }) async {
    input?.dispose();
    return const CloudCredentialResult(
      CloudCredentialOutcome.rejected,
      'Preview only. No credential operation was sent.',
    );
  }
}
