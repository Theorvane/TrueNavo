part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedEmailSettingsSession {
  EmailSettingsCapabilities get emailSettingsCapabilities;
  Future<EmailSettingsInventory> loadEmailSettings();
  Future<EmailSettingsReview> reviewEmailSettings(EmailSettingsRequest request);
  Future<EmailSettingsResult> executeEmailSettings(
    EmailSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
  Future<EmailSettingsResult> checkEmailSettingsJob(
    int jobId, {
    required bool Function() isCurrent,
  });
}

enum EmailSettingsAction { configure, test }

enum EmailSecurity { plain, tls, ssl }

enum EmailPasswordAction { keep, replace, clear }

final class EmailSettingsCapabilities {
  const EmailSettingsCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canConfigure = false,
    this.canTest = false,
  });
  const EmailSettingsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canConfigure = false,
      canTest = false;
  final bool connected, versionSupported, available, canConfigure, canTest;
  bool get supported => connected && versionSupported && available;
  bool supports(EmailSettingsAction action) =>
      supported &&
      (action == EmailSettingsAction.configure ? canConfigure : canTest);
  String? get blockedReason => !connected
      ? 'Connect to inspect SMTP configuration.'
      : !versionSupported
      ? 'Native email settings require stable TrueNAS 25.10.'
      : !available
      ? 'Required public SMTP and readiness reads are unavailable.'
      : null;
}

final class EmailSmtpSettings {
  const EmailSmtpSettings({
    required this.fromEmail,
    this.fromName = '',
    required this.outgoingServer,
    this.port = 587,
    this.security = EmailSecurity.tls,
    this.smtpAuth = true,
    this.username = '',
  });
  final String fromEmail, fromName, outgoingServer, username;
  final int port;
  final EmailSecurity security;
  final bool smtpAuth;
  String? get validationError => !_emailAddress(fromEmail)
      ? 'Use one plain ASCII sender mailbox up to 120 characters.'
      : !_emailText(fromName, 120) || !_emailText(username, 120)
      ? 'Sender name and username must be bounded text without control characters.'
      : outgoingServer.isEmpty ||
            outgoingServer.length > 120 ||
            !_sshHost(outgoingServer)
      ? 'Choose a hostname or unscoped IP address up to 120 characters, without a URL or port.'
      : port < 1 || port > 65535
      ? 'Choose an SMTP port from 1 to 65535.'
      : security == EmailSecurity.plain
      ? 'This app does not configure or test unencrypted PLAIN SMTP.'
      : smtpAuth && username.isEmpty
      ? 'SMTP authentication requires an explicit username.'
      : null;
}

final class EmailConfigSnapshot {
  const EmailConfigSnapshot({
    required this.id,
    required this.settings,
    required this.passwordPresent,
    required this.oauthPresent,
  });
  final int id;
  final EmailSmtpSettings settings;
  final bool? passwordPresent;
  final bool oauthPresent;
  bool get passwordKnown => passwordPresent != null;
}

final class EmailPasswordChange {
  const EmailPasswordChange.keep()
    : action = EmailPasswordAction.keep,
      _bytes = null,
      _valid = true;
  const EmailPasswordChange.clear()
    : action = EmailPasswordAction.clear,
      _bytes = null,
      _valid = true;
  factory EmailPasswordChange.replace(String value) {
    final valid =
        value.isNotEmpty &&
        value.length <= 1024 &&
        value.codeUnits.every((v) => v >= 32 && v <= 126);
    return EmailPasswordChange._(
      valid ? Uint8List.fromList(value.codeUnits) : Uint8List(0),
      valid,
    );
  }
  EmailPasswordChange._(this._bytes, this._valid)
    : action = EmailPasswordAction.replace;
  final EmailPasswordAction action;
  final Uint8List? _bytes;
  final bool _valid;
  // Zeroing bytes also represents disposal without mutable public metadata.
  bool get isDisposed =>
      action == EmailPasswordAction.replace &&
      (_bytes!.isEmpty || _bytes!.first == 0);
  String? get validationError =>
      action == EmailPasswordAction.replace && (!_valid || isDisposed)
      ? 'Enter a fresh password of 1–1024 printable ASCII characters; no controls or non-ASCII characters.'
      : null;
  void dispose() {
    final bytes = _bytes;
    if (bytes != null) bytes.fillRange(0, bytes.length, 0);
  }

  @override
  String toString() => 'EmailPasswordChange(${action.name})';
}

final class EmailSettingsInventory {
  EmailSettingsInventory({
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
    required this.config,
    List<String> rebootReasonCodes = const [],
  }) : environments = List.unmodifiable(environments),
       rebootReasonCodes = List.unmodifiable(rebootReasonCodes);
  final String endpoint, hostId, bootId, currentVersion, state, bootPool;
  final bool fullAdmin, failoverLicensed, conflictingJob, bootHealthy;
  final List<BootEnvironmentSnapshot> environments;
  final List<String> rebootReasonCodes;
  final EmailConfigSnapshot config;
  BootEnvironmentSnapshot? get currentEnvironment =>
      environments.where((e) => e.active).singleOrNull;
  BootEnvironmentSnapshot? get nextEnvironment =>
      environments.where((e) => e.activated).singleOrNull;
  String? get readinessBlockedReason => !fullAdmin
      ? 'This app requires FULL_ADMIN for SMTP changes and tests.'
      : failoverLicensed
      ? 'HA mail changes require the coordinated TrueNAS workflow.'
      : state != 'READY'
      ? 'The original server must report READY.'
      : conflictingJob
      ? 'A visible active or waiting job prevents a new email operation.'
      : !bootHealthy
      ? 'The boot pool must be healthy, online and not scanning.'
      : currentEnvironment == null ||
            nextEnvironment == null ||
            !currentEnvironment!.canActivate ||
            currentEnvironment!.id != nextEnvironment!.id
      ? 'An unchanged bootable current and next boot environment is required.'
      : null;
  String? get blockedReason =>
      readinessBlockedReason ??
      (config.oauthPresent
          ? 'OAuth configuration is present or unprovable. This SMTP-only workflow cannot alter, clear or test it.'
          : !config.passwordKnown
          ? 'Stored password presence is redacted or unprovable. Use the specialized TrueNAS workflow.'
          : null);
  String? get testBlockedReason =>
      blockedReason ??
      config.settings.validationError ??
      (config.settings.smtpAuth && config.passwordPresent != true
          ? 'Saved SMTP authentication requires a known nonempty password.'
          : null);
}

final class EmailSettingsRequest {
  const EmailSettingsRequest({
    required this.inventory,
    required this.action,
    this.settings,
    this.password = const EmailPasswordChange.keep(),
    this.recipient,
  });
  final EmailSettingsInventory inventory;
  final EmailSettingsAction action;
  final EmailSmtpSettings? settings;
  final EmailPasswordChange password;
  final String? recipient;
  String get target => action == EmailSettingsAction.configure
      ? 'EMAIL CONFIG ${inventory.hostId} ${settings?.outgoingServer ?? ""}:${settings?.port ?? ""}'
      : 'SEND EMAIL ${inventory.hostId} ${recipient ?? ""}';
  String? get validationError {
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (action == EmailSettingsAction.test) {
      return inventory.testBlockedReason ??
          (settings != null ||
                  password.action != EmailPasswordAction.keep ||
                  recipient == null ||
                  !_emailAddress(recipient!)
              ? 'Test uses saved configuration only and exactly one explicit ASCII recipient.'
              : null);
    }
    if (recipient != null || settings == null) {
      return 'Choose SMTP settings separately from a test recipient.';
    }
    if (settings!.validationError != null) return settings!.validationError;
    if (password.validationError != null) return password.validationError;
    if (settings!.smtpAuth &&
        (password.action == EmailPasswordAction.clear ||
            password.action == EmailPasswordAction.keep &&
                inventory.config.passwordPresent != true)) {
      return 'Authentication requires an existing kept password or an explicit replacement.';
    }
    if (!settings!.smtpAuth &&
        (password.action == EmailPasswordAction.replace ||
            inventory.config.passwordPresent == true &&
                password.action != EmailPasswordAction.clear)) {
      return 'Disabling authentication with a stored password requires explicit Clear; no secret is erased implicitly.';
    }
    if (_emailSettingsProof(settings!) ==
            _emailSettingsProof(inventory.config.settings) &&
        password.action == EmailPasswordAction.keep) {
      return 'Choose changed settings or an explicit password replacement/clear.';
    }
    return null;
  }
}

final class EmailSettingsReview {
  EmailSettingsReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final EmailSettingsRequest request;
  final String endpoint;
  final List<String> warnings;
  EmailSettingsAction get action => request.action;
  String get target => request.target;
}

enum EmailSettingsOutcome { pending, completed, rejected, unknown }

final class EmailSettingsResult {
  const EmailSettingsResult(this.outcome, this.message, {this.jobId});
  final EmailSettingsOutcome outcome;
  final String message;
  final int? jobId;
}

enum EmailSettingsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class EmailSettingsException implements Exception {
  const EmailSettingsException(this.reason);
  final EmailSettingsExceptionReason reason;
  String get userMessage => switch (reason) {
    EmailSettingsExceptionReason.notAuthenticated =>
      'Connect again before managing SMTP settings.',
    EmailSettingsExceptionReason.unsupportedVersion =>
      'Native email settings require stable TrueNAS 25.10.',
    EmailSettingsExceptionReason.unavailableMethod =>
      'Required public email methods are unavailable.',
    EmailSettingsExceptionReason.busy => 'Another operation is active or an uncertain email operation requires independent inspection.',
    EmailSettingsExceptionReason.staleReview => 'The issued review, secret capsule, connection or authorization changed. No new email request was submitted.',
    EmailSettingsExceptionReason.invalidRequest => 'Choose supported SMTP settings, explicit password intent and a valid single recipient for tests.',
    EmailSettingsExceptionReason.invalidResponse =>
      'Email configuration could not be safely verified.',
    EmailSettingsExceptionReason.unavailable => 'Email information is unavailable. Remote and secret details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _emailReads = {..._powerReads, 'auth.me', 'mail.config'};

final class _EmailRead {
  const _EmailRead(
    this.inventory,
    this.secretHash,
    this.oauthForm,
    this.userNull,
  );
  final EmailSettingsInventory inventory;
  final String secretHash, oauthForm;
  final bool userNull;
}

final class _EmailLease {
  const _EmailLease(this.created, this.proof, this.passwordProof);
  final DateTime created;
  final String proof, passwordProof;
}

final class _EmailJob {
  const _EmailJob(this.id, this.proof);
  final int id;
  final String proof;
}

final class _SessionEmailSettings {
  _SessionEmailSettings({
    required this.client,
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
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _version;
  final String _endpoint;
  final Map _metadata;
  final DateTime Function() _now;
  late final _SessionSystemPower _powerReader;
  final Uint8List _proofKey = Uint8List.fromList(
    List.generate(32, (_) => math.Random.secure().nextInt(256)),
  );
  final Map<EmailSettingsInventory, String> _inventories = {};
  final Map<EmailSettingsReview, _EmailLease> _reviews = {};
  final Set<EmailPasswordChange> _passwords = {};
  bool _calling = false, _terminal = false;
  bool Function()? _operationCurrent;
  _EmailJob? _job;
  bool get isBusy => _calling || _terminal || _job != null;
  bool _current() {
    try {
      return isCurrent() && (_operationCurrent?.call() ?? true);
    } on Object {
      return false;
    }
  }

  bool _method(String name, {bool send = false}) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == send &&
        row['uploadable'] == send &&
        row['downloadable'] == false &&
        row['no_auth_required'] == false &&
        row['private'] != true &&
        row['_private'] != true &&
        (send
            ? row['check_pipes'] == false
            : (row['check_pipes'] == null ||
                  row['check_pipes'] == false ||
                  row['check_pipes'] is List &&
                      (row['check_pipes'] as List).isEmpty));
  }

  EmailSettingsCapabilities get capabilities => EmailSettingsCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: _emailReads.every((name) => _method(name)),
    canConfigure: _method('mail.update'),
    canTest: _method('mail.send', send: true),
  );
  void _guard([EmailSettingsAction? action]) {
    if (!isCurrent()) {
      _emailThrow(EmailSettingsExceptionReason.notAuthenticated);
    }
    if (!_current()) _emailThrow(EmailSettingsExceptionReason.staleReview);
    if (!_version) _emailThrow(EmailSettingsExceptionReason.unsupportedVersion);
    if (!capabilities.supported ||
        action != null && !capabilities.supports(action)) {
      _emailThrow(EmailSettingsExceptionReason.unavailableMethod);
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

  String _hash(String value) {
    final bytes = utf8.encode(value);
    try {
      return crypto.Hmac(crypto.sha256, _proofKey).convert(bytes).toString();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  (EmailConfigSnapshot, String, String, bool) _project(Object? raw) {
    if (raw is! Map ||
        !_powerId(raw['id']) ||
        !raw.containsKey('pass') ||
        !raw.containsKey('oauth') ||
        !_emailText(raw['fromemail'], 120) ||
        !_emailText(raw['fromname'], 120) ||
        !_emailText(raw['outgoingserver'], 120) ||
        raw['port'] is! int ||
        raw['port'] < 0 ||
        raw['port'] > 65535 ||
        !const ['PLAIN', 'TLS', 'SSL'].contains(raw['security']) ||
        raw['smtp'] is! bool ||
        raw['user'] != null && !_emailText(raw['user'], 120)) {
      _emailThrow(EmailSettingsExceptionReason.invalidResponse);
    }
    final settings = EmailSmtpSettings(
      fromEmail: raw['fromemail'] as String,
      fromName: raw['fromname'] as String,
      outgoingServer: raw['outgoingserver'] as String,
      port: raw['port'] as int,
      security: switch (raw['security']) {
        'TLS' => EmailSecurity.tls,
        'SSL' => EmailSecurity.ssl,
        _ => EmailSecurity.plain,
      },
      smtpAuth: raw['smtp'] as bool,
      username: raw['user'] as String? ?? '',
    );
    final pass = raw['pass'];
    final known =
        pass == null ||
        pass is String &&
            pass.length <= 1024 &&
            pass.codeUnits.every((v) => v >= 32 && v <= 126) &&
            !RegExp(r'^\*{3,}$').hasMatch(pass) &&
            !const [
              '<redacted>',
              '[redacted]',
              '**********',
            ].contains(pass.toLowerCase());
    final oauth = raw['oauth'];
    final oauthForm = oauth == null
        ? 'null'
        : oauth is Map && oauth.isEmpty
        ? 'empty'
        : 'present';
    return (
      EmailConfigSnapshot(
        id: raw['id'] as int,
        settings: settings,
        passwordPresent: known ? (pass is String && pass.isNotEmpty) : null,
        oauthPresent: oauthForm == 'present',
      ),
      known ? _hash(pass == null ? 'null' : 'string:$pass') : 'unknown',
      oauthForm,
      raw['user'] == null,
    );
  }

  Future<_EmailRead> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const []));
    final power = await _powerReader._read();
    final config = _project(await _call('mail.config', const []));
    final finalAdmin = _configurationBackupAdmin(
      await _call('auth.me', const []),
    );
    final host = await _call('system.host_id', const []),
        reboot = _powerReboot(await _call('system.reboot.info', const []));
    final state = await _call('system.state', const []);
    if (admin != finalAdmin ||
        host != power.hostId ||
        reboot.$1 != power.bootId ||
        state != power.state ||
        jsonEncode(reboot.$2) != jsonEncode(power.rebootReasonCodes)) {
      _emailThrow(EmailSettingsExceptionReason.staleReview);
    }
    return _EmailRead(
      EmailSettingsInventory(
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
        config: config.$1,
      ),
      config.$2,
      config.$3,
      config.$4,
    );
  }

  void _clearReviews() {
    for (final p in _passwords) {
      p.dispose();
    }
    _passwords.clear();
    _reviews.clear();
    _inventories.clear();
  }

  void dispose() {
    _clearReviews();
    _proofKey.fillRange(0, _proofKey.length, 0);
    _terminal = true;
  }

  Future<EmailSettingsInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _emailThrow(EmailSettingsExceptionReason.busy);
    }
    _calling = true;
    _clearReviews();
    try {
      final read = await _read();
      if (isOtherMutationBusy()) _emailThrow(EmailSettingsExceptionReason.busy);
      _inventories[read.inventory] = _emailProof(read);
      return read.inventory;
    } on EmailSettingsException {
      rethrow;
    } on Object {
      _emailThrow(EmailSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  String _passwordProof(EmailPasswordChange p) =>
      p.action == EmailPasswordAction.replace
      ? _hash(
          'replacement:${p.validationError == null ? ascii.decode(p._bytes!) : "disposed"}',
        )
      : p.action.name;
  Future<EmailSettingsReview> review(EmailSettingsRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      _emailThrow(EmailSettingsExceptionReason.busy);
    }
    final proof = _inventories[request.inventory];
    if (proof == null || request.inventory.endpoint != _endpoint) {
      _emailThrow(EmailSettingsExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      _emailThrow(EmailSettingsExceptionReason.invalidRequest);
    }
    _calling = true;
    // A new review invalidates earlier secrets but may reuse this same capsule.
    for (final p in _passwords) {
      if (!identical(p, request.password)) p.dispose();
    }
    _passwords
      ..clear()
      ..add(request.password);
    _reviews.clear();
    try {
      final fresh = await _read();
      if (_emailProof(fresh) != proof ||
          fresh.inventory.blockedReason != null ||
          request.validationError != null ||
          isOtherMutationBusy()) {
        _emailThrow(EmailSettingsExceptionReason.staleReview);
      }
      final review = EmailSettingsReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          if (request.action == EmailSettingsAction.configure)
            'This writes SMTP configuration only; review does not send mail and saving does not itself perform an SMTP test. TrueNAS commits the database before Gmail initialization and alert cleanup, so a later failure does not prove rollback. Keep omits the password, Replace sends only the newly entered secret, and Clear explicitly removes it. Disabling authentication with a stored password requires Clear.'
          else
            'This sends one fixed plain-text test message to the exact entered recipient using the saved configuration only. Sender, recipient, NAS product/hostname/domain, Message-ID and connection metadata can leave the NAS. TrueNAS prefixes its product and hostname/domain to the subject and uses its system hostname in the SMTP EHLO exchange. Explicitly authorize this external transmission; it cannot be recalled.',
          'TLS/SSL select encrypted SMTP modes, not a verified SMTP identity guarantee. The pinned TrueNAS implementation uses default Python SMTP TLS contexts and does not configure certificate/hostname verification. An untrusted endpoint or network can expose credentials and message contents. Independently verify and accept the SMTP destination risk. TrueNavo API certificate pinning is separate and does not secure this server-to-SMTP connection.',
          'Existing failed mail can already be queued on TrueNAS and later retried using the current settings and sender. This app cannot inspect or cancel that queue. queue:false prevents queuing only this test; it does not cancel earlier queued messages or stop other mail activity.',
          'OAuth must be absent (null or an exact empty object) for this SMTP workflow; its existing representation is preserved by omission. Nonempty or unprovable OAuth is display-only. No provider enrollment, token access, OAuth clearing, arbitrary message, override configuration, attachment, extra header, CC or recipient fallback is exposed.',
          'A saved configuration match is not proof of connectivity, password usability or mail delivery. A test job ID is acceptance only; only an explicit owned-job read showing SUCCESS with result true reports server-side success, never recipient delivery. False, failure, missing jobs, timeout and ambiguous results remain unknown with no automatic polling, retry or resend.',
          'Identity, FULL_ADMIN, READY standalone state, visible job idleness and a healthy unchanged boot environment are conservative public app checks, not an atomic guarantee against other administrators or background mail activity.',
        ],
      );
      _reviews[review] = _EmailLease(
        _now(),
        proof,
        _passwordProof(request.password),
      );
      return review;
    } on EmailSettingsException {
      rethrow;
    } on Object {
      _emailThrow(EmailSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<EmailSettingsResult> execute(
    EmailSettingsReview review,
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

    bool ageValid() {
      if (lease == null) return false;
      final age = _now().difference(lease.created);
      return !age.isNegative && age <= const Duration(minutes: 5);
    }

    try {
      _guard(review.action);
      if (isBusy || isOtherMutationBusy()) {
        _emailThrow(EmailSettingsExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !ageValid() ||
          confirmation != review.target ||
          review.endpoint != _endpoint ||
          review.request.validationError != null ||
          lease.passwordProof != _passwordProof(review.request.password)) {
        _emailThrow(EmailSettingsExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = isCurrent;
      final before = await _read();
      if (_emailProof(before) != lease.proof ||
          before.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        _emailThrow(EmailSettingsExceptionReason.staleReview);
      }
      _guard(review.action);
      if (!ageValid() ||
          review.request.validationError != null ||
          lease.passwordProof != _passwordProof(review.request.password)) {
        _emailThrow(EmailSettingsExceptionReason.staleReview);
      }
      final params = _emailParams(review.request);
      sent = true;
      if (review.action == EmailSettingsAction.test) {
        final id = await client
            .call('mail.send', id: nextId(), params: params)
            .timeout(requestTimeout);
        if (!_powerId(id)) return _unknown();
        _job = _EmailJob(id as int, _emailProof(before, ignoreJobs: true));
        _guard(review.action);
        _clearReviews();
        return _pendingResult();
      }
      final receipt = _project(
        await client
            .call('mail.update', id: nextId(), params: params)
            .timeout(requestTimeout),
      );
      _guard(review.action);
      final expectedHash = switch (review.request.password.action) {
        EmailPasswordAction.keep => before.secretHash,
        EmailPasswordAction.clear => _hash('null'),
        EmailPasswordAction.replace => _hash(
          'string:${ascii.decode(review.request.password._bytes!)}',
        ),
      };
      final expectedUserNull =
          review.request.settings!.username ==
              before.inventory.config.settings.username
          ? before.userNull
          : false;
      if (!_emailConfigMatches(review.request, receipt.$1) ||
          receipt.$2 != expectedHash ||
          receipt.$3 != before.oauthForm ||
          receipt.$4 != expectedUserNull) {
        return _unknown();
      }
      final after = await _read();
      if (_emailBaseProof(before.inventory) !=
              _emailBaseProof(after.inventory) ||
          !_emailConfigMatches(review.request, after.inventory.config) ||
          after.secretHash != expectedHash ||
          after.oauthForm != before.oauthForm ||
          after.userNull != expectedUserNull ||
          after.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        return _unknown();
      }
      _clearReviews();
      return const EmailSettingsResult(
        EmailSettingsOutcome.completed,
        'The SMTP configuration and private credential readback matched. No test message was sent by this operation; connectivity, password usability and delivery remain unverified. Existing queued mail can use the changed configuration.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return EmailSettingsResult(
        EmailSettingsOutcome.rejected,
        error is EmailSettingsException ? error.userMessage : 'Email preflight failed or authorization expired. No new email request was submitted.',
      );
    } finally {
      review.request.password.dispose();
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  Future<EmailSettingsResult> check(
    int jobId, {
    required bool Function() isCurrent,
  }) async {
    final owned = _job;
    if (owned == null || owned.id != jobId || _terminal || _calling) {
      return const EmailSettingsResult(
        EmailSettingsOutcome.rejected,
        'Only this session\'s outstanding test job can be checked. No job request was made.',
      );
    }
    _calling = true;
    _operationCurrent = isCurrent;
    try {
      _guard(EmailSettingsAction.test);
      final fresh = await _read();
      if (_emailProof(fresh, ignoreJobs: true) != owned.proof ||
          isOtherMutationBusy()) {
        return _unknown();
      }
      final rows = await _call('core.get_jobs', [
        [
          ['id', '=', jobId],
        ],
        {
          'limit': 2,
          'select': ['id', 'method', 'state', 'result'],
        },
      ]);
      if (rows is! List || rows.length != 1) return _unknown();
      final row = rows.single;
      if (row is! Map || row['id'] != jobId || row['method'] != 'mail.send') {
        return _unknown();
      }
      switch (row['state']) {
        case 'WAITING':
        case 'RUNNING':
          return _pendingResult();
        case 'SUCCESS':
          if (row['result'] != true) return _unknown();
          _job = null;
          _clearReviews();
          return EmailSettingsResult(
            EmailSettingsOutcome.completed,
            'TrueNAS reports that this test job completed with result true. This is server-side success only, not confirmation that the recipient received or read the message.',
            jobId: jobId,
          );
        default:
          return _unknown();
      }
    } on Object {
      return _unknown();
    } finally {
      _operationCurrent = null;
      _calling = false;
    }
  }

  EmailSettingsResult _pendingResult() => EmailSettingsResult(
    EmailSettingsOutcome.pending,
    'TrueNAS accepted this explicit test job; delivery is unverified. The app will not poll or resend. You may explicitly check this owned job once at a time.',
    jobId: _job!.id,
  );
  EmailSettingsResult _unknown() {
    _terminal = true;
    _clearReviews();
    return EmailSettingsResult(
      EmailSettingsOutcome.unknown,
      'An SMTP configuration change or test transmission may already have occurred. Its outcome is unverified, not rollback or permission to resend. Further writes are fenced; inspect the original server independently.',
      jobId: _job?.id,
    );
  }
}

Never _emailThrow(EmailSettingsExceptionReason reason) =>
    throw EmailSettingsException(reason);
bool _emailText(Object? value, int max) =>
    value is String &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
bool _emailAddress(String value) {
  if (value.length > 120 || value.contains('..')) return false;
  final parts = value.split('@');
  if (parts.length != 2 || parts.first.isEmpty || parts.first.length > 64) {
    return false;
  }
  return RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9._%+-]*[A-Za-z0-9])?$')
              .stringMatch(parts.first) ==
          parts.first &&
      !parts.last.contains(':') &&
      _sshHost(parts.last) &&
      parts.last.contains('.');
}

Map<String, Object?> _emailSettingsMap(EmailSmtpSettings s) => {
  'fromemail': s.fromEmail,
  'fromname': s.fromName,
  'outgoingserver': s.outgoingServer,
  'port': s.port,
  'security': s.security.name.toUpperCase(),
  'smtp': s.smtpAuth,
  'user': s.username,
};
String _emailSettingsProof(EmailSmtpSettings s) =>
    jsonEncode(_emailSettingsMap(s));
String _emailBaseProof(EmailSettingsInventory i, {bool ignoreJobs = false}) =>
    jsonEncode([
      i.endpoint,
      i.hostId,
      i.bootId,
      i.currentVersion,
      i.state,
      i.fullAdmin,
      i.failoverLicensed,
      if (!ignoreJobs) i.conflictingJob,
      i.bootPool,
      i.bootHealthy,
      i.rebootReasonCodes,
      for (final e in i.environments)
        [
          e.id,
          e.dataset,
          e.created,
          e.active,
          e.activated,
          e.keep,
          e.canActivate,
        ],
    ]);
String _emailProof(_EmailRead r, {bool ignoreJobs = false}) => jsonEncode([
  _emailBaseProof(r.inventory, ignoreJobs: ignoreJobs),
  r.inventory.config.id,
  _emailSettingsProof(r.inventory.config.settings),
  r.inventory.config.passwordPresent,
  r.inventory.config.oauthPresent,
  r.secretHash,
  r.oauthForm,
  r.userNull,
]);
bool _emailConfigMatches(EmailSettingsRequest r, EmailConfigSnapshot c) =>
    c.id == r.inventory.config.id &&
    !c.oauthPresent &&
    c.passwordKnown &&
    _emailSettingsProof(c.settings) == _emailSettingsProof(r.settings!);
List<Object?> _emailParams(EmailSettingsRequest r) {
  if (r.action == EmailSettingsAction.test) {
    return [
      {
        'subject': 'TrueNavo SMTP configuration test',
        'text': 'This is an explicitly requested TrueNavo SMTP test. No delivery or recovery guarantee is implied.',
        'html': null,
        'to': [r.recipient!],
        'cc': <String>[],
        'interval': 0,
        'timeout': 30,
        'attachments': false,
        'queue': false,
        'extra_headers': <String, Object?>{},
      },
      <String, Object?>{},
    ];
  }
  final previous = _emailSettingsMap(r.inventory.config.settings);
  return [
    {
      for (final entry in _emailSettingsMap(r.settings!).entries)
        if (entry.value != previous[entry.key]) entry.key: entry.value,
      if (r.password.action == EmailPasswordAction.clear) 'pass': null,
      if (r.password.action == EmailPasswordAction.replace)
        'pass': ascii.decode(r.password._bytes!),
    },
  ];
}
