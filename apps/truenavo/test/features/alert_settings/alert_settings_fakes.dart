import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/alert_settings/alert_settings_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const alertEndpoint = 'wss://sample.example/api/current';
const alertHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const alertCaps = AlertSettingsCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canCreate: true,
  canUpdate: true,
  canDelete: true,
);
const alertServices = [
  AlertServiceSnapshot(
    id: 1,
    name: 'Storage warnings',
    type: 'Mail',
    level: AlertDeliveryLevel.warning,
    enabled: false,
    recipient: 'storage@example.test',
    emailAttributesSupported: true,
  ),
  AlertServiceSnapshot(
    id: 2,
    name: 'Operations critical',
    type: 'Mail',
    level: AlertDeliveryLevel.critical,
    enabled: true,
    recipient: 'ops@example.test',
    emailAttributesSupported: true,
  ),
  AlertServiceSnapshot(
    id: 3,
    name: 'Protected chat',
    type: 'Slack',
    level: AlertDeliveryLevel.error,
    enabled: true,
  ),
];
AlertSettingsInventory alertInventory({
  String endpoint = alertEndpoint,
  String hostId = alertHost,
  bool admin = true,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  String state = 'READY',
  bool nextChanged = false,
  List<AlertServiceSnapshot> services = alertServices,
}) => AlertSettingsInventory(
  endpoint: endpoint,
  hostId: hostId,
  bootId: '12345678-1234-4234-8234-123456789abc',
  currentVersion: '25.10.1',
  state: state,
  fullAdmin: admin,
  failoverLicensed: ha,
  conflictingJob: jobs,
  bootPool: 'boot-pool',
  bootHealthy: healthy,
  services: services,
  environments: [
    BootEnvironmentSnapshot(
      id: '25.10.1',
      dataset: 'boot-pool/ROOT/25.10.1',
      created: '2026-09-01T10:00:00',
      usedBytes: 512,
      active: true,
      activated: !nextChanged,
      keep: true,
      canActivate: true,
    ),
    if (nextChanged)
      const BootEnvironmentSnapshot(
        id: '25.10.2',
        dataset: 'boot-pool/ROOT/25.10.2',
        created: '2026-09-10T10:00:00',
        usedBytes: 512,
        active: false,
        activated: true,
        keep: true,
        canActivate: true,
      ),
  ],
);
AlertSettingsRequest alertRequest(
  AlertSettingsInventory inventory,
  AlertSettingsAction action, {
  EmailAlertServiceSettings? settings,
  AlertServiceSnapshot? service,
}) => AlertSettingsRequest(
  inventory: inventory,
  action: action,
  service: action == AlertSettingsAction.createEmail
      ? null
      : service ??
            inventory.services.firstWhere(
              (s) =>
                  s.isEmail &&
                  s.enabled == (action == AlertSettingsAction.disableEmail),
            ),
  settings:
      action == AlertSettingsAction.createEmail ||
          action == AlertSettingsAction.editEmail
      ? settings ??
            const EmailAlertServiceSettings(
              name: 'Reviewed alerts',
              recipient: 'reviewed@example.test',
            )
      : null,
);

class AlertFake
    implements SessionRepository, AuthenticatedAlertSettingsSession {
  AlertFake({AlertSettingsInventory? inventory, this.caps = alertCaps})
    : inventory = inventory ?? alertInventory();
  AlertSettingsInventory inventory;
  AlertSettingsCapabilities caps;
  int reads = 0, mutations = 0;
  final reviews = <AlertSettingsRequest>[], executes = <AlertSettingsReview>[];
  Future<AlertSettingsInventory> Function()? onLoad;
  Future<AlertSettingsReview> Function(AlertSettingsRequest)? onReview;
  Future<AlertSettingsResult> Function(AlertSettingsReview, bool Function())?
  onExecute;
  @override
  AlertSettingsCapabilities get alertSettingsCapabilities => caps;
  @override
  Future<AlertSettingsInventory> loadAlertSettings() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<AlertSettingsReview> reviewAlertSettings(
    AlertSettingsRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        AlertSettingsReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const [
            'Synthetic supplemental details. No live provider or SMTP contact.',
          ],
        );
  }

  @override
  Future<AlertSettingsResult> executeAlertSettings(
    AlertSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    executes.add(review);
    if (onExecute != null) return onExecute!(review, isCurrent);
    if (isCurrent()) mutations++;
    return const AlertSettingsResult(
      AlertSettingsOutcome.completed,
      'Synthetic configuration verification',
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
  }) => throw UnsupportedError('No connector in alert fixtures.');
}

class AlertHarness {
  AlertHarness({AlertFake? fake}) : api = fake ?? AlertFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final AlertFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = alertEndpoint}) =>
      AuthenticatedSession(
        profileId: 'sample',
        repository: api,
        availableMethodNames: const {},
        version: '25.10.1',
        endpoint: endpoint,
      );
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  Future<void> load() => container.read(alertSettingsInventoryProvider.future);
  void dispose() => container.dispose();
}
