import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

// Independent in-memory RPC fixture. No network, files, credentials or SMTP.
const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _secret = 'SYNTHETIC_ONLY_PRIVATE_PASSWORD';
const _mutations = {'mail.update', 'mail.send'};
const _forbidden = {
  'mail.send_raw',
  'mail.send_mail_queue',
  'mail.local_administrator_email',
  'mail.local_administrators_emails',
  'mail.gmail_initialize',
  'mail.gmail_send',
  'mail.outlook_xoauth2',
  'core.job_abort',
};
const _methods = {
  'system.version_short',
  'system.host_id',
  'system.reboot.info',
  'system.state',
  'failover.licensed',
  'boot.get_state',
  'boot.environment.query',
  'core.get_jobs',
  'auth.me',
  'mail.config',
  ..._mutations,
  ..._forbidden,
  'config.reset',
  'system.reboot',
  'system.shutdown',
  'config.save',
  'core.download',
  'config.upload',
  'auth.generate_token',
  'system.general.config',
  'system.general.timezone_choices',
  'system.general.checkin_waiting',
  'system.general.update',
  'system.ntpserver.query',
  'system.ntpserver.create',
  'system.ntpserver.update',
  'system.ntpserver.delete',
  'service.control',
};

void main() {
  for (final method in ['mail.config', 'mail.update', 'mail.send']) {
    test('generic $method cannot bypass the native secret boundary', () async {
      final h = await _connected();
      final spec = h.repo.adminCatalog.method(method);
      expect(spec?.supported ?? false, isFalse);
      final before = h.wire.calls.length;
      if (spec != null) {
        await expectLater(
          h.repo.invokeAdmin(AdminRequest(method: spec, arguments: const [])),
          throwsA(isA<AdminException>()),
        );
      }
      await expectLater(
        h.repo.query(method),
        throwsA(isA<SessionQueryException>()),
      );
      expect(h.wire.calls.length, before);
    });
  }
  for (final flags in [
    {'job': false},
    {'uploadable': false},
    {'downloadable': true},
    {'check_pipes': true},
    {'check_pipes': <Object?>[]},
    {'check_pipes': null},
    {'no_auth_required': true},
    {'private': true},
  ]) {
    test('send metadata $flags cannot authorize a test', () async {
      final h = await _connected(configure: (w) => w.sendFlags.addAll(flags));
      expect(h.repo.emailSettingsCapabilities.canConfigure, isTrue);
      expect(h.repo.emailSettingsCapabilities.canTest, isFalse);
      final inventory = await h.repo.loadEmailSettings();
      final before = h.wire.calls.length;
      await expectLater(
        h.repo.reviewEmailSettings(
          EmailSettingsRequest(
            inventory: inventory,
            action: EmailSettingsAction.test,
            recipient: 'recipient@example.org',
          ),
        ),
        throwsA(isA<EmailSettingsException>()),
      );
      expect(h.wire.calls.length, before);
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final address in [
    'smtp.example.org\n',
    'smtp.example.org\r\nX-Evil: x',
    'smtp.example.org:587',
    'https://smtp.example.org',
    'user@smtp.example.org',
    'smtp.example.org/path',
    'smtp.example.org extra',
    'smtp.example.org\t',
    '[2001:db8::1]',
    'fe80::1%eth0',
  ]) {
    test(
      'invalid SMTP host is rejected before review RPC: ${jsonEncode(address)}',
      () async {
        final h = await _connected();
        final inventory = await h.repo.loadEmailSettings();
        final settings = _settings(host: address);
        expect(settings.validationError, isNotNull);
        final before = h.wire.calls.length;
        await expectLater(
          h.repo.reviewEmailSettings(
            EmailSettingsRequest(
              inventory: inventory,
              action: EmailSettingsAction.configure,
              settings: settings,
            ),
          ),
          throwsA(isA<EmailSettingsException>()),
        );
        expect(h.wire.calls.length, before);
      },
    );
  }
  for (final invalid in [
    _settings(from: 'sender@example.org\nBcc: victim@example.org'),
    _settings(name: 'NAS\r\nReply-To: victim@example.org'),
    _settings(username: 'user\u0000other'),
    _settings(port: 0),
    _settings(port: 65536),
    _settings(security: EmailSecurity.plain),
  ]) {
    test('control/header/port/plain rejection is local', () async {
      final h = await _connected();
      final inventory = await h.repo.loadEmailSettings();
      final before = h.wire.calls.length;
      expect(invalid.validationError, isNotNull);
      await expectLater(
        h.repo.reviewEmailSettings(
          EmailSettingsRequest(
            inventory: inventory,
            action: EmailSettingsAction.configure,
            settings: invalid,
          ),
        ),
        throwsA(isA<EmailSettingsException>()),
      );
      expect(h.wire.calls.length, before);
    });
  }
  for (final recipient in [
    '',
    'first@example.org,second@example.org',
    'Name <recipient@example.org>',
    'recipient@example.org\n',
    'recipient@example.org\r\nBcc:other@example.org',
    'recipient@localhost',
  ]) {
    test('test recipient never falls back or injects a header', () async {
      final h = await _connected();
      final inventory = await h.repo.loadEmailSettings();
      final before = h.wire.calls.length;
      await expectLater(
        h.repo.reviewEmailSettings(
          EmailSettingsRequest(
            inventory: inventory,
            action: EmailSettingsAction.test,
            recipient: recipient,
          ),
        ),
        throwsA(isA<EmailSettingsException>()),
      );
      expect(h.wire.calls.length, before);
      _noPrivateCalls(h.wire);
    });
  }
  for (final value in [
    '',
    'bad\nsecret',
    'bad\u0000secret',
    '비밀',
    'x' * 1025,
  ]) {
    test('invalid replacement secret is rejected and never echoed', () async {
      final h = await _connected();
      final inventory = await h.repo.loadEmailSettings();
      final password = EmailPasswordChange.replace(value);
      addTearDown(password.dispose);
      expect(password.validationError, isNotNull);
      expect(password.toString(), 'EmailPasswordChange(replace)');
      final before = h.wire.calls.length;
      await expectLater(
        h.repo.reviewEmailSettings(
          EmailSettingsRequest(
            inventory: inventory,
            action: EmailSettingsAction.configure,
            settings: _settings(),
            password: password,
          ),
        ),
        throwsA(isA<EmailSettingsException>()),
      );
      expect(h.wire.calls.length, before);
    });
  }
  for (final oauth in [
    {'provider': 'gmail', 'client_secret': _secret, 'refresh_token': _secret},
    {'provider': 'outlook', 'refresh_token': _secret},
    {'unexpected': _secret},
    '<redacted>',
    false,
    <Object?>[],
  ]) {
    test('nonempty or malformed OAuth is display-only with no send', () async {
      final h = await _connected(configure: (w) => w.config['oauth'] = oauth);
      final inventory = await h.repo.loadEmailSettings();
      expect(inventory.config.oauthPresent, isTrue);
      expect(inventory.blockedReason, isNotNull);
      final before = h.wire.calls.length;
      await expectLater(
        h.repo.reviewEmailSettings(
          EmailSettingsRequest(
            inventory: inventory,
            action: EmailSettingsAction.configure,
            settings: _settings(),
          ),
        ),
        throwsA(isA<EmailSettingsException>()),
      );
      expect(h.wire.calls.length, before);
      expect(
        '${inventory.config}${inventory.blockedReason}',
        isNot(contains(_secret)),
      );
      _noPrivateCalls(h.wire);
    });
  }
  for (final password in [
    '********',
    '<redacted>',
    '[redacted]',
    {'secret': _secret},
  ]) {
    test(
      'redacted password presence does not authorize preservation',
      () async {
        final h = await _connected(
          configure: (w) => w.config['pass'] = password,
        );
        final inventory = await h.repo.loadEmailSettings();
        expect(inventory.config.passwordPresent, isNull);
        expect(inventory.blockedReason, isNotNull);
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  test(
    'read-only projection never acquires SMTP or OAuth credentials publicly',
    () async {
      final h = await _connected(configure: (w) => w.admin = false);
      final inventory = await h.repo.loadEmailSettings();
      expect(inventory.fullAdmin, isFalse);
      expect(inventory.config.passwordPresent, isTrue);
      expect(inventory.blockedReason, contains('FULL_ADMIN'));
      expect(
        '${inventory.config}${inventory.config.settings}$inventory',
        isNot(contains(_secret)),
      );
      final before = h.wire.calls.length;
      await expectLater(
        h.repo.reviewEmailSettings(
          EmailSettingsRequest(
            inventory: inventory,
            action: EmailSettingsAction.test,
            recipient: 'recipient@example.org',
          ),
        ),
        throwsA(isA<EmailSettingsException>()),
      );
      expect(h.wire.calls.length, before);
      expect(h.wire.writes, isEmpty);
      _noPrivateCalls(h.wire);
    },
  );
  for (final oauth in [null, <String, Object?>{}]) {
    test(
      'Keep preserves absent OAuth shape and password by omission',
      () async {
        final h = await _connected(configure: (w) => w.config['oauth'] = oauth);
        final review = await _review(h);
        expect(review.request.inventory.config.oauthPresent, isFalse);
        expect(review.warnings.join(' '), isNot(contains(_secret)));
        expect(review.warnings.join(' '), contains('queued'));
        final result = await h.repo.executeEmailSettings(
          review,
          review.target,
          isCurrent: () => true,
        );
        expect(result.outcome, EmailSettingsOutcome.completed);
        final update = (h.wire.writes.single['params'] as List).single as Map;
        expect(update, {'outgoingserver': 'new.example.org'});
        expect(update.containsKey('pass'), isFalse);
        expect(update.containsKey('oauth'), isFalse);
        expect(h.wire.config['pass'], _secret);
        expect(h.wire.config['oauth'], oauth);
        expect(result.message, isNot(contains(_secret)));
        _noPrivateCalls(h.wire);
      },
    );
  }
  test(
    'Replace sends only the new secret and disposes capsule after completion',
    () async {
      final h = await _connected();
      final password = EmailPasswordChange.replace('SYNTHETIC_NEW_PASSWORD');
      final review = await _review(h, password: password);
      expect(
        review.warnings.join(' '),
        isNot(contains('SYNTHETIC_NEW_PASSWORD')),
      );
      final result = await h.repo.executeEmailSettings(
        review,
        review.target,
        isCurrent: () => true,
      );
      expect(result.outcome, EmailSettingsOutcome.completed);
      expect(
        (h.wire.writes.single['params'] as List).single,
        containsPair('pass', 'SYNTHETIC_NEW_PASSWORD'),
      );
      expect(password.isDisposed, isTrue);
      expect(result.message, isNot(contains('SYNTHETIC_NEW_PASSWORD')));
      expect(h.wire.calls.where((c) => c['method'] == 'mail.send'), isEmpty);
    },
  );
  test(
    'disabling authentication requires deliberate Clear and only null password',
    () async {
      final h = await _connected();
      final inventory = await h.repo.loadEmailSettings();
      final disabled = _settings(auth: false);
      expect(
        EmailSettingsRequest(
          inventory: inventory,
          action: EmailSettingsAction.configure,
          settings: disabled,
        ).validationError,
        isNotNull,
      );
      final review = await h.repo.reviewEmailSettings(
        EmailSettingsRequest(
          inventory: inventory,
          action: EmailSettingsAction.configure,
          settings: disabled,
          password: const EmailPasswordChange.clear(),
        ),
      );
      final result = await h.repo.executeEmailSettings(
        review,
        review.target,
        isCurrent: () => true,
      );
      expect(result.outcome, EmailSettingsOutcome.completed);
      final update = (h.wire.writes.single['params'] as List).single as Map;
      expect(update['smtp'], isFalse);
      expect(update.containsKey('pass'), isTrue);
      expect(update['pass'], isNull);
      expect(update.containsKey('oauth'), isFalse);
    },
  );
  test('SMTP IPv4 is accepted without any probe and test is exact saved-only payload', () async {
    final h = await _connected(
      configure: (w) => w.config['outgoingserver'] = '192.0.2.7',
    );
    final review = await _review(h, action: EmailSettingsAction.test);
    expect(h.wire.writes, isEmpty);
    _noPrivateCalls(h.wire);
    final result = await h.repo.executeEmailSettings(
      review,
      review.target,
      isCurrent: () => true,
    );
    expect(result.outcome, EmailSettingsOutcome.pending);
    expect(result.jobId, 71);
    expect(h.wire.writes.single['params'], [
      {
        'subject': 'TrueNavo SMTP configuration test',
        'text': 'This is an explicitly requested TrueNavo SMTP test. No delivery or recovery guarantee is implied.',
        'html': null,
        'to': ['recipient@example.org'],
        'cc': <String>[],
        'interval': 0,
        'timeout': 30,
        'attachments': false,
        'queue': false,
        'extra_headers': <String, Object?>{},
      },
      <String, Object?>{},
    ]);
    final before = h.wire.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      h.wire.calls.length,
      before,
      reason: 'No automatic polling or resend.',
    );
    _noPrivateCalls(h.wire);
  });
  for (final action in EmailSettingsAction.values) {
    test(
      '$action pending dispatch fences peer workspaces and sanitized uncertainty is terminal',
      () async {
        final h = await _connected();
        final review = await _review(h, action: action);
        h.wire.holdMethod = action == EmailSettingsAction.test
            ? 'mail.send'
            : 'mail.update';
        final submission = h.repo.executeEmailSettings(
          review,
          review.target,
          isCurrent: () => true,
        );
        await h.wire.entered.future.timeout(const Duration(seconds: 2));
        final before = h.wire.calls.length;
        await _expectPeersFenced(h);
        expect(h.wire.calls.length, before);
        h.wire.release.complete('remote-error');
        final result = await submission;
        expect(result.outcome, EmailSettingsOutcome.unknown);
        expect(result.message, isNot(contains(_secret)));
        await _expectPeersFenced(h);
        expect(
          (await h.repo.executeEmailSettings(
            review,
            review.target,
            isCurrent: () => true,
          )).outcome,
          EmailSettingsOutcome.rejected,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(h.wire.calls.length, before);
        expect(h.wire.writes, hasLength(1));
        _noPrivateCalls(h.wire);
      },
    );
  }
  test(
    'accepted test job keeps global fence without implicit polling',
    () async {
      final h = await _connected();
      final review = await _review(h, action: EmailSettingsAction.test);
      expect(
        (await h.repo.executeEmailSettings(
          review,
          review.target,
          isCurrent: () => true,
        )).outcome,
        EmailSettingsOutcome.pending,
      );
      final before = h.wire.calls.length;
      await _expectPeersFenced(h);
      await expectLater(
        h.repo.loadEmailSettings(),
        throwsA(isA<EmailSettingsException>()),
      );
      expect(
        (await h.repo.checkEmailSettingsJob(
          999,
          isCurrent: () => true,
        )).outcome,
        EmailSettingsOutcome.rejected,
      );
      expect(h.wire.calls.length, before);
      expect(h.wire.writes, hasLength(1));
    },
  );
  test('terminal reset fences a previously reviewed SMTP update', () async {
    final h = await _connected();
    final review = await _review(h);
    final reset = await h.repo.reviewConfigurationReset(
      ConfigurationResetRequest(
        inventory: await h.repo.loadConfigurationReset(),
      ),
    );
    expect(
      (await h.repo.executeConfigurationReset(
        reset,
        reset.target,
        isCurrent: () => true,
      )).outcome,
      ConfigurationResetOutcome.accepted,
    );
    final before = h.wire.calls.length;
    expect(
      (await h.repo.executeEmailSettings(
        review,
        review.target,
        isCurrent: () => true,
      )).outcome,
      EmailSettingsOutcome.rejected,
    );
    expect(h.wire.calls.length, before);
    expect(h.wire.writes, isEmpty);
  });
}

EmailSmtpSettings _settings({
  String host = 'new.example.org',
  String from = 'sender@example.org',
  String name = 'NAS',
  String username = 'user',
  int port = 587,
  EmailSecurity security = EmailSecurity.tls,
  bool auth = true,
}) => EmailSmtpSettings(
  fromEmail: from,
  fromName: name,
  outgoingServer: host,
  username: username,
  port: port,
  security: security,
  smtpAuth: auth,
);
void _noPrivateCalls(_Wire w) =>
    expect(w.calls.where((c) => _forbidden.contains(c['method'])), isEmpty);
Future<EmailSettingsReview> _review(
  _Harness h, {
  EmailSettingsAction action = EmailSettingsAction.configure,
  EmailPasswordChange password = const EmailPasswordChange.keep(),
}) async => h.repo.reviewEmailSettings(
  EmailSettingsRequest(
    inventory: await h.repo.loadEmailSettings(),
    action: action,
    settings: action == EmailSettingsAction.configure ? _settings() : null,
    recipient: action == EmailSettingsAction.test
        ? 'recipient@example.org'
        : null,
    password: password,
  ),
);
Future<void> _expectPeersFenced(_Harness h) async {
  await expectLater(
    h.repo.loadConfigurationReset(),
    throwsA(isA<ConfigurationResetException>()),
  );
  await expectLater(
    h.repo.loadConfigurationBackup(),
    throwsA(isA<ConfigurationBackupException>()),
  );
  await expectLater(
    h.repo.loadConfigurationRestore(),
    throwsA(isA<ConfigurationRestoreException>()),
  );
  await expectLater(
    h.repo.loadSystemPower(),
    throwsA(isA<SystemPowerException>()),
  );
  await expectLater(
    h.repo.loadTimeSettings(),
    throwsA(isA<TimeSettingsException>()),
  );
  await expectLater(
    h.repo.execute(
      const ServiceControlCommand(
        service: 'smb',
        action: ServiceControlAction.start,
      ),
    ),
    throwsA(isA<ManagementException>()),
  );
}

Future<_Harness> _connected({void Function(_Wire)? configure}) async {
  final wire = _Wire();
  configure?.call(wire);
  final repo = TrueNasSessionRepository(
    connector: _Connector(wire),
    managementRequestTimeout: const Duration(seconds: 1),
  );
  addTearDown(repo.close);
  await repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
  );
  return _Harness(repo, wire);
}

class _Harness {
  _Harness(this.repo, this.wire);
  final TrueNasSessionRepository repo;
  final _Wire wire;
}

class _Connector implements RpcConnector {
  _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class _Wire
    implements
        RpcTransport,
        ConfigurationBackupDownloadTransport,
        ConfigurationRestoreUploadTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final sendFlags = <String, Object?>{};
  final config = <String, Object?>{
    'id': 1,
    'fromemail': 'sender@example.org',
    'fromname': 'NAS',
    'outgoingserver': 'old.example.org',
    'port': 587,
    'security': 'TLS',
    'smtp': true,
    'user': 'user',
    'pass': _secret,
    'oauth': null,
  };
  bool admin = true;
  String? holdMethod;
  final entered = Completer<void>(), release = Completer<Object?>();
  List<Map<String, dynamic>> get writes =>
      calls.where((c) => _mutations.contains(c['method'])).toList();
  @override
  bool get configurationBackupDownloadSupported => true;
  @override
  bool get configurationRestoreUploadSupported => true;
  @override
  Future<Uint8List> downloadConfigurationBackup({
    required String relativeUrl,
    required int jobId,
  }) => throw StateError('No file transfer expected');
  @override
  Future<int> uploadConfigurationRestore({
    required String token,
    required Uint8List bytes,
  }) {
    bytes.fillRange(0, bytes.length, 0);
    throw StateError('No file transfer expected');
  }

  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(request);
    final method = request['method'] as String;
    final params = request['params'] as List? ?? [];
    if (method == holdMethod) {
      entered.complete();
      final result = await release.future;
      if (result == 'remote-error') {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': request['id'],
            'error': {
              'code': -32000,
              'message': _secret,
              'data': {'errno': 13},
            },
          }),
        );
        return;
      }
    }
    Object? value;
    switch (method) {
      case 'auth.login_ex':
        value = {'response_type': 'SUCCESS'};
      case 'system.info':
        value = {'version': '25.10.1'};
      case 'core.get_methods':
        value = {
          for (final name in _methods)
            name: {
              'job': {
                'mail.send',
                'config.reset',
                'system.reboot',
                'system.shutdown',
                'config.save',
                'config.upload',
                'service.control',
              }.contains(name),
              'uploadable': name == 'config.upload' || name == 'mail.send',
              'downloadable': name == 'config.save',
              'check_pipes': false,
              'private': _forbidden.contains(name),
              'no_auth_required': false,
              'filterable': false,
              'accepts': <Object?>[],
              'returns': [
                {'type': 'boolean'},
              ],
              'roles': ['FULL_ADMIN'],
              if (name == 'mail.send') ...sendFlags,
            },
        };
      case 'auth.me':
        value = {
          'privilege': {
            'roles': [admin ? 'FULL_ADMIN' : 'READONLY_ADMIN'],
          },
          'secret': _secret,
        };
      case 'system.version_short':
        value = '25.10.1';
      case 'system.host_id':
        value = _host;
      case 'system.reboot.info':
        value = {
          'boot_id': '11111111-2222-4333-8444-555555555555',
          'reboot_required_reasons': [],
        };
      case 'system.state':
        value = 'READY';
      case 'failover.licensed':
        value = false;
      case 'boot.get_state':
        value = {
          'name': 'boot-pool',
          'healthy': true,
          'status': 'ONLINE',
          'scan': null,
        };
      case 'boot.environment.query':
        value = [
          {
            'id': '25.10.1',
            'dataset': 'boot-pool/ROOT/25.10.1',
            'created': '2026-09-14T01:00:00',
            'used_bytes': 4096,
            'active': true,
            'activated': true,
            'keep': true,
            'can_activate': true,
          },
        ];
      case 'core.get_jobs':
        value = [];
      case 'mail.config':
        value = config;
      case 'mail.update':
        config.addAll(Map<String, Object?>.from(params.single as Map));
        value = config;
      case 'mail.send':
        value = 71;
      case 'config.reset':
        value = 72;
      case 'system.general.config':
        value = {'timezone': 'UTC'};
      case 'system.general.timezone_choices':
        value = {'UTC': 'UTC'};
      case 'system.general.checkin_waiting':
        value = null;
      case 'system.ntpserver.query':
        value = <Object?>[];
      default:
        throw StateError('Unexpected synthetic method $method');
    }
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': value}),
      );
    }
  }

  @override
  Future<void> close() async {
    if (!inbound.isClosed) {
      await inbound.close();
    }
  }
}
