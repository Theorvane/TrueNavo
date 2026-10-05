// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Pure local samples. No connector, live disk lookup or write can run here.
mixin DisksPreviewAdapter implements AuthenticatedDisksSession {
  static final inventory = DiskInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    failoverLicensed: false,
    warnings: const [
      'SAMPLE DATA — passive inventory and stored policies only. No device health or free-space claim.',
    ],
    disks: const [
      DiskSnapshot(
        identifier: '{serial}SAMPLE-HDD-A',
        name: 'sda',
        serial: 'SAMPLE-HDD-A',
        lunid: null,
        sizeBytes: 8000000000000,
        model: 'Sample capacity drive',
        type: 'HDD',
        bus: 'ATA',
        description: 'Main pool bay 1',
        hddStandby: 'ALWAYS ON',
        advancedPowerManagement: 'DISABLED',
        pool: 'tank',
        zfsGuid: '101',
        rotationRate: 7200,
        identityVerified: true,
      ),
      DiskSnapshot(
        identifier: '{serial}SAMPLE-HDD-B',
        name: 'sdb',
        serial: 'SAMPLE-HDD-B',
        lunid: null,
        sizeBytes: 4000000000000,
        model: 'Sample archive drive',
        type: 'HDD',
        bus: 'ATA',
        description: 'Archive bay',
        hddStandby: '60',
        advancedPowerManagement: '192',
        pool: 'archive',
        zfsGuid: '102',
        rotationRate: 5400,
        identityVerified: true,
      ),
      DiskSnapshot(
        identifier: '{serial}SAMPLE-BOOT',
        name: 'nvme0n1',
        serial: 'SAMPLE-BOOT',
        lunid: null,
        sizeBytes: 500000000000,
        model: 'Sample system SSD',
        type: 'SSD',
        bus: 'NVME',
        description: 'System boot',
        hddStandby: 'ALWAYS ON',
        advancedPowerManagement: 'DISABLED',
        pool: null,
        zfsGuid: '103',
        rotationRate: null,
        identityVerified: true,
        bootDisk: true,
      ),
      DiskSnapshot(
        identifier: '{serial_lunid}SAMPLE-SAS_sample-lun',
        name: 'sdc',
        serial: 'SAMPLE-SAS',
        lunid: 'sample-lun',
        sizeBytes: 2000000000000,
        model: 'Sample SAS drive',
        type: 'HDD',
        bus: 'SAS',
        description: 'Unassigned is not empty',
        hddStandby: 'ALWAYS ON',
        advancedPowerManagement: 'DISABLED',
        pool: null,
        zfsGuid: null,
        rotationRate: 10000,
        identityVerified: true,
      ),
      DiskSnapshot(
        identifier: '{devicename}sdd',
        name: 'sdd',
        serial: '',
        lunid: null,
        sizeBytes: null,
        model: null,
        type: 'UNKNOWN',
        bus: 'UNKNOWN',
        description: 'Unverified cached record',
        hddStandby: 'ALWAYS ON',
        advancedPowerManagement: 'DISABLED',
        pool: null,
        zfsGuid: null,
        rotationRate: null,
      ),
    ],
  );
  @override
  DisksCapabilities get disksCapabilities => const DisksCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
    canUpdate: true,
  );
  @override
  Future<DiskInventory> loadDisks() async => inventory;
  @override
  Future<DiskReview> reviewDisk(DiskRequest request) async {
    if (!identical(request.inventory, inventory) ||
        request.validationError != null) {
      throw const DisksException(DisksExceptionReason.invalidRequest);
    }
    return DiskReview(
      request: request,
      endpoint: inventory.endpoint,
      warnings: const [
        'SAMPLE DATA — all writes are rejected without contacting a NAS.',
        'Only the stored description and admitted power policy are changed. Device readback does not prove hardware application or health.',
        'Power policy changes can delay access and increase spin-down cycles. No disk contents are erased.',
      ],
    );
  }

  @override
  Future<DiskResult> executeDisk(
    DiskReview review,
    String confirmation,
  ) async => const DiskResult(
    DiskOutcome.rejected,
    'Preview only. No disk settings were submitted.',
  );
}
