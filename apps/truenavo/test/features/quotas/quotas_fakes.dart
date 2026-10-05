import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/quotas/quotas_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const quotaEndpoint = 'wss://quota-fixture.example/api/current';

class QuotaFake implements SessionRepository, AuthenticatedQuotasSession {
  bool available = true,
      versionSupported = true,
      canSetUser = true,
      canSetGroup = true;
  int datasetReads = 0,
      inventoryReads = 0,
      resolutions = 0,
      reviews = 0,
      executions = 0;
  String guid = '41';
  final issuedDatasets = <QuotaDataset>{};
  final loadedDatasets = <QuotaDataset>[];
  QuotaChange? lastChange;
  QuotaReview? executedReview;
  String? confirmation;
  Object? datasetError, inventoryError, resolveError, reviewError;
  Future<List<QuotaDataset>>? pendingDatasets;
  Future<QuotaInventory>? pendingInventory;
  Future<QuotaIdentity>? pendingIdentity;
  Future<QuotaResult> Function()? onExecute;
  bool wrongIdentity = false;
  List<QuotaEntry> entries = const [
    QuotaEntry(
      kind: QuotaKind.user,
      id: 1000,
      name: 'alice',
      byteLimit: 1024,
      objectLimit: 10,
      usedBytes: 512,
      usedObjects: 5,
    ),
    QuotaEntry(
      kind: QuotaKind.user,
      id: 1001,
      name: 'unknown-usage',
      byteLimit: 2048,
      objectLimit: 20,
    ),
    QuotaEntry(
      kind: QuotaKind.user,
      id: 1002,
      name: 'unlimited',
      byteLimit: 0,
      objectLimit: 0,
      usedBytes: 256,
      usedObjects: 2,
    ),
    QuotaEntry(
      kind: QuotaKind.group,
      id: 2000,
      name: 'studio',
      byteLimit: 4096,
      objectLimit: 100,
      usedBytes: 8192,
      usedObjects: 10,
    ),
  ];

  @override
  QuotaCapabilities get quotaCapabilities => QuotaCapabilities(
    connected: true,
    versionSupported: versionSupported,
    available: available,
    canSetUser: canSetUser,
    canSetGroup: canSetGroup,
  );
  @override
  Future<List<QuotaDataset>> loadQuotaDatasets() async {
    datasetReads++;
    if (datasetError != null) throw datasetError!;
    final result =
        await (pendingDatasets ??
            Future.value([
              QuotaDataset(id: 'tank/shared', guid: guid),
              const QuotaDataset(id: 'tank/other', guid: '42'),
              const QuotaDataset(
                id: 'tank/protected',
                guid: '43',
                blockedReason:
                    'Read-only filesystem roots are not editable here.',
              ),
            ]));
    issuedDatasets
      ..clear()
      ..addAll(result);
    return result;
  }

  @override
  Future<QuotaInventory> loadQuotas(QuotaDataset dataset) async {
    inventoryReads++;
    loadedDatasets.add(dataset);
    if (!issuedDatasets.contains(dataset)) {
      throw const QuotaException(QuotaExceptionReason.stale);
    }
    if (inventoryError != null) throw inventoryError!;
    return pendingInventory ??
        QuotaInventory(dataset: dataset, entries: entries);
  }

  @override
  Future<QuotaIdentity> resolveQuotaIdentity(
    QuotaInventory inventory,
    QuotaKind kind,
    int id,
  ) async {
    resolutions++;
    if (resolveError != null) throw resolveError!;
    if (id <= 0 || id >= 4294967295) {
      throw const QuotaException(QuotaExceptionReason.invalid);
    }
    return pendingIdentity ??
        QuotaIdentity(
          kind: kind,
          id: wrongIdentity ? id + 1 : id,
          name: inventory.entry(kind, id)?.name ?? 'directory-member',
          source: id == 5000 ? 'LDAP' : 'LOCAL',
          local: id != 5000,
          sid: id == 5000 ? 'S-1-5-21-5000' : null,
        );
  }

  @override
  Future<QuotaReview> reviewQuotaChange(QuotaChange change) async {
    reviews++;
    if (reviewError != null) throw reviewError!;
    if (change.validationError != null) {
      throw const QuotaException(QuotaExceptionReason.invalid);
    }
    lastChange = change;
    final old = change.inventory.entry(
      change.identity.kind,
      change.identity.id,
    );
    return QuotaReview(
      dataset: change.inventory.dataset,
      identity: change.identity,
      confirmation:
          '${change.inventory.dataset.id} ${change.identity.kind.wire} ${change.identity.id}',
      changes: [
        if (change.byteLimit != null)
          'Byte limit: ${old?.byteLimit ?? 0} → ${change.byteLimit == 0 ? 'Unlimited' : change.byteLimit}',
        if (change.objectLimit != null)
          'Object limit: ${old?.objectLimit ?? 0} → ${change.objectLimit == 0 ? 'Unlimited' : change.objectLimit}',
      ],
      warnings: [
        'Limits can deny writes and object creation.',
        if (change.byteLimit != null &&
            change.byteLimit! > 0 &&
            old?.usedBytes != null &&
            change.byteLimit! < old!.usedBytes!)
          'The byte limit is below reported usage.',
        if (change.objectLimit != null &&
            change.objectLimit! > 0 &&
            old?.usedObjects != null &&
            change.objectLimit! < old!.usedObjects!)
          'The object limit is below reported usage.',
      ],
    );
  }

  @override
  Future<QuotaResult> executeQuotaReview(
    QuotaReview review,
    String typed,
  ) async {
    executions++;
    executedReview = review;
    confirmation = typed;
    return onExecute?.call() ??
        const QuotaResult(
          QuotaOutcome.verified,
          'Synthetic quota readback verified.',
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
  }) => throw UnimplementedError('No real connection in quota fixtures.');
}

class QuotaHarness {
  QuotaHarness() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final api = QuotaFake();
  late final AuthenticatedSession session;
  late final ProviderContainer container;
  AuthenticatedSession? active;
  final _subscriptions = <ProviderSubscription<AsyncValue<QuotaInventory>>>[];

  QuotasController get controller =>
      container.read(quotasControllerProvider.notifier);
  QuotasState get state => container.read(quotasControllerProvider);
  ServerOperationLock get lock => container.read(serverOperationLockProvider);

  AuthenticatedSession newSession({String? endpoint = quotaEndpoint}) =>
      AuthenticatedSession(
        profileId: 'quotas',
        repository: api,
        availableMethodNames: const {},
        version: '25.10.1',
        endpoint: endpoint,
      );
  void select(AuthenticatedSession? selected) {
    active = selected;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  Future<QuotaInventory> inventory() async {
    final datasets = await container.read(quotaDatasetsProvider.future);
    final provider = quotaInventoryProvider(datasets.first);
    _subscriptions.add(container.listen(provider, (_, _) {}));
    return container.read(provider.future);
  }

  Future<QuotaReview> review() async {
    final inv = await inventory();
    final identity = await api.resolveQuotaIdentity(inv, QuotaKind.user, 1000);
    return api.reviewQuotaChange(
      QuotaChange(inventory: inv, identity: identity, byteLimit: 2048),
    );
  }

  void dispose() {
    for (final sub in _subscriptions) {
      sub.close();
    }
    container.dispose();
  }
}
