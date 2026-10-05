import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const replicationEndpoint = 'wss://sample.example/api/current';
const replicationCaps = ReplicationCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canCreate: true,
  canUpdate: true,
  canDelete: true,
  canRun: true,
);
const replicationSettings = ReplicationSettings(
  name: 'Archive',
  source: 'tank/source',
  destination: 'backup/archive',
);
const replicationTask = ReplicationTask(
  id: 1,
  name: 'Archive',
  source: 'tank/source',
  destination: 'backup/archive',
  transport: 'LOCAL',
  direction: 'PUSH',
  enabled: true,
  state: 'FINISHED',
  settings: replicationSettings,
);
const replicationAdvancedTask = ReplicationTask(
  id: 2,
  name: 'Offsite archive',
  source: 'tank/source',
  destination: 'remote/archive',
  transport: 'SSH',
  direction: 'PUSH',
  enabled: false,
  state: 'HOLD',
  blockedReason: 'Remote tasks require the advanced TrueNAS workflow.',
);
ReplicationInventory replicationInventory({
  bool conflictingJob = false,
  bool empty = false,
}) => ReplicationInventory(
  endpoint: replicationEndpoint,
  conflictingJob: conflictingJob,
  tasks: empty ? const [] : const [replicationTask, replicationAdvancedTask],
  datasets: const [
    ReplicationDataset(id: 'tank/source', guid: '101', readonly: false),
    ReplicationDataset(id: 'backup/parent', guid: '102', readonly: false),
    ReplicationDataset(id: 'backup/archive', guid: '103', readonly: true),
  ],
);
ReplicationReview replicationReview({
  ReplicationInventory? inventory,
  ReplicationAction action = ReplicationAction.run,
  String endpoint = replicationEndpoint,
}) {
  final data = inventory ?? replicationInventory();
  return ReplicationReview(
    request: ReplicationRequest(
      inventory: data,
      action: action,
      task: action == ReplicationAction.create ? null : data.tasks.first,
      settings:
          action == ReplicationAction.create ||
              action == ReplicationAction.update
          ? replicationSettings.copyWith(name: 'New archive')
          : null,
    ),
    endpoint: endpoint,
    warnings: const ['Reviewed destination warning.'],
    sourceSnapshots: 4,
    destinationSnapshots: 2,
    createsDestination: false,
  );
}

const replicationJob = ReplicationJob(
  id: 42,
  taskId: 1,
  taskName: 'Archive',
  endpoint: replicationEndpoint,
);

class ReplicationFake
    implements SessionRepository, AuthenticatedReplicationSession {
  ReplicationFake({
    ReplicationInventory? inventory,
    this.caps = replicationCaps,
  }) : inventory = inventory ?? replicationInventory();
  final ReplicationInventory inventory;
  final ReplicationCapabilities caps;
  int reads = 0;
  final reviews = <ReplicationRequest>[];
  final writes = <ReplicationReview>[];
  final polls = <ReplicationJob>[];
  Future<ReplicationInventory> Function()? onLoad;
  Future<ReplicationReview> Function(ReplicationRequest)? onReview;
  Future<ReplicationResult> Function()? onExecute, onPoll;
  @override
  ReplicationCapabilities get replicationCapabilities => caps;
  @override
  Future<ReplicationInventory> loadReplication() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<ReplicationReview> reviewReplication(
    ReplicationRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        ReplicationReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const ['Reviewed destination warning.'],
          sourceSnapshots: 4,
          destinationSnapshots: 2,
          createsDestination: false,
        );
  }

  @override
  Future<ReplicationResult> executeReplication(
    ReplicationReview review,
    String confirmation,
  ) async {
    writes.add(review);
    return onExecute?.call() ??
        const ReplicationResult(
          ReplicationOutcome.succeeded,
          'Task operation verified.',
        );
  }

  @override
  Future<ReplicationResult> pollReplication(ReplicationJob job) async {
    polls.add(job);
    return onPoll?.call() ??
        ReplicationResult(
          ReplicationOutcome.pending,
          'Still running',
          job: job,
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
  }) => throw UnsupportedError('No connector in fixtures.');
}

class ReplicationHarness {
  ReplicationHarness({ReplicationFake? fake})
    : api = fake ?? ReplicationFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final ReplicationFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = replicationEndpoint}) =>
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

  void dispose() => container.dispose();
}
