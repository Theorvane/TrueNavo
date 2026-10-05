import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

enum ProtectionFamily {
  snapshots('Snapshot schedules'),
  replication('Replication'),
  cloudSync('Cloud Sync'),
  rsync('Rsync');

  const ProtectionFamily(this.label);
  final String label;
}

enum ProtectionReportedState {
  successful('Reported successful'),
  failed('Reported failed'),
  active('Reported active'),
  attention('Held / waiting for attention'),
  unknown('No recognized status');

  const ProtectionReportedState(this.label);
  final String label;
}

/// Status is historical/server-reported, never a recoverability assertion.
ProtectionReportedState protectionReportedState(String state) =>
    switch (state) {
      'SUCCESS' || 'FINISHED' => ProtectionReportedState.successful,
      'FAILED' || 'ERROR' || 'ABORTED' => ProtectionReportedState.failed,
      'RUNNING' || 'WAITING' => ProtectionReportedState.active,
      'HOLD' || 'LOCKED' => ProtectionReportedState.attention,
      _ => ProtectionReportedState.unknown,
    };

final class ProtectionTaskSummary {
  const ProtectionTaskSummary({
    required this.family,
    required this.id,
    required this.name,
    required this.source,
    required this.destination,
    required this.enabled,
    required this.state,
    required this.schedule,
    this.restriction,
  });
  final ProtectionFamily family;
  final int id;
  final String name, source, destination, state, schedule;
  final bool enabled;
  final String? restriction;
  String get identity => '${family.name}:$id';
  ProtectionReportedState get reportedState => protectionReportedState(state);
  bool matches(String query) => [
    family.label,
    '$id',
    name,
    source,
    destination,
    state,
  ].join(' ').toLowerCase().contains(query.toLowerCase().trim());
}

final class ProtectionSourceSummary {
  ProtectionSourceSummary({
    required this.family,
    required List<ProtectionTaskSummary> tasks,
    this.unavailable,
    this.conflictingJob = false,
  }) : tasks = List.unmodifiable(tasks);
  final ProtectionFamily family;
  final List<ProtectionTaskSummary> tasks;
  final String? unavailable;
  final bool conflictingJob;
  bool get loaded => unavailable == null;
}

final class DataProtectionOverview {
  DataProtectionOverview({
    required this.endpoint,
    required this.observedAt,
    required List<ProtectionSourceSummary> sources,
  }) : sources = List.unmodifiable(sources);
  final String endpoint;

  /// Client completion time of sequential bounded reads, not server event time.
  final DateTime observedAt;
  final List<ProtectionSourceSummary> sources;
  List<ProtectionTaskSummary> get tasks =>
      List.unmodifiable(sources.where((s) => s.loaded).expand((s) => s.tasks));
  int get loadedSources => sources.where((s) => s.loaded).length;
  int get enabled => tasks.where((t) => t.enabled).length;
  int get disabled => tasks.length - enabled;
  int count(ProtectionReportedState state) =>
      tasks.where((t) => t.reportedState == state).length;
}

/// Reads the existing typed inventories only. No generic method runner, remote
/// cloud validation, transfer, snapshot, credential or update action is exposed.
Future<DataProtectionOverview> loadDataProtectionOverview({
  required SessionRepository repository,
  required String endpoint,
  required bool Function() isCurrent,
  DateTime Function()? now,
}) async {
  void requireCurrent() {
    if (!isCurrent()) throw StateError('The connection changed.');
  }

  final sources = <ProtectionSourceSummary>[];
  Future<void> read(
    ProtectionFamily family,
    Future<ProtectionSourceSummary> Function()? load,
  ) async {
    requireCurrent();
    if (load == null) {
      sources.add(
        ProtectionSourceSummary(
          family: family,
          tasks: const [],
          unavailable:
              'This native inventory is not available for this connection.',
        ),
      );
      return;
    }
    try {
      final value = await load();
      requireCurrent();
      sources.add(value);
    } on Object {
      requireCurrent();
      // Never surface arbitrary repository/remote errors in an overview.
      sources.add(
        ProtectionSourceSummary(
          family: family,
          tasks: const [],
          unavailable: 'This inventory could not be read. Counts are unavailable, not zero. Refresh explicitly to try again.',
        ),
      );
    }
  }

  // Sequential reads avoid each adapter's shared request/operation fencing.
  await read(
    ProtectionFamily.snapshots,
    repository is AuthenticatedSnapshotSchedulesSession
        ? () async {
            final i =
                await (repository as AuthenticatedSnapshotSchedulesSession)
                    .loadSnapshotSchedules();
            return ProtectionSourceSummary(
              family: ProtectionFamily.snapshots,
              tasks: [
                for (final t in i.tasks)
                  ProtectionTaskSummary(
                    family: ProtectionFamily.snapshots,
                    id: t.id,
                    name: 'Snapshot policy #${t.id}',
                    source: t.settings.dataset,
                    destination: 'Snapshots on the source dataset',
                    enabled: t.settings.enabled,
                    state: t.state,
                    restriction: t.blockedReason,
                    schedule:
                        '${_snapshotCron(t.settings.cron)} · ${i.timezone}\nWindow ${t.settings.cron.begin}–${t.settings.cron.end}; retention ${t.settings.lifetimeValue} ${t.settings.lifetimeUnit.toLowerCase()}',
                  ),
              ],
            );
          }
        : null,
  );
  await read(
    ProtectionFamily.replication,
    repository is AuthenticatedReplicationSession
        ? () async {
            final i = await (repository as AuthenticatedReplicationSession)
                .loadReplication();
            if (i.endpoint != endpoint) {
              throw StateError('Mismatched endpoint.');
            }
            return ProtectionSourceSummary(
              family: ProtectionFamily.replication,
              conflictingJob: i.conflictingJob,
              tasks: [
                for (final t in i.tasks)
                  ProtectionTaskSummary(
                    family: ProtectionFamily.replication,
                    id: t.id,
                    name: t.name,
                    source: t.source,
                    destination: t.destination,
                    enabled: t.enabled,
                    state: t.state,
                    restriction: t.blockedReason,
                    schedule: t.settings != null
                        ? 'Manual ${t.direction} · ${t.transport}\nDestination retention: ${t.settings!.retention}'
                        : 'Advanced policy; schedule details are not represented here.',
                  ),
              ],
            );
          }
        : null,
  );
  await read(
    ProtectionFamily.cloudSync,
    repository is AuthenticatedCloudSyncSession
        ? () async {
            final i = await (repository as AuthenticatedCloudSyncSession)
                .loadCloudSync();
            if (i.endpoint != endpoint) {
              throw StateError('Mismatched endpoint.');
            }
            return ProtectionSourceSummary(
              family: ProtectionFamily.cloudSync,
              conflictingJob: i.conflictingJob,
              tasks: [
                for (final t in i.tasks)
                  ProtectionTaskSummary(
                    family: ProtectionFamily.cloudSync,
                    id: t.id,
                    name: t.settings.description.isEmpty
                        ? 'Cloud Sync #${t.id}'
                        : t.settings.description,
                    source:
                        '${t.settings.direction} ${t.settings.transferMode} · ${t.settings.path}',
                    destination:
                        '${t.provider} · ${t.settings.bucket.isEmpty ? '' : '${t.settings.bucket}/'}${t.settings.folder}',
                    enabled: t.settings.enabled,
                    state: t.state,
                    restriction: t.blockedReason,
                    schedule:
                        '${t.settings.minute} ${t.settings.hour} ${t.settings.dom} ${t.settings.month} ${t.settings.dow} · ${i.timezone}',
                  ),
              ],
            );
          }
        : null,
  );
  await read(
    ProtectionFamily.rsync,
    repository is AuthenticatedRsyncSession
        ? () async {
            final inventory = await (repository as AuthenticatedRsyncSession)
                .loadRsync();
            requireCurrent();
            if (inventory.endpoint != endpoint ||
                inventory.tasks.length > 128 ||
                inventory.tasks.any((task) => task.id <= 0) ||
                inventory.tasks.map((task) => task.id).toSet().length !=
                    inventory.tasks.length) {
              throw StateError('Unverified Rsync inventory.');
            }
            return ProtectionSourceSummary(
              family: ProtectionFamily.rsync,
              conflictingJob: inventory.conflictingJob,
              tasks: [
                for (final task in inventory.tasks)
                  _rsyncSummary(task, inventory),
              ],
            );
          }
        : null,
  );
  requireCurrent();
  return DataProtectionOverview(
    endpoint: endpoint,
    observedAt: (now ?? DateTime.now)().toUtc(),
    sources: sources,
  );
}

String _snapshotCron(SnapshotScheduleCron c) =>
    '${c.minute} ${c.hour} ${c.dom} ${c.month} ${c.dow}';

ProtectionTaskSummary _rsyncSummary(RsyncTask task, RsyncInventory inventory) {
  // The SDK intentionally withholds settings for unsupported task shapes. Do
  // not reconstruct raw MODULE/PULL, account, SSH or extra-option details here.
  final settings =
      task.supported &&
          task.mode == 'SSH' &&
          task.direction == 'PUSH' &&
          task.settings!.validationError == null
      ? task.settings
      : null;
  final recorded = task.lastJobState;
  final state =
      const {
        'SUCCESS',
        'FAILED',
        'ABORTED',
        'RUNNING',
        'WAITING',
      }.contains(recorded)
      ? recorded!
      : 'No recognized recorded state';
  final description = task.description;
  final safeName =
      description.isNotEmpty &&
      description.length <= 120 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(description);
  final cron = settings?.cron;
  return ProtectionTaskSummary(
    family: ProtectionFamily.rsync,
    id: task.id,
    name: safeName ? description : 'Rsync task #${task.id}',
    source: settings == null
        ? 'Unsupported task details withheld'
        : 'SSH PUSH · ${settings.path}',
    destination: settings == null
        ? 'Unsupported task details withheld'
        : 'SSH connection #${settings.connectionId} · ${settings.remotePath}',
    enabled: task.enabled,
    state: state,
    schedule: cron == null
        ? 'Advanced policy; schedule details are not represented here.'
        : '${cron.minute} ${cron.hour} ${cron.dom} ${cron.month} ${cron.dow} · ${inventory.timezone}',
    restriction: settings == null
        ? 'This task cannot be changed in the bounded native Rsync workflow. Inspect its workspace for restrictions.'
        : inventory.failoverLicensed
        ? 'HA Rsync requires the coordinated TrueNAS workflow.'
        : !task.crossFilesystemProtection
        ? 'A reviewed update is required before enabling or running this legacy task.'
        : null,
  );
}

final dataProtectionOverviewProvider =
    FutureProvider.autoDispose<DataProtectionOverview>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null) {
        throw StateError('Connect to inspect data protection.');
      }
      var mounted = true;
      ref.onDispose(() => mounted = false);
      final lock = ref.read(serverOperationLockProvider);
      final owner = lock.acquire();
      if (owner == null) {
        throw StateError('Another server operation is pending.');
      }
      try {
        return await loadDataProtectionOverview(
          repository: session!.repository,
          endpoint: session.endpoint!,
          isCurrent: () =>
              mounted &&
              identical(session, ref.read(dashboardActiveSessionProvider)),
        );
      } finally {
        lock.release(owner);
      }
    }, retry: (_, _) => null);
