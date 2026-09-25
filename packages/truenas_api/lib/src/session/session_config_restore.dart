part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedConfigurationRestoreSession {
  ConfigurationRestoreCapabilities get configurationRestoreCapabilities;
  Future<ConfigurationRestoreFile> prepareConfigurationRestore(Uint8List bytes);
  Future<ConfigurationRestoreInventory> loadConfigurationRestore();
  Future<ConfigurationRestoreReview> reviewConfigurationRestore(
    ConfigurationRestoreRequest request,
  );
  Future<ConfigurationRestoreResult> executeConfigurationRestore(
    ConfigurationRestoreReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
}

final class ConfigurationRestoreCapabilities {
  const ConfigurationRestoreCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.transferSupported = false,
  });
  const ConfigurationRestoreCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      transferSupported = false;
  final bool connected, versionSupported, available, transferSupported;
  bool get supported =>
      connected && versionSupported && available && transferSupported;
  bool get canRestore => supported;
  String? get blockedReason => !connected
      ? 'Connect before reviewing a configuration restore.'
      : !versionSupported
      ? 'Native configuration restore requires stable TrueNAS 25.10.'
      : !available
      ? 'Required public restoration, token and maintenance-readiness methods are unavailable.'
      : !transferSupported
      ? 'Configuration restore requires the existing Android certificate-pinned upload connection.'
      : null;
}

enum ConfigurationRestoreFormat { database, tar }

/// An opaque sensitive file capsule. The factory consumes its input, retains a
/// separate private byte buffer, and exposes only bounded local envelope facts.
/// A real session accepts only capsules it issued through prepare; this factory
/// is also usable by connector-free previews/fakes, never a session lease.
final class ConfigurationRestoreFile {
  ConfigurationRestoreFile._(
    this._bytes,
    this.sha256,
    this.format,
    this.hasSecretSeed,
    List<String> authorizedKeyMembers,
  ) : byteLength = _bytes!.length,
      authorizedKeyMembers = List.unmodifiable(authorizedKeyMembers);
  factory ConfigurationRestoreFile.fromBytes(Uint8List bytes) {
    Uint8List? copy;
    try {
      if (bytes.length < 512 || bytes.length > _configurationRestoreMaxBytes) {
        _restoreThrow(ConfigurationRestoreExceptionReason.invalidFile);
      }
      copy = Uint8List.fromList(bytes);
      final facts = _restoreInspect(copy);
      final file = ConfigurationRestoreFile._(
        copy,
        crypto.sha256.convert(copy).toString(),
        facts.$1,
        facts.$2,
        facts.$3,
      );
      // Do not relinquish the private-copy cleanup guard before consumption of
      // the supplied buffer succeeds (an immutable hostile buffer can throw).
      bytes.fillRange(0, bytes.length, 0);
      copy = null;
      return file;
    } finally {
      copy?.fillRange(0, copy.length, 0);
      bytes.fillRange(0, bytes.length, 0);
    }
  }
  Uint8List? _bytes;
  final String sha256;
  final int byteLength;
  final ConfigurationRestoreFormat format;
  final bool hasSecretSeed;
  final List<String> authorizedKeyMembers;
  bool get isDisposed => _bytes == null;
  void dispose() {
    _bytes?.fillRange(0, _bytes!.length, 0);
    _bytes = null;
  }
}

final class ConfigurationRestoreInventory {
  ConfigurationRestoreInventory({
    required this.endpoint,
    required this.hostId,
    required this.bootId,
    required this.currentVersion,
    required this.state,
    required this.fullAdmin,
    required this.failoverLicensed,
    required this.conflictingJob,
    required this.bootPool,
    required this.bootHealthy,
    required List<BootEnvironmentSnapshot> environments,
    List<String> rebootReasonCodes = const [],
  }) : environments = List.unmodifiable(environments),
       rebootReasonCodes = List.unmodifiable(rebootReasonCodes);
  final String endpoint, hostId, bootId, currentVersion, state, bootPool;
  final bool fullAdmin, failoverLicensed, conflictingJob, bootHealthy;
  final List<BootEnvironmentSnapshot> environments;
  final List<String> rebootReasonCodes;
  BootEnvironmentSnapshot? get currentEnvironment =>
      environments.where((e) => e.active).singleOrNull;
  BootEnvironmentSnapshot? get nextEnvironment =>
      environments.where((e) => e.activated).singleOrNull;
  String? get blockedReason => !fullAdmin
      ? 'Configuration restore requires FULL_ADMIN privileges.'
      : failoverLicensed
      ? 'HA configuration restore requires the coordinated TrueNAS recovery workflow.'
      : state != 'READY'
      ? 'The original server must report READY.'
      : conflictingJob
      ? 'An active or waiting server job prevents configuration restore.'
      : !bootHealthy
      ? 'The boot pool must be healthy, online and not scanning.'
      : currentEnvironment == null || nextEnvironment == null
      ? 'Exactly one current and one next-boot environment are required.'
      : !currentEnvironment!.canActivate ||
            currentEnvironment!.id != nextEnvironment!.id
      ? 'A different or non-bootable next environment requires the TrueNAS recovery workflow.'
      : null;
}

final class ConfigurationRestoreRequest {
  const ConfigurationRestoreRequest({
    required this.inventory,
    required this.file,
  });
  final ConfigurationRestoreInventory inventory;
  final ConfigurationRestoreFile file;
  String get target => 'RESTORE ${inventory.hostId}';
  String? get validationError =>
      inventory.blockedReason ??
      (file.isDisposed
          ? 'The selected configuration file was discarded. Choose and inspect it again.'
          : null);
}

final class ConfigurationRestoreReview {
  ConfigurationRestoreReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final ConfigurationRestoreRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
}

enum ConfigurationRestoreOutcome { accepted, rejected, unknown }

final class ConfigurationRestoreResult {
  const ConfigurationRestoreResult(this.outcome, this.message, {this.jobId});
  final ConfigurationRestoreOutcome outcome;
  final String message;
  final int? jobId;
}

enum ConfigurationRestoreExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  unsupportedTransport,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  invalidFile,
  unavailable,
}

final class ConfigurationRestoreException implements Exception {
  const ConfigurationRestoreException(this.reason);
  final ConfigurationRestoreExceptionReason reason;
  String get userMessage => switch (reason) {
    ConfigurationRestoreExceptionReason.notAuthenticated =>
      'Connect again before reviewing configuration restore.',
    ConfigurationRestoreExceptionReason.unsupportedVersion =>
      'Native configuration restore requires stable TrueNAS 25.10.',
    ConfigurationRestoreExceptionReason.unavailableMethod =>
      'Required public configuration restore methods are unavailable.',
    ConfigurationRestoreExceptionReason.unsupportedTransport => 'This connection does not support existing-session certificate-pinned upload.',
    ConfigurationRestoreExceptionReason.busy => 'Another operation is active or a restoration requires independent original-server recovery inspection.',
    ConfigurationRestoreExceptionReason.staleReview => 'The connection, file, readiness, review or foreground authorization changed. No configuration upload was submitted.',
    ConfigurationRestoreExceptionReason.invalidRequest => 'Choose a ready standalone FULL_ADMIN session with a healthy unchanged boot environment and a valid inspected file.',
    ConfigurationRestoreExceptionReason.invalidResponse => 'Configuration restoration readiness or authorization could not be validated.',
    ConfigurationRestoreExceptionReason.invalidFile => 'Choose a supported SQLite or uncompressed configuration TAR file between 512 bytes and 10 MiB. This is only an envelope inspection, not a restore validation.',
    ConfigurationRestoreExceptionReason.unavailable => 'Configuration restoration is unavailable. Private file and remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _configurationRestoreMaxBytes = 10485760;

final class _ConfigurationRestoreLease {
  const _ConfigurationRestoreLease(this.created, this.proof, this.fileHash);
  final DateTime created;
  final String proof, fileHash;
}

final class _SessionConfigurationRestore {
  _SessionConfigurationRestore({
    required this.client,
    required this.transport,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherMutationBusy,
    required this.requestTimeout,
    DateTime Function()? now,
  }) : _version =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       _endpoint = summary.endpointUri.toString(),
       _metadata = metadata is Map ? Map.of(metadata) : const {},
       _now = now ?? DateTime.now {
    _powerReader = _SessionSystemPower(
      client: client,
      summary: summary,
      metadata: metadata,
      nextId: nextId,
      isCurrent: _current,
      isOtherMutationBusy: isOtherMutationBusy,
      requestTimeout: requestTimeout,
      now: now,
    );
  }
  final JsonRpcClient client;
  final ConfigurationRestoreUploadTransport? transport;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _version;
  final String _endpoint;
  final Map _metadata;
  final DateTime Function() _now;
  late final _SessionSystemPower _powerReader;
  bool _calling = false, _terminal = false;
  bool Function()? _operationCurrent;
  ConfigurationRestoreFile? _operationFile;
  final Set<ConfigurationRestoreFile> _files = {};
  final Set<ConfigurationRestoreInventory> _inventories = {};
  final Map<ConfigurationRestoreReview, _ConfigurationRestoreLease> _reviews =
      {};
  bool get isBusy => _calling || _terminal;
  bool _current() {
    try {
      return isCurrent() &&
          (_operationCurrent?.call() ?? true) &&
          !(_operationFile?.isDisposed ?? false);
    } on Object {
      return false;
    }
  }

  bool _method(String name, {bool job = false, bool uploadable = false}) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == job &&
        row['uploadable'] == uploadable &&
        row['downloadable'] == false &&
        row['private'] != true &&
        row['_private'] != true &&
        row['no_auth_required'] == false;
  }

  ConfigurationRestoreCapabilities get capabilities =>
      ConfigurationRestoreCapabilities(
        connected: isCurrent(),
        versionSupported: _version,
        available:
            _powerReads.every(_method) &&
            _method('auth.me') &&
            _method('auth.generate_token') &&
            _method('config.upload', job: true, uploadable: true),
        transferSupported:
            transport?.configurationRestoreUploadSupported == true,
      );
  void _guard() {
    if (!isCurrent()) {
      _restoreThrow(ConfigurationRestoreExceptionReason.notAuthenticated);
    }
    if (!_current()) {
      _restoreThrow(ConfigurationRestoreExceptionReason.staleReview);
    }
    if (!_version) {
      _restoreThrow(ConfigurationRestoreExceptionReason.unsupportedVersion);
    }
    if (!capabilities.available) {
      _restoreThrow(ConfigurationRestoreExceptionReason.unavailableMethod);
    }
    if (!capabilities.transferSupported) {
      _restoreThrow(ConfigurationRestoreExceptionReason.unsupportedTransport);
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

  ConfigurationRestoreFile prepare(Uint8List bytes) {
    try {
      _guard();
      if (isBusy || isOtherMutationBusy()) {
        _restoreThrow(ConfigurationRestoreExceptionReason.busy);
      }
      _clearFiles();
      _reviews.clear();
      final file = ConfigurationRestoreFile.fromBytes(bytes);
      _files.add(file);
      return file;
    } on ConfigurationRestoreException {
      rethrow;
    } on Object {
      _restoreThrow(ConfigurationRestoreExceptionReason.invalidFile);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<ConfigurationRestoreInventory> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const []));
    // Reuse the source-audited public power readiness projection, never its
    // execution path: host/boot/version/state/HA/boot pool/environments/jobs.
    final power = await _powerReader._read();
    final finalAdmin = _configurationBackupAdmin(
      await _call('auth.me', const []),
    );
    if (admin != finalAdmin) {
      _restoreThrow(ConfigurationRestoreExceptionReason.staleReview);
    }
    _guard();
    return ConfigurationRestoreInventory(
      endpoint: power.endpoint,
      hostId: power.hostId,
      bootId: power.bootId,
      currentVersion: power.currentVersion,
      state: power.state,
      fullAdmin: admin,
      failoverLicensed: power.failoverLicensed,
      conflictingJob: power.conflictingJob,
      bootPool: power.bootPool,
      bootHealthy: power.bootHealthy,
      environments: power.environments,
      rebootReasonCodes: power.rebootReasonCodes,
    );
  }

  Future<ConfigurationRestoreInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _restoreThrow(ConfigurationRestoreExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final inventory = await _read();
      if (isOtherMutationBusy()) {
        _restoreThrow(ConfigurationRestoreExceptionReason.busy);
      }
      _inventories.add(inventory);
      return inventory;
    } on ConfigurationRestoreException {
      rethrow;
    } on Object {
      _restoreThrow(ConfigurationRestoreExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  void _file(ConfigurationRestoreFile file, {String? hash}) {
    if (!_files.contains(file) ||
        file.isDisposed ||
        file._bytes!.length != file.byteLength ||
        file.byteLength < 512 ||
        file.byteLength > _configurationRestoreMaxBytes ||
        crypto.sha256.convert(file._bytes!).toString() !=
            (hash ?? file.sha256)) {
      _restoreThrow(ConfigurationRestoreExceptionReason.staleReview);
    }
  }

  Future<ConfigurationRestoreReview> review(
    ConfigurationRestoreRequest request,
  ) async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _restoreThrow(ConfigurationRestoreExceptionReason.busy);
    }
    if (!_inventories.contains(request.inventory) ||
        request.inventory.endpoint != _endpoint) {
      _restoreThrow(ConfigurationRestoreExceptionReason.staleReview);
    }
    _file(request.file);
    if (request.validationError != null) {
      _restoreThrow(ConfigurationRestoreExceptionReason.invalidRequest);
    }
    _calling = true;
    _reviews.clear();
    try {
      final fresh = await _read();
      final proof = _restoreProof(request.inventory);
      _file(request.file);
      if (fresh.blockedReason != null ||
          proof != _restoreProof(fresh) ||
          isOtherMutationBusy()) {
        _restoreThrow(ConfigurationRestoreExceptionReason.staleReview);
      }
      final review = ConfigurationRestoreReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'Restoring replaces server configuration and automatically requests a reboot with a 10-second delay in TrueNAS 25.10.1. This is not a dry run; no no-reboot option, cancellation, rollback, retry or automatic reconnect is offered.',
          'The uploaded configuration can replace accounts, credentials, network addresses, certificates, shares and services. Existing access may be lost and the server may not return. Independently verify console or physical access, current backups and all required recovery material first.',
          'Only this local file envelope, byte count, SHA-256 hash and actual archive member presence were inspected. Its source server, TrueNAS version, authenticity, database integrity, migration compatibility and recovery completeness are not verified. Do not restore an untrusted or incompatible file.',
          request.file.hasSecretSeed
              ? 'This archive contains a password-secret-seed member. It will replace the current seed on restart. Presence is not proof that it matches the database or can recover stored credentials or dataset keys.'
              : 'NO PASSWORD SECRET SEED is present. TrueNAS removes the existing seed on restart when the upload lacks it. Stored encrypted credentials or dataset keys may become unrecoverable. Independently confirm the intended recovery plan before proceeding.',
          'TrueNAS removes existing admin, truenas_admin and root authorized-key files on restart when their corresponding files are absent from the upload. Actual included authorized-key members: ${request.file.authorizedKeyMembers.isEmpty ? 'none' : request.file.authorizedKeyMembers.join(', ')}. This can remove SSH access.',
          'Every configuration file is sensitive. The database may contain stored dataset encryption keys, SSH private keys and other secrets; the password secret seed may decrypt them. This is not a separate or complete encryption-key backup. Keep independent recovery-key material.',
          'Storage contents, snapshots, application data and VM data are not restored by this upload. Boot-pool health and current/next environment are checked, but free-space sufficiency, workload quiescence and restored service correctness are not proven.',
          'A short-lived, origin-matched, single-use authentication token is created from this session. It inherits session privileges and is not restricted to this method. No token is displayed, cached or logged. If authorization is cancelled before upload, an already minted token may remain until its inactivity limit or session invalidation; revocation is not claimed.',
          'HTTP 200 and a positive config.upload job ID acknowledge acceptance only, not successful migration, reboot or recovery. A connection loss or any uncertain upload may already have changed the server. Accepted and unknown submissions block further writes until independent original-server recovery inspection and deliberate reconnection; do not repeat the upload to test it.',
        ],
      );
      _reviews[review] = _ConfigurationRestoreLease(
        _now(),
        proof,
        request.file.sha256,
      );
      return review;
    } on ConfigurationRestoreException {
      rethrow;
    } on Object {
      _restoreThrow(ConfigurationRestoreExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<ConfigurationRestoreResult> execute(
    ConfigurationRestoreReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    final lease = _reviews.remove(
      review,
    ); // Every execution attempt consumes its review.
    var sent = false, owns = false;
    Uint8List? uploadBytes;
    bool authorized() {
      try {
        return isCurrent();
      } on Object {
        return false;
      }
    }

    bool validAge() {
      if (lease == null) return false;
      final age = _now().difference(lease.created);
      return !age.isNegative && age <= const Duration(minutes: 5);
    }

    try {
      _guard();
      if (isBusy || isOtherMutationBusy()) {
        _restoreThrow(ConfigurationRestoreExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !validAge() ||
          confirmation != review.target ||
          review.endpoint != _endpoint ||
          review.request.validationError != null) {
        _restoreThrow(ConfigurationRestoreExceptionReason.staleReview);
      }
      _file(review.request.file, hash: lease.fileHash);
      _calling = true;
      owns = true;
      _operationCurrent = isCurrent;
      _operationFile = review.request.file;
      final fresh = await _read();
      _file(review.request.file, hash: lease.fileHash);
      _guard();
      if (!validAge() ||
          fresh.blockedReason != null ||
          _restoreProof(fresh) != lease.proof ||
          isOtherMutationBusy()) {
        _restoreThrow(ConfigurationRestoreExceptionReason.staleReview);
      }
      // Token attributes must be empty for get_token_for_action. The generated
      // token inherits this session's privileges; it is not method-scoped.
      final token = await _call('auth.generate_token', const [
        60,
        {},
        true,
        true,
      ]);
      _file(review.request.file, hash: lease.fileHash);
      _guard();
      if (!validAge() || isOtherMutationBusy()) {
        _restoreThrow(ConfigurationRestoreExceptionReason.staleReview);
      }
      if (token is! String ||
          RegExp(r'^[A-Za-z0-9_-]{32,512}$').stringMatch(token) != token) {
        _restoreThrow(ConfigurationRestoreExceptionReason.invalidResponse);
      }
      uploadBytes = Uint8List.fromList(review.request.file._bytes!);
      if (crypto.sha256.convert(uploadBytes).toString() != lease.fileHash ||
          !authorized() ||
          !validAge()) {
        _restoreThrow(ConfigurationRestoreExceptionReason.staleReview);
      }
      _guard();
      // There are no further preflight awaits. Ownership of this dedicated copy
      // moves to the transport; closing/disposing the UI capsule cannot alter it.
      final transferred = uploadBytes;
      uploadBytes = null;
      sent = true;
      final Future<int> upload;
      try {
        upload = transport!.uploadConfigurationRestore(
          token: token,
          bytes: transferred,
        );
      } on Object {
        transferred.fillRange(0, transferred.length, 0);
        rethrow;
      }
      // Do not wipe a transport-owned buffer on Future.timeout while it may
      // still be read by native upload. Its actual settlement always wipes it.
      final completion = upload.whenComplete(
        () => transferred.fillRange(0, transferred.length, 0),
      );
      final jobId = await completion.timeout(requestTimeout);
      _fence();
      if (!_powerId(jobId)) return _unknown();
      return ConfigurationRestoreResult(
        ConfigurationRestoreOutcome.accepted,
        'TrueNAS returned a configuration-upload job ID. Acceptance is acknowledged only; migration, automatic reboot and recovery are unverified. Inspect the original server independently before deliberately reconnecting. Do not repeat the upload.',
        jobId: jobId,
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return ConfigurationRestoreResult(
        ConfigurationRestoreOutcome.rejected,
        error is ConfigurationRestoreException ? error.userMessage : 'Configuration restore preflight failed or foreground authorization expired. No configuration upload was submitted. An already minted token is not claimed revoked.',
      );
    } finally {
      uploadBytes?.fillRange(0, uploadBytes.length, 0);
      // A valid consumed lease cannot reuse the same sensitive input after any
      // execute attempt. Forged/replayed attempts cannot dispose another lease.
      if (lease != null) {
        review.request.file.dispose();
        _files.remove(review.request.file);
      }
      if (owns) {
        _operationCurrent = null;
        _operationFile = null;
        _calling = false;
      }
    }
  }

  void _fence() {
    _terminal = true;
    _operationFile = null;
    dispose();
  }

  ConfigurationRestoreResult _unknown() {
    _fence();
    return const ConfigurationRestoreResult(
      ConfigurationRestoreOutcome.unknown,
      'A configuration upload may already have changed TrueNAS and scheduled an automatic reboot, but its outcome is unknown. No recovery is verified. Inspect the original server independently before deliberately reconnecting; do not repeat the upload.',
    );
  }

  void _clearFiles() {
    for (final file in _files) {
      file.dispose();
    }
    _files.clear();
  }

  void dispose() {
    _clearFiles();
    _inventories.clear();
    _reviews.clear();
  }
}

String _restoreProof(ConfigurationRestoreInventory inventory) => jsonEncode([
  inventory.endpoint,
  inventory.hostId,
  inventory.bootId,
  inventory.currentVersion,
  inventory.state,
  inventory.fullAdmin,
  inventory.failoverLicensed,
  inventory.conflictingJob,
  inventory.bootPool,
  inventory.bootHealthy,
  inventory.rebootReasonCodes,
  for (final e in inventory.environments)
    [e.id, e.dataset, e.created, e.active, e.activated, e.keep, e.canActivate],
]);

Never _restoreThrow(ConfigurationRestoreExceptionReason reason) =>
    throw ConfigurationRestoreException(reason);

(ConfigurationRestoreFormat, bool, List<String>) _restoreInspect(
  Uint8List bytes,
) {
  if (bytes.length < 512 || bytes.length > _configurationRestoreMaxBytes) {
    _restoreThrow(ConfigurationRestoreExceptionReason.invalidFile);
  }
  if (_configurationBackupSqlite(bytes)) {
    return (ConfigurationRestoreFormat.database, false, const []);
  }
  const dummy = ConfigurationBackupInventory(
    endpoint: '',
    hostId: '',
    currentVersion: '',
    state: '',
    fullAdmin: false,
    failoverLicensed: false,
    conflictingJob: false,
  );
  bool valid(bool seed) => _configurationBackupFile(
    bytes,
    ConfigurationBackupRequest(
      inventory: dummy,
      includeSecretSeed: seed,
      includeAuthorizedKeys: true,
    ),
  );
  final seed = !valid(false);
  if (seed && !valid(true)) {
    _restoreThrow(ConfigurationRestoreExceptionReason.invalidFile);
  }
  // The shared backup envelope validator above has already checked every bound,
  // checksum, allowed path/type/member, PAX record and trailing block.
  final keys = <String>[];
  var offset = 0;
  while (offset + 512 <= bytes.length) {
    final header = Uint8List.sublistView(bytes, offset, offset + 512);
    if (header.every((byte) => byte == 0)) break;
    final name = _configurationBackupTarText(header, 0, 100)!;
    final size = _configurationBackupOctal(header, 124, 12)!;
    if (const {
      'admin_authorized_keys',
      'truenas_admin_authorized_keys',
      'root_authorized_keys',
    }.contains(name)) {
      keys.add(name);
    }
    offset += 512 + ((size + 511) ~/ 512) * 512;
  }
  keys.sort();
  return (ConfigurationRestoreFormat.tar, seed, keys);
}
