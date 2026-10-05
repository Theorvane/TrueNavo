import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../dashboard/dashboard_controller.dart';
import 'virtual_machines_controller.dart';
import 'vm_state_chart.dart';

class VirtualMachinesPage extends ConsumerStatefulWidget {
  const VirtualMachinesPage({super.key});
  @override
  ConsumerState<VirtualMachinesPage> createState() =>
      _VirtualMachinesPageState();
}

class _VirtualMachinesPageState extends ConsumerState<VirtualMachinesPage> {
  bool _reviewing = false;
  bool _loadingReview = false;
  String? _error;
  String _search = '';
  Future<void> _review(
    Future<VmReview> Function(AuthenticatedVirtualMachinesSession) action,
  ) async {
    final api = ref.read(virtualMachinesSessionProvider);
    final session = ref.read(dashboardActiveSessionProvider);
    if (api == null ||
        session == null ||
        _reviewing ||
        ref.read(virtualMachinesControllerProvider).locked) {
      return;
    }
    setState(() {
      _reviewing = true;
      _loadingReview = true;
      _error = null;
    });
    try {
      final review = await action(api);
      if (!mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        return;
      }
      setState(() => _loadingReview = false);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _VmSessionFence(
          session: session,
          child: _VmReviewDialog(
            review: review,
            server: session.endpoint ?? 'Authenticated server',
          ),
        ),
      );
      if (confirmed == true &&
          mounted &&
          identical(session, ref.read(dashboardActiveSessionProvider))) {
        await ref
            .read(virtualMachinesControllerProvider.notifier)
            .execute(session, review, review.targetName);
      }
    } on VmException catch (error) {
      if (mounted) setState(() => _error = error.userMessage);
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'VM review could not be loaded. No operation was submitted.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _reviewing = false;
          _loadingReview = false;
        });
      }
    }
  }

  Future<void> _configuration([VirtualMachine? vm]) async {
    final session = ref.read(dashboardActiveSessionProvider);
    final api = ref.read(virtualMachinesSessionProvider);
    if (api == null || _reviewing) return;
    setState(() {
      _reviewing = true;
      _loadingReview = true;
      _error = null;
    });
    VmConfiguration? config;
    try {
      final choices = await api.loadVmChoices();
      if (!mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        return;
      }
      setState(() => _loadingReview = false);
      config = await showDialog<VmConfiguration>(
        context: context,
        builder: (_) => _VmSessionFence(
          session: session,
          child: _VmConfigurationDialog(vm: vm, choices: choices),
        ),
      );
    } on VmException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } on Object {
      if (mounted) setState(() => _error = 'VM choices could not be loaded.');
    } finally {
      if (mounted) {
        setState(() {
          _reviewing = false;
          _loadingReview = false;
        });
      }
    }
    if (config != null &&
        mounted &&
        identical(session, ref.read(dashboardActiveSessionProvider))) {
      await _review(
        (api) => vm == null
            ? api.reviewVmCreate(config!)
            : api.reviewVmUpdate(vm, config!),
      );
    }
  }

  Future<void> _device(VirtualMachine vm, [VmDevice? device]) async {
    final session = ref.read(dashboardActiveSessionProvider);
    final api = ref.read(virtualMachinesSessionProvider);
    if (api == null || _reviewing) return;
    setState(() {
      _reviewing = true;
      _loadingReview = true;
      _error = null;
    });
    VmDeviceChange? change;
    try {
      final choices = await api.loadVmChoices();
      if (!mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        return;
      }
      setState(() => _loadingReview = false);
      change = await showDialog<VmDeviceChange>(
        context: context,
        builder: (_) => _VmSessionFence(
          session: session,
          child: _VmDeviceDialog(vm: vm, device: device, choices: choices),
        ),
      );
    } on VmException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } on Object {
      if (mounted) {
        setState(() => _error = 'Device choices could not be loaded.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _reviewing = false;
          _loadingReview = false;
        });
      }
    }
    if (change != null &&
        mounted &&
        identical(session, ref.read(dashboardActiveSessionProvider))) {
      await _review((api) => api.reviewVmDevice(vm, change!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(virtualMachinesSessionProvider);
    final capability = api?.virtualMachineCapabilities;
    final operation = ref.watch(virtualMachinesControllerProvider);
    final inventory = capability?.supported == true
        ? ref.watch(virtualMachinesInventoryProvider)
        : const AsyncValue<VmInventory>.loading();
    final locked = _reviewing || operation.locked || inventory.isLoading;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Virtual machines'),
        actions: [
          IconButton(
            tooltip: 'Refresh virtual machines',
            onPressed: locked
                ? null
                : () => ref.invalidate(virtualMachinesInventoryProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text('Virtual machines', style: TdTypography.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'Native guest configuration, reviewed devices and power controls. Backing disks are retained when definitions are removed.',
                ),
                const SizedBox(height: 16),
                if (operation.result != null && capability?.supported != true)
                  _VmOperationPanel(operation: operation),
                if (capability?.supported != true)
                  Text(
                    capability?.blockedReason ??
                        'Connect to manage virtual machines.',
                  )
                else ...[
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: locked || !capability!.allows('vm.create')
                            ? null
                            : _configuration,
                        icon: const Icon(Icons.add),
                        label: const Text('Create virtual machine'),
                      ),
                      if (!capability!.allows('vm.update'))
                        const Text('Read-only VM account'),
                    ],
                  ),
                  if (_loadingReview || inventory.isLoading)
                    const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(_error!),
                    ),
                  if (operation.result != null)
                    _VmOperationPanel(operation: operation),
                  const SizedBox(height: 16),
                  inventory.when(
                    skipLoadingOnRefresh: false,
                    loading: () => const SizedBox.shrink(),
                    error: (_, _) => const SizedBox.shrink(),
                    data: (data) => Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: VmStateChart(
                        states: data.machines.map((vm) => vm.state).toList(),
                      ),
                    ),
                  ),
                  TextField(
                    enabled: !locked,
                    decoration: const InputDecoration(
                      labelText: 'Filter virtual machines',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) => setState(() => _search = value),
                  ),
                  const SizedBox(height: 16),
                  inventory.when(
                    loading: () => const SizedBox.shrink(),
                    error: (_, _) => const Text(
                      'VM inventory could not be loaded. Check this connection and account permissions.',
                    ),
                    data: (data) {
                      final machines = data.machines
                          .where(
                            (vm) => vm.name.toLowerCase().contains(
                              _search.toLowerCase(),
                            ),
                          )
                          .toList();
                      if (machines.isEmpty) {
                        return const Text(
                          'No virtual machines match this view.',
                        );
                      }
                      return Column(
                        children: machines
                            .map(
                              (vm) => Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: TdPanel(
                                  title: vm.name,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      VmStateBadge(state: vm.state),
                                      const SizedBox(height: 8),
                                      Text(
                                        '${vm.configuration.memoryMiB} MiB · ${vm.configuration.vcpus * vm.configuration.cores * vm.configuration.threads} vCPUs',
                                      ),
                                      Text('ID ${vm.id} · ${vm.uuid}'),
                                      Text(
                                        '${vm.configuration.bootloader} · Autostart ${vm.configuration.autostart ? 'on' : 'off'} · Secure boot ${vm.secureBoot ? 'on' : 'off'}',
                                      ),
                                      if (vm
                                          .configuration
                                          .description
                                          .isNotEmpty)
                                        Text(vm.configuration.description),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          OutlinedButton(
                                            onPressed:
                                                locked ||
                                                    vm.state != 'STOPPED' ||
                                                    !capability.allows(
                                                      'vm.update',
                                                    )
                                                ? null
                                                : () => _configuration(vm),
                                            child: const Text('Edit settings'),
                                          ),
                                          OutlinedButton(
                                            onPressed:
                                                locked ||
                                                    vm.state != 'STOPPED' ||
                                                    !capability.allows(
                                                      'vm.device.create',
                                                    )
                                                ? null
                                                : () => _device(vm),
                                            child: const Text('Add device'),
                                          ),
                                          for (final action in VmAction.values)
                                            if (_actionVisible(vm, action) &&
                                                capability.allows(
                                                  _method(action),
                                                ))
                                              OutlinedButton(
                                                onPressed: locked
                                                    ? null
                                                    : () => _review(
                                                        (api) =>
                                                            api.reviewVmAction(
                                                              vm,
                                                              action,
                                                            ),
                                                      ),
                                                child: Text(_label(action)),
                                              ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      if (vm.devices.isEmpty)
                                        const Text(
                                          'No devices attached. Add a disk, installation ISO and network interface before starting.',
                                        ),
                                      for (final device in vm.devices)
                                        ListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: Text(
                                            '${device.type} · ${device.description}',
                                          ),
                                          subtitle: Text(
                                            'Order ${device.order} · Device ${device.id}',
                                          ),
                                          trailing: PopupMenuButton<String>(
                                            enabled:
                                                !locked &&
                                                vm.state == 'STOPPED',
                                            onSelected: (value) {
                                              if (value == 'remove') {
                                                _review(
                                                  (api) => api.reviewVmDevice(
                                                    vm,
                                                    VmDeviceChange.remove(
                                                      device: device,
                                                    ),
                                                  ),
                                                );
                                              } else {
                                                _device(vm, device);
                                              }
                                            },
                                            itemBuilder: (_) => [
                                              if (capability.allows(
                                                'vm.device.update',
                                              ))
                                                const PopupMenuItem(
                                                  value: 'edit',
                                                  child: Text(
                                                    'Edit / boot order',
                                                  ),
                                                ),
                                              if (capability.allows(
                                                'vm.device.delete',
                                              ))
                                                const PopupMenuItem(
                                                  value: 'remove',
                                                  child: Text(
                                                    'Detach, retain backing storage',
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      const Text(
                                        'Guest display/serial streaming, PCI/USB passthrough and backing-disk allocation are not part of this workspace yet.',
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool _actionVisible(VirtualMachine vm, VmAction action) => switch (action) {
  VmAction.start || VmAction.delete => vm.state == 'STOPPED',
  VmAction.stop ||
  VmAction.restart ||
  VmAction.suspend => vm.state == 'RUNNING',
  VmAction.resume => vm.state == 'SUSPENDED',
  VmAction.powerOff => vm.state == 'RUNNING' || vm.state == 'SUSPENDED',
};
String _label(VmAction action) => switch (action) {
  VmAction.powerOff => 'Power off',
  _ => '${action.name[0].toUpperCase()}${action.name.substring(1)}',
};
String _method(VmAction action) =>
    'vm.${action == VmAction.powerOff ? 'poweroff' : action.name}';

/// A profile change replaces the whole modal, including editable old values.
class _VmSessionFence extends ConsumerWidget {
  const _VmSessionFence({required this.session, required this.child});
  final Object? session;
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (identical(session, ref.watch(dashboardActiveSessionProvider))) {
      return child;
    }
    return AlertDialog(
      title: const Text('Connection changed'),
      content: const Text(
        'The previous VM review has been discarded. Reload on the current connection.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _VmOperationPanel extends ConsumerWidget {
  const _VmOperationPanel({required this.operation});
  final VirtualMachinesState operation;
  @override
  Widget build(BuildContext context, WidgetRef ref) => TdPanel(
    title: operation.connectionCurrent
        ? 'VM operation'
        : 'Original-server VM operation',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (operation.server != null)
          Text('Original server: ${operation.server}'),
        if (operation.target != null) Text('Reviewed VM: ${operation.target}'),
        if (operation.identity != null)
          Text('Reviewed identity: ${operation.identity}'),
        if (operation.result?.operation != null)
          Text('Original job ID: ${operation.result!.operation!.id}'),
        Text(operation.result!.userMessage),
        if (!operation.connectionCurrent)
          const Text(
            'This unresolved operation belongs to the original connection, not the currently selected server. Inspect that server before starting another operation there.',
          ),
        if (operation.pending)
          TextButton(
            onPressed: operation.busy
                ? null
                : ref
                      .read(virtualMachinesControllerProvider.notifier)
                      .checkProgress,
            child: const Text('Check progress'),
          ),
        if (operation.unknown && !operation.connectionCurrent)
          TextButton(
            onPressed: ref
                .read(virtualMachinesControllerProvider.notifier)
                .acknowledgeAfterReconnect,
            child: const Text('Acknowledge new connection'),
          ),
      ],
    ),
  );
}

class _VmReviewDialog extends StatefulWidget {
  const _VmReviewDialog({required this.review, required this.server});
  final VmReview review;
  final String server;
  @override
  State<_VmReviewDialog> createState() => _VmReviewDialogState();
}

class _VmReviewDialogState extends State<_VmReviewDialog> {
  String confirmation = '';
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.review.title),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Server: ${widget.server}'),
            Text(widget.review.identity),
            ...widget.review.changes.map(
              (line) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(line),
              ),
            ),
            const Divider(),
            ...widget.review.warnings.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(line),
              ),
            ),
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Type ${widget.review.targetName} to confirm',
              ),
              onChanged: (value) => setState(() => confirmation = value),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: confirmation == widget.review.targetName
            ? () => Navigator.pop(context, true)
            : null,
        child: const Text('Confirm reviewed change'),
      ),
    ],
  );
}

class _VmConfigurationDialog extends StatefulWidget {
  const _VmConfigurationDialog({required this.vm, required this.choices});
  final VirtualMachine? vm;
  final VmChoices choices;
  @override
  State<_VmConfigurationDialog> createState() => _VmConfigurationDialogState();
}

class _VmConfigurationDialogState extends State<_VmConfigurationDialog> {
  final form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields;
  late bool autostart, display, hyperv, tpm;
  late String boot, mode, time;
  String? cpuModel;
  @override
  void initState() {
    super.initState();
    final c =
        widget.vm?.configuration ??
        const VmConfiguration(name: '', memoryMiB: 2048);
    fields = {
      for (final e in {
        'Name': c.name,
        'Description': c.description,
        'Memory (MiB)': '${c.memoryMiB}',
        'Minimum memory (MiB, optional)': c.minMemoryMiB?.toString() ?? '',
        'CPU sockets': '${c.vcpus}',
        'Cores per socket': '${c.cores}',
        'Threads per core': '${c.threads}',
        'Shutdown timeout (seconds)': '${c.shutdownTimeout}',
      }.entries)
        e.key: TextEditingController(text: e.value),
    };
    autostart = c.autostart;
    display = c.ensureDisplayDevice;
    hyperv = c.hypervEnlightenments;
    tpm = c.trustedPlatformModule;
    boot = c.bootloader;
    mode = c.cpuMode;
    time = c.time;
    cpuModel = c.cpuModel;
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.vm == null ? 'Create VM · settings' : 'Edit VM settings',
    ),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 14,
            children: [
              Text(
                'Host limit ${widget.choices.maximumVcpus} vCPUs · presently available ${(widget.choices.availableMemoryBytes / 1048576).floor()} MiB. Availability is volatile.',
              ),
              if (widget.vm == null)
                const Text(
                  'Step 1: create a stopped VM definition. Step 2: add individually reviewed disks, ISO and network devices.',
                ),
              for (final e in fields.entries)
                TextFormField(
                  controller: e.value,
                  decoration: InputDecoration(labelText: e.key),
                  keyboardType: e.key == 'Name' || e.key == 'Description'
                      ? TextInputType.text
                      : TextInputType.number,
                  validator: (v) {
                    if (e.key == 'Description' ||
                        e.key.startsWith('Minimum') && (v ?? '').isEmpty) {
                      return null;
                    }
                    if (e.key == 'Name') {
                      return RegExp(r'^[a-zA-Z_0-9]{1,150}$').hasMatch(v ?? '')
                          ? null
                          : 'Use letters, digits and underscore';
                    }
                    return int.tryParse(v ?? '') != null
                        ? null
                        : 'Enter a whole number';
                  },
                ),
              _dropdown(
                'CPU mode',
                mode,
                const ['HOST-MODEL', 'HOST-PASSTHROUGH', 'CUSTOM'],
                (v) => setState(() {
                  mode = v;
                  cpuModel = null;
                }),
              ),
              if (mode == 'CUSTOM')
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: cpuModel,
                  decoration: const InputDecoration(
                    labelText: 'CPU model (optional)',
                  ),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('Server default'),
                    ),
                    ...widget.choices.cpuModels.map(
                      (v) => DropdownMenuItem(value: v, child: Text(v)),
                    ),
                  ],
                  onChanged: (v) => setState(() => cpuModel = v),
                ),
              _dropdown('Boot firmware', boot, const [
                'UEFI',
                'UEFI_CSM',
              ], (v) => setState(() => boot = v)),
              _dropdown('Guest clock', time, const [
                'LOCAL',
                'UTC',
              ], (v) => setState(() => time = v)),
              SwitchListTile(
                title: const Text('Autostart on server boot'),
                value: autostart,
                onChanged: (v) => setState(() => autostart = v),
              ),
              SwitchListTile(
                title: const Text('Ensure guest display device'),
                value: display,
                onChanged: (v) => setState(() => display = v),
              ),
              SwitchListTile(
                title: const Text('Hyper-V enlightenments'),
                value: hyperv,
                onChanged: (v) => setState(() => hyperv = v),
              ),
              SwitchListTile(
                title: const Text('Trusted platform module'),
                value: tpm,
                onChanged: (v) => setState(() => tpm = v),
              ),
              const Text(
                'Secure-boot/OVMF selection and CPU affinity are preserved on edits; they are not changed by this form.',
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (!form.currentState!.validate()) return;
          Navigator.pop(
            context,
            VmConfiguration(
              name: fields['Name']!.text,
              description: fields['Description']!.text,
              memoryMiB: int.parse(fields['Memory (MiB)']!.text),
              minMemoryMiB: int.tryParse(
                fields['Minimum memory (MiB, optional)']!.text,
              ),
              vcpus: int.parse(fields['CPU sockets']!.text),
              cores: int.parse(fields['Cores per socket']!.text),
              threads: int.parse(fields['Threads per core']!.text),
              shutdownTimeout: int.parse(
                fields['Shutdown timeout (seconds)']!.text,
              ),
              autostart: autostart,
              bootloader: boot,
              cpuMode: mode,
              cpuModel: cpuModel,
              time: time,
              ensureDisplayDevice: display,
              hypervEnlightenments: hyperv,
              trustedPlatformModule: tpm,
            ),
          );
        },
        child: const Text('Review settings'),
      ),
    ],
  );
}

Widget _dropdown(
  String label,
  String value,
  List<String> choices,
  ValueChanged<String> changed,
) => DropdownButtonFormField<String>(
  isExpanded: true,
  initialValue: value,
  decoration: InputDecoration(labelText: label),
  items: choices
      .map(
        (v) => DropdownMenuItem(
          value: v,
          child: Text(v, overflow: TextOverflow.ellipsis),
        ),
      )
      .toList(),
  onChanged: (v) {
    if (v != null) changed(v);
  },
);

class _VmDeviceDialog extends StatefulWidget {
  const _VmDeviceDialog({
    required this.vm,
    required this.device,
    required this.choices,
  });
  final VirtualMachine vm;
  final VmDevice? device;
  final VmChoices choices;
  @override
  State<_VmDeviceDialog> createState() => _VmDeviceDialogState();
}

class _VmDeviceDialogState extends State<_VmDeviceDialog> {
  late String kind;
  String adapter = 'VIRTIO';
  VmDeviceOption? option;
  final path = TextEditingController();
  late final TextEditingController order;
  @override
  void initState() {
    super.initState();
    kind = widget.device == null ? 'DISK' : 'ORDER';
    order = TextEditingController(
      text:
          '${widget.device?.order ?? (widget.vm.devices.isEmpty ? 1000 : widget.vm.devices.map((d) => d.order).reduce((a, b) => a > b ? a : b) + 1)}',
    );
    path.text = widget.device?.attributes['path'] as String? ?? '';
  }

  @override
  void dispose() {
    path.dispose();
    order.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.device == null ? 'Add VM device' : 'Edit VM device'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 14,
          children: [
            _dropdown(
              'Device type',
              kind,
              widget.device == null
                  ? const ['DISK', 'NIC', 'CDROM', 'DISPLAY']
                  : [
                      'ORDER',
                      if (const [
                        'DISK',
                        'NIC',
                        'CDROM',
                      ].contains(widget.device!.type))
                        widget.device!.type,
                    ],
              (v) => setState(() {
                kind = v;
                option = null;
                adapter = 'VIRTIO';
              }),
            ),
            if (kind == 'DISK' || kind == 'NIC') ...[
              DropdownButtonFormField<VmDeviceOption>(
                initialValue: option,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: kind == 'DISK'
                      ? 'Unused existing zvol'
                      : 'Host interface',
                ),
                items:
                    (kind == 'DISK'
                            ? widget.choices.disks
                            : widget.choices.interfaces)
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text(
                              v.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                onChanged: (v) => setState(() => option = v),
              ),
              _dropdown(
                'Adapter',
                adapter,
                kind == 'DISK'
                    ? const ['VIRTIO', 'AHCI']
                    : const ['VIRTIO', 'E1000'],
                (v) => setState(() => adapter = v),
              ),
            ],
            if (kind == 'DISK')
              const Text(
                'Only currently unused existing zvols are listed. Create backing storage in the native storage workspace first.',
              ),
            if (kind == 'CDROM')
              TextField(
                controller: path,
                decoration: const InputDecoration(
                  labelText: 'Existing ISO path (/mnt/...)',
                ),
                onChanged: (_) => setState(() {}),
              ),
            if (kind == 'DISPLAY')
              const Text(
                'Loopback-only SPICE display; no web listener. This does not open an embedded console.',
              ),
            TextField(
              controller: order,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Device / boot order (unused number)',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed:
            int.tryParse(order.text) == null ||
                (kind == 'DISK' || kind == 'NIC') && option == null ||
                kind == 'CDROM' && path.text.isEmpty
            ? null
            : () {
                final n = int.parse(order.text);
                final change = switch (kind) {
                  'DISK' => VmDeviceChange.disk(
                    disk: option!,
                    device: widget.device,
                    order: n,
                    adapter: adapter,
                  ),
                  'NIC' => VmDeviceChange.nic(
                    interface: option!,
                    device: widget.device,
                    order: n,
                    adapter: adapter,
                  ),
                  'CDROM' => VmDeviceChange.cdrom(
                    isoPath: path.text,
                    device: widget.device,
                    order: n,
                  ),
                  'DISPLAY' => VmDeviceChange.display(order: n),
                  _ => VmDeviceChange.order(device: widget.device, order: n),
                };
                Navigator.pop(context, change);
              },
        child: const Text('Review device'),
      ),
    ],
  );
}
