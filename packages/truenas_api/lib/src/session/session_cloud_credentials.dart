part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedCloudCredentialsSession {
  CloudCredentialsCapabilities get cloudCredentialsCapabilities;
  Future<CloudCredentialInventory> loadCloudCredentials();
  Future<CloudCredentialReview> reviewCloudCredential(
    CloudCredentialRequest request,
  );
  Future<CloudCredentialResult> executeCloudCredential(
    CloudCredentialReview review,
    String confirmation, {
    CloudCredentialWriteOnlyInput? input,
  });
}

final class CloudCredentialsCapabilities {
  const CloudCredentialsCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canCreate,
    required this.canUpdate,
    required this.canDelete,
  });
  const CloudCredentialsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canCreate = false,
      canUpdate = false,
      canDelete = false;
  final bool connected,
      versionSupported,
      available,
      canCreate,
      canUpdate,
      canDelete;
  bool get supported => connected && versionSupported && available;
  bool allows(CloudCredentialAction action) =>
      supported &&
      switch (action) {
        CloudCredentialAction.create => canCreate,
        CloudCredentialAction.rename ||
        CloudCredentialAction.replace => canUpdate,
        CloudCredentialAction.delete => canDelete,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect cloud credential references.'
      : !versionSupported
      ? 'Native cloud credentials require stable TrueNAS 25.10.'
      : !available
      ? 'Credential, cloud sync, cloud backup and active-job reads are required.'
      : null;
}

final class CloudCredentialEntry {
  const CloudCredentialEntry({
    required this.id,
    required this.name,
    required this.provider,
  });
  final int id;
  final String name, provider;
  bool get supported => const {'S3', 'DROPBOX'}.contains(provider);
}

final class CloudCredentialReference {
  const CloudCredentialReference({
    required this.kind,
    required this.id,
    required this.credentialId,
    required this.enabled,
  });
  final String kind;
  final int id, credentialId;
  final bool enabled;
}

final class CloudCredentialInventory {
  CloudCredentialInventory({
    required this.endpoint,
    required List<CloudCredentialEntry> credentials,
    required List<CloudCredentialReference> references,
    this.conflictingJob = false,
  }) : credentials = List.unmodifiable(credentials),
       references = List.unmodifiable(references);
  final String endpoint;
  final List<CloudCredentialEntry> credentials;
  final List<CloudCredentialReference> references;
  final bool conflictingJob;
  List<CloudCredentialReference> referencesFor(int id) =>
      references.where((r) => r.credentialId == id).toList(growable: false);
}

enum CloudCredentialAction { create, rename, replace, delete }

/// Display-safe intent. Authentication material never belongs in a review.
final class CloudCredentialRequest {
  const CloudCredentialRequest({
    required this.inventory,
    required this.action,
    this.credential,
    this.name,
    this.provider,
  });
  final CloudCredentialInventory inventory;
  final CloudCredentialAction action;
  final CloudCredentialEntry? credential;
  final String? name, provider;
  String get desiredName => name ?? credential?.name ?? '';
  String get desiredProvider => provider ?? credential?.provider ?? '';
  String get target => action == CloudCredentialAction.create
      ? 'CREATE $desiredName'
      : '${action.name.toUpperCase()} ${credential?.id ?? 0} ${credential?.name ?? ''}';
  String? get validationError {
    if (!_ccText(desiredName, 100) ||
        !{'S3', 'DROPBOX'}.contains(desiredProvider)) {
      return 'Choose S3 or Dropbox and a non-empty name (at most 100 characters).';
    }
    if (action == CloudCredentialAction.create) {
      if (credential != null || name == null || provider == null) {
        return 'A new credential requires its own name and provider.';
      }
    } else {
      if (credential == null ||
          !inventory.credentials.any((e) => identical(e, credential)) ||
          !credential!.supported ||
          desiredProvider != credential!.provider) {
        return 'Choose the exact issued credential; provider conversion is not supported.';
      }
      if (action != CloudCredentialAction.rename &&
          desiredName != credential!.name) {
        return 'Rename is a separate name-only operation.';
      }
      if (action == CloudCredentialAction.rename &&
          desiredName == credential!.name) {
        return 'Enter a different name.';
      }
      if (action == CloudCredentialAction.delete &&
          inventory.referencesFor(credential!.id).isNotEmpty) {
        return 'Remove all cloud sync and cloud backup references before deleting this credential.';
      }
    }
    if ((action == CloudCredentialAction.create ||
            action == CloudCredentialAction.rename) &&
        inventory.credentials.any(
          (e) => e.id != credential?.id && e.name == desiredName,
        )) {
      return 'Choose a unique credential name.';
    }
    if (inventory.conflictingJob) {
      return 'An active server operation may use these credentials. Wait and reload.';
    }
    if (action == CloudCredentialAction.replace &&
        inventory.referencesFor(credential!.id).any((r) => r.enabled)) {
      return 'Disable all referencing schedules before replacing authentication material.';
    }
    return null;
  }
}

/// Ephemeral write-only input, never returned by inventory or held in reviews.
/// dispose releases references; Dart strings cannot be guaranteed zeroized.
final class CloudCredentialWriteOnlyInput {
  CloudCredentialWriteOnlyInput.s3({
    required String accessKeyId,
    required String secretAccessKey,
    required String endpoint,
    required String region,
    required bool skipRegion,
    required bool signaturesV2,
    required int maxUploadParts,
  }) : _data = {
         'type': 'S3',
         'access_key_id': accessKeyId,
         'secret_access_key': secretAccessKey,
         'endpoint': endpoint,
         'region': region,
         'skip_region': skipRegion,
         'signatures_v2': signaturesV2,
         'max_upload_parts': maxUploadParts,
       };
  CloudCredentialWriteOnlyInput.dropbox({
    required String token,
    required String clientId,
    required String clientSecret,
  }) : _data = {
         'type': 'DROPBOX',
         'token': token,
         'client_id': clientId,
         'client_secret': clientSecret,
       };
  Map<String, Object?>? _data;
  bool get disposed => _data == null;
  String? get validationError {
    final data = _data;
    if (data == null) {
      return 'Authentication input was discarded. Enter it again.';
    }
    if (data['type'] == 'S3') {
      if (!_ccSecret(data['access_key_id'], 1024) ||
          !_ccSecret(data['secret_access_key'], 1024)) {
        return 'Enter both new S3 access key fields.';
      }
      final endpoint = data['endpoint'] as String;
      final uri = Uri.tryParse(endpoint);
      if (endpoint.isNotEmpty &&
          (!_ccText(endpoint, 1024) ||
              uri == null ||
              uri.scheme != 'https' ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.hasQuery ||
              uri.hasFragment ||
              uri.path != '' && uri.path != '/' ||
              endpoint.contains('\\'))) {
        return 'Use a bare HTTPS S3 endpoint without credentials, query, fragment or path, or leave empty for AWS.';
      }
      if (!RegExp(r'^[a-z0-9-]{0,63}$').hasMatch(data['region'] as String) ||
          (data['max_upload_parts'] as int) < 1 ||
          (data['max_upload_parts'] as int) > 10000) {
        return 'Use a bounded region and 1–10000 multipart parts.';
      }
    } else if (data['type'] == 'DROPBOX') {
      if (!_ccSecret(data['token'], 16384) ||
          !_ccSecret(data['client_id'], 1024, empty: true) ||
          !_ccSecret(data['client_secret'], 1024, empty: true)) {
        return 'Enter a Dropbox token and explicit optional client values.';
      }
      if ((data['client_id'] as String).isEmpty !=
          (data['client_secret'] as String).isEmpty) {
        return 'Enter both Dropbox custom client values or explicitly leave both empty.';
      }
      try {
        final token = jsonDecode(data['token'] as String);
        if (token is! Map ||
            !_ccSecret(token['access_token'], 8192) ||
            token['token_type'] != 'bearer' &&
                token['token_type'] != 'Bearer') {
          return 'Use an already-issued Dropbox OAuth token JSON object with access_token and bearer token_type.';
        }
      } on Object {
        return 'Use an already-issued Dropbox OAuth token JSON object.';
      }
    } else {
      return 'Unsupported provider.';
    }
    return null;
  }

  void dispose() {
    _data = null;
  }

  @override
  String toString() => 'CloudCredentialWriteOnlyInput(<redacted>)';
}

final class CloudCredentialReview {
  CloudCredentialReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final CloudCredentialRequest request;
  final String endpoint;
  final List<String> warnings;
  CloudCredentialAction get action => request.action;
  String get target => request.target;
}

enum CloudCredentialOutcome { succeeded, rejected, unknown }

final class CloudCredentialResult {
  const CloudCredentialResult(this.outcome, this.message);
  final CloudCredentialOutcome outcome;
  final String message;
}

enum CloudCredentialsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class CloudCredentialsException implements Exception {
  const CloudCredentialsException(this.reason);
  final CloudCredentialsExceptionReason reason;
  String get userMessage => switch (reason) {
    CloudCredentialsExceptionReason.notAuthenticated =>
      'Connect again before managing cloud credentials.',
    CloudCredentialsExceptionReason.unsupportedVersion =>
      'Native cloud credentials require stable TrueNAS 25.10.',
    CloudCredentialsExceptionReason.unavailableMethod =>
      'Required public credential and reference methods are unavailable.',
    CloudCredentialsExceptionReason.busy =>
      'Another operation is active or its outcome is unknown.',
    CloudCredentialsExceptionReason.staleReview =>
      'This review expired or inventory changed. Reload and review again.',
    CloudCredentialsExceptionReason.invalidRequest =>
      'Choose a supported credential and valid explicit settings.',
    CloudCredentialsExceptionReason.invalidResponse =>
      'Credential safety information could not be validated.',
    CloudCredentialsExceptionReason.unavailable =>
      'Credential information is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _ccReads = {
  'cloudsync.credentials.query',
  'cloudsync.query',
  'cloud_backup.query',
  'core.get_jobs',
};

final class _CcSnapshot {
  const _CcSnapshot(this.inventory, this.fingerprint);
  final CloudCredentialInventory inventory;
  final String fingerprint;
}

final class _CcLease {
  const _CcLease(this.snapshot, this.created);
  final _CcSnapshot snapshot;
  final DateTime created;
}

final class _SessionCloudCredentials {
  _SessionCloudCredentials({
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
  final Map<CloudCredentialInventory, _CcSnapshot> _inventories = {};
  final Map<CloudCredentialReview, _CcLease> _reviews = {};
  bool get isBusy => _calling || _uncertain;
  bool _method(String name) {
    final m = _metadata[name];
    return m is Map &&
        m['job'] == false &&
        m['uploadable'] == false &&
        m['downloadable'] == false &&
        m['private'] != true &&
        m['_private'] != true &&
        m['no_auth_required'] == false;
  }

  CloudCredentialsCapabilities get capabilities => CloudCredentialsCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: _ccReads.every(_method),
    canCreate: _method('cloudsync.credentials.create'),
    canUpdate: _method('cloudsync.credentials.update'),
    canDelete: _method('cloudsync.credentials.delete'),
  );
  void _guard([CloudCredentialAction? action]) {
    if (!isCurrent()) {
      throw const CloudCredentialsException(
        CloudCredentialsExceptionReason.notAuthenticated,
      );
    }
    if (!_version) {
      throw const CloudCredentialsException(
        CloudCredentialsExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.supported ||
        action != null && !capabilities.allows(action)) {
      throw const CloudCredentialsException(
        CloudCredentialsExceptionReason.unavailableMethod,
      );
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

  Future<_CcSnapshot> _read() async {
    final raw = await _call('cloudsync.credentials.query', const [
      [],
      {
        'limit': 129,
        'select': ['id', 'name', 'provider.type'],
      },
    ]);
    if (raw is! List || raw.length > 128) _ccInvalid();
    final entries = raw.map(_ccEntry).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (entries.map((e) => e.id).toSet().length != entries.length) _ccInvalid();
    final references = <CloudCredentialReference>[];
    for (final kind in ['cloudsync', 'cloud_backup']) {
      final rows = await _call('$kind.query', const [
        [],
        {
          'limit': 257,
          'select': ['id', 'credentials.id', 'enabled'],
        },
      ]);
      if (rows is! List || rows.length > 256) _ccInvalid();
      final ids = <int>{};
      for (final row in rows) {
        if (row is! Map ||
            !_ccId(row['id']) ||
            !ids.add(row['id'] as int) ||
            row['credentials'] is! Map ||
            !_ccId(row['credentials']['id']) ||
            row['enabled'] is! bool ||
            !entries.any((e) => e.id == row['credentials']['id'])) {
          _ccInvalid();
        }
        references.add(
          CloudCredentialReference(
            kind: kind,
            id: row['id'] as int,
            credentialId: row['credentials']['id'] as int,
            enabled: row['enabled'] as bool,
          ),
        );
      }
    }
    references.sort(
      (a, b) => '${a.kind}/${a.id}'.compareTo('${b.kind}/${b.id}'),
    );
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
    if (jobs is! List || jobs.length > 128) _ccInvalid();
    var conflict = false;
    final jobIds = <int>{};
    for (final row in jobs) {
      if (row is! Map ||
          !_ccId(row['id']) ||
          !jobIds.add(row['id'] as int) ||
          !_ccText(row['method'], 128) ||
          !{'WAITING', 'RUNNING'}.contains(row['state'])) {
        _ccInvalid();
      }
      final method = row['method'] as String;
      conflict |= [
        'cloudsync.',
        'cloud_backup.',
        'replication.',
        'pool.',
        'filesystem.',
        'update.',
        'system.',
      ].any(method.startsWith);
    }
    final inventory = CloudCredentialInventory(
      endpoint: _endpoint,
      credentials: entries,
      references: references,
      conflictingJob: conflict,
    );
    return _CcSnapshot(
      inventory,
      jsonEncode([
        entries.map((e) => [e.id, e.name, e.provider]).toList(),
        references
            .map((r) => [r.kind, r.id, r.credentialId, r.enabled])
            .toList(),
        conflict,
      ]),
    );
  }

  Future<CloudCredentialInventory> load() async {
    _guard();
    if (_calling) {
      throw const CloudCredentialsException(
        CloudCredentialsExceptionReason.busy,
      );
    }
    _calling = true;
    _reviews.clear();
    _inventories.clear();
    try {
      final snap = await _read();
      _inventories[snap.inventory] = snap;
      return snap.inventory;
    } on CloudCredentialsException {
      rethrow;
    } on Object {
      throw const CloudCredentialsException(
        CloudCredentialsExceptionReason.unavailable,
      );
    } finally {
      _calling = false;
    }
  }

  Future<CloudCredentialReview> review(CloudCredentialRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const CloudCredentialsException(
        CloudCredentialsExceptionReason.busy,
      );
    }
    final snapshot = _inventories[request.inventory];
    if (snapshot == null || request.inventory.endpoint != _endpoint) {
      throw const CloudCredentialsException(
        CloudCredentialsExceptionReason.staleReview,
      );
    }
    if (request.validationError != null) {
      throw const CloudCredentialsException(
        CloudCredentialsExceptionReason.invalidRequest,
      );
    }
    _calling = true;
    try {
      final fresh = await _read();
      if (snapshot.fingerprint != fresh.fingerprint || isOtherMutationBusy()) {
        throw const CloudCredentialsException(
          CloudCredentialsExceptionReason.staleReview,
        );
      }
      final refs = request.credential == null
          ? <CloudCredentialReference>[]
          : request.inventory.referencesFor(request.credential!.id);
      final result = CloudCredentialReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'This changes only the stored credential configuration. It does not verify cloud access, list remote files or start a transfer.',
          'Provider: ${request.desiredProvider}. Name: ${request.desiredName}. ${refs.length} referencing cloud sync/backup task(s).',
          if (request.action == CloudCredentialAction.rename) 'Only the name field is submitted. The stored provider object, including every secret and optional field, is preserved by the server.',
          if (request.action == CloudCredentialAction.create ||
              request.action == CloudCredentialAction.replace)
            'All entered provider fields are a complete new record. Empty optional values explicitly replace prior values; no existing secret is fetched, recovered or merged.',
          if (request.action == CloudCredentialAction.replace) 'Replacing credentials changes access for every referencing task. Schedules must be disabled and jobs stopped. Confirm the replacement account can access the intended data before re-enabling tasks in a separate operation.',
          if (request.action == CloudCredentialAction.delete) 'Delete this unused stored credential permanently. The app does not revoke it at the provider or delete remote objects. Keep an independent recovery copy first.',
          'Identity and references are rechecked immediately before submission. A server-side concurrent change after that check cannot be atomically prevented. No automatic retry is performed.',
          'Secret-only changes made elsewhere cannot be detected by this secret-free inventory. Coordinate changes with other administrators.',
        ],
      );
      _reviews.clear();
      _reviews[result] = _CcLease(snapshot, DateTime.now());
      return result;
    } on CloudCredentialsException {
      rethrow;
    } on Object {
      throw const CloudCredentialsException(
        CloudCredentialsExceptionReason.unavailable,
      );
    } finally {
      _calling = false;
    }
  }

  Future<CloudCredentialResult> execute(
    CloudCredentialReview review,
    String confirmation, {
    CloudCredentialWriteOnlyInput? input,
  }) async {
    var sent = false, ownsCall = false;
    try {
      _guard(review.action);
      if (isBusy || isOtherMutationBusy()) {
        throw const CloudCredentialsException(
          CloudCredentialsExceptionReason.busy,
        );
      }
      final lease = _reviews.remove(review);
      if (lease == null ||
          review.endpoint != _endpoint ||
          confirmation != review.target ||
          DateTime.now().difference(lease.created) >
              const Duration(minutes: 5) ||
          review.request.validationError != null) {
        throw const CloudCredentialsException(
          CloudCredentialsExceptionReason.staleReview,
        );
      }
      final request = review.request;
      final needsInput =
          request.action == CloudCredentialAction.create ||
          request.action == CloudCredentialAction.replace;
      if (needsInput
          ? input == null ||
                input.validationError != null ||
                input._data!['type'] != request.desiredProvider
          : input != null) {
        throw const CloudCredentialsException(
          CloudCredentialsExceptionReason.invalidRequest,
        );
      }
      _calling = true;
      ownsCall = true;
      final fresh = await _read();
      if (fresh.fingerprint != lease.snapshot.fingerprint ||
          isOtherMutationBusy()) {
        throw const CloudCredentialsException(
          CloudCredentialsExceptionReason.staleReview,
        );
      }
      final method = switch (request.action) {
        CloudCredentialAction.create => 'cloudsync.credentials.create',
        CloudCredentialAction.rename ||
        CloudCredentialAction.replace => 'cloudsync.credentials.update',
        CloudCredentialAction.delete => 'cloudsync.credentials.delete',
      };
      final params = <Object?>[
        if (request.credential != null) request.credential!.id,
        if (request.action != CloudCredentialAction.delete)
          <String, Object?>{
            if (request.action == CloudCredentialAction.create ||
                request.action == CloudCredentialAction.rename)
              'name': request.desiredName,
            if (needsInput) 'provider': Map<String, Object?>.of(input!._data!),
          },
      ];
      sent = true;
      final receipt = await _call(method, params);
      _reviews.clear();
      _inventories.clear();
      // Responses can contain provider secrets. Only project ID/name/type.
      if (request.action == CloudCredentialAction.delete) {
        if (receipt != true) return _unknown();
      } else {
        final entry = _ccEntry(receipt);
        if (entry.name != request.desiredName ||
            entry.provider != request.desiredProvider ||
            request.credential != null && entry.id != request.credential!.id ||
            request.action == CloudCredentialAction.create &&
                request.inventory.credentials.any((e) => e.id == entry.id)) {
          return _unknown();
        }
      }
      return const CloudCredentialResult(
        CloudCredentialOutcome.succeeded,
        'TrueNAS confirmed the stored credential operation. Cloud connectivity and future task results were not verified.',
      );
    } on JsonRpcRemoteException {
      // CRUD hooks/events may fail after the datastore write, including EACCES.
      if (sent) return _unknown();
      return const CloudCredentialResult(
        CloudCredentialOutcome.rejected,
        'Preflight failed. Nothing was submitted.',
      );
    } on CloudCredentialsException catch (error) {
      if (sent) return _unknown();
      return CloudCredentialResult(
        CloudCredentialOutcome.rejected,
        error.userMessage,
      );
    } on Object {
      if (sent) return _unknown();
      return const CloudCredentialResult(
        CloudCredentialOutcome.rejected,
        'Preflight failed. Nothing was submitted.',
      );
    } finally {
      input?.dispose();
      if (ownsCall) _calling = false;
    }
  }

  CloudCredentialResult _unknown() {
    _uncertain = true;
    _reviews.clear();
    _inventories.clear();
    return const CloudCredentialResult(
      CloudCredentialOutcome.unknown,
      'The credential change may have taken effect. Inspect the original server and reconnect before further changes. Do not repeat the request.',
    );
  }
}

CloudCredentialEntry _ccEntry(Object? raw) {
  if (raw is! Map ||
      !_ccId(raw['id']) ||
      !_ccText(raw['name'], 100) ||
      raw['provider'] is! Map ||
      !_ccText(raw['provider']['type'], 64)) {
    _ccInvalid();
  }
  return CloudCredentialEntry(
    id: raw['id'] as int,
    name: raw['name'] as String,
    provider: raw['provider']['type'] as String,
  );
}

bool _ccId(Object? value) =>
    value is int && value > 0 && value <= 9007199254740991;
bool _ccText(Object? value, int max) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= max &&
    value.trim() == value &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
bool _ccSecret(Object? value, int max, {bool empty = false}) =>
    value is String &&
    (empty || value.trim().isNotEmpty) &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
Never _ccInvalid() => throw const CloudCredentialsException(
  CloudCredentialsExceptionReason.invalidResponse,
);
