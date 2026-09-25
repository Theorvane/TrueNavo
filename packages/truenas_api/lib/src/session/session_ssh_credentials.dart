part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedSshCredentialsSession {
  SshCredentialsCapabilities get sshCredentialsCapabilities;
  Future<SshCredentialInventory> loadSshCredentials();
  Future<SshCredentialReview> reviewSshCredential(SshCredentialRequest request);
  Future<SshCredentialResult> executeSshCredential(
    SshCredentialReview review,
    String confirmation, {
    SshCredentialWriteOnlyInput? input,
  });
}

final class SshCredentialsCapabilities {
  const SshCredentialsCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canImport,
    required this.canGenerate,
    required this.canCreateConnection,
    required this.canRename,
    required this.canDelete,
  });
  const SshCredentialsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canImport = false,
      canGenerate = false,
      canCreateConnection = false,
      canRename = false,
      canDelete = false;
  final bool connected,
      versionSupported,
      available,
      canImport,
      canGenerate,
      canCreateConnection,
      canRename,
      canDelete;
  bool get supported => connected && versionSupported && available;
  bool allows(SshCredentialAction action) =>
      supported &&
      switch (action) {
        SshCredentialAction.importKeyPair => canImport,
        SshCredentialAction.generateKeyPair => canGenerate,
        SshCredentialAction.createConnection => canCreateConnection,
        SshCredentialAction.rename => canRename,
        SshCredentialAction.delete => canDelete,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect SSH credentials.'
      : !versionSupported
      ? 'Native SSH credentials require stable TrueNAS 25.10.'
      : !available
      ? 'Projected keychain, dependency and active-job reads are required.'
      : null;
}

final class SshCredentialEntry {
  const SshCredentialEntry({
    required this.id,
    required this.name,
    required this.type,
    required this.usageCount,
    this.publicKey,
    this.connection,
  });
  final int id, usageCount;
  final String name, type;
  final String? publicKey;
  final SshConnectionSettings? connection;
  bool get isKeyPair => type == 'SSH_KEY_PAIR';
  String? get publicKeyFingerprint =>
      publicKey == null ? null : sshPublicKeyFingerprint(publicKey!);
}

final class SshConnectionSettings {
  const SshConnectionSettings({
    required this.host,
    required this.port,
    required this.username,
    required this.keyPairId,
    required this.remoteHostKey,
    required this.connectTimeout,
  });
  final String host, username, remoteHostKey;
  final int port, keyPairId, connectTimeout;
  String? get validationError => !_sshHost(host)
      ? 'Enter a bare hostname or IP address, without scheme, path, credentials or shell syntax.'
      : port < 1 || port > 65535
      ? 'SSH port must be 1–65535.'
      : !RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]{0,63}$').hasMatch(username)
      ? 'Use a bounded SSH account name, without options or shell characters.'
      : !_sshId(keyPairId)
      ? 'Choose an existing keypair reference.'
      : connectTimeout < 1 || connectTimeout > 120
      ? 'Connection timeout must be 1–120 seconds.'
      : _sshHostKeys(remoteHostKey) == null
      ? 'Supply 1–8 distinct OpenSSH host public keys (at most 1024 characters total), verified independently. Supported: Ed25519, RSA and ECDSA P-256.'
      : null;
  List<String> get hostKeyFingerprints => List.unmodifiable(
    (_sshHostKeys(remoteHostKey) ?? const <String>[]).map(
      (key) => sshPublicKeyFingerprint(key)!,
    ),
  );
}

final class SshCredentialInventory {
  SshCredentialInventory({
    required this.endpoint,
    required List<SshCredentialEntry> credentials,
    this.conflictingJob = false,
  }) : credentials = List.unmodifiable(credentials);
  final String endpoint;
  final List<SshCredentialEntry> credentials;
  final bool conflictingJob;
  Iterable<SshCredentialEntry> get keyPairs =>
      credentials.where((e) => e.isKeyPair);
  Iterable<SshCredentialEntry> get connections =>
      credentials.where((e) => !e.isKeyPair);
  String? get blockedReason => conflictingJob
      ? 'An active server job may use SSH credentials. Wait and reload.'
      : null;
}

enum SshCredentialAction {
  importKeyPair,
  generateKeyPair,
  createConnection,
  rename,
  delete,
}

final class SshCredentialRequest {
  const SshCredentialRequest({
    required this.inventory,
    required this.action,
    this.credential,
    this.name = '',
    this.connection,
    this.hostKeyVerified = false,
  });
  final SshCredentialInventory inventory;
  final SshCredentialAction action;
  final SshCredentialEntry? credential;
  final String name;
  final SshConnectionSettings? connection;
  final bool hostKeyVerified;
  String get target => switch (action) {
    SshCredentialAction.importKeyPair => 'IMPORT $name',
    SshCredentialAction.generateKeyPair => 'GENERATE $name',
    SshCredentialAction.createConnection =>
      'CREATE SSH ${connection?.username ?? ''}@${connection?.host ?? ''}:${connection?.port ?? 0} / $name',
    SshCredentialAction.rename =>
      'RENAME ${credential?.id ?? 0} / ${credential?.name ?? ''}',
    SshCredentialAction.delete =>
      'DELETE ${credential?.id ?? 0} / ${credential?.name ?? ''}',
  };
  String? get validationError {
    if (inventory.blockedReason case final reason?) return reason;
    final existing =
        action == SshCredentialAction.rename ||
        action == SshCredentialAction.delete;
    if (existing) {
      if (credential == null ||
          !inventory.credentials.any((e) => identical(e, credential))) {
        return 'Choose the exact current credential.';
      }
      if (credential!.usageCount != 0) {
        return 'Remove every dependency before renaming or deleting. Cascade is not supported.';
      }
      if (connection != null || hostKeyVerified) {
        return 'Existing credentials cannot replace attributes or host trust in this workspace.';
      }
    } else if (credential != null) {
      return 'Creation cannot target an existing credential.';
    }
    if (action == SshCredentialAction.delete) {
      return name.isEmpty ? null : 'Deletion has no replacement name.';
    }
    if (!_sshText(name, 255) || name.trim() != name) {
      return 'Use a unique name of 1–255 characters without surrounding whitespace.';
    }
    if (inventory.credentials.any(
      (e) => e.id != credential?.id && e.name == name,
    )) {
      return 'Choose a unique keychain name.';
    }
    if (action == SshCredentialAction.rename && credential!.name == name) {
      return 'Enter a different name.';
    }
    if ((action == SshCredentialAction.importKeyPair ||
            action == SshCredentialAction.generateKeyPair) &&
        inventory.keyPairs.length >= 32) {
      return 'This bounded workspace supports at most 32 keypairs. Manage larger inventories in TrueNAS.';
    }
    if (action == SshCredentialAction.createConnection) {
      if (inventory.connections.length >= 32) {
        return 'This bounded workspace supports at most 32 SSH connections. Manage larger inventories in TrueNAS.';
      }
      if (connection == null || connection!.validationError != null) {
        return connection?.validationError ??
            'Enter the manual SSH connection settings.';
      }
      if (!inventory.keyPairs.any((e) => e.id == connection!.keyPairId)) {
        return 'The referenced keypair is not in the current inventory.';
      }
      if (!hostKeyVerified) {
        return 'Independently verify the destination host keys before trusting them.';
      }
    } else if (connection != null || hostKeyVerified) {
      return 'Only a new SSH connection accepts host configuration.';
    }
    return null;
  }
}

/// Write-only, short-lived import input. It must not be held in provider state,
/// profiles, logs or reviews. Only unencrypted single-key OpenSSH containers are
/// accepted; TrueNAS performs actual private/public cryptographic validation.
final class SshCredentialWriteOnlyInput {
  factory SshCredentialWriteOnlyInput.keyPair({
    required String privateKey,
    String? publicKey,
  }) => SshCredentialWriteOnlyInput._(privateKey, publicKey);
  SshCredentialWriteOnlyInput._(this._privateKey, this._publicKey);
  String? _privateKey, _publicKey;
  bool get disposed => _privateKey == null;
  String? get validationError {
    final privateKey = _privateKey;
    if (privateKey == null) {
      return 'Private-key input was discarded. Enter it again.';
    }
    final embedded = _sshPrivatePublicBlob(privateKey);
    if (embedded == null) {
      return 'Use an unencrypted, single-key OpenSSH private-key block (at most 64 KiB). PEM, encrypted and multi-key files are not supported here.';
    }
    if (_publicKey != null && _publicKey!.isNotEmpty) {
      final public = _sshPublicBlob(_publicKey!);
      if (public == null || base64Encode(public) != base64Encode(embedded)) {
        return 'The supplied public key does not match the OpenSSH container identity.';
      }
    }
    return null;
  }

  void dispose() {
    _privateKey = null;
    _publicKey = null;
  }

  Map<String, Object?> _attributes() => {
    'private_key': '${_privateKey!.trim()}\n',
    'public_key': _publicKey == null || _publicKey!.isEmpty
        ? null
        : _sshNormalizePublic(_publicKey!),
  };
  @override
  String toString() => 'SshCredentialWriteOnlyInput(<redacted>)';
}

final class SshCredentialReview {
  SshCredentialReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final SshCredentialRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
  SshCredentialAction get action => request.action;
}

enum SshCredentialOutcome { succeeded, rejected, unknown }

final class SshCredentialResult {
  const SshCredentialResult(this.outcome, this.message, {this.publicKey});
  final SshCredentialOutcome outcome;
  final String message;

  /// Only a public key returned by a separate safe projected verification read.
  final String? publicKey;
}

enum SshCredentialsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  invalidRequest,
  invalidResponse,
  staleReview,
  unavailable,
}

final class SshCredentialsException implements Exception {
  const SshCredentialsException(this.reason);
  final SshCredentialsExceptionReason reason;
  String get userMessage => switch (reason) {
    SshCredentialsExceptionReason.notAuthenticated =>
      'Reconnect before managing SSH credentials.',
    SshCredentialsExceptionReason.unsupportedVersion =>
      'Native SSH credentials require stable TrueNAS 25.10.',
    SshCredentialsExceptionReason.unavailableMethod =>
      'Required public keychain and dependency methods are unavailable.',
    SshCredentialsExceptionReason.busy => 'Another server operation is pending or uncertain. Verify it before continuing.',
    SshCredentialsExceptionReason.invalidRequest => 'Check the exact credential, dependencies and manual host trust. Nothing was sent.',
    SshCredentialsExceptionReason.invalidResponse => 'SSH credential identity could not be verified. Remote details were withheld.',
    SshCredentialsExceptionReason.staleReview => 'The review expired or credential references changed. Reload and review again.',
    SshCredentialsExceptionReason.unavailable => 'SSH credential information could not be read safely. Remote details were withheld.',
  };
  @override
  String toString() => 'SshCredentialsException(${reason.name})';
}

final class _SessionSshCredentials {
  _SessionSshCredentials({
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
  final Set<SshCredentialInventory> _inventories = {};
  final Map<SshCredentialReview, DateTime> _reviews = {};
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

  SshCredentialsCapabilities get capabilities {
    final create = _method('keychaincredential.create');
    return SshCredentialsCapabilities(
      connected: isCurrent(),
      versionSupported: _version,
      available: const [
        'keychaincredential.query',
        'keychaincredential.used_by',
        'core.get_jobs',
      ].every(_method),
      canImport: create,
      canGenerate:
          create && _method('keychaincredential.generate_ssh_key_pair'),
      canCreateConnection: create,
      canRename: _method('keychaincredential.update'),
      canDelete: _method('keychaincredential.delete'),
    );
  }

  void _guard([SshCredentialAction? action]) {
    if (!isCurrent()) {
      throw const SshCredentialsException(
        SshCredentialsExceptionReason.notAuthenticated,
      );
    }
    if (!_version) {
      throw const SshCredentialsException(
        SshCredentialsExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.supported ||
        action != null && !capabilities.allows(action)) {
      throw const SshCredentialsException(
        SshCredentialsExceptionReason.unavailableMethod,
      );
    }
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    _guard();
    final value = await client
        .call(method, id: nextId(), params: args)
        .timeout(requestTimeout);
    _guard();
    return value;
  }

  Future<SshCredentialInventory> _read() async {
    final entries = <SshCredentialEntry>[];
    for (final type in ['SSH_KEY_PAIR', 'SSH_CREDENTIALS']) {
      // Type filtering happens BEFORE projection. Never project private_key on
      // keypair rows: there it is secret material, not a connection's integer ID.
      final rows = await _call('keychaincredential.query', [
        [
          ['type', '=', type],
        ],
        {
          'limit': 33,
          'select': [
            'id',
            'name',
            'type',
            if (type == 'SSH_KEY_PAIR')
              'attributes.public_key'
            else ...[
              'attributes.host',
              'attributes.port',
              'attributes.username',
              'attributes.private_key',
              'attributes.remote_host_key',
              'attributes.connect_timeout',
            ],
          ],
        },
      ]);
      if (rows is! List || rows.length > 32) _sshInvalid();
      for (final row in rows) {
        if (row is! Map ||
            !_sshId(row['id']) ||
            !_sshText(row['name'], 255) ||
            row['type'] != type) {
          _sshInvalid();
        }
        final attributes = row['attributes'];
        if (attributes is! Map) _sshInvalid();
        String? publicKey;
        SshConnectionSettings? connection;
        if (type == 'SSH_KEY_PAIR') {
          // Absence/decryption failure is not interpreted as an empty keypair.
          if (attributes['public_key'] is! String ||
              _sshPublicBlob(attributes['public_key'] as String) == null) {
            _sshInvalid();
          }
          publicKey = _sshNormalizePublic(attributes['public_key'] as String);
        } else {
          if (!_sshText(attributes['host'], 253) ||
              !_sshText(attributes['username'], 128) ||
              attributes['port'] is! int ||
              !_sshId(attributes['private_key']) ||
              attributes['remote_host_key'] is! String ||
              _sshHostKeys(attributes['remote_host_key'] as String) == null ||
              attributes['connect_timeout'] is! int) {
            _sshInvalid();
          }
          connection = SshConnectionSettings(
            host: attributes['host'] as String,
            port: attributes['port'] as int,
            username: attributes['username'] as String,
            keyPairId: attributes['private_key'] as int,
            remoteHostKey: _sshHostKeys(
              attributes['remote_host_key'] as String,
            )!.join('\n'),
            connectTimeout: attributes['connect_timeout'] as int,
          );
          // Existing configuration is untrusted too: never display an embedded
          // password/user-info URI or shell-like account as an ordinary host.
          if (connection.validationError != null) _sshInvalid();
          // Host key material must be structurally public; never retain a
          // misplaced private key or arbitrary raw content in provider models.
        }
        final used = await _call('keychaincredential.used_by', [row['id']]);
        if (used is! List || used.length > 256) _sshInvalid();
        for (final reference in used) {
          if (reference is! Map ||
              !_sshText(reference['title'], 1024) ||
              !{'delete', 'disable'}.contains(reference['unbind_method'])) {
            _sshInvalid();
          }
        }
        entries.add(
          SshCredentialEntry(
            id: row['id'] as int,
            name: row['name'] as String,
            type: type,
            usageCount: used.length,
            publicKey: publicKey,
            connection: connection,
          ),
        );
      }
    }
    if (entries.map((e) => e.id).toSet().length != entries.length) {
      _sshInvalid();
    }
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
    if (jobs is! List || jobs.length > 128) _sshInvalid();
    for (final job in jobs) {
      if (job is! Map ||
          !_sshId(job['id']) ||
          !_sshText(job['method'], 128) ||
          !{'WAITING', 'RUNNING'}.contains(job['state'])) {
        _sshInvalid();
      }
    }
    entries.sort((a, b) => a.id.compareTo(b.id));
    return SshCredentialInventory(
      endpoint: _endpoint,
      credentials: entries,
      conflictingJob: jobs.isNotEmpty,
    );
  }

  Future<SshCredentialInventory> load() async {
    _guard();
    if (_calling) {
      throw const SshCredentialsException(SshCredentialsExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final value = await _read();
      _inventories.add(value);
      return value;
    } on SshCredentialsException {
      rethrow;
    } on Object {
      throw const SshCredentialsException(
        SshCredentialsExceptionReason.unavailable,
      );
    } finally {
      _calling = false;
    }
  }

  Future<SshCredentialReview> review(SshCredentialRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const SshCredentialsException(SshCredentialsExceptionReason.busy);
    }
    if (!_inventories.contains(request.inventory)) {
      throw const SshCredentialsException(
        SshCredentialsExceptionReason.staleReview,
      );
    }
    if (request.validationError != null) {
      throw const SshCredentialsException(
        SshCredentialsExceptionReason.invalidRequest,
      );
    }
    _calling = true;
    try {
      final fresh = await _read();
      if (!_sshSameInventory(fresh, request.inventory)) {
        throw const SshCredentialsException(
          SshCredentialsExceptionReason.staleReview,
        );
      }
      final result = SshCredentialReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'This changes the keychain on $_endpoint only. No remote SSH connection, host-key scan, authentication or authorized_keys setup is performed.',
          if (request.action == SshCredentialAction.importKeyPair) 'The private key is write-only input, held briefly in memory. TrueNAS validates it using local ssh-keygen and temporary mode-0600 files, then persists it encrypted in its keychain. Private material is not returned to the app UI.',
          if (request.action == SshCredentialAction.generateKeyPair) 'This explicitly authorizes TWO operations: generate a server-default RSA keypair in temporary files, then store it in the encrypted keychain. The private value passes through SDK memory only and is never displayed or cached. A partial result is not automatically retried.',
          if (request.action == SshCredentialAction.createConnection) 'You explicitly trust the independently verified host public keys below. Pasting a discovered key is not verification. No remote key discovery or authentication test occurs.',
          if (request.action == SshCredentialAction.createConnection)
            ...request.connection!.hostKeyFingerprints.map(
              (f) => 'Trusted host-key fingerprint: $f',
            ),
          if (request.action == SshCredentialAction.createConnection) 'The selected keypair ID exists, but safe metadata cannot prove that it has a private key or that its value is unchanged. Public-only keypairs are possible. Success means stored configuration, not a usable or authenticated connection.',
          if (request.action == SshCredentialAction.rename) 'Name-only update retains server-side attributes but still revalidates key material and refreshes replication configuration. Only currently unused credentials are allowed.',
          if (request.action == SshCredentialAction.delete) 'Deletion is permanent and cascade is always false. Referencing SSH connections, SFTP cloud credentials, replication and rsync tasks must be removed separately. Existing remote authorized keys or sessions are not revoked.',
          'Dependency checks are repeated before submission. Public used_by references have titles/actions but no stable IDs; only their absence permits rename/delete. Secret-only external replacement is not detectable without reading private material. There is no atomic compare-and-swap protection against external changes.',
          'Any uncertain response after generation or mutation leaves the session write-fenced. Inspect the original server, then reconnect; do not repeat the request.',
        ],
      );
      _reviews.clear();
      _reviews[result] = DateTime.now();
      return result;
    } on SshCredentialsException {
      rethrow;
    } on Object {
      throw const SshCredentialsException(
        SshCredentialsExceptionReason.unavailable,
      );
    } finally {
      _calling = false;
    }
  }

  Future<SshCredentialResult> execute(
    SshCredentialReview review,
    String confirmation, {
    SshCredentialWriteOnlyInput? input,
  }) async {
    Map<String, Object?>? attributes;
    try {
      _guard(review.action);
      if (isBusy || isOtherMutationBusy()) {
        throw const SshCredentialsException(SshCredentialsExceptionReason.busy);
      }
      final issued = _reviews.remove(review);
      if (issued == null ||
          DateTime.now().difference(issued) > const Duration(minutes: 5) ||
          confirmation != review.target ||
          review.endpoint != _endpoint ||
          !_inventories.contains(review.request.inventory)) {
        throw const SshCredentialsException(
          SshCredentialsExceptionReason.staleReview,
        );
      }
      final request = review.request;
      final importing = request.action == SshCredentialAction.importKeyPair;
      if (request.validationError != null ||
          importing && (input == null || input.validationError != null) ||
          !importing && input != null) {
        throw const SshCredentialsException(
          SshCredentialsExceptionReason.invalidRequest,
        );
      }
      _calling = true;
      var dispatched = false;
      try {
        final fresh = await _read();
        if (!_sshSameInventory(fresh, request.inventory) ||
            fresh.blockedReason != null) {
          return const SshCredentialResult(
            SshCredentialOutcome.rejected,
            'Credential identity, dependencies or active jobs changed. Nothing was sent.',
          );
        }
        if (isOtherMutationBusy()) {
          throw const SshCredentialsException(
            SshCredentialsExceptionReason.busy,
          );
        }
        String? expectedPublic;
        if (importing) {
          if (input!.validationError != null) {
            throw const SshCredentialsException(
              SshCredentialsExceptionReason.invalidRequest,
            );
          }
          attributes = input._attributes();
          expectedPublic = _sshBlobPublic(
            _sshPrivatePublicBlob(attributes['private_key'] as String)!,
          );
          input.dispose();
        }
        if (request.action == SshCredentialAction.generateKeyPair) {
          _guard(request.action);
          dispatched = true;
          final generated = await _call(
            'keychaincredential.generate_ssh_key_pair',
            const [],
          );
          if (generated is! Map ||
              generated['private_key'] is! String ||
              generated['public_key'] is! String) {
            return _unknown();
          }
          final generatedInput = SshCredentialWriteOnlyInput.keyPair(
            privateKey: generated['private_key'] as String,
            publicKey: generated['public_key'] as String,
          );
          try {
            if (generatedInput.validationError != null ||
                !(generated['public_key'] as String).startsWith('ssh-rsa ')) {
              return _unknown();
            }
            attributes = generatedInput._attributes();
            expectedPublic = _sshNormalizePublic(
              generated['public_key'] as String,
            );
          } finally {
            generatedInput.dispose();
          }
          // Generation has effects even if references changed before storage.
          final afterGenerate = await _read();
          if (!_sshSameInventory(fresh, afterGenerate)) return _unknown();
        }
        if (isOtherMutationBusy()) {
          if (dispatched) return _unknown();
          throw const SshCredentialsException(
            SshCredentialsExceptionReason.busy,
          );
        }
        _guard(request.action);
        final method = switch (request.action) {
          SshCredentialAction.rename => 'keychaincredential.update',
          SshCredentialAction.delete => 'keychaincredential.delete',
          _ => 'keychaincredential.create',
        };
        final args = switch (request.action) {
          SshCredentialAction.rename => <Object?>[
            request.credential!.id,
            {'name': request.name},
          ],
          SshCredentialAction.delete => <Object?>[
            request.credential!.id,
            {'cascade': false},
          ],
          SshCredentialAction.createConnection => <Object?>[
            {
              'name': request.name,
              'type': 'SSH_CREDENTIALS',
              'attributes': _sshConnectionAttributes(request.connection!),
            },
          ],
          _ => <Object?>[
            {
              'name': request.name,
              'type': 'SSH_KEY_PAIR',
              'attributes': attributes,
            },
          ],
        };
        dispatched = true;
        final receipt = await _call(method, args);
        attributes?.clear();
        attributes = null;
        _inventories.clear();
        _reviews.clear();
        int? receiptId;
        if (request.action == SshCredentialAction.delete) {
          if (receipt != null) return _unknown();
        } else {
          final type = request.action == SshCredentialAction.rename
              ? request.credential!.type
              : request.action == SshCredentialAction.createConnection
              ? 'SSH_CREDENTIALS'
              : 'SSH_KEY_PAIR';
          // Do not traverse or retain receipt.attributes: CRUD returns secrets.
          if (receipt is! Map ||
              !_sshId(receipt['id']) ||
              receipt['name'] != request.name ||
              receipt['type'] != type) {
            return _unknown();
          }
          receiptId = receipt['id'] as int;
          if (request.action == SshCredentialAction.rename
              ? receiptId != request.credential!.id
              : fresh.credentials.any((e) => e.id == receiptId)) {
            return _unknown();
          }
        }
        final after = await _read();
        if (!_sshVerifyAfter(
          request,
          fresh,
          after,
          receiptId,
          expectedPublic,
        )) {
          return _unknown();
        }
        return SshCredentialResult(
          SshCredentialOutcome.succeeded,
          request.action == SshCredentialAction.createConnection
              ? 'The manual SSH configuration was stored and reread. No SSH connection or authentication test was performed.'
              : request.action == SshCredentialAction.delete
              ? 'The unreferenced keychain entry is absent after deletion. Remote authorized keys and existing sessions were not revoked.'
              : request.action == SshCredentialAction.rename
              ? 'The name change was verified through safe projected metadata. Private attributes were not read.'
              : 'The keypair was stored and its public identity verified. Only the public key is available here; private material is not retained by TrueRAID.',
          publicKey: expectedPublic == null
              ? null
              : after.credentials
                    .singleWhere((entry) => entry.id == receiptId)
                    .publicKey,
        );
      } on Object {
        if (dispatched) return _unknown();
        return const SshCredentialResult(
          SshCredentialOutcome.rejected,
          'Preflight did not complete safely. No SSH credential change was sent.',
        );
      } finally {
        _calling = false;
      }
    } finally {
      input?.dispose();
      attributes?.clear();
    }
  }

  SshCredentialResult _unknown() {
    _uncertain = true;
    _inventories.clear();
    _reviews.clear();
    return const SshCredentialResult(
      SshCredentialOutcome.unknown,
      'The SSH keychain outcome is unknown. Private material was discarded. Verify the original server and dependencies, then reconnect; do not repeat this request.',
    );
  }
}

bool _sshId(Object? value) =>
    value is int && value > 0 && value <= 9007199254740991;
bool _sshText(Object? value, int max) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
Never _sshInvalid() => throw const SshCredentialsException(
  SshCredentialsExceptionReason.invalidResponse,
);
bool _sshHost(String host) {
  if (!_sshText(host, 253) || host.trim() != host || host.startsWith('-')) {
    return false;
  }
  if (host.contains(':')) {
    return !host.contains('%') &&
        !host.contains('[') &&
        !host.contains(']') &&
        Uri.tryParse('ssh://[$host]')?.host == host;
  }
  return host
      .split('.')
      .every(
        (s) =>
            s.length <= 63 &&
            RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$').hasMatch(s),
      );
}

List<int>? _sshPublicBlob(String value) {
  if (value.length > 16384) return null;
  final parts = value.trim().split(RegExp(r'\s+'));
  if (parts.length < 2 ||
      !{'ssh-ed25519', 'ssh-rsa', 'ecdsa-sha2-nistp256'}.contains(parts[0]) ||
      value.trim().contains('\n') ||
      !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(parts[1])) {
    return null;
  }
  try {
    final bytes = base64Decode(parts[1]);
    if (bytes.length > 8192 || base64Encode(bytes) != parts[1]) return null;
    final reader = _SshBlobReader(bytes);
    if (utf8.decode(reader.string()) != parts[0]) return null;
    switch (parts[0]) {
      case 'ssh-ed25519':
        if (reader.string().length != 32) return null;
      case 'ssh-rsa':
        final exponent = reader.string(), modulus = reader.string();
        if (!_sshPositiveMpint(exponent) ||
            exponent.length > 8 ||
            exponent.last.isEven ||
            exponent.length == 1 && exponent.single < 3 ||
            !_sshPositiveMpint(modulus) ||
            modulus.length > 1025 ||
            _sshMpintBits(modulus) < 2048 ||
            _sshMpintBits(modulus) > 8192 ||
            modulus.last.isEven) {
          return null;
        }
      case 'ecdsa-sha2-nistp256':
        if (utf8.decode(reader.string()) != 'nistp256') return null;
        final point = reader.string();
        if (point.length != 65 || point.first != 4) return null;
    }
    return reader.done ? bytes : null;
  } on Object {
    return null;
  }
}

String _sshNormalizePublic(String value) =>
    _sshBlobPublic(_sshPublicBlob(value)!);
bool _sshPositiveMpint(List<int> bytes) =>
    bytes.isNotEmpty &&
    (bytes.first == 0
        ? bytes.length > 1 && bytes[1] >= 128
        : bytes.first < 128);
int _sshMpintBits(List<int> bytes) {
  final offset = bytes.first == 0 ? 1 : 0;
  return (bytes.length - offset - 1) * 8 + bytes[offset].bitLength;
}

String _sshBlobPublic(List<int> blob) =>
    '${utf8.decode(_SshBlobReader(blob).string())} ${base64Encode(blob)}';

/// SHA-256 of the SSH wire-format public-key blob, not its base64 text.
String? sshPublicKeyFingerprint(String publicKey) {
  final bytes = _sshPublicBlob(publicKey);
  return bytes == null
      ? null
      : 'SHA256:${base64Encode(crypto.sha256.convert(bytes).bytes).replaceAll('=', '')}';
}

List<String>? _sshHostKeys(String value) {
  if (value.length > 1024) return null;
  final lines = value.trim().split('\n');
  if (lines.isEmpty ||
      lines.length > 8 ||
      lines.any((line) => _sshPublicBlob(line) == null)) {
    return null;
  }
  final keys = lines.map(_sshNormalizePublic).toList();
  if (keys.toSet().length != keys.length) return null;
  return keys;
}

List<int>? _sshPrivatePublicBlob(String value) {
  if (value.length > 65536) return null;
  final match = RegExp(
    r'^-----BEGIN OPENSSH PRIVATE KEY-----\r?\n([A-Za-z0-9+/=\r\n]+)\r?\n-----END OPENSSH PRIVATE KEY-----$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  try {
    final bytes = base64Decode(match[1]!.replaceAll(RegExp(r'\s'), ''));
    final magic = utf8.encode('openssh-key-v1\x00');
    if (bytes.length < magic.length ||
        List.generate(
          magic.length,
          (i) => bytes[i] == magic[i],
        ).any((b) => !b)) {
      return null;
    }
    final reader = _SshBlobReader(bytes, offset: magic.length);
    if (utf8.decode(reader.string()) != 'none' ||
        utf8.decode(reader.string()) != 'none' ||
        reader.string().isNotEmpty ||
        reader.number() != 1) {
      return null;
    }
    final public = reader.string();
    if (_sshPublicBlob(_sshBlobPublic(public)) == null ||
        reader.string().isEmpty ||
        !reader.done) {
      return null;
    }
    return public;
  } on Object {
    return null;
  }
}

final class _SshBlobReader {
  _SshBlobReader(this.bytes, {this.offset = 0});
  final List<int> bytes;
  int offset;
  bool get done => offset == bytes.length;
  int number() {
    if (offset + 4 > bytes.length) {
      throw const FormatException('Invalid SSH field.');
    }
    final n =
        bytes[offset] * 16777216 +
        bytes[offset + 1] * 65536 +
        bytes[offset + 2] * 256 +
        bytes[offset + 3];
    offset += 4;
    return n;
  }

  List<int> string() {
    final length = number();
    if (length > 65536 || offset + length > bytes.length) {
      throw const FormatException('Invalid SSH field.');
    }
    final result = bytes.sublist(offset, offset + length);
    offset += length;
    return result;
  }
}

Map<String, Object?> _sshConnectionAttributes(SshConnectionSettings settings) =>
    {
      'host': settings.host,
      'port': settings.port,
      'username': settings.username,
      'private_key': settings.keyPairId,
      'remote_host_key': _sshHostKeys(settings.remoteHostKey)!.join('\n'),
      'connect_timeout': settings.connectTimeout,
    };
bool _sshSameConnection(SshConnectionSettings? a, SshConnectionSettings? b) =>
    a == null || b == null
    ? a == b
    : a.host == b.host &&
          a.port == b.port &&
          a.username == b.username &&
          a.keyPairId == b.keyPairId &&
          a.remoteHostKey == b.remoteHostKey &&
          a.connectTimeout == b.connectTimeout;
bool _sshSameEntry(
  SshCredentialEntry a,
  SshCredentialEntry b, {
  bool ignoreName = false,
  bool ignoreUsage = false,
}) =>
    a.id == b.id &&
    (ignoreName || a.name == b.name) &&
    a.type == b.type &&
    (ignoreUsage || a.usageCount == b.usageCount) &&
    a.publicKey == b.publicKey &&
    _sshSameConnection(a.connection, b.connection);
bool _sshSameInventory(SshCredentialInventory a, SshCredentialInventory b) =>
    a.endpoint == b.endpoint &&
    a.conflictingJob == b.conflictingJob &&
    a.credentials.length == b.credentials.length &&
    List.generate(
      a.credentials.length,
      (i) => _sshSameEntry(a.credentials[i], b.credentials[i]),
    ).every((v) => v);
bool _sshVerifyAfter(
  SshCredentialRequest request,
  SshCredentialInventory before,
  SshCredentialInventory after,
  int? receiptId,
  String? expectedPublic,
) {
  if (before.endpoint != after.endpoint || after.conflictingJob) return false;
  final action = request.action;
  final expectedCount =
      before.credentials.length +
      (action == SshCredentialAction.delete
          ? -1
          : action == SshCredentialAction.rename
          ? 0
          : 1);
  if (after.credentials.length != expectedCount) return false;
  for (final old in before.credentials) {
    final matches = after.credentials.where((e) => e.id == old.id).toList();
    if (action == SshCredentialAction.delete &&
        old.id == request.credential!.id) {
      if (matches.isNotEmpty) return false;
      continue;
    }
    if (matches.length != 1) return false;
    final current = matches.single;
    if (action == SshCredentialAction.rename &&
        old.id == request.credential!.id) {
      if (!_sshSameEntry(old, current, ignoreName: true) ||
          current.name != request.name) {
        return false;
      }
    } else if (action == SshCredentialAction.createConnection &&
        old.id == request.connection!.keyPairId) {
      if (!_sshSameEntry(old, current, ignoreUsage: true) ||
          current.usageCount != old.usageCount + 1) {
        return false;
      }
    } else if (action == SshCredentialAction.delete &&
        request.credential!.connection?.keyPairId == old.id) {
      if (!_sshSameEntry(old, current, ignoreUsage: true) ||
          current.usageCount != old.usageCount - 1) {
        return false;
      }
    } else if (!_sshSameEntry(old, current)) {
      return false;
    }
  }
  if (action == SshCredentialAction.delete ||
      action == SshCredentialAction.rename) {
    return true;
  }
  final created = after.credentials.where((e) => e.id == receiptId).toList();
  if (created.length != 1 ||
      created.single.name != request.name ||
      created.single.usageCount != 0) {
    return false;
  }
  if (action == SshCredentialAction.createConnection) {
    final expected = request.connection!;
    return created.single.type == 'SSH_CREDENTIALS' &&
        _sshSameConnection(
          created.single.connection,
          SshConnectionSettings(
            host: expected.host,
            port: expected.port,
            username: expected.username,
            keyPairId: expected.keyPairId,
            remoteHostKey: _sshHostKeys(expected.remoteHostKey)!.join('\n'),
            connectTimeout: expected.connectTimeout,
          ),
        );
  }
  return created.single.isKeyPair && created.single.publicKey == expectedPublic;
}
