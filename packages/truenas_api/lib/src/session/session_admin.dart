part of 'true_nas_session_repository.dart';

/// Reviewed native administration, separate from the six-method inventory API.
abstract interface class AuthenticatedAdminSession {
  AdminCatalog get adminCatalog;
  Future<AdminResult> invokeAdmin(AdminRequest request);
  Future<AdminResult> pollAdminJob(AdminJobSubmitted job);
}

final class AdminMethodSpec {
  AdminMethodSpec._({
    required this.name,
    required this.parameters,
    required this.returnSchema,
    required this.isJob,
    required this.roles,
    required this.filterable,
    required this.unsupportedReason,
  });
  final String name;
  final List<AdminParameter> parameters;
  final AdminSchema? returnSchema;
  final bool isJob;
  final bool filterable;
  final Set<String> roles;
  final String? unsupportedReason;
  bool get supported => unsupportedReason == null;
}

/// Catalogue identity is tied to one authenticated connection. Constructing a
/// catalogue for a fixture does not grant its specs access to another session.
final class AdminCatalog {
  const AdminCatalog.disconnected()
    : methods = const {},
      versionSupported = false,
      _connected = false,
      _isCurrent = null;
  AdminCatalog.fromMetadata({
    required String version,
    required Object? metadata,
    bool connected = true,
  }) : this._(connected, null, version: version, metadata: metadata);
  AdminCatalog._(
    this._connected,
    this._isCurrent, {
    required String version,
    required Object? metadata,
  }) : versionSupported =
           _managementVersion(version) == _ManagementVersion.v2510,
       methods = _adminMethods(metadata);
  final Map<String, AdminMethodSpec> methods;
  final bool versionSupported;
  final bool _connected;
  final bool Function()? _isCurrent;
  bool get connected => _connected && (_isCurrent?.call() ?? true);
  AdminMethodSpec? method(String name) => methods[name];
}

Map<String, AdminMethodSpec> _adminMethods(Object? metadata) {
  if (metadata is! Map || metadata.length > 4096) return const {};
  final policies = {for (final p in adminOperationDefinitions) p.method: p};
  final result = <String, AdminMethodSpec>{};
  for (final entry in metadata.entries) {
    final name = entry.key;
    if (name is! String || !policies.containsKey(name)) continue;
    final m = entry.value;
    String? reason;
    final parameters = <AdminParameter>[];
    AdminSchema? returns;
    var job = false;
    var filterable = false;
    final roles = <String>{};
    if (m is! Map ||
        m['accepts'] is! List ||
        m['returns'] is! List ||
        (m['returns'] as List).length != 1 ||
        m['job'] is! bool ||
        m['no_auth_required'] is! bool ||
        m['uploadable'] is! bool ||
        m['downloadable'] is! bool ||
        m['filterable'] is! bool) {
      reason = 'The server did not provide complete method metadata.';
    } else {
      job = m['job'] == true;
      filterable = m['filterable'] == true;
      if (m['roles'] is List) {
        roles.addAll((m['roles'] as List).whereType<String>());
      }
      if (m['private'] == true ||
          m['_private'] == true ||
          m['no_auth_required'] == true) {
        reason =
            'This method is not an authenticated public management operation.';
      } else if (m['uploadable'] == true ||
          m['downloadable'] == true ||
          m['check_pipes'] == true ||
          (m['check_pipes'] is List && (m['check_pipes'] as List).isNotEmpty)) {
        reason = 'This operation requires a dedicated file-transfer workflow.';
      }
      try {
        if ((m['accepts'] as List).length > 32) throw const FormatException();
        final names = <String>{};
        for (final raw in m['accepts'] as List) {
          if (raw is! Map ||
              raw['_name_'] is! String ||
              raw['_required_'] is! bool) {
            throw const FormatException();
          }
          final name = raw['_name_'] as String;
          if (name.isEmpty || name.length > 128 || !names.add(name)) {
            throw const FormatException();
          }
          final schema = AdminSchema.fromJson(Map<String, Object?>.from(raw));
          final required = raw['_required_'] == true;
          parameters.add(
            AdminParameter(name: name, schema: schema, required: required),
          );
          if (required && !schema.supported) {
            reason ??= 'A required input needs a dedicated editor.';
          }
        }
        final rawReturn = (m['returns'] as List).single;
        if (rawReturn is! Map) throw const FormatException();
        returns = AdminSchema.fromJson(Map<String, Object?>.from(rawReturn));
      } on Object {
        reason = 'The method schema could not be interpreted safely.';
      }
    }
    reason ??= policies[name]!.blockedReason;
    if (job && !metadata.containsKey('core.get_jobs')) {
      reason ??= 'The account cannot inspect asynchronous job completion.';
    }
    result[name] = AdminMethodSpec._(
      name: name,
      parameters: List.unmodifiable(parameters),
      returnSchema: returns,
      isJob: job,
      roles: Set.unmodifiable(roles),
      filterable: filterable,
      unsupportedReason: reason,
    );
  }
  return Map.unmodifiable(result);
}

final class AdminRequest {
  AdminRequest({required this.method, required List<Object?> arguments})
    : arguments = _adminRequestArguments(arguments);
  final AdminMethodSpec method;
  final List<Object?> arguments;

  /// Transient, schema-aware confirmation preview. Never logs or persists
  /// credentials and does not replace the original values sent to middleware.
  List<Object?> get redactedArguments => List.unmodifiable([
    for (var i = 0; i < arguments.length; i++)
      _adminSanitize(
        arguments[i],
        schema: i < method.parameters.length
            ? method.parameters[i].schema
            : null,
        bounded: false,
      ),
  ]);
  @override
  String toString() => 'AdminRequest(${method.name}, [redacted])';
}

List<Object?> _adminRequestArguments(List<Object?> arguments) {
  var nodes = 0;
  var characters = 0;
  void check(Object? value, int depth) {
    if (++nodes > 4096 || depth > 12) {
      throw const AdminException(AdminExceptionReason.invalidInput);
    }
    if (value is String) characters += value.length;
    if (value is Map) {
      for (final e in value.entries) {
        if (e.key is! String) {
          throw const AdminException(AdminExceptionReason.invalidInput);
        }
        characters += (e.key as String).length;
        check(e.value, depth + 1);
      }
    } else if (value is List) {
      for (final child in value) {
        check(child, depth + 1);
      }
    }
    if (characters > 65536) {
      throw const AdminException(AdminExceptionReason.invalidInput);
    }
  }

  if (arguments.length > 32) {
    throw const AdminException(AdminExceptionReason.invalidInput);
  }
  check(arguments, 0);
  return _adminFreeze(arguments) as List<Object?>;
}

enum AdminExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  invalidInput,
  staleSession,
  busy,
  duplicateRequest,
}

final class AdminException implements Exception {
  const AdminException(this.reason);
  final AdminExceptionReason reason;
  String get userMessage => switch (reason) {
    AdminExceptionReason.notAuthenticated =>
      'Connect to a server before managing it.',
    AdminExceptionReason.unsupportedVersion =>
      'The native administration adapter supports TrueNAS 25.10 releases.',
    AdminExceptionReason.unavailableMethod => 'This operation is not available in the native client for this account and schema.',
    AdminExceptionReason.invalidInput =>
      'Review the required fields and supported server input types.',
    AdminExceptionReason.staleSession =>
      'The server connection changed. Review the operation again.',
    AdminExceptionReason.busy =>
      'Another management operation is pending or needs verification.',
    AdminExceptionReason.duplicateRequest => 'This request was already submitted. Refresh server state before starting again.',
  };
  @override
  String toString() => userMessage;
}

enum AdminStatus { completed, submitted, failed, unknown }

enum AdminFailureReason { denied, rejected, operationFailed, aborted }

sealed class AdminResult {
  const AdminResult(this.request);

  /// Results retain a redacted request only; credentials never become UI state.
  final AdminRequest request;
  AdminStatus get status;
  String get userMessage;
}

final class AdminCompleted extends AdminResult {
  const AdminCompleted(super.request, {required this.value});
  final Object? value;
  @override
  AdminStatus get status => AdminStatus.completed;
  @override
  String get userMessage => 'The server completed the request.';
}

final class AdminJobSubmitted extends AdminResult {
  const AdminJobSubmitted(super.request, {required this.jobId});
  final int jobId;
  @override
  AdminStatus get status => AdminStatus.submitted;
  @override
  String get userMessage =>
      'The server accepted the job. Its completion is not yet confirmed.';
}

final class AdminFailed extends AdminResult {
  const AdminFailed(super.request, {required this.reason});
  final AdminFailureReason reason;
  @override
  AdminStatus get status => AdminStatus.failed;
  @override
  String get userMessage => switch (reason) {
    AdminFailureReason.denied =>
      'The account does not have permission for this operation.',
    AdminFailureReason.rejected =>
      'The server rejected the request. Review its inputs and dependencies.',
    AdminFailureReason.operationFailed =>
      'The server reported that the job failed.',
    AdminFailureReason.aborted =>
      'The server reported that the job was aborted.',
  };
}

final class AdminOutcomeUnknown extends AdminResult {
  const AdminOutcomeUnknown(super.request, {this.jobId});
  final int? jobId;
  @override
  AdminStatus get status => AdminStatus.unknown;
  @override
  String get userMessage =>
      'Completion could not be confirmed. Inspect the original server and reconnect before another mutation. Do not repeat this request.';
}

final class _SessionAdmin {
  _SessionAdmin({
    required this.client,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherBusy,
    required this.requestTimeout,
  }) : catalog = AdminCatalog._(
         true,
         isCurrent,
         version: summary.version,
         metadata: metadata,
       ),
       methods = Set.unmodifiable(summary.availableMethodNames);
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent;
  final bool Function() isOtherBusy;
  final Duration requestTimeout;
  final AdminCatalog catalog;
  final Set<String> methods;
  final _submitted = Expando<bool>();
  final _jobs = <AdminJobSubmitted, AdminResult>{};
  bool isSubmitting = false;
  bool _unknownMutation = false;
  static final _mutationMethods = {
    for (final policy in adminOperationDefinitions)
      if (policy.risk != AdminRisk.read) policy.method,
  };

  /// Submission is transient, but owned mutation jobs and untraceable writes
  /// retain the shared fence until terminal verification or a fresh session.
  bool get isBusy =>
      isSubmitting ||
      _unknownMutation ||
      _jobs.entries.any(
        (entry) =>
            entry.value is AdminJobSubmitted &&
            _mutationMethods.contains(entry.key.request.method.name),
      );

  AdminOutcomeUnknown _unknown(AdminRequest request) {
    if (_mutationMethods.contains(request.method.name)) _unknownMutation = true;
    return AdminOutcomeUnknown(request);
  }

  Future<Object?> _call(String method, List<Object?> args) =>
      client.call(method, id: nextId(), params: args).timeout(requestTimeout);

  Future<AdminResult> invoke(AdminRequest request) async {
    if (!isCurrent()) {
      throw const AdminException(AdminExceptionReason.staleSession);
    }
    if (!catalog.versionSupported) {
      throw const AdminException(AdminExceptionReason.unsupportedVersion);
    }
    final spec = catalog.method(request.method.name);
    if (!identical(spec, request.method)) {
      throw const AdminException(AdminExceptionReason.staleSession);
    }
    if (spec == null || !spec.supported) {
      throw const AdminException(AdminExceptionReason.unavailableMethod);
    }
    if (request.arguments.length > spec.parameters.length) {
      throw const AdminException(AdminExceptionReason.invalidInput);
    }
    for (var i = 0; i < spec.parameters.length; i++) {
      final p = spec.parameters[i];
      if (i >= request.arguments.length) {
        if (p.required) {
          throw const AdminException(AdminExceptionReason.invalidInput);
        }
      } else if (p.schema.validate(request.arguments[i]) != null) {
        throw const AdminException(AdminExceptionReason.invalidInput);
      }
    }
    final mutating = _mutationMethods.contains(spec.name);
    if (isSubmitting || isOtherBusy() || mutating && isBusy) {
      throw const AdminException(AdminExceptionReason.busy);
    }
    if (_submitted[request] == true) {
      throw const AdminException(AdminExceptionReason.duplicateRequest);
    }
    _submitted[request] = true;
    isSubmitting = true;
    // Result state keeps the operation identity but never its submitted values.
    final redacted = AdminRequest(method: spec, arguments: const []);
    try {
      final value = await _call(spec.name, request.arguments);
      if (!isCurrent()) return _unknown(redacted);
      // The shared sanitizer caps maps at 100 entries. Never present a
      // truncated address-choice map as a complete listener inventory.
      if (spec.name == 'iscsi.portal.listen_ip_choices' &&
          !_completeIscsiListenerChoices(value)) {
        return AdminFailed(redacted, reason: AdminFailureReason.rejected);
      }
      if (spec.isJob) {
        if (value is! int || value <= 0) return _unknown(redacted);
        final submitted = AdminJobSubmitted(redacted, jobId: value);
        if (_jobs.length >= 64) {
          // Read-only jobs may be numerous; they cannot evict the mutation
          // handle whose eventual terminal read is needed to release a fence.
          final evictable = _jobs.entries
              .where(
                (entry) =>
                    entry.value is! AdminJobSubmitted ||
                    !_mutationMethods.contains(entry.key.request.method.name),
              )
              .firstOrNull;
          if (evictable != null) _jobs.remove(evictable.key);
        }
        _jobs[submitted] = submitted;
        return submitted;
      }
      return AdminCompleted(
        redacted,
        value: _adminSanitize(value, schema: spec.returnSchema),
      );
    } on JsonRpcRemoteException catch (error) {
      final errno = error.data is Map ? (error.data as Map)['errno'] : null;
      final denied = errno is int && (errno == 1 || errno == 13);
      if (mutating && !denied) return _unknown(redacted);
      return AdminFailed(
        redacted,
        reason: denied
            ? AdminFailureReason.denied
            : AdminFailureReason.rejected,
      );
    } on Object {
      return _unknown(redacted);
    } finally {
      isSubmitting = false;
    }
  }

  Future<AdminResult> poll(AdminJobSubmitted job) async {
    final known = _jobs[job];
    if (!isCurrent() || known == null || !methods.contains('core.get_jobs')) {
      return AdminOutcomeUnknown(
        AdminRequest(method: job.request.method, arguments: const []),
        jobId: job.jobId,
      );
    }
    if (known is! AdminJobSubmitted) return known;
    try {
      final rows = await _call('core.get_jobs', [
        [
          ['id', '=', job.jobId],
        ],
        {
          'limit': 1,
          'select': ['id', 'method', 'state', 'result'],
          'extra': {'raw_result': false},
        },
      ]);
      if (!isCurrent() || rows is! List || rows.length != 1) {
        return AdminOutcomeUnknown(job.request, jobId: job.jobId);
      }
      final row = rows.single;
      if (row is! Map ||
          row['id'] is! int ||
          row['id'] != job.jobId ||
          row['method'] != job.request.method.name) {
        return AdminOutcomeUnknown(job.request, jobId: job.jobId);
      }
      final result = switch (row['state']) {
        'WAITING' || 'RUNNING' => job,
        'SUCCESS' => AdminCompleted(
          job.request,
          value: _adminSanitize(
            row['result'],
            schema: job.request.method.returnSchema,
          ),
        ),
        'FAILED' => AdminFailed(
          job.request,
          reason: AdminFailureReason.operationFailed,
        ),
        'ABORTED' => AdminFailed(
          job.request,
          reason: AdminFailureReason.aborted,
        ),
        _ => AdminOutcomeUnknown(job.request, jobId: job.jobId),
      };
      if (result is AdminCompleted || result is AdminFailed) {
        _jobs[job] = result;
      }
      return result;
    } on Object {
      return AdminOutcomeUnknown(job.request, jobId: job.jobId);
    }
  }
}

bool _completeIscsiListenerChoices(Object? raw) {
  if (raw is! Map || raw.length > 100) return false;
  for (final entry in raw.entries) {
    final address = entry.key;
    final description = entry.value;
    if (address is! String ||
        address.isEmpty ||
        address.length > 64 ||
        address.contains(RegExp(r'[\x00-\x20\x7f]')) ||
        description is! String ||
        description.length > 512) {
      return false;
    }
  }
  return true;
}

Object? _adminSanitize(
  Object? value, {
  AdminSchema? schema,
  int depth = 0,
  bool bounded = true,
}) {
  if (bounded && depth > 8) return '[truncated]';
  final branches = _adminSchemaBranches(schema).toList();
  if (branches.any((s) => s.secret)) {
    return '[redacted]';
  }
  if (value == null || value is bool || value is num) return value;
  if (value is String) {
    if (!bounded) return value;
    final safe = value.replaceAll(
      RegExp(
        r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]',
      ),
      '',
    );
    return safe.length <= 512 ? safe : '${safe.substring(0, 512)}…';
  }
  if (value is List) {
    final itemSchema = _adminRedactionUnion(
      branches.map((s) => s.items).whereType<AdminSchema>(),
    );
    return List<Object?>.unmodifiable([
      for (final item in bounded ? value.take(100) : value)
        _adminSanitize(
          item,
          schema: itemSchema,
          depth: depth + 1,
          bounded: bounded,
        ),
      if (bounded && value.length > 100) '[additional items omitted]',
    ]);
  }
  if (value is Map) {
    AdminSchema? propertySchema(String key) {
      return _adminRedactionUnion(
        branches.map((s) => s.properties[key]).whereType<AdminSchema>(),
      );
    }

    return Map<String, Object?>.unmodifiable({
      for (final e in bounded ? value.entries.take(100) : value.entries)
        if (e.key is String && (!bounded || (e.key as String).length <= 128))
          e.key as String: _adminSensitiveKey(e.key as String)
              ? '[redacted]'
              : _adminSanitize(
                  e.value,
                  schema: propertySchema(e.key as String),
                  depth: depth + 1,
                  bounded: bounded,
                ),
    });
  }
  return '[unsupported value]';
}

Iterable<AdminSchema> _adminSchemaBranches(AdminSchema? schema) sync* {
  if (schema == null) return;
  yield schema;
  for (final variant in schema.variants) {
    yield* _adminSchemaBranches(variant);
  }
}

AdminSchema? _adminRedactionUnion(Iterable<AdminSchema> schemas) {
  final values = schemas.toList();
  if (values.isEmpty) return null;
  if (values.length == 1) return values.single;
  return AdminSchema._({'anyOf': List.unmodifiable(values.map((s) => s.raw))});
}
