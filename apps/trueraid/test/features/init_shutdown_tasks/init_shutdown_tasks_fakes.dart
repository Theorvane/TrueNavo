import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/init_shutdown_tasks/init_shutdown_tasks_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import '../alert_settings/alert_settings_fakes.dart' show alertInventory;

const initEndpoint = 'wss://sample.example/api/current';
const initHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const initBody = 'printf %s SYNTHETIC_PRIVATE_COMMAND_BODY';
const initCaps = InitShutdownTasksCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canCreate: true,
  canUpdate: true,
  canDelete: true,
);
const initTasks = [
  InitShutdownTaskSnapshot(
    id: 1,
    type: 'COMMAND',
    phase: InitShutdownTaskPhase.postinit,
    enabled: false,
    timeoutSeconds: 10,
  ),
  InitShutdownTaskSnapshot(
    id: 2,
    type: 'COMMAND',
    phase: InitShutdownTaskPhase.shutdown,
    enabled: true,
    timeoutSeconds: 20,
  ),
  InitShutdownTaskSnapshot(
    id: 3,
    type: 'SCRIPT',
    phase: InitShutdownTaskPhase.preinit,
    enabled: false,
    timeoutSeconds: 30,
  ),
];
InitShutdownTasksInventory initInventory({
  String endpoint = initEndpoint,
  String hostId = initHost,
  bool admin = true,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  String state = 'READY',
  bool nextChanged = false,
  List<InitShutdownTaskSnapshot> tasks = initTasks,
}) => InitShutdownTasksInventory(
  readiness: alertInventory(
    endpoint: endpoint,
    hostId: hostId,
    admin: admin,
    ha: ha,
    jobs: jobs,
    healthy: healthy,
    state: state,
    nextChanged: nextChanged,
    services: const [],
  ),
  tasks: tasks,
);
InitShutdownTasksRequest initRequest(
  InitShutdownTasksInventory i,
  InitShutdownTasksAction action, {
  InitShutdownTaskCommand? command,
  InitShutdownTaskPhase phase = InitShutdownTaskPhase.postinit,
  int timeout = 20,
  InitShutdownTaskSnapshot? task,
}) => InitShutdownTasksRequest(
  inventory: i,
  action: action,
  task: action == InitShutdownTasksAction.create
      ? null
      : task ??
            i.tasks.firstWhere(
              (t) =>
                  t.isCommand &&
                  t.enabled == (action == InitShutdownTasksAction.disable),
            ),
  settings:
      action == InitShutdownTasksAction.create ||
          action == InitShutdownTasksAction.replace
      ? InitShutdownTaskSettings(phase: phase, timeoutSeconds: timeout)
      : null,
  command:
      action == InitShutdownTasksAction.create ||
          action == InitShutdownTasksAction.replace
      ? command ?? InitShutdownTaskCommand(initBody)
      : null,
);

class InitFake
    implements SessionRepository, AuthenticatedInitShutdownTasksSession {
  InitFake({InitShutdownTasksInventory? inventory, this.caps = initCaps})
    : inventory = inventory ?? initInventory();
  InitShutdownTasksInventory inventory;
  InitShutdownTasksCapabilities caps;
  int reads = 0, mutations = 0;
  final reviews = <InitShutdownTasksRequest>[],
      executes = <InitShutdownTasksReview>[];
  Future<InitShutdownTasksInventory> Function()? onLoad;
  Future<InitShutdownTasksReview> Function(InitShutdownTasksRequest)? onReview;
  Future<InitShutdownTasksResult> Function(
    InitShutdownTasksReview,
    bool Function(),
  )?
  onExecute;
  @override
  InitShutdownTasksCapabilities get initShutdownTasksCapabilities => caps;
  @override
  Future<InitShutdownTasksInventory> loadInitShutdownTasks() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<InitShutdownTasksReview> reviewInitShutdownTasks(
    InitShutdownTasksRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        InitShutdownTasksReview(
          request: request,
          endpoint: inventory.endpoint,
          commandReference: 'f' * 64,
          warnings: const [
            'Synthetic supplemental details. No live server or command execution.',
          ],
        );
  }

  @override
  Future<InitShutdownTasksResult> executeInitShutdownTasks(
    InitShutdownTasksReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    executes.add(review);
    if (onExecute != null) return onExecute!(review, isCurrent);
    if (isCurrent()) mutations++;
    return const InitShutdownTasksResult(
      InitShutdownTasksOutcome.completed,
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
  }) => throw UnsupportedError('No connector in NFS fixtures.');
}

class InitHarness {
  InitHarness({InitFake? fake}) : api = fake ?? InitFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final InitFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = initEndpoint}) =>
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
      container.read(initShutdownTasksInventoryProvider.future);
  void dispose() => container.dispose();
}
