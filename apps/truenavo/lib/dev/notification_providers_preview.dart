import 'package:truenas_api/truenas_api.dart';

/// No stored credentials, external connectors or provider dispatcher.
mixin NotificationProvidersPreviewAdapter
    implements AuthenticatedNotificationProvidersSession {
  static final _inventory = NotificationProvidersInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    hostId: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
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
    services: const [
      NotificationProviderSnapshot(
        id: 21,
        name: 'Operations channel',
        type: 'Slack',
        level: AlertDeliveryLevel.warning,
        enabled: false,
      ),
      NotificationProviderSnapshot(
        id: 22,
        name: 'On-call chat',
        type: 'Telegram',
        level: AlertDeliveryLevel.critical,
        enabled: true,
      ),
      NotificationProviderSnapshot(
        id: 23,
        name: 'Incident response',
        type: 'PagerDuty',
        level: AlertDeliveryLevel.error,
        enabled: false,
      ),
      NotificationProviderSnapshot(
        id: 24,
        name: 'Metrics receiver',
        type: 'InfluxDB',
        level: AlertDeliveryLevel.notice,
        enabled: false,
      ),
      NotificationProviderSnapshot(
        id: 25,
        name: 'Email uses separate workspace',
        type: 'Mail',
        level: AlertDeliveryLevel.warning,
        enabled: true,
      ),
    ],
  );
  @override
  NotificationProvidersCapabilities get notificationProvidersCapabilities =>
      const NotificationProvidersCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canCreate: true,
        canUpdate: true,
        canDelete: true,
      );
  @override
  Future<NotificationProvidersInventory> loadNotificationProviders() async =>
      _inventory;
  @override
  Future<NotificationProvidersReview> reviewNotificationProviders(
    NotificationProvidersRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      request.credentials?.dispose();
      throw const NotificationProvidersException(
        NotificationProvidersExceptionReason.invalidRequest,
      );
    }
    return NotificationProvidersReview(
      request: request,
      endpoint: _inventory.endpoint,
      destinationSummary: 'SAMPLE DESTINATION ONLY · no external service',
      publicFields: const {
        'Configuration': 'Sample only; no stored credentials',
      },
      unencrypted: request.provider!.unencrypted,
      warnings: const [
        'SAMPLE ONLY. No provider, configuration write, test or notification is created.',
        'Real enablement can send sensitive alerts externally. Disable and delete cannot recall in-flight delivery.',
      ],
    );
  }

  @override
  Future<NotificationProvidersResult> executeNotificationProviders(
    NotificationProvidersReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    review.request.credentials?.dispose();
    return const NotificationProvidersResult(
      NotificationProvidersOutcome.rejected,
      'Sample preview: no provider write, test, credentials or delivery was submitted.',
    );
  }
}
