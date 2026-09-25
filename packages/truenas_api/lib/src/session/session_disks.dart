part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedDisksSession {
  DisksCapabilities get disksCapabilities;
  Future<DiskInventory> loadDisks();
  Future<DiskReview> reviewDisk(DiskRequest request);
  Future<DiskResult> executeDisk(DiskReview review, String confirmation);
}

final class DisksCapabilities {
  const DisksCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canUpdate = false,
  });
  const DisksCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canUpdate = false;
  final bool connected, versionSupported, available, canUpdate;
  bool get supported => connected && versionSupported && available;
  String? get blockedReason => !connected
      ? 'Connect to inspect disks.'
      : !versionSupported
      ? 'Native disk settings require stable TrueNAS 25.10.'
      : !available
      ? 'Disk, passive device identity, boot ownership, HA and active-job reads are required.'
      : null;
}

final class DiskSettings {
  const DiskSettings({
    required this.description,
    required this.hddStandby,
    required this.advancedPowerManagement,
  });
  static const standbyChoices = <String>[
    'ALWAYS ON',
    '5',
    '10',
    '20',
    '30',
    '60',
    '120',
    '180',
    '240',
    '300',
    '330',
  ];
  static const apmChoices = <String>[
    'DISABLED',
    '1',
    '64',
    '127',
    '128',
    '192',
    '254',
  ];
  final String description, hddStandby, advancedPowerManagement;
  String? get validationError => !_diskText(description, 120, empty: true)
      ? 'Description must be at most 120 characters without control characters.'
      : !standbyChoices.contains(hddStandby) ||
            !apmChoices.contains(advancedPowerManagement)
      ? 'Choose a supported standby and advanced power-management value.'
      : null;
}

/// A bounded disk.query projection plus passive udev serial and boot checks.
/// No SED, password, SMART command output, partition or temperature payload.
final class DiskSnapshot {
  const DiskSnapshot({
    required this.identifier,
    required this.name,
    required this.serial,
    required this.lunid,
    required this.sizeBytes,
    required this.model,
    required this.type,
    required this.bus,
    required this.description,
    required this.hddStandby,
    required this.advancedPowerManagement,
    required this.pool,
    required this.zfsGuid,
    required this.rotationRate,
    this.identityVerified = false,
    this.bootDisk = false,
  });
  final String identifier, name, serial, type, bus;
  final String description, hddStandby, advancedPowerManagement;
  final String? lunid, model, pool, zfsGuid;
  final int? sizeBytes, rotationRate;
  final bool identityVerified, bootDisk;
  double? get temperatureCelsius => null;
  String get smartStatus => 'Not available from passive inventory';
  DiskSettings get settings => DiskSettings(
    description: description,
    hddStandby: hddStandby,
    advancedPowerManagement: advancedPowerManagement,
  );
  String? get blockedReason => !identityVerified
      ? 'A unique serial-based identifier could not be matched to the current passive device inventory.'
      : sizeBytes == null || sizeBytes! <= 0
      ? 'Disk capacity is unknown; settings changes are blocked.'
      : null;
  String? get powerManagementBlockedReason =>
      blockedReason ??
      (bootDisk
          ? 'Boot-disk power settings require the TrueNAS maintenance workflow.'
          : type != 'HDD' || bus != 'ATA'
          ? 'Power settings are limited to verified non-boot ATA hard disks. Description-only changes remain available.'
          : null);
}

final class DiskInventory {
  DiskInventory({
    required this.endpoint,
    required this.failoverLicensed,
    required List<DiskSnapshot> disks,
    this.conflictingJob = false,
    List<String> warnings = const [],
  }) : disks = List.unmodifiable(disks),
       warnings = List.unmodifiable(warnings);
  final String endpoint;
  final bool failoverLicensed, conflictingJob;
  final List<DiskSnapshot> disks;
  final List<String> warnings;
  String? get blockedReason => failoverLicensed
      ? 'HA disk settings require the coordinated TrueNAS workflow.'
      : conflictingJob
      ? 'An active or waiting server job prevents disk settings changes.'
      : null;
}

final class DiskRequest {
  const DiskRequest({
    required this.inventory,
    required this.disk,
    required this.settings,
  });
  final DiskInventory inventory;
  final DiskSnapshot disk;
  final DiskSettings settings;
  String get target => 'UPDATE ${disk.identifier}';
  bool get changesPowerManagement =>
      settings.hddStandby != disk.hddStandby ||
      settings.advancedPowerManagement != disk.advancedPowerManagement;
  String? get validationError =>
      inventory.blockedReason ??
      (!inventory.disks.any((d) => identical(d, disk))
          ? 'Choose the exact disk from this inventory.'
          : disk.blockedReason ??
                settings.validationError ??
                (changesPowerManagement
                    ? disk.powerManagementBlockedReason
                    : null) ??
                (_diskSettingsEqual(settings, disk.settings)
                    ? 'Change at least one supported setting.'
                    : null));
}

final class DiskReview {
  DiskReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final DiskRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
}

enum DiskOutcome { succeeded, rejected, unknown }

final class DiskResult {
  const DiskResult(this.outcome, this.message);
  final DiskOutcome outcome;
  final String message;
}

enum DisksExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class DisksException implements Exception {
  const DisksException(this.reason);
  final DisksExceptionReason reason;
  String get userMessage => switch (reason) {
    DisksExceptionReason.notAuthenticated =>
      'Connect again before managing disks.',
    DisksExceptionReason.unsupportedVersion =>
      'Native disk settings require stable TrueNAS 25.10.',
    DisksExceptionReason.unavailableMethod =>
      'Required public disk safety methods are unavailable.',
    DisksExceptionReason.busy =>
      'Another operation is active or its outcome is unknown.',
    DisksExceptionReason.staleReview => 'Disk identity, settings, ownership, connection or review changed. Reload and review again.',
    DisksExceptionReason.invalidRequest =>
      'Choose a verified standalone disk and different supported settings.',
    DisksExceptionReason.invalidResponse =>
      'Disk safety information could not be validated.',
    DisksExceptionReason.unavailable =>
      'Disk information is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _diskReads = {
  'disk.query',
  'device.get_info',
  'boot.get_disks',
  'failover.licensed',
  'core.get_jobs',
};
const _diskSelect = [
  'identifier',
  'name',
  'serial',
  'lunid',
  'size',
  'model',
  'type',
  'bus',
  'description',
  'hddstandby',
  'advpowermgmt',
  'pool',
  'zfs_guid',
  'rotationrate',
  'expiretime',
];

final class _DiskLease {
  const _DiskLease(this.created, this.proof);
  final DateTime created;
  final String proof;
}

final class _SessionDisks {
  _SessionDisks({
    required this.client,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherMutationBusy,
    required this.requestTimeout,
  }) : _version =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       _endpoint = summary.endpointUri.toString(),
       _metadata = metadata is Map ? Map.of(metadata) : const {};
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _version;
  final String _endpoint;
  final Map _metadata;
  bool _calling = false, _uncertain = false;
  final Set<DiskInventory> _inventories = {};
  final Map<DiskReview, _DiskLease> _reviews = {};
  bool get isBusy => _calling || _uncertain;
  bool _method(String name) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == false &&
        row['uploadable'] == false &&
        row['downloadable'] == false &&
        row['private'] != true &&
        row['_private'] != true &&
        row['no_auth_required'] == false;
  }

  DisksCapabilities get capabilities => DisksCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: _diskReads.every(_method),
    canUpdate: _method('disk.update'),
  );
  void _guard({bool write = false}) {
    if (!isCurrent()) {
      throw const DisksException(DisksExceptionReason.notAuthenticated);
    }
    if (!_version) {
      throw const DisksException(DisksExceptionReason.unsupportedVersion);
    }
    if (!capabilities.supported || write && !capabilities.canUpdate) {
      throw const DisksException(DisksExceptionReason.unavailableMethod);
    }
  }

  Future<Object?> _call(String method, List<Object?> params) async {
    _guard();
    final result = await client
        .call(method, id: nextId(), params: params)
        .timeout(requestTimeout);
    _guard();
    return result;
  }

  Future<DiskInventory> _read() async {
    final licensed = await _call('failover.licensed', const []);
    final rows = await _call('disk.query', const [
      [],
      {
        'limit': 513,
        'select': _diskSelect,
        'extra': {'include_expired': false, 'passwords': false, 'pools': true},
      },
    ]);
    // serials_only reads udev properties; full details may issue rotation ioctls.
    final devices = await _call('device.get_info', const [
      {'type': 'DISK', 'get_partitions': false, 'serials_only': true},
    ]);
    final boot = await _call('boot.get_disks', const []);
    final jobs = await _call('core.get_jobs', const [
      [
        [
          'state',
          'in',
          ['WAITING', 'RUNNING'],
        ],
      ],
      {
        'limit': 129,
        'select': ['id', 'method', 'state'],
      },
    ]);
    if (licensed is! bool ||
        rows is! List ||
        rows.length > 512 ||
        devices is! Map ||
        devices.length > 512 ||
        boot is! List ||
        boot.length > 512 ||
        jobs is! List ||
        jobs.length > 128) {
      _diskInvalid();
    }
    final serials = <String, String>{};
    for (final entry in devices.entries) {
      if (!_diskName(entry.key) || !_diskText(entry.value, 256, empty: true)) {
        _diskInvalid();
      }
      serials[entry.key as String] = entry.value as String;
    }
    if (boot.any((d) => !_diskName(d)) || boot.toSet().length != boot.length) {
      _diskInvalid();
    }
    final jobIds = <int>{};
    for (final job in jobs) {
      if (job is! Map ||
          job['id'] is! int ||
          job['id'] <= 0 ||
          !jobIds.add(job['id'] as int) ||
          !_diskMethod(job['method']) ||
          !const {'WAITING', 'RUNNING'}.contains(job['state'])) {
        _diskInvalid();
      }
    }
    final parsed = rows.map(_diskParse).toList();
    if (parsed.map((d) => d.identifier).toSet().length != parsed.length ||
        parsed.map((d) => d.name).toSet().length != parsed.length) {
      _diskInvalid();
    }
    final disks = <DiskSnapshot>[];
    for (final d in parsed) {
      final expected = d.lunid != null && d.lunid!.isNotEmpty
          ? '{serial_lunid}${d.serial}_${d.lunid}'
          : '{serial}${d.serial}';
      final verified =
          d.serial.isNotEmpty &&
          d.identifier == expected &&
          serials[d.name] == d.serial &&
          serials.values.where((s) => s == d.serial).length == 1 &&
          parsed.where((other) => other.serial == d.serial).length == 1;
      disks.add(
        DiskSnapshot(
          identifier: d.identifier,
          name: d.name,
          serial: d.serial,
          lunid: d.lunid,
          sizeBytes: d.sizeBytes,
          model: d.model,
          type: d.type,
          bus: d.bus,
          description: d.description,
          hddStandby: d.hddStandby,
          advancedPowerManagement: d.advancedPowerManagement,
          pool: d.pool,
          zfsGuid: d.zfsGuid,
          rotationRate: d.rotationRate,
          identityVerified: verified,
          bootDisk: boot.contains(d.name),
        ),
      );
    }
    disks.sort((a, b) => a.name.compareTo(b.name));
    return DiskInventory(
      endpoint: _endpoint,
      failoverLicensed: licensed,
      disks: disks,
      conflictingJob: jobs.isNotEmpty,
      warnings: const [
        'Inventory settings, size and pool ownership come from the current unexpired disk cache. Presence is cross-checked only by unique passive device name/serial; this is not a hardware-health test.',
        'Pool names describe imported/boot ownership, not all exported pools or other consumers. No disk is declared safe to erase or remove.',
        'Temperature and SMART health are unknown. No temperature, SMART, partition, import scan or disk-waking probe is requested.',
      ],
    );
  }

  Future<DiskInventory> load() async {
    _guard();
    if (_calling) throw const DisksException(DisksExceptionReason.busy);
    _calling = true;
    _reviews.clear();
    _inventories.clear();
    try {
      final inventory = await _read();
      _inventories.add(inventory);
      return inventory;
    } on DisksException {
      rethrow;
    } on Object {
      throw const DisksException(DisksExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<DiskReview> review(DiskRequest request) async {
    _guard(write: true);
    if (isBusy || isOtherMutationBusy()) {
      throw const DisksException(DisksExceptionReason.busy);
    }
    if (!_inventories.contains(request.inventory) ||
        request.inventory.endpoint != _endpoint) {
      throw const DisksException(DisksExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      throw const DisksException(DisksExceptionReason.invalidRequest);
    }
    _calling = true;
    try {
      final fresh = await _read(), proof = _diskProof(request.disk);
      if (!_matches(fresh, request.disk.identifier, proof) ||
          isOtherMutationBusy()) {
        throw const DisksException(DisksExceptionReason.staleReview);
      }
      final review = DiskReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'Exact disk: ${request.disk.name}; identifier ${request.disk.identifier}; serial ${request.disk.serial}; ${request.disk.sizeBytes} bytes. Imported pool: ${request.disk.pool ?? 'not reported'}. Boot disk: ${request.disk.bootDisk ? 'yes' : 'no'}.',
          'Only changed description, standby and advanced power-management fields are sent. SED passwords, keys, pool topology, partitions and all other settings are preserved.',
          if (request.changesPowerManagement) 'Power settings can affect every workload using this disk, including its pool. Standby/APM may increase wake-up latency and mechanical load/unload cycles; verify hardware support and intended settings.',
          if (request.changesPowerManagement) 'TrueNAS stores these settings, then launches unchecked asynchronous hdparm work; the standby command is delayed by about 60 seconds. Readback confirms stored configuration only, not physical application. Do not interpret success as a verified sleep or power state.',
          'The unique passive name/serial, cached identity, capacity, type, ownership and old settings are rechecked with standalone HA status and visible active jobs before submission. Server visibility and a last-moment hot-swap or concurrent change can still race this preflight.',
          'No automatic retry occurs. If submission or readback is uncertain, inspect the original server and reconnect before further writes. No wipe, format, replacement, SED, SMART or temperature command is issued.',
        ],
      );
      _reviews.clear();
      _reviews[review] = _DiskLease(DateTime.now(), proof);
      return review;
    } on DisksException {
      rethrow;
    } on Object {
      throw const DisksException(DisksExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  bool _matches(DiskInventory inv, String identifier, String proof) =>
      inv.blockedReason == null &&
      inv.disks
          .where((d) => d.identifier == identifier)
          .any((d) => d.blockedReason == null && _diskProof(d) == proof);
  Future<DiskResult> execute(DiskReview review, String confirmation) async {
    var sent = false, owns = false;
    try {
      _guard(write: true);
      if (isBusy || isOtherMutationBusy()) {
        throw const DisksException(DisksExceptionReason.busy);
      }
      final lease = _reviews.remove(review);
      if (lease == null ||
          review.endpoint != _endpoint ||
          confirmation != review.target ||
          DateTime.now().difference(lease.created) >
              const Duration(minutes: 5) ||
          review.request.validationError != null) {
        throw const DisksException(DisksExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      final fresh = await _read(),
          disk = review.request.disk,
          settings = review.request.settings;
      if (!_matches(fresh, disk.identifier, lease.proof) ||
          isOtherMutationBusy()) {
        throw const DisksException(DisksExceptionReason.staleReview);
      }
      final patch = <String, Object?>{
        if (settings.description != disk.description)
          'description': settings.description,
        if (settings.hddStandby != disk.hddStandby)
          'hddstandby': settings.hddStandby,
        if (settings.advancedPowerManagement != disk.advancedPowerManagement)
          'advpowermgmt': settings.advancedPowerManagement,
      };
      sent = true;
      final receipt = await _call('disk.update', [disk.identifier, patch]);
      _reviews.clear();
      _inventories.clear();
      // Update returns a disk without joined pool ownership. Never retain extras.
      if (receipt is! Map ||
          receipt['identifier'] != disk.identifier ||
          receipt['name'] != disk.name ||
          receipt['serial'] != disk.serial ||
          receipt['description'] != settings.description ||
          receipt['hddstandby'] != settings.hddStandby ||
          receipt['advpowermgmt'] != settings.advancedPowerManagement) {
        return _unknown();
      }
      final after = await _read(),
          match = after.disks
              .where((d) => d.identifier == disk.identifier)
              .singleOrNull;
      if (after.blockedReason != null ||
          match == null ||
          match.blockedReason != null ||
          _diskProof(match, settings: false) !=
              _diskProof(disk, settings: false) ||
          !_diskSettingsEqual(match.settings, settings)) {
        return _unknown();
      }
      return const DiskResult(
        DiskOutcome.succeeded,
        'TrueNAS reports the requested stored settings for this exact disk. Hardware power-state application and disk health are not verified.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return DiskResult(
        DiskOutcome.rejected,
        error is DisksException
            ? error.userMessage
            : 'Preflight failed. Nothing was submitted.',
      );
    } finally {
      if (owns) _calling = false;
    }
  }

  DiskResult _unknown() {
    _uncertain = true;
    _reviews.clear();
    _inventories.clear();
    return const DiskResult(
      DiskOutcome.unknown,
      'Disk settings may have been stored or scheduled for hardware application, but the exact result is unverified. Inspect the original server and reconnect before further changes. Do not repeat this operation.',
    );
  }
}

DiskSnapshot _diskParse(Object? raw) {
  if (raw is! Map ||
      !_diskSelect.every(raw.containsKey) ||
      !_diskText(raw['identifier'], 512) ||
      !_diskName(raw['name']) ||
      !_diskText(raw['serial'], 256, empty: true) ||
      !_diskNullableText(raw['lunid'], 256) ||
      !_diskNullableInt(raw['size'], 0, 9007199254740991) ||
      !_diskNullableText(raw['model'], 256) ||
      !(raw['type'] == null || _diskToken(raw['type'])) ||
      !_diskToken(raw['bus']) ||
      !_diskText(raw['description'], 1024, empty: true) ||
      !DiskSettings.standbyChoices.contains(raw['hddstandby']) ||
      !DiskSettings.apmChoices.contains(raw['advpowermgmt']) ||
      !_diskNullableText(raw['pool'], 256) ||
      !(raw['zfs_guid'] == null ||
          raw['zfs_guid'] is String &&
              RegExp(r'^\d{1,20}$').hasMatch(raw['zfs_guid'] as String)) ||
      !_diskNullableInt(raw['rotationrate'], 0, 100000) ||
      !raw.containsKey('expiretime') ||
      raw['expiretime'] != null) {
    _diskInvalid();
  }
  return DiskSnapshot(
    identifier: raw['identifier'] as String,
    name: raw['name'] as String,
    serial: raw['serial'] as String,
    lunid: raw['lunid'] as String?,
    sizeBytes: raw['size'] as int?,
    model: raw['model'] as String?,
    type: raw['type'] as String? ?? 'UNKNOWN',
    bus: raw['bus'] as String,
    description: raw['description'] as String,
    hddStandby: raw['hddstandby'] as String,
    advancedPowerManagement: raw['advpowermgmt'] as String,
    pool: raw['pool'] as String?,
    zfsGuid: raw['zfs_guid'] as String?,
    rotationRate: raw['rotationrate'] as int?,
  );
}

bool _diskText(Object? value, int max, {bool empty = false}) =>
    value is String &&
    (empty || value.isNotEmpty) &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]').hasMatch(value);
bool _diskNullableText(Object? value, int max) =>
    value == null || _diskText(value, max, empty: true);
bool _diskNullableInt(Object? value, int min, int max) =>
    value == null || value is int && value >= min && value <= max;
bool _diskName(Object? value) =>
    value is String && RegExp(r'^[a-z][a-z0-9]{0,62}$').hasMatch(value);
bool _diskToken(Object? value) =>
    value is String && RegExp(r'^[A-Z][A-Z0-9_-]{0,31}$').hasMatch(value);
bool _diskMethod(Object? value) =>
    value is String && RegExp(r'^[a-z][a-z0-9_.]{0,127}$').hasMatch(value);
bool _diskSettingsEqual(DiskSettings a, DiskSettings b) =>
    a.description == b.description &&
    a.hddStandby == b.hddStandby &&
    a.advancedPowerManagement == b.advancedPowerManagement;
String _diskProof(DiskSnapshot d, {bool settings = true}) => jsonEncode([
  d.identifier,
  d.name,
  d.serial,
  d.lunid,
  d.sizeBytes,
  d.model,
  d.type,
  d.bus,
  d.pool,
  d.zfsGuid,
  d.rotationRate,
  d.identityVerified,
  d.bootDisk,
  if (settings) ...[d.description, d.hddStandby, d.advancedPowerManagement],
]);
Never _diskInvalid() =>
    throw const DisksException(DisksExceptionReason.invalidResponse);
