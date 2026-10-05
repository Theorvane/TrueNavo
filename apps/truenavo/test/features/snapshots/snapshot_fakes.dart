import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/snapshots/snapshots_controller.dart';
import 'package:truenas_api/truenas_api.dart';

AuthenticatedSession snapshotSession(SnapshotFake api) => AuthenticatedSession(
  profileId: 'nas',
  repository: api,
  availableMethodNames: const {},
  version: '25.10.1',
  endpoint: 'wss://nas.example/api/current',
);

class SnapshotHarness {
  SnapshotHarness({SnapshotFake? repository})
    : api = repository ?? SnapshotFake() {
    session = snapshotSession(api);
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final SnapshotFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  SnapshotsController get controller =>
      container.read(snapshotsControllerProvider.notifier);
  SnapshotsState get state => container.read(snapshotsControllerProvider);
  ServerOperationLock get lock => container.read(serverOperationLockProvider);
  Future<void> create() => controller.create(
    expectedSession: session,
    request: SnapshotCreateRequest(dataset: api.dataset, name: 'new-snapshot'),
  );
  Future<void> delete({String? confirmation}) => controller.delete(
    expectedSession: session,
    request: SnapshotDeleteRequest(
      snapshot: api.entry,
      confirmation: confirmation ?? api.entry.id,
    ),
  );
  void select(AuthenticatedSession? value) {
    active = value;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  void dispose() => container.dispose();
}

class SnapshotFake implements SessionRepository, AuthenticatedSnapshotsSession {
  var dataset = const SnapshotDataset(
    id: 'tank/data',
    guid: '18446744073709551610',
    creationSeconds: 1700000000,
  );
  SnapshotEntry entry = SnapshotEntry(
    id: 'tank/data@manual-1',
    dataset: 'tank/data',
    name: 'manual-1',
    guid: '18446744073709551615',
    creationSeconds: 1720000000,
    creationTxg: '43210',
    usedBytes: 1024,
    referencedBytes: 536870912,
    holds: {},
    userReferences: 0,
    clones: [],
    deferredDestroy: false,
  );
  var writable = true;
  var datasetReads = 0;
  final queries = <SnapshotQuery>[];
  final creates = <SnapshotCreateRequest>[];
  final deletes = <SnapshotDeleteRequest>[];
  final recoveryPlans = <SnapshotRecoveryPlan>[];
  final recoveries = <SnapshotRecoveryRequest>[];
  SnapshotRecoveryReview? recoveryReview;
  SnapshotOperationOutcome outcome = SnapshotOperationOutcome.verified;
  Future<SnapshotOperationResult> Function()? onWrite;
  Future<void> Function()? beforeRead;
  @override
  SnapshotsCapabilities get snapshotsCapabilities => SnapshotsCapabilities(
    connected: true,
    versionSupported: true,
    canRead: true,
    canCreate: writable,
    canDelete: writable,
    canClone: writable,
    canRollback: writable,
    canHold: writable,
    canRelease: writable,
  );
  @override
  Future<List<SnapshotDataset>> loadSnapshotDatasets() async {
    datasetReads++;
    return [dataset];
  }

  @override
  Future<SnapshotPageResult> loadSnapshots(SnapshotQuery query) async {
    queries.add(query);
    await beforeRead?.call();
    return SnapshotPageResult(
      entries: entry.name.startsWith(query.namePrefix) ? [entry] : [],
      hasMore: false,
    );
  }

  @override
  Future<SnapshotOperationResult> createSnapshot(
    SnapshotCreateRequest request,
  ) async {
    creates.add(request);
    return onWrite?.call() ??
        SnapshotOperationResult(
          outcome: outcome,
          message: 'Fixture create result',
        );
  }

  @override
  Future<SnapshotOperationResult> deleteSnapshot(
    SnapshotDeleteRequest request,
  ) async {
    deletes.add(request);
    return onWrite?.call() ??
        SnapshotOperationResult(
          outcome: outcome,
          message: 'Fixture delete result',
        );
  }

  @override
  Future<SnapshotRecoveryReview> reviewSnapshotRecovery(
    SnapshotRecoveryPlan plan,
  ) async {
    recoveryPlans.add(plan);
    await beforeRead?.call();
    return recoveryReview ??
        SnapshotRecoveryReview(
          plan: plan,
          snapshots: plan.snapshots,
          datasets: [dataset],
          newerSnapshots: [],
          warnings: ['Synthetic impact only. No real server exists.'],
        );
  }

  @override
  Future<SnapshotOperationResult> applySnapshotRecovery(
    SnapshotRecoveryRequest request,
  ) async {
    recoveries.add(request);
    return onWrite?.call() ??
        SnapshotOperationResult(
          outcome: outcome,
          message: 'Fixture recovery result',
        );
  }

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnimplementedError();
  @override
  Future<void> close() async {}
}
