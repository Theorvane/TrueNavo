import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/cron_tasks/cron_tasks_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import '../alert_settings/alert_settings_fakes.dart'
    show alertInventory, alertEndpoint;

const cronCaps = CronTasksCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canCreate: true,
  canUpdate: true,
  canDelete: true,
  canRun: true,
);
const cronDefault = CronTaskSettings(
  user: 'root',
  description: 'Maintenance',
  schedule: CronTaskSchedule(),
  hideStdout: true,
  hideStderr: true,
);
CronTasksInventory cronInventory({
  String? hostId,
  String endpoint = alertEndpoint,
  bool admin = true,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  bool? directory = false,
  List<CronTaskSnapshot>? tasks,
  List<CronTaskUser>? users,
}) => CronTasksInventory(
  readiness: alertInventory(
    endpoint: endpoint,
    hostId:
        hostId ??
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    admin: admin,
    ha: ha,
    jobs: jobs,
    healthy: healthy,
    services: const [],
  ),
  tasks:
      tasks ??
      const [
        CronTaskSnapshot(id: 1, enabled: false, settings: cronDefault),
        CronTaskSnapshot(id: 2, enabled: true, settings: cronDefault),
      ],
  users:
      users ??
      const [
        CronTaskUser(id: 1, uid: 0, username: 'root'),
        CronTaskUser(id: 2, uid: 1000, username: 'worker'),
      ],
  timezone: 'Etc/UTC',
  directoryConfigured: directory,
);
CronTasksRequest cronRequest(
  CronTasksInventory i, {
  CronTasksAction action = CronTasksAction.edit,
  bool replace = false,
}) => CronTasksRequest(
  inventory: i,
  action: action,
  task: action == CronTasksAction.create
      ? null
      : i.tasks.firstWhere(
          (t) =>
              t.enabled ==
              (action == CronTasksAction.disable ||
                  action == CronTasksAction.run),
        ),
  settings: action == CronTasksAction.create || action == CronTasksAction.edit
      ? const CronTaskSettings(
          user: 'root',
          description: 'Changed maintenance',
          schedule: CronTaskSchedule(),
          hideStdout: true,
          hideStderr: true,
        )
      : null,
  command: action == CronTasksAction.create || replace
      ? CronTaskCommand.fromText('printf SYNTHETIC_PRIVATE_COMMAND')
      : null,
);

class CronFake implements SessionRepository, AuthenticatedCronTasksSession {
  CronFake({CronTasksInventory? inventory, this.caps = cronCaps})
    : inventory = inventory ?? cronInventory();
  CronTasksInventory inventory;
  CronTasksCapabilities caps;
  int reads = 0, mutations = 0;
  final reviews = <CronTasksRequest>[], executes = <CronTasksReview>[];
  Future<CronTasksInventory> Function()? onLoad;
  Future<CronTasksReview> Function(CronTasksRequest)? onReview;
  Future<CronTasksResult> Function(CronTasksReview, bool Function())? onExecute;
  @override
  CronTasksCapabilities get cronTasksCapabilities => caps;
  @override
  Future<CronTasksInventory> loadCronTasks() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<CronTasksReview> reviewCronTasks(CronTasksRequest r) async {
    reviews.add(r);
    return onReview?.call(r) ??
        CronTasksReview(
          request: r,
          endpoint: inventory.endpoint,
          warnings: const [
            'Synthetic global scheduler-regeneration warning. No live command run.',
          ],
        );
  }

  @override
  Future<CronTasksResult> executeCronTasks(
    CronTasksReview r,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    executes.add(r);
    if (onExecute != null) return onExecute!(r, isCurrent);
    if (isCurrent()) mutations++;
    return const CronTasksResult(
      CronTasksOutcome.completed,
      'Synthetic configuration verification',
    );
  }

  @override
  Future<void> close() async {
    for (final r in reviews) {
      r.command?.dispose();
    }
  }

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnsupportedError('Synthetic cron only');
}

class CronHarness {
  CronHarness({CronFake? fake}) : api = fake ?? CronFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final CronFake api;
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

  Future<void> load() => container.read(cronTasksInventoryProvider.future);
  void dispose() {
    container.dispose();
    for (final r in api.reviews) {
      r.command?.dispose();
    }
  }
}
