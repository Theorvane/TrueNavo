// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Static connector-free sample, no NAS access or live alert writes.
mixin AlertsPreviewAdapter implements AuthenticatedAlertsSession {
  static final inventory = AlertInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    failoverLicensed: false,
    alerts: [
      AlertSnapshot(
        id: '11111111-1111-4111-8111-111111111111',
        klass: 'VolumeStatus',
        source: 'VolumeStatus',
        node: 'Controller A',
        level: 'CRITICAL',
        firstSeen: DateTime.utc(2026, 9, 14, 1),
        lastSeen: DateTime.utc(2026, 9, 14, 3),
        dismissed: false,
        oneShot: false,
      ),
      AlertSnapshot(
        id: '22222222-2222-4222-8222-222222222222',
        klass: 'ZpoolCapacityWarning',
        source: 'ZpoolCapacity',
        node: 'Controller A',
        level: 'WARNING',
        firstSeen: DateTime.utc(2026, 9, 13),
        lastSeen: DateTime.utc(2026, 9, 14, 3),
        dismissed: false,
        oneShot: false,
        metrics: const {'Reported pool capacity (%)': 92},
      ),
      AlertSnapshot(
        id: '33333333-3333-4333-8333-333333333333',
        klass: 'CertificateIsExpiringSoon',
        source: 'CertificateChecks',
        node: 'Controller A',
        level: 'WARNING',
        firstSeen: DateTime.utc(2026, 9, 13),
        lastSeen: DateTime.utc(2026, 9, 14),
        dismissed: true,
        oneShot: false,
        metrics: const {'Reported days until expiry': 2},
      ),
      AlertSnapshot(
        id: '44444444-4444-4444-8444-444444444444',
        klass: 'WebUiCertificateSetupFailed',
        source: '',
        node: 'Controller A',
        level: 'CRITICAL',
        firstSeen: DateTime.utc(2026, 9, 13),
        lastSeen: DateTime.utc(2026, 9, 13),
        dismissed: false,
        oneShot: true,
      ),
    ],
  );
  @override
  AlertsCapabilities get alertsCapabilities => const AlertsCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
    canDismiss: true,
    canRestore: true,
  );
  @override
  Future<AlertInventory> loadAlerts() async => inventory;
  @override
  Future<AlertReview> reviewAlert(AlertRequest request) async {
    if (!identical(request.inventory, inventory) ||
        request.validationError != null) {
      throw const AlertsException(AlertsExceptionReason.invalidRequest);
    }
    return AlertReview(
      request: request,
      endpoint: inventory.endpoint,
      warnings: [
        'SAMPLE DATA — this preview never contacts a NAS and rejects all writes.',
        'Dismissal changes visibility only; it does not resolve the condition. Restore does not guarantee a notification.',
        'Exact UUID and current state require preflight and post-read verification. One-shot and HA changes are unsupported.',
      ],
    );
  }

  @override
  Future<AlertResult> executeAlert(
    AlertReview review,
    String confirmation,
  ) async => const AlertResult(
    AlertOutcome.rejected,
    'Preview only. No alert change was submitted.',
  );
}
