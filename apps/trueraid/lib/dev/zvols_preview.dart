import 'package:truenas_api/truenas_api.dart';

/// Synthetic visual fixtures only: no connector, credential or mutation.
mixin ZvolsPreviewAdapter implements AuthenticatedZvolsSession {
  static final inventory = ZvolInventory(
    parents: const [
      ZvolParent(
        id: 'tank/virtual_disks',
        guid: '101',
        availableBytes: 1099511627776,
      ),
    ],
    volumes: const [
      ZvolEntry(
        id: 'tank/virtual_disks/services',
        guid: '201',
        sizeBytes: 137438953472,
        blockSizeBytes: 16384,
        usedBytes: 137438953472,
        referencedBytes: 34359738368,
        reservationBytes: 0,
        refreservationBytes: 137438953472,
        compression: 'LZ4',
        sync: 'STANDARD',
        readonly: false,
      ),
      ZvolEntry(
        id: 'tank/virtual_disks/lab',
        guid: '202',
        sizeBytes: 68719476736,
        blockSizeBytes: 16384,
        usedBytes: 12884901888,
        referencedBytes: 8589934592,
        reservationBytes: 0,
        refreservationBytes: 0,
        compression: 'ZSTD',
        sync: 'STANDARD',
        readonly: false,
      ),
      ZvolEntry(
        id: 'tank/virtual_disks/archive',
        guid: '203',
        sizeBytes: 34359738368,
        blockSizeBytes: 16384,
        usedBytes: 34359738368,
        referencedBytes: 17179869184,
        reservationBytes: 0,
        refreservationBytes: 34359738368,
        compression: 'LZ4',
        sync: 'ALWAYS',
        readonly: true,
      ),
    ],
  );
  @override
  ZvolCapabilities get zvolCapabilities => ZvolCapabilities(
    connected: true,
    versionSupported: true,
    methods: {
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
    },
  );
  @override
  Future<ZvolInventory> loadZvols() async => inventory;
  @override
  Future<String> loadZvolRecommendedBlockSize(ZvolParent parent) async => '16K';
  ZvolReview _sample(
    ZvolAction action,
    String target,
    List<String> changes,
  ) => ZvolReview(
    action: action,
    target: target,
    identity: 'Synthetic preview identity',
    changes: changes,
    warnings: const [
      'Sample only. No storage operation can be submitted from this preview.',
    ],
  );
  @override
  Future<ZvolReview> reviewZvolCreate(ZvolCreate request) async =>
      _sample(ZvolAction.create, request.target, [
        'Logical size: ${request.sizeBytes} bytes',
        'Block size: ${request.blockSize}',
        'Provisioning: ${request.thin ? 'thin' : 'reserved'}',
        'No filesystem or VM is created.',
      ]);
  @override
  Future<ZvolReview> reviewZvolUpdate(
    ZvolUpdate request,
  ) async => _sample(ZvolAction.update, request.volume.id, [
    if (request.sizeBytes != null)
      'Logical size: ${request.volume.sizeBytes} → ${request.sizeBytes} bytes',
    if (request.compression != null)
      'Compression: ${request.volume.compression} → ${request.compression}',
    if (request.sync != null) 'Sync: ${request.volume.sync} → ${request.sync}',
    if (request.readonly != null)
      'Read-only: ${request.volume.readonly} → ${request.readonly}',
  ]);
  @override
  Future<ZvolReview> reviewZvolDelete(ZvolEntry volume) async => _sample(
    ZvolAction.delete,
    volume.id,
    ['Permanently destroys the selected virtual disk.'],
  );
  @override
  Future<ZvolResult> executeZvolReview(
    ZvolReview review,
    String confirmation,
  ) async => const ZvolResult(
    ZvolOutcome.rejected,
    'Sample preview: all writes are disabled.',
  );
}
