import 'package:truenas_api/truenas_api.dart';

/// Connector-free sample metadata. This adapter never generates private keys,
/// stores credentials, scans hosts or starts SSH connections.
mixin SshCredentialsPreviewAdapter
    implements AuthenticatedSshCredentialsSession {
  static const _publicKey =
      'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB';
  static final _inventory = SshCredentialInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    credentials: [
      const SshCredentialEntry(
        id: 1,
        name: 'Backup public identity',
        type: 'SSH_KEY_PAIR',
        usageCount: 1,
        publicKey: _publicKey,
      ),
      const SshCredentialEntry(
        id: 2,
        name: 'Offline spare identity',
        type: 'SSH_KEY_PAIR',
        usageCount: 0,
        publicKey: _publicKey,
      ),
      const SshCredentialEntry(
        id: 3,
        name: 'Archive destination',
        type: 'SSH_CREDENTIALS',
        usageCount: 2,
        connection: SshConnectionSettings(
          host: 'archive-demo.example',
          port: 22,
          username: 'backup',
          keyPairId: 1,
          remoteHostKey: _publicKey,
          connectTimeout: 10,
        ),
      ),
    ],
  );
  @override
  SshCredentialsCapabilities get sshCredentialsCapabilities =>
      const SshCredentialsCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canImport: true,
        canGenerate: true,
        canCreateConnection: true,
        canRename: true,
        canDelete: true,
      );
  @override
  Future<SshCredentialInventory> loadSshCredentials() async => _inventory;
  @override
  Future<SshCredentialReview> reviewSshCredential(
    SshCredentialRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const SshCredentialsException(
        SshCredentialsExceptionReason.invalidRequest,
      );
    }
    return SshCredentialReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. No private-key generation, credential write, host scan or remote connection can occur.',
      ],
    );
  }

  @override
  Future<SshCredentialResult> executeSshCredential(
    SshCredentialReview review,
    String confirmation, {
    SshCredentialWriteOnlyInput? input,
  }) async {
    input?.dispose();
    return const SshCredentialResult(
      SshCredentialOutcome.rejected,
      'Sample preview: no key generation, private key, credential write or network request.',
    );
  }
}
