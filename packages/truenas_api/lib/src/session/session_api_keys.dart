part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedApiKeysSession {
  ApiKeysCapabilities get apiKeysCapabilities;
  Future<ApiKeyInventory> loadApiKeys();
  Future<ApiKeyReview> reviewApiKey(ApiKeyRequest request);
  Future<ApiKeyResult> executeApiKey(ApiKeyReview review, String confirmation);
}

final class ApiKeysCapabilities {
  const ApiKeysCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canCreate,
    required this.canUpdate,
    required this.canDelete,
  });
  const ApiKeysCapabilities.disconnected()
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
  bool supports(ApiKeyAction action) =>
      supported &&
      switch (action) {
        ApiKeyAction.create => canCreate,
        ApiKeyAction.edit || ApiKeyAction.rotate => canUpdate,
        ApiKeyAction.delete => canDelete,
      };
  String? get blockedReason => !connected
      ? 'Connect to manage API keys.'
      : !versionSupported
      ? 'Native API keys require stable TrueNAS 25.10.'
      : !available
      ? 'Current identity, session, local user, key and security reads are required.'
      : null;
}

final class ApiKeySnapshot {
  const ApiKeySnapshot({
    required this.id,
    required this.name,
    required this.username,
    required this.userId,
    required this.createdAt,
    required this.expiresAt,
    required this.local,
    required this.revoked,
  });
  final int id;
  final String name;
  final String? username;
  final Object userId;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final bool local, revoked;
  bool get expired => expiresAt != null && !expiresAt!.isAfter(DateTime.now());
}

/// Contains public display identity only. No key hash, key value or auth token.
final class ApiKeyInventory {
  ApiKeyInventory({
    required this.endpoint,
    required this.username,
    required this.userId,
    required this.sessionId,
    required this.credentialType,
    required this.currentKeyId,
    required this.accountEligible,
    required this.stig,
    required List<ApiKeySnapshot> keys,
    List<String> accountRoles = const [],
  }) : keys = List.unmodifiable(keys),
       accountRoles = List.unmodifiable(accountRoles);
  final String endpoint, username, sessionId, credentialType;
  final int userId;
  final int? currentKeyId;
  final bool accountEligible, stig;
  final List<ApiKeySnapshot> keys;
  final List<String> accountRoles;
  String? get blockedReason => stig
      ? 'GPOS STIG mode prohibits API-key changes.'
      : !accountEligible
      ? 'Only the current, unlocked, role-bearing local non-builtin account is supported.'
      : !{
          'API_KEY',
          'LOGIN_PASSWORD',
          'LOGIN_TWOFACTOR',
        }.contains(credentialType)
      ? 'This session credential cannot be safely identified for key management.'
      : credentialType == 'API_KEY' &&
            (currentKeyId == null ||
                !keys.any(
                  (k) => k.id == currentKeyId && !k.revoked && !k.expired,
                ))
      ? 'The current API key could not be matched to active inventory.'
      : null;
  String? targetBlockedReason(ApiKeySnapshot key) =>
      blockedReason ??
      (key.id == currentKeyId
          ? 'The API key authenticating this session is protected. Use a separate password or OTP session.'
          : key.username != username || key.userId != userId || !key.local
          ? 'System, legacy, directory-service and other-account keys are protected.'
          : null);
}

enum ApiKeyAction { create, edit, rotate, delete }

final class ApiKeyRequest {
  const ApiKeyRequest({
    required this.inventory,
    required this.action,
    this.key,
    this.name = '',
    this.expiresAt,
  });
  final ApiKeyInventory inventory;
  final ApiKeyAction action;
  final ApiKeySnapshot? key;
  final String name;
  final DateTime? expiresAt;

  /// TrueNAS stores expiration as integer Unix seconds.
  DateTime? get serverExpiry => expiresAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          expiresAt!.millisecondsSinceEpoch ~/ 1000 * 1000,
          isUtc: true,
        );
  String get target => action == ApiKeyAction.create
      ? 'CREATE $name'
      : '${action.name.toUpperCase()} ${key?.id ?? ''} / ${key?.name ?? ''}';
  String? get validationError {
    if (inventory.blockedReason case final reason?) return reason;
    if (action == ApiKeyAction.create && key != null) {
      return 'Creation cannot target an existing key.';
    }
    if (action != ApiKeyAction.create) {
      if (key == null || !inventory.keys.any((k) => identical(k, key))) {
        return 'Select an exact current key.';
      }
      if (inventory.targetBlockedReason(key!) case final reason?) return reason;
    }
    if (action == ApiKeyAction.delete) {
      return name.isNotEmpty || expiresAt != null
          ? 'Deletion does not accept replacement fields.'
          : null;
    }
    if (!_apiKeyText(name, 200) || name.trim() != name) {
      return 'Enter a name of 1–200 characters without leading or trailing whitespace.';
    }
    if (inventory.keys.any((k) => k.id != key?.id && k.name == name)) {
      return 'This account already has a key with that name.';
    }
    if (serverExpiry != null &&
        (!serverExpiry!.isAfter(
              DateTime.now().add(const Duration(minutes: 1)),
            ) ||
            serverExpiry!.isAfter(
              DateTime.now().add(const Duration(days: 366)),
            ))) {
      return 'Choose an expiry between one minute and one year from now, or explicitly choose no expiry.';
    }
    return null;
  }
}

final class ApiKeyReview {
  ApiKeyReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final ApiKeyRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
  ApiKeyAction get action => request.action;
}

/// A newly returned value can be consumed once. Do not put this object into
/// provider state, persistence, logging or a diagnostic message. Dart strings
/// cannot be guaranteed to be zeroized. Discard on dismissal/session change.
final class ApiKeyOneTimeSecret {
  ApiKeyOneTimeSecret(String value) : _value = value;
  String? _value;
  String? take() {
    final value = _value;
    _value = null;
    return value;
  }

  void discard() => _value = null;
  @override
  String toString() => 'ApiKeyOneTimeSecret(redacted)';
}

enum ApiKeyOutcome { succeeded, rejected, unknown }

final class ApiKeyResult {
  const ApiKeyResult(this.outcome, this.message, {this.secret});
  final ApiKeyOutcome outcome;
  final String message;
  final ApiKeyOneTimeSecret? secret;
  ApiKeyResult get withoutSecret => ApiKeyResult(outcome, message);
  @override
  String toString() => 'ApiKeyResult(${outcome.name})';
}

enum ApiKeysExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  unavailable,
  invalidResponse,
  invalidRequest,
  staleReview,
  busy,
}

final class ApiKeysException implements Exception {
  const ApiKeysException(this.reason);
  final ApiKeysExceptionReason reason;
  String get userMessage => switch (reason) {
    ApiKeysExceptionReason.notAuthenticated =>
      'Reconnect before managing API keys.',
    ApiKeysExceptionReason.unsupportedVersion =>
      'This TrueNAS version is not supported for native API keys.',
    ApiKeysExceptionReason.unavailableMethod =>
      'Required API-key methods are unavailable.',
    ApiKeysExceptionReason.unavailable => 'API-key information could not be read safely. Remote details were withheld.',
    ApiKeysExceptionReason.invalidResponse =>
      'API-key identity could not be verified. Remote details were withheld.',
    ApiKeysExceptionReason.invalidRequest =>
      'Check the selected account, key and expiry. Nothing was sent.',
    ApiKeysExceptionReason.staleReview =>
      'The review expired or identity changed. Reload and review again.',
    ApiKeysExceptionReason.busy => 'Another operation is pending or uncertain. Verify it before another change.',
  };
  @override
  String toString() => 'ApiKeysException(${reason.name})';
}

final class _SessionApiKeys {
  _SessionApiKeys({
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
       _identity = summary.identity,
       _metadata = metadata is Map ? Map.of(metadata) : const {};
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final String _endpoint, _identity;
  final bool _supportedVersion;
  final Map _metadata;
  bool _calling = false, _uncertain = false;
  final Set<ApiKeyInventory> _inventories = {};
  final Map<ApiKeyReview, DateTime> _reviews = {};
  bool get isBusy => _calling || _uncertain;
  static const _reads = {
    'auth.me',
    'auth.sessions',
    'user.query',
    'api_key.query',
    'system.security.config',
  };
  bool _method(String name, {bool write = false}) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == false &&
        row['uploadable'] == false &&
        row['downloadable'] == false &&
        row['private'] != true &&
        row['_private'] != true &&
        (!write || row['no_auth_required'] == false);
  }

  ApiKeysCapabilities get capabilities => ApiKeysCapabilities(
    connected: isCurrent(),
    versionSupported: _supportedVersion,
    available: _reads.every(_method),
    canCreate: _method('api_key.create', write: true),
    canUpdate: _method('api_key.update', write: true),
    canDelete: _method('api_key.delete', write: true),
  );
  void _guard([ApiKeyAction? action]) {
    if (!isCurrent()) {
      throw const ApiKeysException(ApiKeysExceptionReason.notAuthenticated);
    }
    if (!_supportedVersion) {
      throw const ApiKeysException(ApiKeysExceptionReason.unsupportedVersion);
    }
    if (!capabilities.supported ||
        action != null && !capabilities.supports(action)) {
      throw const ApiKeysException(ApiKeysExceptionReason.unavailableMethod);
    }
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    _guard();
    final result = await client
        .call(method, id: nextId(), params: args)
        .timeout(requestTimeout);
    _guard();
    return result;
  }

  Future<ApiKeyInventory> _load() async {
    final me = await _call('auth.me', const []);
    if (me is! Map ||
        !_apiKeyText(me['pw_name'], 128) ||
        me['pw_name'] != _identity) {
      _apiKeyInvalid();
    }
    final username = me['pw_name'] as String;
    final sessions = await _call('auth.sessions', const [
      [
        ['current', '=', true],
      ],
      {
        'limit': 2,
        'select': [
          'id',
          'current',
          'internal',
          'secure_transport',
          'credentials',
          'credentials_data',
        ],
      },
    ]);
    if (sessions is! List || sessions.length != 1) _apiKeyInvalid();
    final session = sessions.single;
    if (session is! Map ||
        session['current'] != true ||
        session['internal'] != false ||
        session['secure_transport'] != true ||
        !_apiKeyText(session['id'], 256) ||
        !_apiKeyText(session['credentials'], 64)) {
      _apiKeyInvalid();
    }
    final credential = session['credentials'] as String;
    final data = session['credentials_data'];
    if (data is! Map || data['username'] != username) _apiKeyInvalid();
    int? currentKey;
    if (credential == 'API_KEY') {
      final key = data['api_key'];
      if (key is! Map || !_apiKeyId(key['id'])) _apiKeyInvalid();
      currentKey = key['id'] as int;
    }
    final users = await _call('user.query', [
      [
        ['username', '=', username],
        ['local', '=', true],
      ],
      {
        'limit': 2,
        'select': ['id', 'username', 'local', 'builtin', 'locked', 'roles'],
      },
    ]);
    if (users is! List || users.length != 1) _apiKeyInvalid();
    final user = users.single;
    if (user is! Map ||
        !_apiKeyId(user['id']) ||
        user['username'] != username ||
        user['local'] != true ||
        user['builtin'] is! bool ||
        user['locked'] is! bool ||
        user['roles'] is! List ||
        (user['roles'] as List).any((r) => !_apiKeyText(r, 128))) {
      _apiKeyInvalid();
    }
    final security = await _call('system.security.config', const []);
    if (security is! Map || security['enable_gpos_stig'] is! bool) {
      _apiKeyInvalid();
    }
    final rows = await _call('api_key.query', [
      [
        ['username', '=', username],
      ],
      {
        'limit': 129,
        'select': [
          'id',
          'name',
          'username',
          'user_identifier',
          'created_at',
          'expires_at',
          'local',
          'revoked',
        ],
      },
    ]);
    if (rows is! List || rows.length > 128) _apiKeyInvalid();
    final keys = rows.map(_apiKeyParse).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (keys.any((k) => k.username != username) ||
        keys.map((k) => k.id).toSet().length != keys.length) {
      _apiKeyInvalid();
    }
    return ApiKeyInventory(
      endpoint: _endpoint,
      username: username,
      userId: user['id'] as int,
      sessionId: session['id'] as String,
      credentialType: credential,
      currentKeyId: currentKey,
      accountEligible:
          user['builtin'] == false &&
          user['locked'] == false &&
          (user['roles'] as List).isNotEmpty,
      stig: security['enable_gpos_stig'] as bool,
      keys: keys,
      accountRoles: List<String>.from(user['roles'] as List)..sort(),
    );
  }

  Future<ApiKeyInventory> load() async {
    _guard();
    if (_calling) throw const ApiKeysException(ApiKeysExceptionReason.busy);
    _calling = true;
    _reviews.clear();
    _inventories.clear();
    try {
      final inventory = await _load();
      _inventories.add(inventory);
      return inventory;
    } on ApiKeysException {
      rethrow;
    } on Object {
      throw const ApiKeysException(ApiKeysExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<ApiKeyReview> review(ApiKeyRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const ApiKeysException(ApiKeysExceptionReason.busy);
    }
    if (!_inventories.contains(request.inventory)) {
      throw const ApiKeysException(ApiKeysExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      throw const ApiKeysException(ApiKeysExceptionReason.invalidRequest);
    }
    _calling = true;
    try {
      final fresh = await _load();
      if (!_apiKeySameInventory(fresh, request.inventory)) {
        throw const ApiKeysException(ApiKeysExceptionReason.staleReview);
      }
      final review = ApiKeyReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'Only keys of ${fresh.username} on $_endpoint are in scope. The current authentication key is protected.',
          'API keys inherit the account privileges. They are password-equivalent credentials; use the least-privileged account and a short expiry.',
          if (request.action != ApiKeyAction.delete &&
              request.expiresAt == null)
            'No expiry was explicitly selected. This credential will remain valid until removed, rotated or server-revoked.',
          if (request.action == ApiKeyAction.create ||
              request.action == ApiKeyAction.rotate)
            'The new key is returned once, never stored by TrueRAID. Reveal only in a private place and record it in a password manager. Losing the response cannot be recovered by retrying.',
          if (request.action == ApiKeyAction.rotate) 'Rotation immediately replaces this key. Update every client that used it; the old value cannot be recovered.',
          if (request.action == ApiKeyAction.edit) 'Name and expiry edits update the database without immediately regenerating PAM authentication configuration in this server version. Expiry edits are not an immediate revocation mechanism. Existing sessions are not terminated.',
          if (request.action == ApiKeyAction.delete) 'Deletion removes this key permanently and blocks future authentication with it. Existing authenticated sessions may continue; this is not a session-termination operation.',
          'The server changes its key database and may regenerate authentication configuration. A failure may follow partial effects. No request is automatically replayed.',
          'Identity is rechecked immediately before dispatch; TrueNAS provides no atomic compare-and-swap protection against concurrent administrators.',
          'A secret-only rotation by another administrator cannot be detected from this safe metadata projection. No key hashes are fetched to compare credential versions.',
        ],
      );
      _reviews.clear();
      _reviews[review] = DateTime.now();
      return review;
    } on ApiKeysException {
      rethrow;
    } on Object {
      throw const ApiKeysException(ApiKeysExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<ApiKeyResult> execute(ApiKeyReview review, String confirmation) async {
    _guard(review.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const ApiKeysException(ApiKeysExceptionReason.busy);
    }
    final issued = _reviews.remove(review);
    if (issued == null ||
        DateTime.now().difference(issued) > const Duration(minutes: 5) ||
        review.endpoint != _endpoint ||
        confirmation != review.target ||
        !_inventories.contains(review.request.inventory)) {
      throw const ApiKeysException(ApiKeysExceptionReason.staleReview);
    }
    final request = review.request;
    if (request.validationError != null) {
      throw const ApiKeysException(ApiKeysExceptionReason.invalidRequest);
    }
    _calling = true;
    var dispatched = false;
    try {
      final fresh = await _load();
      if (!_apiKeySameInventory(fresh, request.inventory) ||
          fresh.blockedReason != null) {
        return const ApiKeyResult(
          ApiKeyOutcome.rejected,
          'Account, credential or key inventory changed. Nothing was sent.',
        );
      }
      if (isOtherMutationBusy()) {
        throw const ApiKeysException(ApiKeysExceptionReason.busy);
      }
      _guard(request.action);
      final method = switch (request.action) {
        ApiKeyAction.create => 'api_key.create',
        ApiKeyAction.edit || ApiKeyAction.rotate => 'api_key.update',
        ApiKeyAction.delete => 'api_key.delete',
      };
      final payload = {
        'name': request.name,
        'expires_at': request.serverExpiry?.toIso8601String(),
      };
      final args = switch (request.action) {
        ApiKeyAction.create => <Object?>[
          {...payload, 'username': fresh.username},
        ],
        ApiKeyAction.edit || ApiKeyAction.rotate => <Object?>[
          request.key!.id,
          {...payload, 'reset': request.action == ApiKeyAction.rotate},
        ],
        ApiKeyAction.delete => <Object?>[request.key!.id],
      };
      dispatched = true;
      final result = await _call(method, args);
      _inventories.clear();
      _reviews.clear();
      if (request.action == ApiKeyAction.delete) {
        if (result != true) return _unknown();
        return const ApiKeyResult(
          ApiKeyOutcome.succeeded,
          'The server confirmed key deletion. Existing sessions were not terminated.',
        );
      }
      final key = _apiKeyParse(result);
      if (key.username != fresh.username ||
          key.userId != fresh.userId ||
          !key.local ||
          key.name != request.name ||
          key.expiresAt != request.serverExpiry ||
          (request.action != ApiKeyAction.create &&
              key.createdAt != request.key!.createdAt) ||
          (request.action == ApiKeyAction.edit &&
              key.revoked != request.key!.revoked) ||
          (request.action != ApiKeyAction.create &&
              key.id != request.key!.id) ||
          (request.action == ApiKeyAction.create &&
              fresh.keys.any((k) => k.id == key.id)) ||
          (request.action != ApiKeyAction.edit && key.revoked)) {
        return _unknown();
      }
      final rawKey = (result as Map)['key'];
      final generated = request.action != ApiKeyAction.edit;
      if (generated &&
              (rawKey is! String ||
                  !RegExp('^${key.id}-[A-Za-z0-9]{64}\$').hasMatch(rawKey)) ||
          !generated && rawKey != null) {
        return _unknown();
      }
      return ApiKeyResult(
        ApiKeyOutcome.succeeded,
        generated
            ? 'The server returned a new key once. Reveal and save it securely before closing.'
            : 'The server confirmed the name and expiry change.',
        secret: generated ? ApiKeyOneTimeSecret(rawKey as String) : null,
      );
    } on Object {
      // Even permission-shaped errors can follow datastore writes and PAM-file
      // regeneration. Every post-dispatch error is uncertain, never retryable.
      if (dispatched) return _unknown();
      return const ApiKeyResult(
        ApiKeyOutcome.rejected,
        'Preflight did not complete safely. No key change was sent.',
      );
    } finally {
      _calling = false;
    }
  }

  ApiKeyResult _unknown() {
    _uncertain = true;
    _reviews.clear();
    _inventories.clear();
    return const ApiKeyResult(
      ApiKeyOutcome.unknown,
      'The key change outcome is unknown. Verify the original server and clients, then reconnect. Do not repeat this request; no secret was retained.',
    );
  }
}

bool _apiKeyId(Object? value) =>
    value is int && value > 0 && value <= 9007199254740991;
bool _apiKeyText(Object? value, int max) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
Never _apiKeyInvalid() =>
    throw const ApiKeysException(ApiKeysExceptionReason.invalidResponse);
DateTime? _apiKeyDate(
  Object? value, {
  bool nullable = false,
  bool naiveUtc = false,
}) {
  if (value == null && nullable) return null;
  if (value is Map && value.length == 1 && value[r'$date'] is int) {
    try {
      return DateTime.fromMillisecondsSinceEpoch(
        value[r'$date'] as int,
        isUtc: true,
      );
    } on Object {
      _apiKeyInvalid();
    }
  }
  if (value is String && value.length <= 64) {
    final match = RegExp(
      r'^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d{1,6})?(Z|[+-]\d\d:\d\d)?$',
    ).firstMatch(value);
    if (match == null || !naiveUtc && match[7] == null) _apiKeyInvalid();
    final parts = List.generate(6, (i) => int.parse(match[i + 1]!));
    final calendar = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    if (calendar.year != parts[0] ||
        calendar.month != parts[1] ||
        calendar.day != parts[2] ||
        calendar.hour != parts[3] ||
        calendar.minute != parts[4] ||
        calendar.second != parts[5]) {
      _apiKeyInvalid();
    }
    final zone = match[7];
    if (zone != null &&
        zone != 'Z' &&
        (int.parse(zone.substring(1, 3)) > 23 ||
            int.parse(zone.substring(4)) > 59)) {
      _apiKeyInvalid();
    }
    final date = DateTime.tryParse(zone == null ? '${value}Z' : value);
    if (date != null && date.isUtc) return date;
  }
  _apiKeyInvalid();
}

ApiKeySnapshot _apiKeyParse(Object? value) {
  if (value is! Map ||
      !value.containsKey('expires_at') ||
      !_apiKeyId(value['id']) ||
      !_apiKeyText(value['name'], 200) ||
      value['username'] != null && !_apiKeyText(value['username'], 128) ||
      !(_apiKeyId(value['user_identifier']) ||
          _apiKeyText(value['user_identifier'], 200)) ||
      value['local'] is! bool ||
      value['revoked'] is! bool) {
    _apiKeyInvalid();
  }
  return ApiKeySnapshot(
    id: value['id'] as int,
    name: value['name'] as String,
    username: value['username'] as String?,
    // do_create returns str(user.id), whereas query's item_extend returns int.
    // Canonical positive numeric owners are the same local identity. Never
    // coerce legacy markers, directory SIDs, zero or noncanonical strings.
    userId: _apiKeyOwner(value['user_identifier'] as Object),
    createdAt: _apiKeyDate(value['created_at'], naiveUtc: true)!,
    expiresAt: _apiKeyDate(value['expires_at'], nullable: true),
    local: value['local'] as bool,
    revoked: value['revoked'] as bool,
  );
}

Object _apiKeyOwner(Object value) {
  if (value is String && RegExp(r'^[1-9][0-9]{0,15}$').hasMatch(value)) {
    final numeric = int.tryParse(value);
    if (_apiKeyId(numeric)) return numeric!;
  }
  return value;
}

bool _apiKeySame(ApiKeySnapshot a, ApiKeySnapshot b) =>
    a.id == b.id &&
    a.name == b.name &&
    a.username == b.username &&
    a.userId == b.userId &&
    a.createdAt == b.createdAt &&
    a.expiresAt == b.expiresAt &&
    a.local == b.local &&
    a.revoked == b.revoked;
bool _apiKeySameInventory(ApiKeyInventory a, ApiKeyInventory b) =>
    a.endpoint == b.endpoint &&
    a.username == b.username &&
    a.userId == b.userId &&
    a.sessionId == b.sessionId &&
    a.credentialType == b.credentialType &&
    a.currentKeyId == b.currentKeyId &&
    a.accountEligible == b.accountEligible &&
    a.stig == b.stig &&
    a.accountRoles.length == b.accountRoles.length &&
    List.generate(
      a.accountRoles.length,
      (i) => a.accountRoles[i] == b.accountRoles[i],
    ).every((v) => v) &&
    a.keys.length == b.keys.length &&
    List.generate(
      a.keys.length,
      (i) => _apiKeySame(a.keys[i], b.keys[i]),
    ).every((v) => v);
