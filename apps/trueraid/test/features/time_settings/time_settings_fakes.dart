import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/time_settings/time_settings_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const timeEndpoint = 'wss://sample.example/api/current';
const timeHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const timeCaps = TimeSettingsCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canChangeTimezone: true,
  canCreateNtp: true,
  canUpdateNtp: true,
  canDeleteNtp: true,
);
const timeServers = [
  NtpServerSnapshot(
    id: 1,
    settings: NtpServerSettings(address: 'clock-one.example', prefer: true),
  ),
  NtpServerSnapshot(
    id: 2,
    settings: NtpServerSettings(address: 'clock-two.example'),
  ),
];
TimeSettingsInventory timeInventory({
  String endpoint = timeEndpoint,
  String hostId = timeHost,
  bool admin = true,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  String state = 'READY',
  bool nextChanged = false,
  bool rollbackKnown = true,
  int? rollback,
  List<NtpServerSnapshot> servers = timeServers,
}) => TimeSettingsInventory(
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
  timezone: 'UTC',
  timezones: const ['UTC', 'Asia/Seoul', 'Europe/London'],
  servers: servers,
  guiRollbackKnown: rollbackKnown,
  guiRollbackSeconds: rollback,
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
TimeSettingsRequest timeRequest(
  TimeSettingsInventory inventory,
  TimeSettingsAction action, {
  bool burst = false,
  NtpServerSettings? settings,
}) => TimeSettingsRequest(
  inventory: inventory,
  action: action,
  timezone: action == TimeSettingsAction.timezone ? 'Asia/Seoul' : null,
  server:
      action == TimeSettingsAction.updateNtp ||
          action == TimeSettingsAction.deleteNtp
      ? inventory.servers.first
      : null,
  settings:
      action == TimeSettingsAction.createNtp ||
          action == TimeSettingsAction.updateNtp
      ? settings ??
            NtpServerSettings(
              address: action == TimeSettingsAction.createNtp
                  ? 'clock-new.example'
                  : inventory.servers.first.settings.address,
              burst: burst,
              prefer: action == TimeSettingsAction.createNtp,
            )
      : null,
);

class TimeFake implements SessionRepository, AuthenticatedTimeSettingsSession {
  TimeFake({TimeSettingsInventory? inventory, this.caps = timeCaps})
    : inventory = inventory ?? timeInventory();
  TimeSettingsInventory inventory;
  TimeSettingsCapabilities caps;
  int reads = 0, mutations = 0;
  final reviews = <TimeSettingsRequest>[], executes = <TimeSettingsReview>[];
  Future<TimeSettingsInventory> Function()? onLoad;
  Future<TimeSettingsReview> Function(TimeSettingsRequest)? onReview;
  Future<TimeSettingsResult> Function(TimeSettingsReview, bool Function())?
  onExecute;
  @override
  TimeSettingsCapabilities get timeSettingsCapabilities => caps;
  @override
  Future<TimeSettingsInventory> loadTimeSettings() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<TimeSettingsReview> reviewTimeSettings(
    TimeSettingsRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        TimeSettingsReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const [
            'Synthetic review only. Configured values do not establish synchronization.',
          ],
        );
  }

  @override
  Future<TimeSettingsResult> executeTimeSettings(
    TimeSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    executes.add(review);
    if (onExecute != null) return onExecute!(review, isCurrent);
    if (isCurrent()) mutations++;
    return const TimeSettingsResult(
      TimeSettingsOutcome.completed,
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
  }) => throw UnsupportedError('No connector in time fixtures.');
}

class TimeHarness {
  TimeHarness({TimeFake? fake}) : api = fake ?? TimeFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final TimeFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = timeEndpoint}) =>
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

  Future<void> load() => container.read(timeSettingsInventoryProvider.future);
  void dispose() => container.dispose();
}
