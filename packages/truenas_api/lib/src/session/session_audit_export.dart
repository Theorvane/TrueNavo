part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedAuditExportSession {
  AuditExportCapabilities get auditExportCapabilities;
  Future<AuditExportReview> reviewAuditExport(AuditExportRequest request);
  Future<AuditExportResult> executeAuditExport(
    AuditExportReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
  Future<AuditExportResult> pollAuditExport(
    AuditExportOperation operation, {
    required bool Function() isCurrent,
  });
}

enum AuditExportFormat { csv, json, yaml }

final class AuditExportCapabilities {
  const AuditExportCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.transferSupported = false,
  });
  const AuditExportCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      transferSupported = false;
  final bool connected, versionSupported, available, transferSupported;
  bool get canExport =>
      connected && versionSupported && available && transferSupported;
}

final class AuditExportRequest {
  const AuditExportRequest({
    required this.query,
    required this.format,
    required this.sensitiveDataAccepted,
    required this.serverArtifactAccepted,
    required this.rowLimitAccepted,
  });
  final AuditQuery query;
  final AuditExportFormat format;
  final bool sensitiveDataAccepted, serverArtifactAccepted, rowLimitAccepted;
  String? get validationError => !query.valid || query.page != 0
      ? 'Choose one valid UTC interval of at most 31 days at page zero.'
      : !sensitiveDataAccepted
      ? 'Acknowledge that full audit payloads can contain sensitive data.'
      : !serverArtifactAccepted
      ? 'Acknowledge the temporary server-side report and retention cleanup.'
      : !rowLimitAccepted
      ? 'Acknowledge the explicit 10,000-row export limit.'
      : null;
}

final class AuditExportReview {
  AuditExportReview({
    required this.request,
    required this.endpoint,
    required this.hostId,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final AuditExportRequest request;
  final String endpoint, hostId;
  final List<String> warnings;
  String get target =>
      'EXPORT AUDIT $hostId '
      '${request.query.service.name.toUpperCase()} '
      '${request.format.name.toUpperCase()} '
      '${request.query.from.millisecondsSinceEpoch} '
      '${request.query.until.millisecondsSinceEpoch}';
}

final class AuditExportOperation {
  const AuditExportOperation._({
    required this.id,
    required this.endpoint,
    required this.hostId,
    required this.bootId,
    required this.format,
  });
  final int id;
  final String endpoint, hostId, bootId;
  final AuditExportFormat format;
}

final class AuditExportArtifact {
  factory AuditExportArtifact({
    required Uint8List bytes,
    required String filename,
  }) => AuditExportArtifact._(bytes, filename);
  AuditExportArtifact._(this._bytes, this.filename);
  Uint8List? _bytes;
  final String filename;
  int get byteLength => _bytes?.length ?? 0;
  Uint8List takeBytes() {
    final value = _bytes;
    if (value == null) throw StateError('Audit report bytes are unavailable.');
    _bytes = null;
    return value;
  }

  void dispose() {
    _bytes?.fillRange(0, _bytes!.length, 0);
    _bytes = null;
  }
}

enum AuditExportOutcome { pending, completed, rejected, unknown }

final class AuditExportResult {
  const AuditExportResult(
    this.outcome,
    this.message, {
    this.operation,
    this.artifact,
  });
  final AuditExportOutcome outcome;
  final String message;
  final AuditExportOperation? operation;
  final AuditExportArtifact? artifact;
}

enum AuditExportExceptionReason {
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

final class AuditExportException implements Exception {
  const AuditExportException(this.reason);
  final AuditExportExceptionReason reason;
  String get userMessage => switch (reason) {
    AuditExportExceptionReason.notAuthenticated =>
      'Connect again before exporting audit data.',
    AuditExportExceptionReason.unsupportedVersion =>
      'Native audit export requires stable TrueNAS 25.10.',
    AuditExportExceptionReason.unavailableMethod =>
      'Required public audit export and download methods are unavailable.',
    AuditExportExceptionReason.unsupportedTransport => 'Audit export requires the certificate-pinned bounded download transport.',
    AuditExportExceptionReason.busy =>
      'Another operation or unresolved audit export prevents this request.',
    AuditExportExceptionReason.staleReview =>
      'The server, boot, permission, filter or review changed.',
    AuditExportExceptionReason.invalidRequest =>
      'Review the interval, format and all export disclosures.',
    AuditExportExceptionReason.invalidResponse =>
      'The audit export job or downloaded report could not be verified.',
    AuditExportExceptionReason.unavailable =>
      'Audit export is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

final class _AuditExportLease {
  const _AuditExportLease(this.issuedAt, this.hostId, this.bootId);
  final DateTime issuedAt;
  final String hostId, bootId;
}

final class _AuditExportOwned {
  const _AuditExportOwned(this.operation, this.argumentsProof);
  final AuditExportOperation operation;
  final String argumentsProof;
}

final class _SessionAuditExport {
  _SessionAuditExport({
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
    _power = _SessionSystemPower(
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
  final ConfigurationBackupDownloadTransport? transport;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _version;
  final String _endpoint;
  final Map _metadata;
  final DateTime Function() _now;
  late final _SessionSystemPower _power;
  final Map<AuditExportReview, _AuditExportLease> _reviews = {};
  final Map<AuditExportOperation, _AuditExportOwned> _operations = {};
  final Uint8List _key = Uint8List.fromList(
    List.generate(32, (_) => math.Random.secure().nextInt(256)),
  );
  bool _calling = false, _terminal = false, _disposed = false;
  bool Function()? _operationCurrent;
  bool get isBusy => _calling || _terminal || _operations.isNotEmpty;

  void dispose() {
    _disposed = true;
    _reviews.clear();
    _operations.clear();
    _key.fillRange(0, _key.length, 0);
  }

  bool _current() {
    try {
      return !_disposed && isCurrent() && (_operationCurrent?.call() ?? true);
    } on Object {
      return false;
    }
  }

  bool _method(String name, {bool job = false, bool downloadable = false}) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == job &&
        row['uploadable'] == false &&
        row['downloadable'] == downloadable &&
        row['no_auth_required'] == false &&
        row['private'] != true &&
        row['_private'] != true;
  }

  AuditExportCapabilities get capabilities => AuditExportCapabilities(
    connected: _current(),
    versionSupported: _version,
    available:
        _method('audit.export', job: true) &&
        _method('audit.download_report', job: true, downloadable: true) &&
        _method('core.download') &&
        _method('core.get_jobs') &&
        _method('auth.me') &&
        _method('system.host_id'),
    transferSupported: transport?.configurationBackupDownloadSupported == true,
  );

  Never _throw(AuditExportExceptionReason reason) =>
      throw AuditExportException(reason);

  void _guard() {
    if (_disposed || !isCurrent()) {
      _throw(AuditExportExceptionReason.notAuthenticated);
    }
    if (!_current()) _throw(AuditExportExceptionReason.staleReview);
    if (!_version) _throw(AuditExportExceptionReason.unsupportedVersion);
    if (!capabilities.available) {
      _throw(AuditExportExceptionReason.unavailableMethod);
    }
    if (!capabilities.transferSupported) {
      _throw(AuditExportExceptionReason.unsupportedTransport);
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

  String _digest(Object? value) {
    if (!_smbBounded(value)) _throw(AuditExportExceptionReason.invalidResponse);
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(_smbCanonical(value))),
    );
    try {
      return crypto.Hmac(crypto.sha256, _key).convert(bytes).toString();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Map<String, Object?> _payload(AuditExportRequest request) {
    final query = request.query;
    return {
      'services': [query.service.name.toUpperCase()],
      'remote_controller': false,
      'export_format': request.format.name.toUpperCase(),
      'query-filters': [
        ['message_timestamp', '>=', query.from.millisecondsSinceEpoch ~/ 1000],
        ['message_timestamp', '<', query.until.millisecondsSinceEpoch ~/ 1000],
        if (query.username.isNotEmpty) ['username', '=', query.username],
        if (query.success != null) ['success', '=', query.success],
      ],
      'query-options': {
        'order_by': ['message_timestamp', 'audit_id'],
        'limit': 10000,
        'force_sql_filters': true,
      },
    };
  }

  Future<(String, String)> _readiness() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const []));
    final power = await _power._read();
    final adminAfter = _configurationBackupAdmin(
      await _call('auth.me', const []),
    );
    if (!admin ||
        !adminAfter ||
        power.failoverLicensed ||
        power.state != 'READY' ||
        power.conflictingJob ||
        !power.bootHealthy ||
        power.currentEnvironment == null ||
        power.nextEnvironment == null ||
        power.currentEnvironment!.id != power.nextEnvironment!.id) {
      _throw(AuditExportExceptionReason.invalidRequest);
    }
    return (power.hostId, power.bootId);
  }

  Future<AuditExportReview> review(AuditExportRequest request) async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _throw(AuditExportExceptionReason.busy);
    }
    if (request.validationError != null) {
      _throw(AuditExportExceptionReason.invalidRequest);
    }
    _calling = true;
    _reviews.clear();
    try {
      final ready = await _readiness();
      if (isOtherMutationBusy()) _throw(AuditExportExceptionReason.busy);
      final value = AuditExportReview(
        request: request,
        endpoint: _endpoint,
        hostId: ready.$1,
        warnings: const [
          'The report includes full audit payloads, including data deliberately excluded from the on-screen viewer.',
          'TrueNAS creates a temporary server-side report retained until periodic cleanup. Local cancellation does not delete it.',
          'The report is limited to 10,000 ordered rows in one service and one UTC interval; it is not proof of complete capture or tamper evidence.',
          'Report generation and output download are separate jobs. A failure after dispatch is uncertain and is never automatically retried.',
        ],
      );
      _reviews[value] = _AuditExportLease(_now(), ready.$1, ready.$2);
      return value;
    } on AuditExportException {
      rethrow;
    } on Object {
      _throw(AuditExportExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  bool _leaseCurrent(_AuditExportLease lease) {
    final age = _now().difference(lease.issuedAt);
    return !age.isNegative && age <= const Duration(minutes: 5);
  }

  Future<AuditExportResult> execute(
    AuditExportReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    final lease = _reviews.remove(review);
    var sent = false, owns = false;
    bool authorized() {
      try {
        return isCurrent();
      } on Object {
        return false;
      }
    }

    try {
      _guard();
      if (isBusy || isOtherMutationBusy()) {
        _throw(AuditExportExceptionReason.busy);
      }
      if (lease == null ||
          !_leaseCurrent(lease) ||
          !authorized() ||
          confirmation != review.target ||
          review.endpoint != _endpoint ||
          review.hostId != lease.hostId ||
          review.request.validationError != null) {
        _throw(AuditExportExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = isCurrent;
      final ready = await _readiness();
      if (ready.$1 != lease.hostId ||
          ready.$2 != lease.bootId ||
          !_leaseCurrent(lease) ||
          !authorized() ||
          isOtherMutationBusy()) {
        _throw(AuditExportExceptionReason.staleReview);
      }
      final payload = _payload(review.request);
      sent = true;
      final receipt = await client
          .call('audit.export', id: nextId(), params: [payload])
          .timeout(requestTimeout);
      _guard();
      if (!_powerId(receipt)) return _unknown();
      final operation = AuditExportOperation._(
        id: receipt as int,
        endpoint: _endpoint,
        hostId: lease.hostId,
        bootId: lease.bootId,
        format: review.request.format,
      );
      _operations[operation] = _AuditExportOwned(operation, _digest([payload]));
      return AuditExportResult(
        AuditExportOutcome.pending,
        'The owned audit report job was submitted. Check this same job; no request is replayed.',
        operation: operation,
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return AuditExportResult(
        AuditExportOutcome.rejected,
        error is AuditExportException
            ? error.userMessage
            : 'Audit export preflight failed. No report job was submitted.',
      );
    } finally {
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  Future<AuditExportResult> poll(
    AuditExportOperation operation, {
    required bool Function() isCurrent,
  }) async {
    bool authorized() {
      try {
        return isCurrent();
      } on Object {
        return false;
      }
    }

    if (_calling || _terminal || !authorized() || isOtherMutationBusy()) {
      _throw(AuditExportExceptionReason.busy);
    }
    _calling = true;
    _operationCurrent = isCurrent;
    try {
      return await _poll(operation);
    } on Object {
      return _unknown(operation: operation);
    } finally {
      _operationCurrent = null;
      _calling = false;
    }
  }

  Future<AuditExportResult> _poll(AuditExportOperation operation) async {
    final owned = _operations[operation];
    if (owned == null ||
        operation.endpoint != _endpoint ||
        await _call('system.host_id', const []) != operation.hostId) {
      _throw(AuditExportExceptionReason.staleReview);
    }
    final rows = await _call('core.get_jobs', [
      [
        ['id', '=', operation.id],
      ],
      {
        'limit': 2,
        'select': ['id', 'method', 'arguments', 'state', 'error', 'result'],
      },
    ]);
    if (rows is! List || rows.length != 1 || rows.single is! Map) {
      return _unknown(operation: operation);
    }
    final row = rows.single as Map;
    if (row['id'] != operation.id ||
        row['method'] != 'audit.export' ||
        _digest(row['arguments']) != owned.argumentsProof ||
        !row.containsKey('error') ||
        !row.containsKey('result')) {
      return _unknown(operation: operation);
    }
    if (const {'WAITING', 'RUNNING'}.contains(row['state'])) {
      return AuditExportResult(
        AuditExportOutcome.pending,
        "The owned audit report job is still ${row['state']}. "
        'Check it again; no export is replayed.',
        operation: operation,
      );
    }
    if (const {'FAILED', 'ABORTED'}.contains(row['state'])) {
      _operations.remove(operation);
      return const AuditExportResult(
        AuditExportOutcome.rejected,
        'The audit report job did not succeed. Remote details were withheld.',
      );
    }
    final report = _reportName(row['result'], operation.format);
    if (row['state'] != 'SUCCESS' || row['error'] != null || report == null) {
      return _unknown(operation: operation);
    }
    return _download(operation, report);
  }

  Future<AuditExportResult> _download(
    AuditExportOperation operation,
    String report,
  ) async {
    final receipt = await _call('core.download', [
      'audit.download_report',
      [
        {'report_name': report},
      ],
      report,
      false,
    ]);
    if (receipt is! List ||
        receipt.length != 2 ||
        !_powerId(receipt[0]) ||
        !_configurationBackupUrl(receipt[1], receipt[0] as int)) {
      return _unknown(operation: operation);
    }
    final downloadJob = receipt[0] as int;
    Uint8List? bytes;
    var abandoned = false;
    final transfer = transport!
        .downloadConfigurationBackup(
          relativeUrl: receipt[1] as String,
          jobId: downloadJob,
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
    if (bytes.isEmpty ||
        bytes.length > 16 * 1024 * 1024 ||
        bytes.length < 3 ||
        bytes[0] != 0x1f ||
        bytes[1] != 0x8b ||
        bytes[2] != 0x08) {
      bytes.fillRange(0, bytes.length, 0);
      return _unknown(operation: operation);
    }
    final jobs = await _call('core.get_jobs', [
      [
        ['id', '=', downloadJob],
      ],
      {
        'limit': 2,
        'select': ['id', 'method', 'state', 'error', 'result'],
      },
    ]);
    if (jobs is! List || jobs.length != 1 || jobs.single is! Map) {
      bytes.fillRange(0, bytes.length, 0);
      return _unknown(operation: operation);
    }
    final job = jobs.single as Map;
    if (job['id'] != downloadJob ||
        job['method'] != 'audit.download_report' ||
        job['state'] != 'SUCCESS' ||
        job['error'] != null ||
        job['result'] != null ||
        await _call('system.host_id', const []) != operation.hostId) {
      bytes.fillRange(0, bytes.length, 0);
      return _unknown(operation: operation);
    }
    _operations.remove(operation);
    return AuditExportResult(
      AuditExportOutcome.completed,
      'Both owned jobs and the bounded gzip report were verified. Archive contents, completeness and file-provider durability remain unverified.',
      artifact: AuditExportArtifact(bytes: bytes, filename: report),
    );
  }

  String? _reportName(Object? raw, AuditExportFormat format) {
    if (raw is! String ||
        raw.length > 512 ||
        !raw.startsWith('/') ||
        raw.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return null;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.hasQuery || uri.hasFragment || uri.path != raw) {
      return null;
    }
    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final pattern = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
      '[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\.${format.name}'
      r'\.tar\.gz$',
    );
    return pattern.stringMatch(name) == name ? name : null;
  }

  AuditExportResult _unknown({AuditExportOperation? operation}) {
    _terminal = true;
    _reviews.clear();
    return AuditExportResult(
      AuditExportOutcome.unknown,
      'An audit report or download job may already have run. No file was released and further writes are fenced; inspect the original server independently before reconnecting.',
      operation: operation,
    );
  }
}
