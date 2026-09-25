import 'package:truenas_api/truenas_api.dart';

/// Connector-free fixture. It never creates, rotates or returns a real key.
mixin ApiKeysPreviewAdapter implements AuthenticatedApiKeysSession {
  static final _inventory = ApiKeyInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    username: 'demo-admin',
    userId: 42,
    sessionId: 'synthetic-session',
    credentialType: 'API_KEY',
    currentKeyId: 1,
    accountEligible: true,
    stig: false,
    keys: [
      ApiKeySnapshot(
        id: 1,
        name: 'TrueRAID · current session',
        username: 'demo-admin',
        userId: 42,
        createdAt: DateTime.utc(2026, 9, 1),
        expiresAt: DateTime.utc(2099),
        local: true,
        revoked: false,
      ),
      ApiKeySnapshot(
        id: 2,
        name: 'Backup monitoring',
        username: 'demo-admin',
        userId: 42,
        createdAt: DateTime.utc(2026, 8, 1),
        expiresAt: null,
        local: true,
        revoked: false,
      ),
      ApiKeySnapshot(
        id: 3,
        name: 'Retired integration',
        username: 'demo-admin',
        userId: 42,
        createdAt: DateTime.utc(2025, 8, 1),
        expiresAt: DateTime.utc(2025, 9, 1),
        local: true,
        revoked: false,
      ),
      ApiKeySnapshot(
        id: 4,
        name: 'Revoked client',
        username: 'demo-admin',
        userId: 42,
        createdAt: DateTime.utc(2025, 8, 1),
        expiresAt: null,
        local: true,
        revoked: true,
      ),
    ],
  );
  @override
  ApiKeysCapabilities get apiKeysCapabilities => const ApiKeysCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
    canCreate: true,
    canUpdate: true,
    canDelete: true,
  );
  @override
  Future<ApiKeyInventory> loadApiKeys() async => _inventory;
  @override
  Future<ApiKeyReview> reviewApiKey(ApiKeyRequest request) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const ApiKeysException(ApiKeysExceptionReason.invalidRequest);
    }
    return ApiKeyReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. No key change, credential reveal or network request is possible.',
      ],
    );
  }

  @override
  Future<ApiKeyResult> executeApiKey(
    ApiKeyReview review,
    String confirmation,
  ) async => const ApiKeyResult(
    ApiKeyOutcome.rejected,
    'Sample preview: no API-key request was sent.',
  );
}
