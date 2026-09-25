part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedConfigurationBackupSession {
  ConfigurationBackupCapabilities get configurationBackupCapabilities;
  Future<ConfigurationBackupInventory> loadConfigurationBackup();
  Future<ConfigurationBackupReview> reviewConfigurationBackup(
    ConfigurationBackupRequest request,
  );
  Future<ConfigurationBackupResult> executeConfigurationBackup(
    ConfigurationBackupReview review,
    String confirmation,
  );
}

final class ConfigurationBackupCapabilities {
  const ConfigurationBackupCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.transferSupported = false,
  });
  const ConfigurationBackupCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      transferSupported = false;
  final bool connected, versionSupported, available, transferSupported;
  bool get supported =>
      connected && versionSupported && available && transferSupported;
  bool get canExport => supported;
  String? get blockedReason => !connected
      ? 'Connect before reviewing a configuration backup.'
      : !versionSupported
      ? 'Native configuration backup requires stable TrueNAS 25.10.'
      : !available
      ? 'Required public configuration backup and readiness methods are unavailable.'
      : !transferSupported
      ? 'Configuration backup requires a same-session certificate-pinned file transfer. This connection does not support it.'
      : null;
}

final class ConfigurationBackupInventory {
  const ConfigurationBackupInventory({
    required this.endpoint,
    required this.hostId,
    required this.currentVersion,
    required this.state,
    required this.fullAdmin,
    required this.failoverLicensed,
    required this.conflictingJob,
  });
  final String endpoint, hostId, currentVersion, state;
  final bool fullAdmin, failoverLicensed, conflictingJob;
  String? get blockedReason => !fullAdmin
      ? 'Configuration backup requires the FULL_ADMIN role.'
      : failoverLicensed
      ? 'HA configuration backup requires the coordinated TrueNAS workflow.'
      : state != 'READY'
      ? 'The original server must report READY.'
      : conflictingJob
      ? 'An active or waiting server job prevents a new configuration backup.'
      : null;
}

final class ConfigurationBackupRequest {
  const ConfigurationBackupRequest({
    required this.inventory,
    this.includeSecretSeed = false,
    this.includeAuthorizedKeys = false,
  });
  final ConfigurationBackupInventory inventory;
  final bool includeSecretSeed, includeAuthorizedKeys;
  String get target => 'BACKUP ${inventory.hostId}';
  String? get validationError => inventory.blockedReason;
  String get filename => includeSecretSeed || includeAuthorizedKeys
      ? 'truenas-configuration.tar'
      : 'truenas-configuration.db';
}

final class ConfigurationBackupReview {
  ConfigurationBackupReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final ConfigurationBackupRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
}

/// Sensitive, single-owner bytes. No token, remote filename or archive contents
/// are exposed as text. The recipient of [takeBytes] must wipe the returned
/// buffer after saving. Dart/platform copies cannot be guaranteed erased.
final class ConfigurationBackupArtifact {
  ConfigurationBackupArtifact({
    required Uint8List bytes,
    required this.filename,
    required this.includesSecretSeed,
    required this.includesAuthorizedKeys,
    // Keep bytes named and public while retaining private mutable ownership.
    // ignore: prefer_initializing_formals
  }) : _bytes = bytes;
  Uint8List? _bytes;
  final String filename;
  final bool includesSecretSeed, includesAuthorizedKeys;
  int get byteLength => _bytes?.length ?? 0;
  bool get isDisposed => _bytes == null;
  Uint8List takeBytes() {
    final bytes = _bytes;
    if (bytes == null) {
      throw StateError('Configuration backup bytes are unavailable.');
    }
    _bytes = null;
    return bytes;
  }

  void dispose() {
    _bytes?.fillRange(0, _bytes!.length, 0);
    _bytes = null;
  }
}

enum ConfigurationBackupOutcome { completed, rejected, unknown }

final class ConfigurationBackupResult {
  const ConfigurationBackupResult(
    this.outcome,
    this.message, {
    this.jobId,
    this.artifact,
  });
  final ConfigurationBackupOutcome outcome;
  final String message;
  final int? jobId;
  final ConfigurationBackupArtifact? artifact;
}

enum ConfigurationBackupExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  unsupportedTransport,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class ConfigurationBackupException implements Exception {
  const ConfigurationBackupException(this.reason);
  final ConfigurationBackupExceptionReason reason;
  String get userMessage => switch (reason) {
    ConfigurationBackupExceptionReason.notAuthenticated =>
      'Connect again before reviewing a configuration backup.',
    ConfigurationBackupExceptionReason.unsupportedVersion =>
      'Native configuration backup requires stable TrueNAS 25.10.',
    ConfigurationBackupExceptionReason.unavailableMethod =>
      'Required public configuration backup methods are unavailable.',
    ConfigurationBackupExceptionReason.unsupportedTransport => 'This connection does not support same-session certificate-pinned configuration transfer.',
    ConfigurationBackupExceptionReason.busy => 'Another operation is active or a backup requires original-server job inspection before reconnecting.',
    ConfigurationBackupExceptionReason.staleReview => 'The original server, privileges, readiness or review changed. Reload and review again.',
    ConfigurationBackupExceptionReason.invalidRequest => 'Choose a ready standalone server with FULL_ADMIN privileges and no visible active jobs.',
    ConfigurationBackupExceptionReason.invalidResponse =>
      'Configuration backup information or file bytes could not be validated.',
    ConfigurationBackupExceptionReason.unavailable =>
      'Configuration backup is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _configurationBackupReads = {
  'system.version_short',
  'system.host_id',
  'system.state',
  'failover.licensed',
  'auth.me',
  'core.get_jobs',
};
const _configurationBackupMaxBytes = 16 * 1024 * 1024;

final class _ConfigurationBackupLease {
  const _ConfigurationBackupLease(this.created, this.proof);
  final DateTime created;
  final String proof;
}

final class _SessionConfigurationBackup {
  _SessionConfigurationBackup({
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
       _sessionVersion = summary.version,
       _endpoint = summary.endpointUri.toString(),
       _metadata = metadata is Map ? Map.of(metadata) : const {},
       _now = now ?? DateTime.now;
  final JsonRpcClient client;
  final ConfigurationBackupDownloadTransport? transport;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _version;
  final String _sessionVersion, _endpoint;
  final Map _metadata;
  final DateTime Function() _now;
  bool _calling = false, _terminal = false;
  final Set<ConfigurationBackupInventory> _inventories = {};
  final Map<ConfigurationBackupReview, _ConfigurationBackupLease> _reviews = {};
  bool get isBusy => _calling || _terminal;
  bool _method(String name, {bool job = false, bool downloadable = false}) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == job &&
        row['uploadable'] == false &&
        row['downloadable'] == downloadable &&
        row['private'] != true &&
        row['_private'] != true &&
        row['no_auth_required'] == false;
  }

  ConfigurationBackupCapabilities get capabilities =>
      ConfigurationBackupCapabilities(
        connected: isCurrent(),
        versionSupported: _version,
        available:
            _configurationBackupReads.every(_method) &&
            _method('core.download') &&
            _method('config.save', job: true, downloadable: true),
        transferSupported:
            transport?.configurationBackupDownloadSupported == true,
      );
  void _guard() {
    if (!isCurrent()) {
      _configurationBackupThrow(
        ConfigurationBackupExceptionReason.notAuthenticated,
      );
    }
    if (!_version) {
      _configurationBackupThrow(
        ConfigurationBackupExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.available) {
      _configurationBackupThrow(
        ConfigurationBackupExceptionReason.unavailableMethod,
      );
    }
    if (!capabilities.transferSupported) {
      _configurationBackupThrow(
        ConfigurationBackupExceptionReason.unsupportedTransport,
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

  Future<ConfigurationBackupInventory> _read() async {
    final version = await _call('system.version_short', const []);
    final host = await _call('system.host_id', const []);
    final state = await _call('system.state', const []);
    final licensed = await _call('failover.licensed', const []);
    final admin = _configurationBackupAdmin(await _call('auth.me', const []));
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
    if (version != _sessionVersion ||
        !_powerText(version, 96) ||
        host is! String ||
        RegExp(r'^[0-9a-f]{64}$').stringMatch(host) != host ||
        !const {'BOOTING', 'READY', 'SHUTTING_DOWN'}.contains(state) ||
        licensed is! bool ||
        jobs is! List ||
        jobs.length > 128) {
      _configurationBackupThrow(
        ConfigurationBackupExceptionReason.invalidResponse,
      );
    }
    final ids = <int>{};
    for (final row in jobs) {
      if (row is! Map ||
          !_powerId(row['id']) ||
          !ids.add(row['id'] as int) ||
          !_configurationBackupMethodName(row['method']) ||
          !const {'WAITING', 'RUNNING'}.contains(row['state'])) {
        _configurationBackupThrow(
          ConfigurationBackupExceptionReason.invalidResponse,
        );
      }
    }
    if (host != await _call('system.host_id', const []) ||
        version != await _call('system.version_short', const []) ||
        state != await _call('system.state', const []) ||
        admin != _configurationBackupAdmin(await _call('auth.me', const []))) {
      _configurationBackupThrow(ConfigurationBackupExceptionReason.staleReview);
    }
    return ConfigurationBackupInventory(
      endpoint: _endpoint,
      hostId: host,
      currentVersion: version as String,
      state: state as String,
      fullAdmin: admin,
      failoverLicensed: licensed,
      conflictingJob: jobs.isNotEmpty,
    );
  }

  Future<ConfigurationBackupInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _configurationBackupThrow(ConfigurationBackupExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final inventory = await _read();
      if (isOtherMutationBusy()) {
        _configurationBackupThrow(ConfigurationBackupExceptionReason.busy);
      }
      _inventories.add(inventory);
      return inventory;
    } on ConfigurationBackupException {
      rethrow;
    } on Object {
      _configurationBackupThrow(ConfigurationBackupExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<ConfigurationBackupResult> execute(
    ConfigurationBackupReview review,
    String confirmation,
  ) async {
    final lease = _reviews.remove(review); // Every attempt consumes the lease.
    var sent = false, owns = false;
    int? jobId;
    Uint8List? bytes;
    try {
      _guard();
      if (isBusy || isOtherMutationBusy()) {
        _configurationBackupThrow(ConfigurationBackupExceptionReason.busy);
      }
      final age = lease == null ? null : _now().difference(lease.created);
      if (lease == null ||
          review.endpoint != _endpoint ||
          confirmation != review.target ||
          age!.isNegative ||
          age > const Duration(minutes: 5) ||
          review.request.validationError != null) {
        _configurationBackupThrow(
          ConfigurationBackupExceptionReason.staleReview,
        );
      }
      _calling = true;
      owns = true;
      final fresh = await _read();
      final dispatchAge = _now().difference(lease.created);
      if (fresh.blockedReason != null ||
          _configurationBackupProof(fresh) != lease.proof ||
          isOtherMutationBusy() ||
          dispatchAge.isNegative ||
          dispatchAge > const Duration(minutes: 5)) {
        _configurationBackupThrow(
          ConfigurationBackupExceptionReason.staleReview,
        );
      }
      _guard();
      sent = true;
      final receipt = await _call('core.download', [
        'config.save',
        [
          {
            'secretseed': review.request.includeSecretSeed,
            'pool_keys': false,
            'root_authorized_keys': review.request.includeAuthorizedKeys,
          },
        ],
        review.request.filename,
        false,
      ]);
      if (receipt is! List ||
          receipt.length != 2 ||
          !_powerId(receipt[0]) ||
          !_configurationBackupUrl(receipt[1], receipt[0] as int)) {
        _configurationBackupThrow(
          ConfigurationBackupExceptionReason.invalidResponse,
        );
      }
      jobId = receipt[0] as int;
      var abandoned = false;
      // Future.timeout cannot cancel a platform download. Any late response is
      // explicitly wiped rather than leaving an abandoned secret byte buffer.
      final transfer = transport!
          .downloadConfigurationBackup(
            relativeUrl: receipt[1] as String,
            jobId: jobId,
          )
          .then((value) {
            if (abandoned) value.fillRange(0, value.length, 0);
            return value;
          });
      try {
        bytes = await transfer.timeout(requestTimeout);
      } finally {
        abandoned = true;
      }
      _guard();
      if (isOtherMutationBusy() ||
          bytes.isEmpty ||
          bytes.length > _configurationBackupMaxBytes) {
        _configurationBackupThrow(
          ConfigurationBackupExceptionReason.invalidResponse,
        );
      }
      // HTTP 200/EOF precedes job completion in file_app.py. Query only this
      // exact job once; RUNNING/WAITING is unknown, never a successful backup.
      final jobs = await _call('core.get_jobs', [
        [
          ['id', '=', jobId],
        ],
        {
          'limit': 2,
          'select': ['id', 'method', 'state', 'error', 'result'],
        },
      ]);
      if (jobs is! List || jobs.length != 1 || jobs.single is! Map) {
        _configurationBackupThrow(
          ConfigurationBackupExceptionReason.invalidResponse,
        );
      }
      final job = jobs.single as Map;
      if (job['id'] != jobId ||
          job['method'] != 'config.save' ||
          !job.containsKey('error') ||
          !job.containsKey('result')) {
        _configurationBackupThrow(
          ConfigurationBackupExceptionReason.invalidResponse,
        );
      }
      if (const {'FAILED', 'ABORTED'}.contains(job['state'])) {
        _inventories.clear();
        _reviews.clear();
        return ConfigurationBackupResult(
          ConfigurationBackupOutcome.rejected,
          'The configuration export job did not succeed. Downloaded bytes were discarded; remote job details were withheld.',
          jobId: jobId,
        );
      }
      if (job['state'] != 'SUCCESS' ||
          job['error'] != null ||
          job['result'] != null ||
          !_configurationBackupFile(bytes, review.request)) {
        _configurationBackupThrow(
          ConfigurationBackupExceptionReason.invalidResponse,
        );
      }
      if (await _call('system.host_id', const []) != fresh.hostId ||
          await _call('system.version_short', const []) !=
              fresh.currentVersion ||
          await _call('system.state', const []) != 'READY' ||
          !_configurationBackupAdmin(await _call('auth.me', const []))) {
        _configurationBackupThrow(
          ConfigurationBackupExceptionReason.staleReview,
        );
      }
      _guard();
      if (isOtherMutationBusy()) {
        _configurationBackupThrow(ConfigurationBackupExceptionReason.busy);
      }
      final artifact = ConfigurationBackupArtifact(
        bytes: bytes,
        filename: review.request.filename,
        includesSecretSeed: review.request.includeSecretSeed,
        includesAuthorizedKeys: review.request.includeAuthorizedKeys,
      );
      bytes = null; // Ownership moves to the one-use artifact, then the saver.
      _inventories.clear();
      _reviews.clear();
      return ConfigurationBackupResult(
        ConfigurationBackupOutcome.completed,
        'The bounded configuration file and successful export job were verified. Save the sensitive file to a trusted destination; restore readiness is unverified.',
        jobId: jobId,
        artifact: artifact,
      );
    } on Object catch (error) {
      if (sent) {
        _terminal = true;
        _inventories.clear();
        _reviews.clear();
        return ConfigurationBackupResult(
          ConfigurationBackupOutcome.unknown,
          'The configuration export may have started, but a safe complete file could not be verified. No file was released. Inspect the original server jobs independently before deliberately reconnecting; do not repeat the export.',
          jobId: jobId,
        );
      }
      return ConfigurationBackupResult(
        ConfigurationBackupOutcome.rejected,
        error is ConfigurationBackupException
            ? error.userMessage
            : 'Configuration backup preflight failed. No export was submitted.',
      );
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      if (owns) _calling = false;
    }
  }

  Future<ConfigurationBackupReview> review(
    ConfigurationBackupRequest request,
  ) async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _configurationBackupThrow(ConfigurationBackupExceptionReason.busy);
    }
    if (!_inventories.contains(request.inventory) ||
        request.inventory.endpoint != _endpoint) {
      _configurationBackupThrow(ConfigurationBackupExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      _configurationBackupThrow(
        ConfigurationBackupExceptionReason.invalidRequest,
      );
    }
    _calling = true;
    _reviews.clear();
    try {
      final fresh = await _read();
      final proof = _configurationBackupProof(request.inventory);
      if (fresh.blockedReason != null ||
          proof != _configurationBackupProof(fresh) ||
          isOtherMutationBusy()) {
        _configurationBackupThrow(
          ConfigurationBackupExceptionReason.staleReview,
        );
      }
      final review = ConfigurationBackupReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'Every configuration backup is sensitive, including database-only exports. It can contain credentials, password hashes, identities and private server configuration. Store it only in a destination you trust; cloud-backed document providers may synchronize it.',
          request.includeSecretSeed
              ? 'The selected password secret seed permits decryption of saved configuration secrets. This export is not encrypted by the app and must be protected like administrator credentials.'
              : 'The password secret seed is excluded. This is not a complete recovery backup: encrypted configuration credentials may not be recoverable without the original seed.',
          request.includeAuthorizedKeys
              ? 'Existing admin, truenas_admin and root SSH authorized-key files are requested. Missing files are not invented. This option adds authorized-key files; the configuration database may already contain stored SSH private keys and other secrets.'
              : 'SSH authorized-key files are excluded. Their preservation on restore is not guaranteed.',
          'Storage data, dataset contents and snapshots are not backed up. This is not a separate or complete encryption-key export: stored dataset encryption keys and other secrets may be present in the configuration database and may be decrypted with the secret seed. Keep independent recovery-key backups. The pool_keys option is ignored by TrueNAS SCALE and is always false.',
          'The original host, stable version, FULL_ADMIN privilege, READY standalone state and visible job headers are rechecked. This is not an atomic database snapshot, integrity check, recovery rehearsal or guarantee against another administrator changing configuration.',
          'Only a bounded file download and matching successful config.save job are accepted. A successful download is not proof that the file was saved safely or can restore the server. The app does not upload, reset configuration or reboot.',
          'If transfer or completion is uncertain, no file is released and this connection remains blocked. Inspect the original server jobs independently before deliberately reconnecting. Do not repeat export to test whether it worked.',
        ],
      );
      _reviews[review] = _ConfigurationBackupLease(_now(), proof);
      return review;
    } on ConfigurationBackupException {
      rethrow;
    } on Object {
      _configurationBackupThrow(ConfigurationBackupExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }
}

Never _configurationBackupThrow(ConfigurationBackupExceptionReason reason) =>
    throw ConfigurationBackupException(reason);

bool _configurationBackupAdmin(Object? value) {
  if (value is! Map || value['privilege'] is! Map) {
    _configurationBackupThrow(
      ConfigurationBackupExceptionReason.invalidResponse,
    );
  }
  final roles = (value['privilege'] as Map)['roles'];
  if (roles is! List ||
      roles.length > 1024 ||
      roles.any(
        (role) =>
            role is! String ||
            RegExp(r'^[A-Z][A-Z0-9_]{0,127}$').stringMatch(role) != role,
      ) ||
      roles.toSet().length != roles.length) {
    _configurationBackupThrow(
      ConfigurationBackupExceptionReason.invalidResponse,
    );
  }
  return roles.contains('FULL_ADMIN');
}

bool _configurationBackupMethodName(Object? value) =>
    value is String &&
    RegExp(r'^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*){1,5}$').stringMatch(value) ==
        value &&
    value.length <= 160;
bool _configurationBackupUrl(Object? value, int id) {
  if (value is! String || value.length > 560) return false;
  final match = RegExp(
    r'^/_download/([1-9][0-9]{0,15})\?auth_token=([A-Za-z0-9_-]{32,512})$',
  ).firstMatch(value);
  return match != null &&
      match.group(0) == value &&
      int.tryParse(match.group(1)!) == id;
}

String _configurationBackupProof(ConfigurationBackupInventory inventory) =>
    jsonEncode([
      inventory.endpoint,
      inventory.hostId,
      inventory.currentVersion,
      inventory.state,
      inventory.fullAdmin,
      inventory.failoverLicensed,
      inventory.conflictingJob,
    ]);

bool _configurationBackupSqlite(Uint8List bytes) {
  const magic = [
    83,
    81,
    76,
    105,
    116,
    101,
    32,
    102,
    111,
    114,
    109,
    97,
    116,
    32,
    51,
    0,
  ];
  if (bytes.length < 512 || bytes.length > _configurationBackupMaxBytes) {
    return false;
  }
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  final raw = bytes[16] * 256 + bytes[17];
  final pageSize = raw == 1 ? 65536 : raw;
  return pageSize >= 512 &&
      pageSize <= 65536 &&
      pageSize & (pageSize - 1) == 0 &&
      bytes.length % pageSize == 0 &&
      const [1, 2].contains(bytes[18]) &&
      const [1, 2].contains(bytes[19]);
}

// Validate a small, uncompressed Python tar/PAX envelope without extracting,
// decoding or displaying database/seed/key contents. Extended paths, links,
// sparse data and arbitrary archive members are intentionally unsupported.
bool _configurationBackupFile(
  Uint8List bytes,
  ConfigurationBackupRequest request,
) {
  if (bytes.length > _configurationBackupMaxBytes) return false;
  if (!request.includeSecretSeed && !request.includeAuthorizedKeys) {
    return _configurationBackupSqlite(bytes);
  }
  if (bytes.length < 1536 || bytes.length % 512 != 0) return false;
  var offset = 0, headers = 0, extendedPending = false;
  final members = <String>{};
  while (offset + 512 <= bytes.length) {
    final header = Uint8List.sublistView(bytes, offset, offset + 512);
    if (header.every((byte) => byte == 0)) {
      if (extendedPending ||
          bytes.length - offset < 1024 ||
          !Uint8List.sublistView(bytes, offset).every((byte) => byte == 0)) {
        return false;
      }
      return members.contains('freenas-v1.db') &&
          (members.contains('pwenc_secret') == request.includeSecretSeed);
    }
    if (++headers > 10) return false;
    final checksum = _configurationBackupOctal(header, 148, 8);
    var actualChecksum = 0;
    for (var index = 0; index < 512; index++) {
      actualChecksum += index >= 148 && index < 156 ? 32 : header[index];
    }
    final name = _configurationBackupTarText(header, 0, 100);
    final size = _configurationBackupOctal(header, 124, 12);
    if (checksum != actualChecksum ||
        name == null ||
        size == null ||
        size > _configurationBackupMaxBytes ||
        _configurationBackupTarText(header, 257, 6) != 'ustar' ||
        header[263] != 48 ||
        header[264] != 48 ||
        _configurationBackupTarText(header, 345, 155) != '' ||
        _configurationBackupTarText(header, 157, 100) != '') {
      return false;
    }
    final start = offset + 512, end = start + size;
    final next = start + ((size + 511) ~/ 512) * 512;
    if (end > bytes.length || next > bytes.length) return false;
    final data = Uint8List.sublistView(bytes, start, end);
    final type = header[156];
    if (type == 120) {
      if (extendedPending ||
          name != '././@PaxHeader' ||
          size > 2048 ||
          !_configurationBackupPax(data)) {
        return false;
      }
      extendedPending = true;
    } else {
      if (type != 0 && type != 48 || !members.add(name)) return false;
      extendedPending = false;
      switch (name) {
        case 'freenas-v1.db':
          if (!_configurationBackupSqlite(data)) return false;
        case 'pwenc_secret':
          if (!request.includeSecretSeed || size == 0 || size > 4096) {
            return false;
          }
        case 'admin_authorized_keys' ||
            'truenas_admin_authorized_keys' ||
            'root_authorized_keys':
          if (!request.includeAuthorizedKeys) return false;
        default:
          return false;
      }
    }
    offset = next;
  }
  return false;
}

int? _configurationBackupOctal(Uint8List bytes, int offset, int length) {
  final value = _configurationBackupTarText(bytes, offset, length)?.trim();
  if (value == null || RegExp(r'^[0-7]{1,11}$').stringMatch(value) != value) {
    return null;
  }
  return int.tryParse(value, radix: 8);
}

String? _configurationBackupTarText(Uint8List bytes, int offset, int length) {
  final part = Uint8List.sublistView(bytes, offset, offset + length);
  final zero = part.indexOf(0);
  if (zero >= 0 && part.skip(zero).any((byte) => byte != 0 && byte != 32)) {
    return null;
  }
  final text = zero < 0 ? part : part.sublist(0, zero);
  if (text.any((byte) => byte < 32 || byte > 126)) return null;
  return String.fromCharCodes(text);
}

bool _configurationBackupPax(Uint8List data) {
  var offset = 0;
  final keys = <String>{};
  while (offset < data.length) {
    final space = data.indexOf(32, offset);
    if (space < 0 || space - offset > 4 || space == offset) return false;
    final lengthText = String.fromCharCodes(data.sublist(offset, space));
    if (RegExp(r'^[1-9][0-9]{0,3}$').stringMatch(lengthText) != lengthText) {
      return false;
    }
    final length = int.parse(lengthText), end = offset + int.parse(lengthText);
    if (length <= space - offset + 2 ||
        end > data.length ||
        data[end - 1] != 10) {
      return false;
    }
    final record = data.sublist(space + 1, end - 1);
    if (record.any((byte) => byte < 32 || byte > 126)) return false;
    final text = String.fromCharCodes(record);
    final match = RegExp(
      r'^(mtime|atime|ctime)=([0-9]{1,16}(?:\.[0-9]{1,12})?)$',
    ).firstMatch(text);
    if (match == null || match.group(0) != text || !keys.add(match.group(1)!)) {
      return false;
    }
    offset = end;
  }
  return keys.isNotEmpty;
}
