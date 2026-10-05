// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Configuration samples only: no provider connector, send method or dispatcher.
mixin AlertSettingsPreviewAdapter implements AuthenticatedAlertSettingsSession {
  static final _inventory = AlertSettingsInventory(
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
      AlertServiceSnapshot(
        id: 11,
        name: 'Operations email',
        type: 'Mail',
        level: AlertDeliveryLevel.warning,
        enabled: false,
        recipient: 'operations@example.com',
        emailAttributesSupported: true,
      ),
      AlertServiceSnapshot(
        id: 12,
        name: 'Critical on-call',
        type: 'Mail',
        level: AlertDeliveryLevel.critical,
        enabled: true,
        recipient: 'oncall@example.com',
        emailAttributesSupported: true,
      ),
      AlertServiceSnapshot(
        id: 13,
        name: 'Legacy administrator delivery',
        type: 'Mail',
        level: AlertDeliveryLevel.error,
        enabled: false,
        recipient: '',
        emailAttributesSupported: true,
      ),
      AlertServiceSnapshot(
        id: 14,
        name: 'Team channel',
        type: 'Slack',
        level: AlertDeliveryLevel.warning,
        enabled: true,
      ),
      AlertServiceSnapshot(
        id: 15,
        name: 'Unsupported email configuration',
        type: 'Mail',
        level: AlertDeliveryLevel.emergency,
        enabled: true,
      ),
    ],
  );

  @override
  AlertSettingsCapabilities get alertSettingsCapabilities =>
      const AlertSettingsCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canCreate: true,
        canUpdate: true,
        canDelete: true,
      );

  @override
  Future<AlertSettingsInventory> loadAlertSettings() async => _inventory;

  @override
  Future<AlertSettingsReview> reviewAlertSettings(
    AlertSettingsRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const AlertSettingsException(
        AlertSettingsExceptionReason.invalidRequest,
      );
    }
    return AlertSettingsReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. No service, SMTP connection, provider test, message or server write is created.',
        'Real enablement allows ongoing external HTML alert delivery and server-default queued retries. Disabling or deleting cannot recall queued or in-flight mail or stop independent notification paths.',
        'Charts describe loaded configuration, not delivery, coverage or health. Provider credentials are not part of this sample.',
      ],
    );
  }

  @override
  Future<AlertSettingsResult> executeAlertSettings(
    AlertSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => const AlertSettingsResult(
    AlertSettingsOutcome.rejected,
    'Sample preview: no notification service, configuration write, test or delivery was performed.',
  );
}
