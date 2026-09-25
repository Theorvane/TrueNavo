import 'package:truenas_api/truenas_api.dart';

/// Synthetic preview only. No transport, credential, job or mutation exists.
mixin VirtualMachinesPreviewAdapter
    implements AuthenticatedVirtualMachinesSession {
  @override
  VmCapabilities get virtualMachineCapabilities => const VmCapabilities(
    connected: true,
    versionSupported: true,
    methods: {
      'vm.query',
      'vm.create',
      'vm.update',
      'vm.delete',
      'vm.start',
      'vm.stop',
      'vm.restart',
      'vm.poweroff',
      'vm.suspend',
      'vm.resume',
      'vm.device.create',
      'vm.device.update',
      'vm.device.delete',
    },
  );
  @override
  Future<VmInventory> loadVirtualMachines() async => VmInventory(
    machines: [
      VirtualMachine(
        id: 1,
        uuid: '11111111-1111-4111-8111-111111111111',
        state: 'RUNNING',
        configuration: const VmConfiguration(
          name: 'ubuntu_services',
          description: 'Synthetic Linux guest for the native preview.',
          memoryMiB: 8192,
          cores: 4,
          autostart: true,
        ),
        devices: [
          VmDevice(
            id: 10,
            vmId: 1,
            type: 'DISK',
            order: 1001,
            attributes: const {
              'path': '/dev/zvol/tank/vm/ubuntu',
              'type': 'VIRTIO',
            },
          ),
          VmDevice(
            id: 11,
            vmId: 1,
            type: 'NIC',
            order: 1002,
            attributes: const {'nic_attach': 'br0', 'type': 'VIRTIO'},
          ),
        ],
      ),
      VirtualMachine(
        id: 2,
        uuid: '22222222-2222-4222-8222-222222222222',
        state: 'STOPPED',
        configuration: const VmConfiguration(
          name: 'test_lab',
          description: 'Stopped guest ready for reviewed configuration.',
          memoryMiB: 4096,
          cores: 2,
        ),
        devices: const [],
      ),
    ],
  );
  @override
  Future<VmChoices> loadVmChoices() async => VmChoices(
    maximumVcpus: 64,
    availableMemoryBytes: 24 * 1024 * 1024 * 1024,
    cpuModels: const ['qemu64'],
    disks: const [
      VmDeviceOption(
        kind: 'DISK',
        value: '/dev/zvol/tank/vm/unused',
        label: 'tank/vm/unused',
      ),
    ],
    interfaces: const [
      VmDeviceOption(kind: 'NIC', value: 'br0', label: 'Bridge br0'),
    ],
  );
  VmReview _vmPreviewReview(
    String title,
    String target, [
    String identity = 'Synthetic preview',
  ]) => VmReview(
    title: title,
    targetName: target,
    identity: identity,
    changes: const ['Synthetic preview only; no changes will be submitted.'],
    warnings: const [
      'This preview has no server transport. Confirmation is always rejected.',
    ],
  );
  @override
  Future<VmReview> reviewVmCreate(VmConfiguration configuration) async =>
      _vmPreviewReview('Create virtual machine', configuration.name);
  @override
  Future<VmReview> reviewVmUpdate(
    VirtualMachine vm,
    VmConfiguration configuration,
  ) async => _vmPreviewReview('Change VM settings', vm.name, vm.uuid);
  @override
  Future<VmReview> reviewVmAction(VirtualMachine vm, VmAction action) async =>
      _vmPreviewReview('${action.name} virtual machine', vm.name, vm.uuid);
  @override
  Future<VmReview> reviewVmDevice(
    VirtualMachine vm,
    VmDeviceChange change,
  ) async => _vmPreviewReview('Change VM device', vm.name, vm.uuid);
  @override
  Future<VmOperationResult> executeVmReview(
    VmReview review, {
    required String confirmation,
  }) async => const VmOperationResult(outcome: VmOperationOutcome.rejected);
  @override
  Future<VmOperationResult> pollVmOperation(
    VmOperationHandle operation,
  ) async => const VmOperationResult(outcome: VmOperationOutcome.rejected);
}
