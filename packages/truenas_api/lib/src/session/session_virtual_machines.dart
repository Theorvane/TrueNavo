part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedVirtualMachinesSession {
  VmCapabilities get virtualMachineCapabilities;
  Future<VmInventory> loadVirtualMachines();
  Future<VmChoices> loadVmChoices();
  Future<VmReview> reviewVmCreate(VmConfiguration configuration);
  Future<VmReview> reviewVmUpdate(
    VirtualMachine vm,
    VmConfiguration configuration,
  );
  Future<VmReview> reviewVmAction(VirtualMachine vm, VmAction action);
  Future<VmReview> reviewVmDevice(VirtualMachine vm, VmDeviceChange change);
  Future<VmOperationResult> executeVmReview(
    VmReview review, {
    required String confirmation,
  });
  Future<VmOperationResult> pollVmOperation(VmOperationHandle operation);
}

final class VmCapabilities {
  const VmCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.methods,
  });
  const VmCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      methods = const {};
  final bool connected, versionSupported;
  final Set<String> methods;
  bool get supported =>
      connected && versionSupported && methods.contains('vm.query');
  bool allows(String method) => supported && methods.contains(method);
  String? get blockedReason => !connected
      ? 'Connect to manage virtual machines.'
      : !versionSupported
      ? 'Native VM management requires stable TrueNAS 25.10.'
      : !supported
      ? 'VM discovery is unavailable to this account.'
      : null;
}

final class VmConfiguration {
  const VmConfiguration({
    required this.name,
    required this.memoryMiB,
    this.description = '',
    this.vcpus = 1,
    this.cores = 1,
    this.threads = 1,
    this.autostart = false,
    this.bootloader = 'UEFI',
    this.cpuMode = 'HOST-MODEL',
    this.cpuModel,
    this.minMemoryMiB,
    this.shutdownTimeout = 90,
    this.time = 'LOCAL',
    this.ensureDisplayDevice = true,
    this.hypervEnlightenments = false,
    this.trustedPlatformModule = false,
  });
  final String name, description, bootloader, cpuMode, time;
  final String? cpuModel;
  final int memoryMiB, vcpus, cores, threads, shutdownTimeout;
  final int? minMemoryMiB;
  final bool autostart,
      ensureDisplayDevice,
      hypervEnlightenments,
      trustedPlatformModule;
  Map<String, Object?> _wire() => {
    'name': name,
    'description': description,
    'memory': memoryMiB,
    'min_memory': minMemoryMiB,
    'vcpus': vcpus,
    'cores': cores,
    'threads': threads,
    'autostart': autostart,
    'bootloader': bootloader,
    'cpu_mode': cpuMode,
    'cpu_model': cpuModel,
    'shutdown_timeout': shutdownTimeout,
    'time': time,
    'ensure_display_device': ensureDisplayDevice,
    'hyperv_enlightenments': hypervEnlightenments,
    'trusted_platform_module': trustedPlatformModule,
  };
}

final class VirtualMachine {
  VirtualMachine({
    required this.id,
    required this.uuid,
    required this.configuration,
    required this.state,
    required List<VmDevice> devices,
    this.secureBoot = false,
  }) : devices = List.unmodifiable(devices);
  final int id;
  final String uuid, state;
  final VmConfiguration configuration;
  final List<VmDevice> devices;
  final bool secureBoot;
  String get name => configuration.name;
}

/// Only explicit non-secret device fields are projected from vm.query.
final class VmDevice {
  VmDevice({
    required this.id,
    required this.vmId,
    required this.type,
    required this.order,
    required Map<String, Object?> attributes,
  }) : attributes = Map.unmodifiable(attributes);
  final int id, vmId, order;
  final String type;
  final Map<String, Object?> attributes;
  String get description =>
      '${attributes['path'] ?? attributes['nic_attach'] ?? attributes['type'] ?? type}';
}

final class VmInventory {
  VmInventory({required List<VirtualMachine> machines})
    : machines = List.unmodifiable(machines);
  final List<VirtualMachine> machines;
}

final class VmDeviceOption {
  const VmDeviceOption({
    required this.kind,
    required this.value,
    required this.label,
  });
  final String kind, value, label;
}

final class VmChoices {
  VmChoices({
    required this.maximumVcpus,
    required this.availableMemoryBytes,
    required List<String> cpuModels,
    required List<VmDeviceOption> disks,
    required List<VmDeviceOption> interfaces,
  }) : cpuModels = List.unmodifiable(cpuModels),
       disks = List.unmodifiable(disks),
       interfaces = List.unmodifiable(interfaces);
  final int maximumVcpus, availableMemoryBytes;
  final List<String> cpuModels;
  final List<VmDeviceOption> disks, interfaces;
}

enum VmAction { start, stop, restart, powerOff, suspend, resume, delete }

enum VmDeviceChangeKind { disk, nic, cdrom, display, order, remove }

final class VmDeviceChange {
  const VmDeviceChange.disk({
    required VmDeviceOption disk,
    this.device,
    this.order = 1001,
    this.adapter = 'VIRTIO',
  }) : kind = VmDeviceChangeKind.disk,
       option = disk,
       path = null;
  const VmDeviceChange.nic({
    required VmDeviceOption interface,
    this.device,
    this.order = 1002,
    this.adapter = 'VIRTIO',
  }) : kind = VmDeviceChangeKind.nic,
       option = interface,
       path = null;
  const VmDeviceChange.cdrom({
    required String isoPath,
    this.device,
    this.order = 1000,
  }) : kind = VmDeviceChangeKind.cdrom,
       option = null,
       path = isoPath,
       adapter = '';
  const VmDeviceChange.display({this.order = 1002})
    : kind = VmDeviceChangeKind.display,
      option = null,
      path = null,
      adapter = '',
      device = null;
  const VmDeviceChange.order({required this.device, required this.order})
    : kind = VmDeviceChangeKind.order,
      option = null,
      path = null,
      adapter = '';
  const VmDeviceChange.remove({required this.device})
    : kind = VmDeviceChangeKind.remove,
      option = null,
      path = null,
      order = 0,
      adapter = '';
  final VmDeviceChangeKind kind;
  final VmDevice? device;
  final VmDeviceOption? option;
  final String? path;
  final String adapter;
  final int order;
}

final class VmReview {
  VmReview({
    required this.title,
    required this.targetName,
    required this.identity,
    required List<String> changes,
    required List<String> warnings,
  }) : changes = List.unmodifiable(changes),
       warnings = List.unmodifiable(warnings);
  final String title, targetName, identity;
  final List<String> changes, warnings;
}

enum VmOperationOutcome { rejected, submitted, running, verified, unknown }

final class VmOperationHandle {
  const VmOperationHandle({required this.id, required this.targetName});
  final int id;
  final String targetName;
}

final class VmOperationResult {
  const VmOperationResult({required this.outcome, this.operation});
  final VmOperationOutcome outcome;
  final VmOperationHandle? operation;
  String get userMessage => switch (outcome) {
    VmOperationOutcome.rejected =>
      'The operation was not submitted. Reload and review current VM details.',
    VmOperationOutcome.submitted || VmOperationOutcome.running => 'The VM operation is pending. Only its own job and readback will be checked.',
    VmOperationOutcome.verified =>
      'The requested VM change was independently verified.',
    VmOperationOutcome.unknown => 'The outcome is uncertain. Further writes are locked until reconnect; inspect the VM before any new action.',
  };
}

enum VmExceptionReason {
  disconnected,
  unsupported,
  unavailable,
  busy,
  stale,
  invalidInput,
  invalidResponse,
}

final class VmException implements Exception {
  const VmException(this.reason);
  final VmExceptionReason reason;
  String get userMessage => switch (reason) {
    VmExceptionReason.disconnected =>
      'The selected connection is no longer current.',
    VmExceptionReason.unsupported =>
      'This workflow requires stable TrueNAS 25.10.',
    VmExceptionReason.unavailable =>
      'The required VM method is unavailable or the read failed.',
    VmExceptionReason.busy => 'Another server operation is pending.',
    VmExceptionReason.stale =>
      'VM identity, settings or dependencies changed. Reload and review again.',
    VmExceptionReason.invalidInput =>
      'Review the VM values, supported choices and current power state.',
    VmExceptionReason.invalidResponse =>
      'The server returned incomplete or unexpected VM details.',
  };
  @override
  String toString() => userMessage;
}

final class _VmObservation {
  const _VmObservation(this.fingerprint, this.fields, this.devices);
  final String fingerprint;
  final Map<String, String> fields;
  final Map<int, Map<String, String>> devices;
}

final class _VmPlan {
  _VmPlan({
    required this.method,
    required this.arguments,
    required this.target,
    this.vm,
    this.configuration,
    this.action,
    this.deviceChange,
    this.resourceFingerprint,
  });
  final String method, target;
  final List<Object?> arguments;
  final VirtualMachine? vm;
  final VmConfiguration? configuration;
  final VmAction? action;
  final VmDeviceChange? deviceChange;
  final String? resourceFingerprint;
  int? createdId;
  String? createdUuid;
  int? deviceId;
}

final class _SessionVirtualMachines {
  _SessionVirtualMachines({
    required this.client,
    required ServerSummary summary,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherBusy,
    required this.requestTimeout,
  }) : methods = Set.unmodifiable(summary.availableMethodNames),
       versionSupported =
           _managementVersion(summary.version) == _ManagementVersion.v2510;
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherBusy;
  final Duration requestTimeout;
  final Set<String> methods;
  final bool versionSupported;
  bool _writing = false, _uncertain = false, _reading = false, _polling = false;
  int _queued = 0;
  Future<void> _tail = Future.value();
  VmOperationHandle? _active;
  final _machines = <VirtualMachine, _VmObservation>{};
  final _options = <VmDeviceOption>{};
  final _reviews = <VmReview, _VmPlan>{};
  final _jobs = <VmOperationHandle, _VmPlan>{};
  bool get isBusy => _writing || _uncertain || _active != null;
  VmCapabilities get capabilities => VmCapabilities(
    connected: isCurrent(),
    versionSupported: versionSupported,
    methods: methods,
  );
  void _guard([String? method]) {
    if (!isCurrent()) throw const VmException(VmExceptionReason.disconnected);
    if (!versionSupported) {
      throw const VmException(VmExceptionReason.unsupported);
    }
    if (!methods.contains('vm.query') ||
        method != null && !methods.contains(method)) {
      throw const VmException(VmExceptionReason.unavailable);
    }
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    _guard(method);
    final result = await client
        .call(method, id: nextId(), params: args)
        .timeout(requestTimeout);
    _guard();
    return result;
  }

  Future<T> _read<T>(Future<T> Function() action) async {
    _guard();
    if (_writing || _polling || _queued >= 8) {
      throw const VmException(VmExceptionReason.busy);
    }
    _queued++;
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      _guard();
      if (_writing || _polling) throw const VmException(VmExceptionReason.busy);
      _reading = true;
      return await action();
    } on VmException {
      rethrow;
    } on Object {
      throw const VmException(VmExceptionReason.unavailable);
    } finally {
      _reading = false;
      _queued--;
      done.complete();
    }
  }

  Future<VmInventory> inventory() =>
      _read(() async => VmInventory(machines: await _inventory()));
  Future<List<VirtualMachine>> _inventory({int? id}) async {
    final result = await _call('vm.query', [
      if (id == null)
        <Object?>[]
      else
        [
          ['id', '=', id],
        ],
      {'limit': id == null ? 257 : 2},
    ]);
    if (result is! List || result.length > (id == null ? 256 : 1)) {
      throw const VmException(VmExceptionReason.invalidResponse);
    }
    final machines = result.map(_parse).toList();
    if (machines.map((v) => v.id).toSet().length != machines.length ||
        machines.map((v) => v.uuid).toSet().length != machines.length) {
      throw const VmException(VmExceptionReason.invalidResponse);
    }
    return machines;
  }

  VirtualMachine _parse(Object? value) {
    if (value is! Map ||
        !_vmInt(value['id'], 1) ||
        !_vmText(value['uuid'], 64) ||
        !RegExp(r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')
            .hasMatch(value['uuid'] as String) ||
        value['status'] is! Map ||
        !_vmText((value['status'] as Map)['state'], 32) ||
        value['devices'] is! List ||
        (value['devices'] as List).length > 128 ||
        !_appsExactConfigNumbers(value)) {
      throw const VmException(VmExceptionReason.invalidResponse);
    }
    final config = _vmConfig(value);
    final devices = <VmDevice>[];
    for (final raw in value['devices'] as List) {
      if (raw is! Map ||
          !_vmInt(raw['id'], 1) ||
          raw['vm'] != value['id'] ||
          !_vmInt(raw['order'], 0) ||
          raw['attributes'] is! Map ||
          !_vmText((raw['attributes'] as Map)['dtype'], 20)) {
        throw const VmException(VmExceptionReason.invalidResponse);
      }
      final attrs = raw['attributes'] as Map;
      final safe = <String, Object?>{};
      for (final key in const [
        'path',
        'nic_attach',
        'type',
        'resolution',
        'port',
        'web_port',
        'bind',
        'web',
        'mac',
        'iotype',
      ]) {
        final v = attrs[key];
        if (v is String && _vmText(v, 2048) || v is bool || v is int) {
          safe[key] = v;
        }
      }
      devices.add(
        VmDevice(
          id: raw['id'] as int,
          vmId: value['id'] as int,
          type: attrs['dtype'] as String,
          order: raw['order'] as int,
          attributes: safe,
        ),
      );
    }
    if (devices.map((d) => d.id).toSet().length != devices.length) {
      throw const VmException(VmExceptionReason.invalidResponse);
    }
    final vm = VirtualMachine(
      id: value['id'] as int,
      uuid: value['uuid'] as String,
      configuration: config,
      state: (value['status'] as Map)['state'] as String,
      devices: devices,
      secureBoot: value['enable_secure_boot'] == true,
    );
    final fingerprint = _appsFingerprint({
      for (final entry in value.entries)
        if (entry.key != 'status' && entry.key != 'display_available')
          entry.key: entry.value,
    });
    if (_machines.length >= 2048) _machines.remove(_machines.keys.first);
    _machines[vm] = _VmObservation(
      fingerprint,
      {
        for (final e in value.entries)
          if (e.key != 'status' && e.key != 'display_available')
            e.key as String: _appsFingerprint(e.value),
      },
      {
        for (final d in value['devices'] as List)
          (d as Map)['id'] as int: {
            for (final e in (d['attributes'] as Map).entries)
              e.key as String: _appsFingerprint(e.value),
            '@order': _appsFingerprint(d['order']),
          },
      },
    );
    return vm;
  }

  Future<VirtualMachine> _fresh(
    VirtualMachine vm, {
    bool stopped = false,
  }) async {
    final observation = _machines[vm];
    if (observation == null) throw const VmException(VmExceptionReason.stale);
    final rows = await _inventory(id: vm.id);
    if (rows.length != 1 ||
        rows.single.uuid != vm.uuid ||
        rows.single.state != vm.state ||
        _machines[rows.single]!.fingerprint != observation.fingerprint) {
      throw const VmException(VmExceptionReason.stale);
    }
    if (stopped && rows.single.state != 'STOPPED') {
      throw const VmException(VmExceptionReason.invalidInput);
    }
    return rows.single;
  }

  Future<VmChoices> choices() => _read(_choices);
  Future<Map<String, String>> _choiceMap(String method) async {
    final raw = await _call(method, const []);
    if (raw is! Map ||
        raw.length > 4096 ||
        raw.entries.any(
          (e) => !_vmText(e.key, 2048) || !_vmText(e.value, 2048),
        )) {
      throw const VmException(VmExceptionReason.invalidResponse);
    }
    return raw.map((k, v) => MapEntry(k as String, v as String));
  }

  Future<VmChoices> _choices() async {
    final maximum = await _call('vm.maximum_supported_vcpus', const []);
    final memory = await _call('vm.get_available_memory', const [false]);
    if (!_vmInt(maximum, 1, 4096) || !_vmInt(memory, 0)) {
      throw const VmException(VmExceptionReason.invalidResponse);
    }
    final models = methods.contains('vm.cpu_model_choices')
        ? await _choiceMap('vm.cpu_model_choices')
        : <String, String>{};
    final disks = methods.contains('vm.device.disk_choices')
        ? await _choiceMap('vm.device.disk_choices')
        : <String, String>{};
    final interfaces = methods.contains('vm.device.nic_attach_choices')
        ? await _choiceMap('vm.device.nic_attach_choices')
        : <String, String>{};
    final used = (await _inventory())
        .expand((vm) => vm.devices)
        .where((d) => d.type == 'DISK' || d.type == 'RAW')
        .map((d) => d.attributes['path'])
        .toSet();
    final diskOptions = [
      for (final e in disks.entries)
        if (!used.contains(e.key) && e.key.startsWith('/dev/zvol/'))
          VmDeviceOption(kind: 'DISK', value: e.key, label: e.value),
    ];
    final nicOptions = [
      for (final e in interfaces.entries)
        VmDeviceOption(kind: 'NIC', value: e.key, label: e.value),
    ];
    _options.addAll([...diskOptions, ...nicOptions]);
    if (_options.length > 8192) {
      _options.clear();
      _options.addAll([...diskOptions, ...nicOptions]);
    }
    return VmChoices(
      maximumVcpus: maximum as int,
      availableMemoryBytes: memory as int,
      cpuModels: models.keys.toList(),
      disks: diskOptions,
      interfaces: nicOptions,
    );
  }

  Future<void> _validateConfig(
    VmConfiguration config, {
    VirtualMachine? vm,
  }) async {
    if (!_vmValidConfig(config)) {
      throw const VmException(VmExceptionReason.invalidInput);
    }
    final choices = await _choices();
    if (config.vcpus * config.cores * config.threads > choices.maximumVcpus ||
        config.cpuModel != null &&
            !choices.cpuModels.contains(config.cpuModel)) {
      throw const VmException(VmExceptionReason.invalidInput);
    }
    if ((await _inventory()).any(
      (v) => v.name == config.name && v.id != vm?.id,
    )) {
      throw const VmException(VmExceptionReason.stale);
    }
  }

  VmReview _issue(
    _VmPlan plan,
    String title,
    List<String> changes,
    List<String> warnings,
  ) {
    if (_reviews.length >= 64) _reviews.remove(_reviews.keys.first);
    final review = VmReview(
      title: title,
      targetName: plan.target,
      identity: plan.vm?.uuid ?? 'New VM; UUID assigned by server',
      changes: changes,
      warnings: [
        ...warnings,
        'The review is single-use. Concurrent external changes cannot be atomically excluded by this API.',
      ],
    );
    _reviews[review] = plan;
    return review;
  }

  Future<VmReview> reviewCreate(VmConfiguration config) => _read(() async {
    _guard('vm.create');
    await _validateConfig(config);
    return _issue(
      _VmPlan(
        method: 'vm.create',
        arguments: [config._wire()],
        target: config.name,
        configuration: config,
      ),
      'Create virtual machine',
      _configChanges(null, config),
      [
        'Creates a VM definition without storage or network devices. Attach each device in a separate reviewed step.',
        if (config.autostart) 'Autostart enables boot on a future server startup, even before device setup is complete.',
      ],
    );
  });
  Future<VmReview> reviewUpdate(VirtualMachine vm, VmConfiguration config) =>
      _read(() async {
        _guard('vm.update');
        await _fresh(vm, stopped: true);
        await _validateConfig(config, vm: vm);
        final changes = _configChanges(vm.configuration, config);
        if (changes.isEmpty) {
          throw const VmException(VmExceptionReason.invalidInput);
        }
        final old = vm.configuration._wire();
        final patch = {
          for (final e in config._wire().entries)
            if (!_adminEqual(e.value, old[e.key])) e.key: e.value,
        };
        return _issue(
          _VmPlan(
            method: 'vm.update',
            arguments: [vm.id, patch],
            target: vm.name,
            vm: vm,
            configuration: config,
          ),
          'Change virtual machine settings',
          changes,
          [
            'Only the reviewed fields change. Devices, UUID, secure boot, CPU affinity and unedited advanced settings are preserved.',
            if (vm.name != config.name) 'Renaming also renames the VM domain and UEFI state; a partial server failure requires manual inspection.',
          ],
        );
      });
  Future<VmReview> reviewAction(
    VirtualMachine vm,
    VmAction action,
  ) => _read(() async {
    final method = _vmMethod(action);
    _guard(method);
    if (action == VmAction.stop || action == VmAction.restart) {
      _guard('core.get_jobs');
    }
    await _fresh(vm);
    _validateState(vm, action);
    if (action == VmAction.start) await _memoryCheck(vm);
    final storage = _vmRunsGuest(action) ? await _storageFingerprint(vm) : null;
    return _issue(
      _VmPlan(
        method: method,
        arguments: _actionArgs(vm, action),
        target: vm.name,
        vm: vm,
        action: action,
        resourceFingerprint: storage,
      ),
      '${_vmActionLabel(action)} virtual machine',
      [
        '${vm.name} · ID ${vm.id} · ${vm.uuid}',
        'Current state: ${vm.state}',
        if (action == VmAction.delete)
          ...vm.devices.map((d) => 'Detach ${d.type}: ${d.description}'),
      ],
      [
        switch (action) {
          VmAction.delete => 'Permanently removes the VM definition and its device definitions/UEFI state. All zvols and backing files are retained; no storage cleanup is requested. If an external administrator starts this guest after the final state check, the server can power it off during deletion.',
          VmAction.powerOff => 'Immediately removes guest power. Unsaved data can be lost and guest filesystems can be damaged.',
          VmAction.restart => 'The server forcibly powers off an unresponsive guest after its configured timeout, then starts with memory overcommit enabled. Unsaved data can be lost and host memory can be overcommitted.',
          VmAction.stop => 'Sends graceful shutdown only; it does not force poweroff after timeout. An unresponsive guest may remain running.',
          VmAction.start => 'Starts the guest with overcommit disabled. Guest applications can modify attached disks and access the selected network.',
          VmAction.suspend =>
            'Pauses guest execution; allocated resources remain in use.',
          VmAction.resume =>
            'Resumes guest execution and access to its storage and network.',
        },
      ],
    );
  });
  void _validateState(VirtualMachine vm, VmAction action) {
    final allowed = switch (action) {
      VmAction.start || VmAction.delete => vm.state == 'STOPPED',
      VmAction.stop ||
      VmAction.restart ||
      VmAction.suspend => vm.state == 'RUNNING',
      VmAction.resume => vm.state == 'SUSPENDED',
      VmAction.powerOff => vm.state == 'RUNNING' || vm.state == 'SUSPENDED',
    };
    if (!allowed) throw const VmException(VmExceptionReason.invalidInput);
  }

  Future<void> _memoryCheck(VirtualMachine vm) async {
    final raw = await _call('vm.get_available_memory', const [false]);
    if (!_vmInt(raw, 0)) {
      throw const VmException(VmExceptionReason.invalidResponse);
    }
    if ((vm.configuration.minMemoryMiB ?? vm.configuration.memoryMiB) *
            1048576 >
        (raw as int)) {
      throw const VmException(VmExceptionReason.invalidInput);
    }
  }

  Future<String> _zvolFingerprint(String path) async {
    if (!path.startsWith('/dev/zvol/') || path.contains('..')) {
      throw const VmException(VmExceptionReason.invalidInput);
    }
    final name = path.substring('/dev/zvol/'.length).replaceAll('+', ' ');
    final raw = await _call('pool.dataset.query', [
      [
        ['id', '=', name],
      ],
      {
        'limit': 2,
        'extra': {
          'flat': true,
          'retrieve_children': false,
          'retrieve_user_props': false,
          'properties': ['guid', 'creation', 'volsize', 'readonly'],
        },
      },
    ]);
    if (raw is! List || raw.length != 1 || raw.single is! Map) {
      throw const VmException(VmExceptionReason.invalidResponse);
    }
    final row = raw.single as Map;
    String? property(String key) {
      final v = row[key];
      return v is Map && v['rawvalue'] is String
          ? v['rawvalue'] as String
          : null;
    }

    final guid = property('guid');
    final creation = property('creation');
    final size = property('volsize');
    if (row['id'] != name ||
        row['type'] != 'VOLUME' ||
        row['locked'] != false ||
        guid == null ||
        !RegExp(r'^[0-9]{1,20}$').hasMatch(guid) ||
        creation == null ||
        !RegExp(r'^[0-9]{1,20}$').hasMatch(creation) ||
        size == null ||
        !RegExp(r'^[0-9]{1,20}$').hasMatch(size) ||
        property('readonly') != 'off') {
      throw const VmException(VmExceptionReason.invalidResponse);
    }
    return _appsFingerprint([name, guid, creation, size]);
  }

  Future<String> _storageFingerprint(VirtualMachine vm) async {
    final identities = <String>[];
    final directoryProofs = <String, List<Object?>>{};
    for (final device in vm.devices) {
      if (device.type == 'DISK') {
        final path = device.attributes['path'];
        if (path is! String) {
          throw const VmException(VmExceptionReason.invalidResponse);
        }
        identities.add(await _zvolFingerprint(path));
      } else if (device.type == 'RAW' || device.type == 'CDROM') {
        final path = device.attributes['path'];
        if (path is! String) {
          throw const VmException(VmExceptionReason.invalidResponse);
        }
        // Running guest disk contents are mutable; inode/mount/size are identity.
        identities.add(
          await _fileFingerprint(
            path,
            includeContentTimestamps: false,
            directoryProofs: directoryProofs,
          ),
        );
      }
    }
    return _appsFingerprint(identities);
  }

  /// stat.realpath resolves a symlink only when the leaf itself is a link in
  /// TS-25.10.1. Every ancestor must therefore be observed as a real DIRECTORY.
  /// This is a bounded observation, not an atomic openat/O_NOFOLLOW guarantee.
  Future<String> _fileFingerprint(
    String path, {
    required bool includeContentTimestamps,
    Map<String, List<Object?>>? directoryProofs,
  }) async {
    final parts = path.split('/').skip(1).toList();
    if (!_vmText(path, 2048) ||
        !path.startsWith('/mnt/') ||
        path.contains(RegExp(r'[{}]')) ||
        parts.length < 3 ||
        parts.length > 32 ||
        parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const VmException(VmExceptionReason.invalidInput);
    }
    final observed = directoryProofs ?? <String, List<Object?>>{};
    final ancestors = <List<Object?>>[];
    var prefix = '';
    for (var i = 0; i < parts.length - 1; i++) {
      prefix += '/${parts[i]}';
      if (!observed.containsKey(prefix)) {
        if (observed.length >= 64) {
          throw const VmException(VmExceptionReason.invalidInput);
        }
        final stat = await _call('filesystem.stat', [prefix]);
        if (stat is! Map ||
            stat['type'] != 'DIRECTORY' ||
            stat['realpath'] != prefix ||
            !_vmInt(stat['inode'], 0) ||
            !_vmInt(stat['dev'], 0) ||
            !_vmInt(stat['mount_id'], 0)) {
          throw const VmException(VmExceptionReason.invalidResponse);
        }
        observed[prefix] = [
          prefix,
          stat['inode'],
          stat['dev'],
          stat['mount_id'],
        ];
      }
      ancestors.add(observed[prefix]!);
    }
    final stat = await _call('filesystem.stat', [path]);
    if (stat is! Map ||
        stat['type'] != 'FILE' ||
        stat['realpath'] != path ||
        !_vmInt(stat['inode'], 0) ||
        !_vmInt(stat['dev'], 0) ||
        !_vmInt(stat['mount_id'], 0) ||
        !_vmInt(stat['size'], 0) ||
        !_appsExactConfigNumbers(stat) ||
        includeContentTimestamps &&
            (stat['mtime'] is! num || stat['ctime'] is! num)) {
      throw const VmException(VmExceptionReason.invalidResponse);
    }
    return _appsFingerprint([
      ancestors,
      path,
      stat['inode'],
      stat['dev'],
      stat['mount_id'],
      stat['size'],
      if (includeContentTimestamps) stat['mtime'],
      if (includeContentTimestamps) stat['ctime'],
    ]);
  }

  List<Object?> _actionArgs(VirtualMachine vm, VmAction action) => [
    vm.id,
    if (action == VmAction.start)
      {'overcommit': false}
    else if (action == VmAction.stop)
      {'force': false, 'force_after_timeout': false}
    else if (action == VmAction.delete)
      {'zvols': false, 'force': false},
  ];
  Future<(List<Object?>, String?)> _deviceArgs(
    VirtualMachine vm,
    VmDeviceChange change,
  ) async {
    final device = change.device;
    if (device != null && !vm.devices.contains(device) ||
        change.order < 0 ||
        change.order > 100000) {
      throw const VmException(VmExceptionReason.invalidInput);
    }
    if (change.kind == VmDeviceChangeKind.remove) {
      if (device == null) {
        throw const VmException(VmExceptionReason.invalidInput);
      }
      return (
        [
          device.id,
          {'force': false, 'raw_file': false, 'zvol': false},
        ],
        null,
      );
    }
    if (change.kind == VmDeviceChangeKind.order) {
      if (device == null ||
          device.order == change.order ||
          vm.devices.any((d) => d.id != device.id && d.order == change.order)) {
        throw const VmException(VmExceptionReason.invalidInput);
      }
      return (
        [
          device.id,
          {'order': change.order},
        ],
        null,
      );
    }
    final attrs = <String, Object?>{};
    String? resourceFingerprint;
    if (change.kind == VmDeviceChangeKind.disk ||
        change.kind == VmDeviceChangeKind.nic) {
      final option = change.option;
      final disk = change.kind == VmDeviceChangeKind.disk;
      if (option == null ||
          !_options.contains(option) ||
          option.kind != (disk ? 'DISK' : 'NIC') ||
          !(disk ? const ['AHCI', 'VIRTIO'] : const ['E1000', 'VIRTIO'])
              .contains(change.adapter)) {
        throw const VmException(VmExceptionReason.invalidInput);
      }
      final choices = await _choiceMap(
        disk ? 'vm.device.disk_choices' : 'vm.device.nic_attach_choices',
      );
      if (choices[option.value] != option.label) {
        throw const VmException(VmExceptionReason.stale);
      }
      if (disk &&
          (await _inventory())
              .expand((v) => v.devices)
              .any(
                (d) =>
                    d.id != device?.id && d.attributes['path'] == option.value,
              )) {
        throw const VmException(VmExceptionReason.stale);
      }
      attrs.addAll({
        'dtype': disk ? 'DISK' : 'NIC',
        'type': change.adapter,
        if (disk) 'path': option.value else 'nic_attach': option.value,
        if (disk && device == null) 'create_zvol': false,
      });
      resourceFingerprint = _appsFingerprint([
        option.value,
        choices[option.value],
        if (disk) await _zvolFingerprint(option.value),
      ]);
    } else if (change.kind == VmDeviceChangeKind.cdrom) {
      final path = change.path;
      if (path == null || !path.toLowerCase().endsWith('.iso')) {
        throw const VmException(VmExceptionReason.invalidInput);
      }
      resourceFingerprint = await _fileFingerprint(
        path,
        includeContentTimestamps: true,
      );
      attrs.addAll({'dtype': 'CDROM', 'path': path});
    } else {
      if (device != null || vm.devices.any((d) => d.type == 'DISPLAY')) {
        throw const VmException(VmExceptionReason.invalidInput);
      }
      // Local-only SPICE, no web listener and no credential retained in reviews.
      attrs.addAll({
        'dtype': 'DISPLAY',
        'type': 'SPICE',
        'bind': '127.0.0.1',
        'web': false,
        'wait': false,
        'resolution': '1024x768',
      });
    }
    if (device != null && device.type != attrs['dtype']) {
      throw const VmException(VmExceptionReason.invalidInput);
    }
    if (vm.devices.any((d) => d.id != device?.id && d.order == change.order)) {
      throw const VmException(VmExceptionReason.invalidInput);
    }
    return (
      device == null
          ? [
              {'vm': vm.id, 'order': change.order, 'attributes': attrs},
            ]
          : [
              device.id,
              {'order': change.order, 'attributes': attrs},
            ],
      resourceFingerprint,
    );
  }

  Future<VmReview> reviewDevice(
    VirtualMachine vm,
    VmDeviceChange change,
  ) => _read(() async {
    final method = change.kind == VmDeviceChangeKind.remove
        ? 'vm.device.delete'
        : change.device == null
        ? 'vm.device.create'
        : 'vm.device.update';
    _guard(method);
    await _fresh(vm, stopped: true);
    final args = await _deviceArgs(vm, change);
    return _issue(
      _VmPlan(
        method: method,
        arguments: args.$1,
        target: vm.name,
        vm: vm,
        deviceChange: change,
        resourceFingerprint: args.$2,
      ),
      'Change virtual machine device',
      [
        'VM ${vm.name} · ${vm.uuid}',
        '${change.kind.name}: ${change.option?.label ?? change.path ?? change.device?.description ?? 'Local SPICE display'}',
        if (change.kind != VmDeviceChangeKind.remove)
          'Boot/device order: ${change.order}',
      ],
      [
        if (change.kind == VmDeviceChangeKind.remove)
          'Detaches this device only. Backing raw files and zvols are retained.'
        else if (change.kind == VmDeviceChangeKind.disk)
          'The guest can modify all data on the selected zvol after it starts. This does not create or erase a zvol.'
        else if (change.kind == VmDeviceChangeKind.nic)
          'The guest will access this host network attachment when started.'
        else if (change.kind == VmDeviceChangeKind.cdrom)
          'The server validates ISO readability and can temporarily change file ownership during validation. Libvirt may adjust ownership when the guest starts. Parent-directory and file identity checks are not atomic with attachment.'
        else if (change.kind == VmDeviceChangeKind.display)
          'Adds a loopback-only SPICE display, without a web listener. Native console streaming is not included.',
      ],
    );
  });
  Future<VmOperationResult> execute(
    VmReview review, {
    required String confirmation,
  }) async {
    _guard();
    if (isBusy || _reading || _queued > 0 || _polling || isOtherBusy()) {
      throw const VmException(VmExceptionReason.busy);
    }
    final plan = _reviews.remove(review);
    if (plan == null || confirmation != review.targetName) {
      return const VmOperationResult(outcome: VmOperationOutcome.rejected);
    }
    _writing = true;
    bool dispatched = false;
    try {
      _guard(plan.method);
      if (plan.vm != null) {
        await _fresh(
          plan.vm!,
          stopped:
              plan.configuration != null ||
              plan.deviceChange != null ||
              plan.action == VmAction.delete,
        );
      }
      if (plan.configuration != null) {
        await _validateConfig(plan.configuration!, vm: plan.vm);
      }
      if (plan.action != null) {
        _validateState(plan.vm!, plan.action!);
        if (plan.action == VmAction.start) await _memoryCheck(plan.vm!);
        if (_vmRunsGuest(plan.action!) &&
            await _storageFingerprint(plan.vm!) != plan.resourceFingerprint) {
          throw const VmException(VmExceptionReason.stale);
        }
      }
      if (plan.deviceChange != null) {
        final fresh = await _deviceArgs(plan.vm!, plan.deviceChange!);
        if (!_adminEqual(fresh.$1, plan.arguments) ||
            fresh.$2 != plan.resourceFingerprint) {
          throw const VmException(VmExceptionReason.stale);
        }
      }
      // Last identity/state fence follows every dependency read.
      if (plan.vm != null) await _fresh(plan.vm!);
      _guard(plan.method);
      if (isOtherBusy()) throw const VmException(VmExceptionReason.busy);
      dispatched = true;
      final raw = await _call(plan.method, plan.arguments);
      if (plan.action == VmAction.stop || plan.action == VmAction.restart) {
        if (!_vmInt(raw, 1)) return _unknown();
        final handle = VmOperationHandle(
          id: raw as int,
          targetName: plan.target,
        );
        _active = handle;
        _jobs[handle] = plan;
        return VmOperationResult(
          outcome: VmOperationOutcome.submitted,
          operation: handle,
        );
      }
      if (plan.method == 'vm.create') {
        final created = _parse(raw);
        if (created.name != plan.target || created.state != 'STOPPED') {
          return _unknown();
        }
        plan.createdId = created.id;
        plan.createdUuid = created.uuid;
      } else if (plan.method == 'vm.device.create') {
        if (raw is! Map || !_vmInt(raw['id'], 1) || raw['vm'] != plan.vm!.id) {
          return _unknown();
        }
        plan.deviceId = raw['id'] as int;
      } else if (plan.method.endsWith('.delete') && raw != true) {
        return _unknown();
      }
      return await _verify(plan)
          ? const VmOperationResult(outcome: VmOperationOutcome.verified)
          : _unknown();
    } on Object {
      return dispatched
          ? _unknown()
          : const VmOperationResult(outcome: VmOperationOutcome.rejected);
    } finally {
      _writing = false;
    }
  }

  VmOperationResult _unknown() {
    _uncertain = true;
    return const VmOperationResult(outcome: VmOperationOutcome.unknown);
  }

  Future<bool> _verify(_VmPlan plan) async {
    final rows = await _inventory(id: plan.vm?.id ?? plan.createdId);
    if (plan.action == VmAction.delete) return rows.isEmpty;
    if (rows.length != 1) return false;
    final vm = rows.single;
    if (vm.uuid != (plan.vm?.uuid ?? plan.createdUuid)) return false;
    if (plan.vm != null) {
      final old = _machines[plan.vm]!;
      final current = _machines[vm]!;
      final changed = plan.configuration != null
          ? (plan.arguments.last as Map).keys.toSet()
          : plan.deviceChange != null
          ? <Object?>{'devices'}
          : <Object?>{};
      if (!_adminEqual(
        {
          for (final e in old.fields.entries)
            if (!changed.contains(e.key)) e.key: e.value,
        },
        {
          for (final e in current.fields.entries)
            if (!changed.contains(e.key)) e.key: e.value,
        },
      )) {
        return false;
      }
      if (plan.deviceChange != null) {
        final change = plan.deviceChange!;
        final targetId = change.device?.id ?? plan.deviceId;
        if (!_adminEqual(
          {
            for (final e in old.devices.entries)
              if (e.key != targetId) '${e.key}': e.value,
          },
          {
            for (final e in current.devices.entries)
              if (e.key != targetId) '${e.key}': e.value,
          },
        )) {
          return false;
        }
        if (change.device != null && change.kind != VmDeviceChangeKind.remove) {
          final patch = plan.arguments.last as Map;
          final attrPatch = patch['attributes'];
          final changedFields = <Object?>{
            '@order',
            if (attrPatch is Map) ...attrPatch.keys,
          };
          if (!_adminEqual(
            {
              for (final e in old.devices[targetId]!.entries)
                if (!changedFields.contains(e.key)) e.key: e.value,
            },
            {
              for (final e in (current.devices[targetId] ?? {}).entries)
                if (!changedFields.contains(e.key)) e.key: e.value,
            },
          )) {
            return false;
          }
        }
      }
    }
    if (plan.configuration != null) {
      return _adminEqual(
            vm.configuration._wire(),
            plan.configuration!._wire(),
          ) &&
          vm.state == 'STOPPED';
    }
    if (plan.deviceChange != null) {
      if (vm.state != 'STOPPED') return false;
      final change = plan.deviceChange!;
      final matches = vm.devices
          .where((d) => d.id == (change.device?.id ?? plan.deviceId))
          .toList();
      if (change.kind == VmDeviceChangeKind.remove) return matches.isEmpty;
      if (matches.length != 1 || matches.single.order != change.order) {
        return false;
      }
      final expected = (plan.arguments.last as Map)['attributes'];
      if (expected is Map) {
        for (final e in expected.entries) {
          if (e.key == 'dtype'
              ? matches.single.type != e.value
              : e.key != 'create_zvol' &&
                    e.key != 'wait' &&
                    !_adminEqual(matches.single.attributes[e.key], e.value)) {
            return false;
          }
        }
      }
      return true;
    }
    final expected = switch (plan.action!) {
      VmAction.start || VmAction.restart || VmAction.resume => 'RUNNING',
      VmAction.suspend => 'SUSPENDED',
      _ => 'STOPPED',
    };
    return vm.state == expected &&
        _machines[vm]!.fingerprint == _machines[plan.vm]!.fingerprint;
  }

  Future<VmOperationResult> poll(VmOperationHandle handle) async {
    final plan = _jobs[handle];
    if (plan == null || !identical(_active, handle) || _uncertain) {
      return const VmOperationResult(outcome: VmOperationOutcome.unknown);
    }
    if (_writing || _reading || _queued > 0 || _polling) {
      throw const VmException(VmExceptionReason.busy);
    }
    _polling = true;
    try {
      final raw = await _call('core.get_jobs', [
        [
          ['id', '=', handle.id],
        ],
        {'limit': 2},
      ]);
      if (raw is! List || raw.length != 1 || raw.single is! Map) {
        return _unknown();
      }
      final row = raw.single as Map;
      if (row['id'] != handle.id ||
          row['method'] != plan.method ||
          !_adminEqual(row['arguments'], plan.arguments)) {
        return _unknown();
      }
      if (row['state'] == 'WAITING' || row['state'] == 'RUNNING') {
        return VmOperationResult(
          outcome: VmOperationOutcome.running,
          operation: handle,
        );
      }
      if (row['state'] != 'SUCCESS') return _unknown();
      if (!await _verify(plan)) return _unknown();
      _jobs.remove(handle);
      _active = null;
      return const VmOperationResult(outcome: VmOperationOutcome.verified);
    } on Object {
      return _unknown();
    } finally {
      _polling = false;
    }
  }
}

bool _vmText(Object? value, int maximum) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= maximum &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]'));
bool _vmRunsGuest(VmAction action) =>
    const [VmAction.start, VmAction.restart, VmAction.resume].contains(action);
bool _vmInt(Object? value, int minimum, [int maximum = 9007199254740991]) =>
    value is int && value >= minimum && value <= maximum;
bool _vmValidConfig(VmConfiguration c) =>
    RegExp(r'^[a-zA-Z_0-9]{1,150}$').hasMatch(c.name) &&
    c.description.length <= 250 &&
    !c.description.contains(RegExp(r'[\x00-\x1f\x7f]')) &&
    _vmInt(c.memoryMiB, 20, 8589934591) &&
    (c.minMemoryMiB == null || _vmInt(c.minMemoryMiB, 20, c.memoryMiB)) &&
    _vmInt(c.vcpus, 1, 4096) &&
    _vmInt(c.cores, 1, 4096) &&
    _vmInt(c.threads, 1, 4096) &&
    const ['UEFI', 'UEFI_CSM'].contains(c.bootloader) &&
    const ['CUSTOM', 'HOST-MODEL', 'HOST-PASSTHROUGH'].contains(c.cpuMode) &&
    (c.cpuModel == null || c.cpuMode == 'CUSTOM' && _vmText(c.cpuModel, 256)) &&
    const ['LOCAL', 'UTC'].contains(c.time) &&
    _vmInt(c.shutdownTimeout, 5, 300);
VmConfiguration _vmConfig(Map raw) {
  if (!_vmText(raw['name'], 150) ||
      raw['description'] is! String ||
      !_vmInt(raw['memory'], 20) ||
      !_vmInt(raw['vcpus'], 1) ||
      !_vmInt(raw['cores'], 1) ||
      !_vmInt(raw['threads'], 1) ||
      raw['autostart'] is! bool ||
      raw['ensure_display_device'] is! bool ||
      raw['hyperv_enlightenments'] is! bool ||
      raw['trusted_platform_module'] is! bool ||
      !_vmInt(raw['shutdown_timeout'], 5, 300) ||
      raw['bootloader'] is! String ||
      raw['cpu_mode'] is! String ||
      raw['time'] is! String ||
      raw['cpu_model'] != null && raw['cpu_model'] is! String ||
      raw['min_memory'] != null && raw['min_memory'] is! int) {
    throw const VmException(VmExceptionReason.invalidResponse);
  }
  final c = VmConfiguration(
    name: raw['name'] as String,
    description: raw['description'] as String,
    memoryMiB: raw['memory'] as int,
    minMemoryMiB: raw['min_memory'] as int?,
    vcpus: raw['vcpus'] as int,
    cores: raw['cores'] as int,
    threads: raw['threads'] as int,
    autostart: raw['autostart'] as bool,
    ensureDisplayDevice: raw['ensure_display_device'] as bool,
    hypervEnlightenments: raw['hyperv_enlightenments'] as bool,
    trustedPlatformModule: raw['trusted_platform_module'] as bool,
    shutdownTimeout: raw['shutdown_timeout'] as int,
    bootloader: raw['bootloader'] as String,
    cpuMode: raw['cpu_mode'] as String,
    cpuModel: raw['cpu_model'] as String?,
    time: raw['time'] as String,
  );
  if (!_vmValidConfig(c)) {
    throw const VmException(VmExceptionReason.invalidResponse);
  }
  return c;
}

List<String> _configChanges(VmConfiguration? before, VmConfiguration after) => [
  for (final e in after._wire().entries)
    if (before == null || !_adminEqual(before._wire()[e.key], e.value))
      '${e.key}: ${before == null ? '' : '${before._wire()[e.key] ?? 'Default'} → '}${e.value ?? 'Default'}',
];
String _vmMethod(VmAction action) =>
    'vm.${switch (action) {
      VmAction.powerOff => 'poweroff',
      _ => action.name,
    }}';
String _vmActionLabel(VmAction action) => switch (action) {
  VmAction.powerOff => 'Power off',
  _ => '${action.name[0].toUpperCase()}${action.name.substring(1)}',
};
