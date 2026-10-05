part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedSystemUpdatesSession {
  SystemUpdatesCapabilities get systemUpdatesCapabilities;
  Future<SystemUpdateInventory> loadSystemUpdates();
  Future<SystemUpdateReview> reviewSystemUpdate(SystemUpdateRequest request);
  Future<SystemUpdateResult> executeSystemUpdate(
    SystemUpdateReview review,
    String confirmation,
  );
  Future<SystemUpdateResult> pollSystemUpdate(SystemUpdateJob job);
}

final class SystemUpdatesCapabilities {
  const SystemUpdatesCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canCheck,
    required this.canDownload,
    required this.canInstall,
  });
  const SystemUpdatesCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canCheck = false,
      canDownload = false,
      canInstall = false;
  final bool connected,
      versionSupported,
      available,
      canCheck,
      canDownload,
      canInstall;
  bool get supported => connected && versionSupported && available;
  bool supports(SystemUpdateAction action) =>
      supported &&
      switch (action) {
        SystemUpdateAction.check => canCheck,
        SystemUpdateAction.download => canDownload,
        SystemUpdateAction.install => canInstall,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect system updates.'
      : !versionSupported
      ? 'Native system updates require stable TrueNAS 25.10.'
      : !available
      ? 'Current version, boot pool, boot environments, HA and job reads are required.'
      : null;
}

final class SystemUpdateVersion {
  const SystemUpdateVersion({
    required this.train,
    required this.version,
    required this.filename,
    required this.checksum,
    required this.downloadBytes,
    required this.profile,
    this.releaseNotes,
    this.blockedReason,
  });
  final String train, version, filename, checksum, profile;
  final int downloadBytes;
  final String? releaseNotes, blockedReason;
  String get target => '$train / $version';
}

final class SystemUpdateInventory {
  SystemUpdateInventory({
    required this.endpoint,
    required this.currentVersion,
    required this.bootPool,
    required this.bootHealthy,
    required this.failoverLicensed,
    required this.conflictingJob,
    required List<BootEnvironmentSnapshot> environments,
    this.bootSizeBytes,
    this.bootAllocatedBytes,
    this.bootFreeBytes,
    this.checked = false,
    this.checkError,
    this.currentTrain,
    this.currentProfile,
    this.matchesProfile,
    this.downloadPercent,
    this.downloadVersion,
    List<SystemUpdateVersion> versions = const [],
  }) : environments = List.unmodifiable(environments),
       versions = List.unmodifiable(versions);
  final String endpoint, currentVersion, bootPool;
  final bool bootHealthy, failoverLicensed, conflictingJob, checked;
  final int? bootSizeBytes, bootAllocatedBytes, bootFreeBytes;
  final List<BootEnvironmentSnapshot> environments;
  final List<SystemUpdateVersion> versions;
  final String? checkError, currentTrain, currentProfile, downloadVersion;
  final bool? matchesProfile;
  final double? downloadPercent;
  String? get blockedReason => failoverLicensed
      ? 'HA systems require the coordinated TrueNAS update workflow.'
      : conflictingJob
      ? 'A boot, update, failover or power operation is already active.'
      : !bootHealthy
      ? 'A healthy, idle boot pool is required.'
      : environments.isEmpty ||
            environments.where((e) => e.active).length != 1 ||
            environments.where((e) => e.activated).length != 1
      ? 'Boot selection is unavailable.'
      : !environments.singleWhere((e) => e.active).activated
      ? 'A different boot environment is selected for next boot. Resolve it in TrueNAS first.'
      : null;
  String? get installBlockedReason =>
      blockedReason ??
      (bootFreeBytes == null || bootFreeBytes! <= 0
          ? 'Boot-pool free space must be known and nonzero.'
          : environments.any((e) => !e.active && !e.activated && !e.keep)
          ? 'Protect every inactive boot environment with Keep before installation; the installer can prune unprotected environments.'
          : null);
}

enum SystemUpdateAction { check, download, install }

final class SystemUpdateRequest {
  const SystemUpdateRequest({
    required this.inventory,
    required this.action,
    this.version,
  });
  final SystemUpdateInventory inventory;
  final SystemUpdateAction action;
  final SystemUpdateVersion? version;
  String get target => action == SystemUpdateAction.check
      ? 'CHECK ${inventory.currentVersion}'
      : '${action.name.toUpperCase()} ${version?.version ?? ''}';
  String? get validationError =>
      inventory.blockedReason ??
      (action == SystemUpdateAction.check
          ? (version == null
                ? null
                : 'Checking does not accept a target release.')
          : !inventory.checked ||
                inventory.checkError != null ||
                inventory.matchesProfile != true
          ? 'Complete a successful update-source check with a matching current profile first.'
          : version == null ||
                !inventory.versions.any((v) => identical(v, version))
          ? 'Select an exact release from this checked inventory.'
          : version!.blockedReason ??
                (action == SystemUpdateAction.install
                    ? inventory.installBlockedReason ??
                          (inventory.environments.any(
                                (e) => e.id == version!.version,
                              )
                              ? 'A boot environment already uses the selected version name. Resolve it in TrueNAS before installation.'
                              : null)
                    : null));
}

/// Display values are public for connector-free fixtures; only session-issued
/// instances are accepted by executeSystemUpdate.
final class SystemUpdateReview {
  SystemUpdateReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final SystemUpdateRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
  SystemUpdateAction get action => request.action;
}

final class SystemUpdateJob {
  const SystemUpdateJob({
    required this.id,
    required this.action,
    required this.endpoint,
    required this.currentVersion,
    required this.version,
  });
  final int id;
  final SystemUpdateAction action;
  final String endpoint, currentVersion;
  final SystemUpdateVersion version;
}

enum SystemUpdateOutcome {
  checked,
  pending,
  succeeded,
  failed,
  rejected,
  unknown,
}

final class SystemUpdateResult {
  const SystemUpdateResult(
    this.outcome,
    this.message, {
    this.inventory,
    this.job,
    this.percent,
    this.rebootRequired = false,
  });
  final SystemUpdateOutcome outcome;
  final String message;
  final SystemUpdateInventory? inventory;
  final SystemUpdateJob? job;
  final double? percent;
  final bool rebootRequired;
}

enum SystemUpdatesExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class SystemUpdatesException implements Exception {
  const SystemUpdatesException(this.reason);
  final SystemUpdatesExceptionReason reason;
  String get userMessage => switch (reason) {
    SystemUpdatesExceptionReason.notAuthenticated =>
      'A current authenticated connection is required.',
    SystemUpdatesExceptionReason.unsupportedVersion =>
      'This update adapter supports stable TrueNAS 25.10 only.',
    SystemUpdatesExceptionReason.unavailableMethod =>
      'Required public update methods or permissions are unavailable.',
    SystemUpdatesExceptionReason.busy =>
      'Another server operation is pending or needs verification.',
    SystemUpdatesExceptionReason.staleReview => 'The connection, release, boot state or review changed. Nothing was submitted.',
    SystemUpdatesExceptionReason.invalidRequest =>
      'Review a supported exact update target first.',
    SystemUpdatesExceptionReason.invalidResponse =>
      'Update safety information could not be validated.',
    SystemUpdatesExceptionReason.unavailable =>
      'Update information is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

final class _SessionSystemUpdates {
  _SessionSystemUpdates({
    required this.client,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherMutationBusy,
    required this.requestTimeout,
  }) : _supportedVersion =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       _endpoint = summary.endpointUri.toString(),
       _sessionVersion = summary.version,
       _metadata = metadata is Map ? Map.of(metadata) : const {};
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _supportedVersion;
  final String _endpoint, _sessionVersion;
  final Map _metadata;
  bool _calling = false, _uncertain = false, _applied = false;
  final Set<SystemUpdateInventory> _inventories = {};
  final Map<SystemUpdateReview, DateTime> _reviews = {};
  final Map<SystemUpdateJob, SystemUpdateInventory> _jobs = {};
  SystemUpdateInventory? _catalog;
  bool get isBusy => _calling || _uncertain || _applied || _jobs.isNotEmpty;
  static const _localMethods = {
    'system.version_short',
    'boot.get_state',
    'boot.environment.query',
    'failover.licensed',
    'core.get_jobs',
  };
  bool _method(String name, {bool job = false}) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == job &&
        row['uploadable'] == false &&
        row['downloadable'] == false &&
        row['private'] != true &&
        row['_private'] != true &&
        (!job || row['no_auth_required'] == false);
  }

  SystemUpdatesCapabilities get capabilities {
    final available = _localMethods.every(_method);
    final check =
        _method('update.status') && _method('update.available_versions');
    return SystemUpdatesCapabilities(
      connected: isCurrent(),
      versionSupported: _supportedVersion,
      available: available,
      canCheck: check,
      canDownload: check && _method('update.download', job: true),
      canInstall: check && _method('update.run', job: true),
    );
  }

  void _guard([SystemUpdateAction? action]) {
    if (!isCurrent()) {
      throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.notAuthenticated,
      );
    }
    if (!_supportedVersion) {
      throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.supported ||
        action != null && !capabilities.supports(action)) {
      throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.unavailableMethod,
      );
    }
  }

  Future<Object?> _call(String method, List<Object?> params) async {
    _guard();
    final value = await client
        .call(method, id: nextId(), params: params)
        .timeout(requestTimeout);
    _guard();
    return value;
  }

  Future<SystemUpdateInventory> _local() async {
    final version = await _call('system.version_short', const []);
    final ha = await _call('failover.licensed', const []);
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
    final boot = await _call('boot.get_state', const []);
    final rows = await _call('boot.environment.query', const [
      [],
      {'limit': 129},
    ]);
    if (version != _sessionVersion ||
        !_updateText(version, 96) ||
        ha is! bool ||
        jobs is! List ||
        jobs.length > 128 ||
        boot is! Map ||
        !_updateToken(boot['name'], 64) ||
        boot['healthy'] is! bool ||
        !_updateText(boot['status'], 32) ||
        rows is! List ||
        rows.length > 128) {
      _updateInvalid();
    }
    var conflict = false;
    for (final job in jobs) {
      if (job is! Map ||
          !_updateInt(job['id']) ||
          !_updateText(job['method'], 128) ||
          !{'WAITING', 'RUNNING'}.contains(job['state'])) {
        _updateInvalid();
      }
      final method = job['method'] as String;
      conflict |=
          method.startsWith('boot.') ||
          method.startsWith('update.') ||
          method.startsWith('failover.') ||
          method == 'system.reboot' ||
          method == 'system.shutdown';
    }
    final environments = rows.map(_bootParse).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (environments.map((e) => e.id).toSet().length != environments.length ||
        environments.any((e) => e.dataset.split('/').first != boot['name'])) {
      _updateInvalid();
    }
    final scan = boot['scan'];
    if (scan != null && scan is! Map) _updateInvalid();
    final idleScan =
        scan == null ||
        scan is Map && {'NONE', 'FINISHED', 'CANCELED'}.contains(scan['state']);
    int? number(String key) {
      final value = boot[key];
      if (value == null) return null;
      if (!_updateInt(value)) _updateInvalid();
      return value as int;
    }

    final size = number('size'),
        used = number('allocated'),
        free = number('free');
    if (size != null &&
        (used != null && used > size ||
            free != null && free > size ||
            used != null && free != null && used + free != size)) {
      _updateInvalid();
    }
    return SystemUpdateInventory(
      endpoint: _endpoint,
      currentVersion: version as String,
      bootPool: boot['name'] as String,
      bootHealthy:
          boot['healthy'] == true && boot['status'] == 'ONLINE' && idleScan,
      failoverLicensed: ha,
      conflictingJob: conflict,
      environments: environments,
      bootSizeBytes: size,
      bootAllocatedBytes: used,
      bootFreeBytes: free,
    );
  }

  SystemUpdateInventory _withCatalog(
    SystemUpdateInventory local,
    SystemUpdateInventory? catalog,
  ) => SystemUpdateInventory(
    endpoint: local.endpoint,
    currentVersion: local.currentVersion,
    bootPool: local.bootPool,
    bootHealthy: local.bootHealthy,
    failoverLicensed: local.failoverLicensed,
    conflictingJob: local.conflictingJob,
    environments: local.environments,
    bootSizeBytes: local.bootSizeBytes,
    bootAllocatedBytes: local.bootAllocatedBytes,
    bootFreeBytes: local.bootFreeBytes,
    checked: catalog?.checked ?? false,
    checkError: catalog?.checkError,
    currentTrain: catalog?.currentTrain,
    currentProfile: catalog?.currentProfile,
    matchesProfile: catalog?.matchesProfile,
    downloadPercent: catalog?.downloadPercent,
    downloadVersion: catalog?.downloadVersion,
    versions: catalog?.versions ?? const [],
  );
  Future<SystemUpdateInventory> load() async {
    _guard();
    if (_calling) {
      throw const SystemUpdatesException(SystemUpdatesExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final local = await _local();
      final result = _withCatalog(local, _catalog);
      _inventories.add(result);
      return result;
    } on SystemUpdatesException {
      rethrow;
    } on Object {
      throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.unavailable,
      );
    } finally {
      _calling = false;
    }
  }

  Future<SystemUpdateReview> review(SystemUpdateRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const SystemUpdatesException(SystemUpdatesExceptionReason.busy);
    }
    if (!_inventories.contains(request.inventory)) {
      throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.staleReview,
      );
    }
    if (request.validationError != null) {
      throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.invalidRequest,
      );
    }
    _calling = true;
    try {
      final local = await _local();
      if (!_updateSameLocal(request.inventory, local)) {
        throw const SystemUpdatesException(
          SystemUpdatesExceptionReason.staleReview,
        );
      }
      final review = SystemUpdateReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'This exact authenticated endpoint is $_endpoint. Current version: ${request.inventory.currentVersion}.',
          'Checking contacts the configured update source, fetches release notes and may initialize the server update profile. Source configuration and TLS trust are server-owned and are not independently attested here.',
          if (request.action != SystemUpdateAction.check) 'The exact train, release filename, advertised SHA-256 and download size are rechecked before dispatch. The source can still change after preflight; there is no compare-and-swap API.',
          if (request.action != SystemUpdateAction.check) 'Downloading writes or reuses the shared staged image, can remove a mismatching old image and may retry internally on the server. TrueNavo never retries or resumes the operation.',
          if (request.action != SystemUpdateAction.check) 'Download progress and job success do not prove staged-image integrity. There is no public read-only staged hash or uncompressed-size proof.',
          if (request.action == SystemUpdateAction.install) 'Installation creates and selects a new boot environment and runs server prechecks and checksum verification. Every inactive boot environment must remain kept; a concurrent external Keep change can still permit server pruning.',
          if (request.action == SystemUpdateAction.install) 'Displayed boot-pool free bytes are not installer-available space or an installation-size guarantee. The server decides whether the image fits; failures can leave partial effects.',
          if (request.action == SystemUpdateAction.install) 'Back up configuration and arrange an outage/recovery plan first. HA, downgrades, prereleases, manual uploads and warning-bypass resume are not supported. Automatic reboot is always false; reboot remains a separate TrueNAS action.',
        ],
      );
      _reviews.clear();
      _reviews[review] = DateTime.now();
      return review;
    } on SystemUpdatesException {
      rethrow;
    } on Object {
      throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.unavailable,
      );
    } finally {
      _calling = false;
    }
  }

  Future<SystemUpdateInventory> _check(SystemUpdateInventory local) async {
    final status = await _call('update.status', const []);
    if (status is! Map || !{'NORMAL', 'ERROR'}.contains(status['code'])) {
      _updateInvalid();
    }
    if (status['code'] == 'ERROR') {
      final error = status['error'];
      if (status['status'] != null ||
          error is! Map ||
          !_updateToken(error['errname'], 64)) {
        _updateInvalid();
      }
      return _withCatalog(
        local,
        SystemUpdateInventory(
          endpoint: _endpoint,
          currentVersion: local.currentVersion,
          bootPool: local.bootPool,
          bootHealthy: local.bootHealthy,
          failoverLicensed: local.failoverLicensed,
          conflictingJob: local.conflictingJob,
          environments: local.environments,
          checked: true,
          checkError:
              const {
                'EFAULT',
                'ENONET',
                'ENETUNREACH',
                'ECONNRESET',
                'ETIMEDOUT',
                'ENOPKG',
                'EHAUNAVAILABLE',
                'EREBOOTREQUIRED',
                'EACCES',
                'EPERM',
                'EIO',
                'ENOENT',
                'EBUSY',
              }.contains(error['errname'])
              ? error['errname'] as String
              : 'UNAVAILABLE',
        ),
      );
    }
    final info = status['status'];
    if (info is! Map ||
        info['current_version'] is! Map ||
        status['error'] != null) {
      _updateInvalid();
    }
    final current = info['current_version'] as Map;
    if (!_updateToken(current['train'], 128) ||
        !_updateToken(current['profile'], 32) ||
        current['matches_profile'] is! bool) {
      _updateInvalid();
    }
    final versions = await _call('update.available_versions', const []);
    if (versions is! List || versions.length > 128) _updateInvalid();
    final parsed = <SystemUpdateVersion>[];
    final seen = <String>{};
    for (final row in versions) {
      final value = _updateVersion(row, local.currentVersion);
      if (!seen.add(value.target)) _updateInvalid();
      parsed.add(value);
    }
    final progress = status['update_download_progress'];
    double? percent;
    String? downloadVersion;
    if (progress != null) {
      if (progress is! Map || !_updateText(progress['version'], 96)) {
        _updateInvalid();
      }
      percent = _updatePercent(progress['percent']);
      if (percent == null) _updateInvalid();
      downloadVersion = progress['version'] as String;
    }
    return SystemUpdateInventory(
      endpoint: _endpoint,
      currentVersion: local.currentVersion,
      bootPool: local.bootPool,
      bootHealthy: local.bootHealthy,
      failoverLicensed: local.failoverLicensed,
      conflictingJob: local.conflictingJob,
      environments: local.environments,
      bootSizeBytes: local.bootSizeBytes,
      bootAllocatedBytes: local.bootAllocatedBytes,
      bootFreeBytes: local.bootFreeBytes,
      checked: true,
      currentTrain: current['train'] as String,
      currentProfile: current['profile'] as String,
      matchesProfile: current['matches_profile'] as bool,
      versions: parsed,
      downloadPercent: percent,
      downloadVersion: downloadVersion,
    );
  }

  Future<SystemUpdateResult> execute(
    SystemUpdateReview review,
    String confirmation,
  ) async {
    _guard(review.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const SystemUpdatesException(SystemUpdatesExceptionReason.busy);
    }
    final issued = _reviews.remove(review);
    if (issued == null ||
        DateTime.now().difference(issued) > const Duration(minutes: 5) ||
        !_inventories.contains(review.request.inventory) ||
        review.endpoint != _endpoint ||
        confirmation != review.target) {
      throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.staleReview,
      );
    }
    final request = review.request;
    if (request.validationError != null) {
      throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.invalidRequest,
      );
    }
    _calling = true;
    var effectful = false;
    try {
      final before = await _local();
      if (!_updateSameLocal(before, request.inventory) ||
          before.blockedReason != null) {
        return const SystemUpdateResult(
          SystemUpdateOutcome.rejected,
          'Boot or session safety state changed. No update-source or mutation request was sent.',
        );
      }
      if (isOtherMutationBusy()) {
        throw const SystemUpdatesException(SystemUpdatesExceptionReason.busy);
      }
      // Even status may initialize config.profile. Once started, exceptions are
      // conservatively uncertain rather than silently replayable read failures.
      effectful = true;
      final checked = await _check(before);
      final finalLocal = await _local();
      if (!_updateSameLocal(before, finalLocal)) return _unknown();
      if (checked.checkError == 'EREBOOTREQUIRED') {
        _applied = true;
        _catalog = checked;
        _inventories.clear();
        _reviews.clear();
        _inventories.add(checked);
        return SystemUpdateResult(
          SystemUpdateOutcome.checked,
          'TrueNAS reports an already-applied update requiring reboot. No image or reboot request was sent. Inspect TrueNAS; further writes remain blocked in this session.',
          inventory: checked,
          rebootRequired: true,
        );
      }
      if (request.action == SystemUpdateAction.check) {
        _catalog = checked;
        _inventories.clear();
        _reviews.clear();
        _inventories.add(checked);
        return SystemUpdateResult(
          SystemUpdateOutcome.checked,
          checked.checkError == null
              ? 'Update-source check completed. No image was downloaded or installed.'
              : 'The update source reported ${checked.checkError}. Availability is unknown; no image was downloaded or installed.',
          inventory: checked,
        );
      }
      final selected = request.version!;
      if (checked.checkError != null ||
          checked.matchesProfile != true ||
          checked.currentTrain != request.inventory.currentTrain ||
          checked.currentProfile != request.inventory.currentProfile ||
          !checked.versions.any((v) => _updateSameVersion(v, selected))) {
        return const SystemUpdateResult(
          SystemUpdateOutcome.rejected,
          'The checked source, profile or exact release changed. No download or install request was sent.',
        );
      }
      if (request.action == SystemUpdateAction.install &&
          finalLocal.installBlockedReason != null) {
        return const SystemUpdateResult(
          SystemUpdateOutcome.rejected,
          'Boot-environment protections or free-space information changed. Installation was not sent.',
        );
      }
      if (isOtherMutationBusy()) {
        return const SystemUpdateResult(
          SystemUpdateOutcome.rejected,
          'Another operation became active. No download or install request was sent.',
        );
      }
      _guard(request.action);
      final method = request.action == SystemUpdateAction.download
          ? 'update.download'
          : 'update.run';
      final receipt = await _call(
        method,
        _updateArguments(request.action, selected),
      );
      if (!_updateInt(receipt) || receipt == 0) return _unknown();
      final job = SystemUpdateJob(
        id: receipt as int,
        action: request.action,
        endpoint: _endpoint,
        currentVersion: before.currentVersion,
        version: selected,
      );
      _jobs[job] = before;
      _reviews.clear();
      _inventories.clear();
      return SystemUpdateResult(
        SystemUpdateOutcome.pending,
        'The server accepted an owned update job. Use Check progress explicitly; do not repeat the request.',
        job: job,
      );
    } on Object {
      if (effectful) return _unknown();
      return const SystemUpdateResult(
        SystemUpdateOutcome.rejected,
        'Local preflight failed. No update-source, download or install request was sent.',
      );
    } finally {
      _calling = false;
    }
  }

  SystemUpdateResult _unknown({SystemUpdateJob? job}) {
    if (job == null) _uncertain = true;
    _reviews.clear();
    _inventories.clear();
    return SystemUpdateResult(
      SystemUpdateOutcome.unknown,
      job == null
          ? 'The operation may have taken effect. Inspect the original endpoint in TrueNAS and reconnect before further changes. Do not repeat this request.'
          : 'The owned job could not be verified. Its lock remains held; explicitly check this same job again or inspect the original endpoint. No operation is replayed.',
      job: job,
    );
  }

  Future<SystemUpdateResult> poll(SystemUpdateJob job) async {
    _guard();
    final baseline = _jobs[job];
    if (baseline == null || _calling || job.endpoint != _endpoint) {
      throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.staleReview,
      );
    }
    _calling = true;
    try {
      final raw = await _call('core.get_jobs', [
        [
          ['id', '=', job.id],
        ],
        {
          'limit': 2,
          'select': [
            'id',
            'method',
            'arguments',
            'state',
            'progress',
            'result',
          ],
        },
      ]);
      if (raw is! List || raw.length != 1 || raw.single is! Map) {
        return _unknown(job: job);
      }
      final row = raw.single as Map;
      if (row['id'] is! int ||
          row['id'] != job.id ||
          row['method'] !=
              (job.action == SystemUpdateAction.download
                  ? 'update.download'
                  : 'update.run') ||
          !_updateWireEqual(
            row['arguments'],
            _updateArguments(job.action, job.version),
          )) {
        return _unknown(job: job);
      }
      final state = row['state'];
      if ({'WAITING', 'RUNNING'}.contains(state)) {
        final progress = row['progress'];
        return SystemUpdateResult(
          SystemUpdateOutcome.pending,
          'Owned ${job.action.name} job is ${state == 'WAITING' ? 'waiting' : 'running'}. Progress is server-reported, not an integrity or boot-success proof.',
          job: job,
          percent: progress is Map ? _updatePercent(progress['percent']) : null,
        );
      }
      if ({'FAILED', 'ABORTED'}.contains(state)) {
        _jobs.remove(job);
        _catalog = null;
        return const SystemUpdateResult(
          SystemUpdateOutcome.failed,
          'The owned job stopped without success. Partial staging or installation effects may remain. Inspect TrueNAS before planning a new operation; no retry, warning bypass or reboot was requested.',
        );
      }
      if (state != 'SUCCESS' || row['result'] != true) {
        return _unknown(job: job);
      }
      if (job.action == SystemUpdateAction.install) {
        final after = await _local();
        final oldActive = baseline.environments.singleWhere((e) => e.active);
        final active = after.environments.where((e) => e.active).toList();
        final next = after.environments.where((e) => e.activated).toList();
        if (!after.bootHealthy ||
            after.failoverLicensed ||
            after.conflictingJob ||
            after.environments.length != baseline.environments.length + 1 ||
            baseline.environments.any((e) => e.id == job.version.version) ||
            after.currentVersion != baseline.currentVersion ||
            after.bootPool != baseline.bootPool ||
            active.length != 1 ||
            !_bootSameIdentity(oldActive, active.single) ||
            next.length != 1 ||
            next.single.id != job.version.version ||
            next.single.active ||
            !next.single.canActivate ||
            baseline.environments.any(
              (old) => !after.environments.any(
                (fresh) => _bootSameRow(old, fresh, ignoreActivated: true),
              ),
            )) {
          return _unknown(job: job);
        }
        _applied = true;
      }
      _jobs.remove(job);
      _catalog = null;
      _reviews.clear();
      _inventories.clear();
      return SystemUpdateResult(
        SystemUpdateOutcome.succeeded,
        job.action == SystemUpdateAction.download
            ? 'The owned download job completed. The public API does not prove a staged-image hash; installation performs its own checks. Nothing was installed or rebooted.'
            : 'The owned install job completed and the new next-boot environment was observed. The running version is unchanged. Reboot separately in TrueNAS; further writes remain blocked in this session.',
        rebootRequired: job.action == SystemUpdateAction.install,
      );
    } on Object {
      return _unknown(job: job);
    } finally {
      _calling = false;
    }
  }
}

bool _updateInt(Object? v) => v is int && v >= 0 && v <= 9007199254740991;
bool _updateText(Object? v, int max) =>
    v is String &&
    v.isNotEmpty &&
    v.length <= max &&
    !RegExp(
      r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
    ).hasMatch(v);
bool _updateToken(Object? v, int max) =>
    _updateText(v, max) &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').stringMatch(v as String) == v;
double? _updatePercent(Object? v) =>
    v is num && v.isFinite && v >= 0 && v <= 100 ? v.toDouble() : null;
List<int>? _updateNumericVersion(String v) {
  final clean = v.replaceFirst(RegExp(r'^TrueNAS(?:-SCALE)?-'), '');
  if (RegExp(r'^\d{2}\.\d{1,2}(?:\.\d{1,4}){0,3}$').stringMatch(clean) !=
      clean) {
    return null;
  }
  return clean.split('.').map(int.parse).toList();
}

bool _updateNewer(String old, String next) {
  final a = _updateNumericVersion(old), b = _updateNumericVersion(next);
  if (a == null || b == null) return false;
  for (var i = 0; i < math.max(a.length, b.length); i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return y > x;
  }
  return false;
}

SystemUpdateVersion _updateVersion(Object? raw, String current) {
  if (raw is! Map ||
      !_updateToken(raw['train'], 128) ||
      raw['version'] is! Map) {
    _updateInvalid();
  }
  final value = raw['version'] as Map;
  final manifest = value['manifest'];
  if (!_updateToken(value['version'], 96) ||
      manifest is! Map ||
      manifest['train'] != raw['train'] ||
      manifest['version'] != value['version'] ||
      !_updateToken(manifest['filename'], 160) ||
      manifest['checksum'] is! String ||
      RegExp(r'^[a-fA-F0-9]{64}$')
              .stringMatch(manifest['checksum'] as String) !=
          manifest['checksum'] ||
      !_updateInt(manifest['filesize']) ||
      manifest['filesize'] == 0 ||
      !_updateToken(manifest['profile'], 32)) {
    _updateInvalid();
  }
  final notes = value['release_notes'];
  return SystemUpdateVersion(
    train: raw['train'] as String,
    version: value['version'] as String,
    filename: manifest['filename'] as String,
    checksum: (manifest['checksum'] as String).toLowerCase(),
    downloadBytes: manifest['filesize'] as int,
    profile: manifest['profile'] as String,
    releaseNotes: notes is String && notes.length <= 32768
        ? notes.replaceAll(
            RegExp(
              r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u202a-\u202e\u2060-\u206f]',
            ),
            '',
          )
        : null,
    blockedReason: !_updateNewer(current, value['version'] as String)
        ? 'Only strictly newer stable numeric releases are supported; no downgrade, same-version reinstall or prerelease.'
        : !{'GENERAL', 'MISSION_CRITICAL'}.contains(manifest['profile'])
        ? 'Developer and early-adopter releases are inspect-only.'
        : null,
  );
}

bool _updateSameVersion(SystemUpdateVersion a, SystemUpdateVersion b) =>
    a.train == b.train &&
    a.version == b.version &&
    a.filename == b.filename &&
    a.checksum == b.checksum &&
    a.downloadBytes == b.downloadBytes &&
    a.profile == b.profile &&
    a.blockedReason == b.blockedReason;
bool _updateSameLocal(SystemUpdateInventory a, SystemUpdateInventory b) =>
    a.endpoint == b.endpoint &&
    a.currentVersion == b.currentVersion &&
    a.bootPool == b.bootPool &&
    a.bootHealthy == b.bootHealthy &&
    a.failoverLicensed == b.failoverLicensed &&
    a.conflictingJob == b.conflictingJob &&
    a.bootSizeBytes == b.bootSizeBytes &&
    a.bootAllocatedBytes == b.bootAllocatedBytes &&
    a.bootFreeBytes == b.bootFreeBytes &&
    a.environments.length == b.environments.length &&
    a.environments.every((e) => b.environments.any((n) => _bootSameRow(e, n)));
List<Object?> _updateArguments(
  SystemUpdateAction action,
  SystemUpdateVersion v,
) => action == SystemUpdateAction.download
    ? [v.train, v.version]
    : [
        {
          'dataset_name': null,
          'resume': false,
          'train': v.train,
          'version': v.version,
          'reboot': false,
        },
      ];
bool _updateWireEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _updateWireEqual(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable.generate(a.length).every((i) => _updateWireEqual(a[i], b[i]));
  }
  return a.runtimeType == b.runtimeType && a == b;
}

Never _updateInvalid() => throw const SystemUpdatesException(
  SystemUpdatesExceptionReason.invalidResponse,
);
