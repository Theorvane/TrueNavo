// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Synthetic SMTP metadata only. There is no mail connector or job dispatcher.
mixin EmailSettingsPreviewAdapter implements AuthenticatedEmailSettingsSession {
  static final _inventory = EmailSettingsInventory(
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
    config: const EmailConfigSnapshot(
      id: 1,
      passwordPresent: true,
      oauthPresent: false,
      settings: EmailSmtpSettings(
        fromEmail: 'alerts@example.com',
        fromName: 'TrueNavo notifications',
        outgoingServer: 'smtp.example.com',
        username: 'alerts@example.com',
      ),
    ),
  );

  @override
  EmailSettingsCapabilities get emailSettingsCapabilities =>
      const EmailSettingsCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canConfigure: true,
        canTest: true,
      );

  @override
  Future<EmailSettingsInventory> loadEmailSettings() async => _inventory;

  @override
  Future<EmailSettingsReview> reviewEmailSettings(
    EmailSettingsRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const EmailSettingsException(
        EmailSettingsExceptionReason.invalidRequest,
      );
    }
    return EmailSettingsReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: [
        'SAMPLE ONLY. No server connection, DNS lookup, SMTP authentication, email transmission, job or settings write occurs.',
        if (request.action == EmailSettingsAction.configure)
          'Real SMTP changes can affect later alerts and previously queued messages. Saving does not itself test delivery. Keep, Replace and Clear have distinct credential effects.'
        else
          'Real test mail sends one fixed message to the exact recipient using saved settings. The NAS adds its product and hostname/domain to the subject and can disclose its SMTP handshake identity. This is external transmission, not a dry run.',
        'Configured SMTP TLS is not a verified server identity guarantee. Independently accept the destination and credential risk; TrueNavo API certificate pinning is separate.',
        'This test disables server retry queuing, but does not remove older queued emails or stop other notification activity.',
        'Accepted jobs and server-side success do not prove recipient delivery. Uncertain results must not be retried automatically.',
      ],
    );
  }

  @override
  Future<EmailSettingsResult> executeEmailSettings(
    EmailSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    review.request.password.dispose();
    return const EmailSettingsResult(
      EmailSettingsOutcome.rejected,
      'Sample preview: no SMTP connection, configuration change, email or job was created.',
    );
  }

  @override
  Future<EmailSettingsResult> checkEmailSettingsJob(
    int jobId, {
    required bool Function() isCurrent,
  }) async => const EmailSettingsResult(
    EmailSettingsOutcome.rejected,
    'Sample preview has no mail job or transport to check.',
  );
}
