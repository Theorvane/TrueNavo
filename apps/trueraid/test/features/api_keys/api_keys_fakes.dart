import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const apiKeyEndpoint = 'wss://sample.example/api/current';
const syntheticApiKey = '99-SYNTHETIC-ONLY-NOT-A-REAL-SERVER-KEY';
const apiKeyCaps = ApiKeysCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canCreate: true,
  canUpdate: true,
  canDelete: true,
);

ApiKeyInventory keyInventory({bool empty = false, bool stig = false}) =>
    ApiKeyInventory(
      endpoint: apiKeyEndpoint,
      username: 'sample-admin',
      userId: 42,
      sessionId: 'synthetic-session',
      credentialType: 'LOGIN_PASSWORD',
      currentKeyId: empty ? null : 1,
      accountEligible: true,
      stig: stig,
      keys: empty
          ? []
          : [
              ApiKeySnapshot(
                id: 1,
                name: 'Current protected key',
                username: 'sample-admin',
                userId: 42,
                createdAt: DateTime.utc(2025),
                expiresAt: null,
                local: true,
                revoked: false,
              ),
              ApiKeySnapshot(
                id: 2,
                name: 'Backup monitoring',
                username: 'sample-admin',
                userId: 42,
                createdAt: DateTime.utc(2025),
                expiresAt: null,
                local: true,
                revoked: false,
              ),
              ApiKeySnapshot(
                id: 3,
                name: 'Expired client',
                username: 'sample-admin',
                userId: 42,
                createdAt: DateTime.utc(2020),
                expiresAt: DateTime.utc(2021),
                local: true,
                revoked: false,
              ),
              ApiKeySnapshot(
                id: 4,
                name: 'Revoked client',
                username: 'sample-admin',
                userId: 42,
                createdAt: DateTime.utc(2020),
                expiresAt: null,
                local: true,
                revoked: true,
              ),
            ],
    );

ApiKeyReview keyReview(
  ApiKeyInventory inventory, {
  ApiKeyAction action = ApiKeyAction.create,
}) => ApiKeyReview(
  request: ApiKeyRequest(
    inventory: inventory,
    action: action,
    key: action == ApiKeyAction.create ? null : inventory.keys[1],
    name: action == ApiKeyAction.delete ? '' : 'New integration',
  ),
  endpoint: inventory.endpoint,
  warnings: const [
    'Existing authenticated sessions are not terminated.',
    'Store any new key securely.',
  ],
);

class ApiKeysFake implements SessionRepository, AuthenticatedApiKeysSession {
  ApiKeysFake({ApiKeyInventory? inventory, this.caps = apiKeyCaps})
    : inventory = inventory ?? keyInventory();
  final ApiKeyInventory inventory;
  final ApiKeysCapabilities caps;
  int reads = 0;
  final reviews = <ApiKeyRequest>[];
  final writes = <ApiKeyReview>[];
  Future<ApiKeyInventory> Function()? onLoad;
  Future<ApiKeyReview> Function(ApiKeyRequest)? onReview;
  Future<ApiKeyResult> Function()? onExecute;
  @override
  ApiKeysCapabilities get apiKeysCapabilities => caps;
  @override
  Future<ApiKeyInventory> loadApiKeys() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<ApiKeyReview> reviewApiKey(ApiKeyRequest request) async {
    reviews.add(request);
    return onReview?.call(request) ??
        ApiKeyReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const [
            'Existing authenticated sessions are not terminated.',
            'Store any new key securely.',
          ],
        );
  }

  @override
  Future<ApiKeyResult> executeApiKey(
    ApiKeyReview review,
    String confirmation,
  ) async {
    writes.add(review);
    return onExecute?.call() ??
        const ApiKeyResult(
          ApiKeyOutcome.succeeded,
          'Synthetic operation confirmed.',
        );
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnsupportedError('No connector exists in this fixture.');
}

class ApiKeysHarness {
  ApiKeysHarness({ApiKeysFake? fake}) : api = fake ?? ApiKeysFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final ApiKeysFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({
    String? endpoint = apiKeyEndpoint,
    ApiKeysFake? fake,
  }) => AuthenticatedSession(
    profileId: 'sample',
    repository: fake ?? api,
    availableMethodNames: const {},
    version: '25.10.1',
    endpoint: endpoint,
  );
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  void dispose() => container.dispose();
}
