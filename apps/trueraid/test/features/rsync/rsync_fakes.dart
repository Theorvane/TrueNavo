import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const rsEndpoint = 'wss://sample.example/api/current';
const rsCaps = RsyncCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canCreate: true,
  canUpdate: true,
  canDelete: true,
  canRun: true,
);
const rsSettings = RsyncSettings(
  path: '/mnt/tank/media',
  user: 'backup',
  connectionId: 21,
  remotePath: '/srv/backup',
  description: 'Media copy',
);
RsyncInventory rsInventory({
  String endpoint = rsEndpoint,
  bool enabled = false,
  bool ha = false,
  bool empty = false,
  bool locked = false,
  bool unsupported = false,
  bool jobs = false,
  bool crossFilesystemProtection = true,
  String? lastState = 'SUCCESS',
}) => RsyncInventory(
  endpoint: endpoint,
  timezone: 'Asia/Seoul',
  failoverLicensed: ha,
  conflictingJob: jobs,
  tasks: empty
      ? []
      : [
          RsyncTask(
            id: 11,
            description: 'Media copy',
            mode: unsupported ? 'MODULE' : 'SSH',
            direction: unsupported ? 'PULL' : 'PUSH',
            enabled: enabled,
            locked: locked,
            lastJobState: lastState,
            crossFilesystemProtection: crossFilesystemProtection,
            blockedReason: unsupported
                ? 'Unsupported settings remain read-only.'
                : null,
            settings: unsupported
                ? null
                : RsyncSettings(
                    path: rsSettings.path,
                    user: rsSettings.user,
                    connectionId: rsSettings.connectionId,
                    remotePath: rsSettings.remotePath,
                    description: rsSettings.description,
                    enabled: enabled,
                  ),
          ),
        ],
  connections: [
    RsyncConnection(
      id: 21,
      name: 'Backup SSH',
      host: 'backup.example',
      port: 22,
      username: 'replica',
      keyPairId: 31,
      publicKeyFingerprint: 'SHA256:public-fixture',
      hostKeyFingerprints: ['SHA256:host-fixture'],
    ),
  ],
  users: const [RsyncUser(id: 41, uid: 1001, username: 'backup')],
  datasets: const [
    RsyncDataset(id: 'tank/media', guid: '101', path: '/mnt/tank/media'),
  ],
);
RsyncRequest rsRequest(
  RsyncInventory inventory, {
  RsyncAction action = RsyncAction.run,
}) => RsyncRequest(
  inventory: inventory,
  action: action,
  task: inventory.tasks.first,
);
RsyncReview rsReview(
  RsyncInventory inventory, {
  RsyncAction action = RsyncAction.run,
}) => RsyncReview(
  request: rsRequest(inventory, action: action),
  endpoint: rsEndpoint,
  warnings: const ['Synthetic review. Destination files may be overwritten.'],
);
RsyncJob rsJob({
  int id = 80,
  int taskId = 11,
  String endpoint = rsEndpoint,
  String path = '/mnt/tank/media',
  int connectionId = 21,
  String remotePath = '/srv/backup',
}) => RsyncJob(
  id: id,
  taskId: taskId,
  endpoint: endpoint,
  path: path,
  connectionId: connectionId,
  remotePath: remotePath,
);

class RsFake implements SessionRepository, AuthenticatedRsyncSession {
  RsFake({RsyncInventory? inventory, this.caps = rsCaps})
    : inventory = inventory ?? rsInventory();
  RsyncInventory inventory;
  RsyncCapabilities caps;
  int reads = 0;
  final reviews = <RsyncRequest>[],
      writes = <RsyncReview>[],
      checks = <RsyncJob>[];
  Future<RsyncInventory> Function()? onLoad;
  Future<RsyncReview> Function(RsyncRequest)? onReview;
  Future<RsyncResult> Function(RsyncReview)? onExecute;
  Future<RsyncResult> Function(RsyncJob)? onCheck;
  @override
  RsyncCapabilities get rsyncCapabilities => caps;
  @override
  Future<RsyncInventory> loadRsync() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<RsyncReview> reviewRsync(RsyncRequest request) async {
    reviews.add(request);
    return onReview?.call(request) ??
        RsyncReview(
          request: request,
          endpoint: rsEndpoint,
          warnings: const ['Synthetic maintenance review. Confirm once only.'],
        );
  }

  @override
  Future<RsyncResult> executeRsync(
    RsyncReview review,
    String confirmation,
  ) async {
    writes.add(review);
    return onExecute?.call(review) ??
        const RsyncResult(
          RsyncOutcome.succeeded,
          'Synthetic configuration observed; no server was contacted.',
        );
  }

  @override
  Future<RsyncResult> checkRsyncJob(RsyncJob job) async {
    checks.add(job);
    return onCheck?.call(job) ??
        const RsyncResult(
          RsyncOutcome.succeeded,
          'Synthetic owned job verified.',
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

class RsHarness {
  RsHarness({RsFake? fake}) : api = fake ?? RsFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final RsFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = rsEndpoint}) =>
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
