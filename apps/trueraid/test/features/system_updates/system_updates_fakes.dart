import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const updatesEndpoint = 'wss://sample.example/api/current';
const updatesCaps = SystemUpdatesCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canCheck: true,
  canDownload: true,
  canInstall: true,
);
const updatesVersion = SystemUpdateVersion(
  train: 'TrueNAS-SCALE-Goldeye',
  version: '25.10.2',
  filename: 'TrueNAS-SCALE-25.10.2.update',
  checksum: 'sample-source-checksum',
  downloadBytes: 2147483648,
  profile: 'GENERAL',
);

SystemUpdateInventory updatesInventory({
  bool checked = true,
  String? checkError,
  bool? matchesProfile = true,
  bool healthy = true,
  bool ha = false,
  bool conflictingJob = false,
  bool keep = true,
  int? size = 68719476736,
  int? allocated = 17179869184,
  int? free = 51539607552,
  List<SystemUpdateVersion>? versions,
  double? downloadPercent,
}) => SystemUpdateInventory(
  endpoint: updatesEndpoint,
  currentVersion: '25.10.1',
  bootPool: 'boot-pool',
  bootHealthy: healthy,
  failoverLicensed: ha,
  conflictingJob: conflictingJob,
  bootSizeBytes: size,
  bootAllocatedBytes: allocated,
  bootFreeBytes: free,
  checked: checked,
  checkError: checkError,
  currentTrain: checked ? 'TrueNAS-SCALE-Goldeye' : null,
  currentProfile: checked ? 'GENERAL' : null,
  matchesProfile: checked ? matchesProfile : null,
  downloadPercent: downloadPercent,
  versions: versions ?? (checked ? const [updatesVersion] : const []),
  environments: [
    const BootEnvironmentSnapshot(
      id: '25.10.1',
      dataset: 'boot-pool/ROOT/25.10.1',
      created: '2026-01-01 00:00:00',
      usedBytes: 8589934592,
      active: true,
      activated: true,
      keep: true,
      canActivate: true,
    ),
    BootEnvironmentSnapshot(
      id: '25.10.0',
      dataset: 'boot-pool/ROOT/25.10.0',
      created: '2025-10-01 00:00:00',
      usedBytes: 8589934592,
      active: false,
      activated: false,
      keep: keep,
      canActivate: true,
    ),
  ],
);

SystemUpdateReview updatesReview({
  SystemUpdateInventory? inventory,
  SystemUpdateAction action = SystemUpdateAction.download,
  String endpoint = updatesEndpoint,
}) {
  final data = inventory ?? updatesInventory();
  return SystemUpdateReview(
    request: SystemUpdateRequest(
      inventory: data,
      action: action,
      version: action == SystemUpdateAction.check ? null : data.versions.first,
    ),
    endpoint: endpoint,
    warnings: const ['Exact server source warning.'],
  );
}

SystemUpdateJob updatesJob({
  SystemUpdateAction action = SystemUpdateAction.download,
}) => SystemUpdateJob(
  id: 42,
  action: action,
  endpoint: updatesEndpoint,
  currentVersion: '25.10.1',
  version: updatesVersion,
);

class UpdatesFake
    implements SessionRepository, AuthenticatedSystemUpdatesSession {
  UpdatesFake({SystemUpdateInventory? inventory, this.caps = updatesCaps})
    : inventory = inventory ?? updatesInventory();
  SystemUpdateInventory inventory;
  final SystemUpdatesCapabilities caps;
  int reads = 0;
  final reviews = <SystemUpdateRequest>[];
  final writes = <SystemUpdateReview>[];
  final polls = <SystemUpdateJob>[];
  Future<SystemUpdateInventory> Function()? onLoad;
  Future<SystemUpdateReview> Function(SystemUpdateRequest)? onReview;
  Future<SystemUpdateResult> Function()? onExecute;
  Future<SystemUpdateResult> Function()? onPoll;
  @override
  SystemUpdatesCapabilities get systemUpdatesCapabilities => caps;
  @override
  Future<SystemUpdateInventory> loadSystemUpdates() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<SystemUpdateReview> reviewSystemUpdate(
    SystemUpdateRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        SystemUpdateReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const ['Exact server source warning.'],
        );
  }

  @override
  Future<SystemUpdateResult> executeSystemUpdate(
    SystemUpdateReview review,
    String confirmation,
  ) async {
    writes.add(review);
    final result =
        await (onExecute?.call() ??
            Future.value(
              const SystemUpdateResult(
                SystemUpdateOutcome.succeeded,
                'Download reported success. Checksum not independently verified.',
              ),
            ));
    if (result.inventory case final value?) inventory = value;
    return result;
  }

  @override
  Future<SystemUpdateResult> pollSystemUpdate(SystemUpdateJob job) async {
    polls.add(job);
    return onPoll?.call() ??
        SystemUpdateResult(
          SystemUpdateOutcome.pending,
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
  }) => throw UnsupportedError('No transport in fixtures.');
}

class UpdatesHarness {
  UpdatesHarness({UpdatesFake? fake}) : api = fake ?? UpdatesFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final UpdatesFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({
    String? endpoint = updatesEndpoint,
    UpdatesFake? fake,
  }) => AuthenticatedSession(
    profileId: 'sample',
    repository: fake ?? api,
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
