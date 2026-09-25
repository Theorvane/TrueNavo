import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/notification_providers/notification_providers_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const providersSecret = 'SYNTHETIC_PRIVATE_PROVIDER_SECRET';
Map<String, Object?> providerFields(NotificationProviderType p) => switch (p) {
  NotificationProviderType.slack || NotificationProviderType.opsGenie => {},
  NotificationProviderType.mattermost => {
    'username': 'TrueRAID',
    'channel': 'operations',
  },
  NotificationProviderType.telegram => {
    'chat_ids': [-1001234567890, 123456],
  },
  NotificationProviderType.pagerDuty => {'client_name': 'TrueRAID'},
  NotificationProviderType.victorOps => {},
  NotificationProviderType.awsSns => {
    'region': 'us-east-1',
    'topic_arn': 'arn:aws:sns:us-east-1:123456789012:operations',
  },
  NotificationProviderType.influxDb => {
    'host': 'metrics.example.test',
    'username': 'alerts',
    'database': 'alerts',
    'series_name': 'truenas',
  },
  NotificationProviderType.snmpTrap => {
    'host': 'traps.example.test',
    'port': 162,
  },
};
Map<String, String> providerSecrets(
  NotificationProviderType p, {
  String suffix = '',
}) => switch (p) {
  NotificationProviderType.slack => {
    'url': 'https://hooks.example.test/private/$providersSecret$suffix',
  },
  NotificationProviderType.mattermost => {
    'url': 'https://chat.example.test/private/$providersSecret$suffix',
    'icon_url': '',
  },
  NotificationProviderType.telegram => {
    'bot_token': '123456:SYNTHETIC_TOKEN$suffix',
  },
  NotificationProviderType.pagerDuty => {
    'service_key': '$providersSecret$suffix',
  },
  NotificationProviderType.opsGenie => {
    'api_key': '$providersSecret$suffix',
    'api_url': '',
  },
  NotificationProviderType.victorOps => {
    'api_key': '$providersSecret$suffix',
    'routing_key': 'operations',
  },
  NotificationProviderType.awsSns => {
    'aws_access_key_id': 'SYNTHETIC_ACCESS_ID',
    'aws_secret_access_key': '$providersSecret$suffix',
  },
  NotificationProviderType.influxDb => {'password': '$providersSecret$suffix'},
  NotificationProviderType.snmpTrap => {'community': '$providersSecret$suffix'},
};

const providersEndpoint = 'wss://sample.example/api/current';
const providersHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const providersCaps = NotificationProvidersCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canCreate: true,
  canUpdate: true,
  canDelete: true,
);
const providersServices = [
  NotificationProviderSnapshot(
    id: 1,
    name: 'Provider one',
    type: 'Slack',
    level: AlertDeliveryLevel.warning,
    enabled: false,
  ),
  NotificationProviderSnapshot(
    id: 2,
    name: 'Provider two',
    type: 'Slack',
    level: AlertDeliveryLevel.critical,
    enabled: true,
  ),
  NotificationProviderSnapshot(
    id: 3,
    name: 'Separate email',
    type: 'Mail',
    level: AlertDeliveryLevel.error,
    enabled: true,
  ),
];
NotificationProvidersInventory providersInventory({
  String endpoint = providersEndpoint,
  String hostId = providersHost,
  bool admin = true,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  String state = 'READY',
  bool nextChanged = false,
  List<NotificationProviderSnapshot> services = providersServices,
}) => NotificationProvidersInventory(
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
NotificationProvidersRequest providersRequest(
  NotificationProvidersInventory inventory,
  NotificationProvidersAction action, {
  NotificationProviderSettings? settings,
  NotificationProviderSnapshot? service,
  NotificationProviderType? provider,
}) {
  final selected = action == NotificationProvidersAction.create
      ? null
      : service ??
            inventory.services.firstWhere(
              (s) =>
                  s.provider != null &&
                  s.enabled == (action == NotificationProvidersAction.disable),
            );
  final type = provider ?? selected?.provider ?? NotificationProviderType.slack;
  final replacing =
      action == NotificationProvidersAction.create ||
      action == NotificationProvidersAction.replace;
  return NotificationProvidersRequest(
    inventory: inventory,
    action: action,
    service: selected,
    settings: replacing
        ? settings ??
              NotificationProviderSettings(
                provider: type,
                name: 'Reviewed provider',
                fields: providerFields(type),
              )
        : null,
    credentials: replacing
        ? NotificationProviderCredentials(
            provider: type,
            values: providerSecrets(type),
          )
        : null,
  );
}

class ProvidersFake
    implements SessionRepository, AuthenticatedNotificationProvidersSession {
  ProvidersFake({
    NotificationProvidersInventory? inventory,
    this.caps = providersCaps,
  }) : inventory = inventory ?? providersInventory();
  NotificationProvidersInventory inventory;
  NotificationProvidersCapabilities caps;
  int reads = 0, mutations = 0;
  final reviews = <NotificationProvidersRequest>[],
      executes = <NotificationProvidersReview>[];
  Future<NotificationProvidersInventory> Function()? onLoad;
  Future<NotificationProvidersReview> Function(NotificationProvidersRequest)?
  onReview;
  Future<NotificationProvidersResult> Function(
    NotificationProvidersReview,
    bool Function(),
  )?
  onExecute;
  @override
  NotificationProvidersCapabilities get notificationProvidersCapabilities =>
      caps;
  @override
  Future<NotificationProvidersInventory> loadNotificationProviders() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<NotificationProvidersReview> reviewNotificationProviders(
    NotificationProvidersRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        NotificationProvidersReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const [
            'Synthetic supplemental details. No actual provider contact.',
          ],
          destinationSummary: 'Verified fixture destination on provider.example.test; opaque synthetic reference only',
          publicFields: const {'Scope': 'Synthetic configuration only'},
          unencrypted: request.provider!.unencrypted,
        );
  }

  @override
  Future<NotificationProvidersResult> executeNotificationProviders(
    NotificationProvidersReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    executes.add(review);
    if (onExecute != null) return onExecute!(review, isCurrent);
    if (isCurrent()) mutations++;
    return const NotificationProvidersResult(
      NotificationProvidersOutcome.completed,
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

class ProvidersHarness {
  ProvidersHarness({ProvidersFake? fake}) : api = fake ?? ProvidersFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final ProvidersFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = providersEndpoint}) =>
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

  Future<void> load() =>
      container.read(notificationProvidersInventoryProvider.future);
  void dispose() => container.dispose();
}
