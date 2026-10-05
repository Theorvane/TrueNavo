import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const zvolMethods = {
  'pool.dataset.query',
  'pool.dataset.create',
  'pool.dataset.update',
  'pool.dataset.delete',
  'pool.dataset.attachments',
  'pool.dataset.recommended_zvol_blocksize',
  'pool.snapshot.query',
  'vm.device.query',
  'iscsi.extent.query',
  'nvmet.namespace.query',
};
const zvolParent = ZvolParent(
  id: 'tank/virtual_disks',
  guid: '101',
  availableBytes: 1099511627776,
);
const zvolVolume = ZvolEntry(
  id: 'tank/virtual_disks/lab',
  guid: '202',
  sizeBytes: 68719476736,
  blockSizeBytes: 16384,
  usedBytes: 12884901888,
  referencedBytes: 8589934592,
  reservationBytes: 0,
  refreservationBytes: 0,
  compression: 'LZ4',
  sync: 'STANDARD',
  readonly: false,
);
const reservedZvol = ZvolEntry(
  id: 'tank/virtual_disks/reserved',
  guid: '203',
  sizeBytes: 34359738368,
  blockSizeBytes: 16384,
  usedBytes: 34359738368,
  referencedBytes: 8589934592,
  reservationBytes: 0,
  refreservationBytes: 34359738368,
  compression: 'LZ4',
  sync: 'ALWAYS',
  readonly: false,
);
const customZvol = ZvolEntry(
  id: 'tank/virtual_disks/custom',
  guid: '204',
  sizeBytes: 34359738368,
  blockSizeBytes: 16384,
  usedBytes: 12884901888,
  referencedBytes: 8589934592,
  reservationBytes: 0,
  refreservationBytes: 17179869184,
  compression: 'ZSTD',
  sync: 'STANDARD',
  readonly: true,
);
ZvolReview zvolReview({
  ZvolAction action = ZvolAction.update,
  String target = 'tank/virtual_disks/lab',
}) => ZvolReview(
  action: action,
  target: target,
  identity: 'GUID 202; existing block 16384 bytes',
  changes: const ['Logical size: 68719476736 → 85899345920 bytes'],
  warnings: const [
    'Guest partition and filesystem growth are separate operations.',
  ],
);

class ZvolsFake implements SessionRepository, AuthenticatedZvolsSession {
  ZvolsFake({this.methods = zvolMethods, ZvolInventory? inventory})
    : inventory =
          inventory ??
          ZvolInventory(
            parents: [zvolParent],
            volumes: [zvolVolume, reservedZvol, customZvol],
          );
  final Set<String> methods;
  final ZvolInventory inventory;
  int reads = 0;
  final recommendations = <ZvolParent>[];
  final creates = <ZvolCreate>[];
  final updates = <ZvolUpdate>[];
  final deletes = <ZvolEntry>[];
  final writes = <ZvolReview>[];
  final confirmations = <String>[];
  Future<ZvolInventory> Function()? onLoad;
  Future<ZvolResult> Function()? onExecute;
  Future<String> Function(ZvolParent)? onRecommendation;
  Future<ZvolReview> Function(ZvolCreate)? onCreate;
  Future<ZvolReview> Function(ZvolUpdate)? onUpdate;
  Future<ZvolReview> Function(ZvolEntry)? onDelete;
  @override
  ZvolCapabilities get zvolCapabilities => ZvolCapabilities(
    connected: true,
    versionSupported: true,
    methods: methods,
  );
  @override
  Future<ZvolInventory> loadZvols() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<String> loadZvolRecommendedBlockSize(ZvolParent parent) async {
    recommendations.add(parent);
    return onRecommendation?.call(parent) ?? '16K';
  }

  @override
  Future<ZvolReview> reviewZvolCreate(ZvolCreate request) async {
    creates.add(request);
    return onCreate?.call(request) ??
        ZvolReview(
          action: ZvolAction.create,
          target: request.target,
          identity:
              'Parent GUID ${request.parent.guid}; block ${request.blockSize}',
          changes: [
            'Logical size: ${request.sizeBytes} bytes',
            'Provisioning: ${request.thin ? 'thin' : 'reserved'}',
            'Compression: ${request.compression}',
            'Sync: ${request.sync}',
          ],
          warnings: [
            'Creates a block device only; no guest filesystem is created.',
          ],
        );
  }

  @override
  Future<ZvolReview> reviewZvolUpdate(ZvolUpdate request) async {
    updates.add(request);
    return onUpdate?.call(request) ?? zvolReview(target: request.volume.id);
  }

  @override
  Future<ZvolReview> reviewZvolDelete(ZvolEntry volume) async {
    deletes.add(volume);
    return onDelete?.call(volume) ??
        ZvolReview(
          action: ZvolAction.delete,
          target: volume.id,
          identity: 'GUID ${volume.guid}',
          changes: ['Permanently destroys this virtual disk.'],
          warnings: ['No snapshots or attached consumers were found.'],
        );
  }

  @override
  Future<ZvolResult> executeZvolReview(
    ZvolReview review,
    String confirmation,
  ) async {
    writes.add(review);
    confirmations.add(confirmation);
    return onExecute?.call() ??
        const ZvolResult(ZvolOutcome.verified, 'Storage readback verified.');
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
  }) => throw UnimplementedError();
}

class ZvolsHarness {
  ZvolsHarness({ZvolsFake? fake}) : api = fake ?? ZvolsFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final ZvolsFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({
    String? endpoint = 'wss://sample.example/api/current',
    ZvolsFake? fake,
  }) => AuthenticatedSession(
    profileId: 'zvol-test',
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
