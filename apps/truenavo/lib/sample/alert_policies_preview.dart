// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Isolated configuration fixtures. No support or alert dispatch exists here.
mixin AlertPoliciesPreviewAdapter implements AuthenticatedAlertPoliciesSession {
  static final _inventory = AlertPoliciesInventory(
    readiness: AlertSettingsInventory(
      endpoint: 'wss://nas-demo.example/api/current',
      hostId:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      bootId: '12345678-1234-4234-8234-123456789abc',
      currentVersion: '25.10.1',
      state: 'READY',
      fullAdmin: true,
      failoverLicensed: false,
      conflictingJob: false,
      bootPool: 'boot-pool',
      bootHealthy: true,
      environments: const [
        BootEnvironmentSnapshot(
          id: '25.10.1',
          dataset: 'boot-pool/ROOT/25.10.1',
          created: '2026-09-01T10:00:00',
          usedBytes: 4294967296,
          active: true,
          activated: true,
          keep: true,
          canActivate: true,
        ),
      ],
      services: const [],
    ),
    configId: 1,
    supportAvailable: false,
    supportEnabled: false,
    classes: const [
      AlertClassPolicySnapshot(
        id: 'PoolCapacity',
        title: 'Pool capacity warning',
        categoryId: 'STORAGE',
        categoryTitle: 'Storage',
        defaultLevel: AlertDeliveryLevel.warning,
        supportsProactiveSupport: false,
        hasOverride: true,
        overrides: AlertClassOverrides(policy: AlertPolicyFrequency.hourly),
      ),
      AlertClassPolicySnapshot(
        id: 'ScrubFinished',
        title: 'Scrub completed',
        categoryId: 'STORAGE',
        categoryTitle: 'Storage',
        defaultLevel: AlertDeliveryLevel.info,
        supportsProactiveSupport: false,
        hasOverride: true,
        overrides: AlertClassOverrides(policy: AlertPolicyFrequency.daily),
      ),
      AlertClassPolicySnapshot(
        id: 'CertificateExpiring',
        title: 'Certificate nearing expiration',
        categoryId: 'CERTIFICATES',
        categoryTitle: 'Certificates',
        defaultLevel: AlertDeliveryLevel.warning,
        supportsProactiveSupport: false,
        hasOverride: false,
      ),
      AlertClassPolicySnapshot(
        id: 'DiskFailure',
        title: 'Disk failure requires attention',
        categoryId: 'HARDWARE',
        categoryTitle: 'Hardware',
        defaultLevel: AlertDeliveryLevel.critical,
        supportsProactiveSupport: true,
        hasOverride: false,
      ),
    ],
  );
  @override
  AlertPoliciesCapabilities get alertPoliciesCapabilities =>
      const AlertPoliciesCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canUpdate: true,
        canReadSupportEligibility: true,
      );
  @override
  Future<AlertPoliciesInventory> loadAlertPolicies() async => _inventory;
  @override
  Future<AlertPoliciesReview> reviewAlertPolicies(
    AlertPoliciesRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const AlertPoliciesException(
        AlertPoliciesExceptionReason.invalidRequest,
      );
    }
    return AlertPoliciesReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. No policy update, support request or notification is submitted.',
        'NEVER hides standard alerts and notification-service delivery, but does not stop independent mail or proactive support.',
        'Class reset preserves unrelated overrides. Restoring proactive support defaults can allow external system-detail disclosure.',
      ],
    );
  }

  @override
  Future<AlertPoliciesResult> executeAlertPolicies(
    AlertPoliciesReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => const AlertPoliciesResult(
    AlertPoliciesOutcome.rejected,
    'Sample preview: no policy write, support request or notification was performed.',
  );
}
