import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const scheduleMethods = {
  'pool.snapshottask.query',
  'pool.dataset.query',
  'pool.filesystem_choices',
  'pool.snapshot.query',
  'replication.query',
  'vmware.query',
  'system.general.config',
  'pool.snapshottask.create',
  'pool.snapshottask.update',
  'pool.snapshottask.delete',
  'pool.snapshottask.run',
  'pool.snapshottask.update_will_change_retention_for',
  'pool.snapshottask.delete_will_change_retention_for',
};
SnapshotScheduleInventory scheduleInventory({
  bool enabled = true,
  String? blockedReason,
  String minute = '0',
}) => SnapshotScheduleInventory(
  timezone: 'Asia/Seoul',
  datasets: const [
    SnapshotScheduleDataset(id: 'tank/media', guid: '100', kind: 'FILESYSTEM'),
    SnapshotScheduleDataset(
      id: 'tank/media/cache',
      guid: '101',
      kind: 'FILESYSTEM',
    ),
    SnapshotScheduleDataset(id: 'tank/backup', guid: '102', kind: 'FILESYSTEM'),
  ],
  tasks: [
    SnapshotScheduleTask(
      id: 4,
      state: 'ERROR',
      blockedReason: blockedReason,
      settings: SnapshotScheduleSettings(
        dataset: 'tank/media',
        enabled: enabled,
        cron: SnapshotScheduleCron(minute: minute, hour: '2'),
      ),
    ),
  ],
);

class SchedulesFake
    implements SessionRepository, AuthenticatedSnapshotSchedulesSession {
  SchedulesFake({
    this.methods = scheduleMethods,
    SnapshotScheduleInventory? inventory,
  }) : inventory = inventory ?? scheduleInventory();
  final Set<String> methods;
  final SnapshotScheduleInventory inventory;
  int reads = 0;
  final reviews = <SnapshotScheduleRequest>[];
  final writes = <SnapshotScheduleReview>[];
  Future<SnapshotScheduleInventory> Function()? onLoad;
  Future<SnapshotScheduleReview> Function(SnapshotScheduleRequest)? onReview;
  Future<SnapshotScheduleResult> Function()? onExecute;
  @override
  SnapshotSchedulesCapabilities get snapshotSchedulesCapabilities =>
      SnapshotSchedulesCapabilities(
        connected: true,
        versionSupported: true,
        methods: methods,
      );
  @override
  Future<SnapshotScheduleInventory> loadSnapshotSchedules() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<SnapshotScheduleReview> reviewSnapshotSchedule(
    SnapshotScheduleRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        SnapshotScheduleReview(
          action: request.action,
          target: request.target,
          identity: 'issued-fixture',
          changes: [
            'Exact reviewed ${request.action.name} for ${request.target}',
          ],
          warnings: ['Retention changes can affect future expiry.'],
          affectedSnapshots: ['tank/media@auto-2026-09-12_02-00'],
        );
  }

  @override
  Future<SnapshotScheduleResult> executeSnapshotSchedule(
    SnapshotScheduleReview review,
    String confirmation,
  ) async {
    writes.add(review);
    return onExecute?.call() ??
        SnapshotScheduleResult(
          review.action == SnapshotScheduleAction.run
              ? SnapshotScheduleOutcome.accepted
              : SnapshotScheduleOutcome.verified,
          review.action == SnapshotScheduleAction.run
              ? 'The run was queued.'
              : 'The schedule was verified.',
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
  }) => throw UnsupportedError('No transport in fixtures.');
}

class SchedulesHarness {
  SchedulesHarness({SchedulesFake? fake}) : api = fake ?? SchedulesFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final SchedulesFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({
    String? endpoint = 'wss://sample.example/api/current',
    SchedulesFake? fake,
  }) => AuthenticatedSession(
    profileId: 'sample',
    repository: fake ?? api,
    availableMethodNames: (fake ?? api).methods,
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

SnapshotScheduleReview scheduleReview({
  SnapshotScheduleAction action = SnapshotScheduleAction.update,
}) => SnapshotScheduleReview(
  action: action,
  target: 'Task 4: tank/media',
  identity: 'issued-fixture',
  changes: ['Retention 2 WEEK → 1 WEEK'],
  warnings: [],
  affectedSnapshots: [],
);
