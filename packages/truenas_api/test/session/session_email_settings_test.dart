import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _boot = '11111111-2222-4333-8444-555555555555';
const _secret = 'SYNTHETIC_STORED_MAIL_SECRET';
const _replacement = 'SYNTHETIC_REPLACEMENT_MAIL_SECRET';
const _reads = {
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
};
const _all = {..._reads, 'mail.update', 'mail.send'};
Map<String, Object?> _env() => {
  'id': '25.10.1',
  'dataset': 'boot-pool/ROOT/25.10.1',
  'created': '2026-09-14T01:00:00',
  'used_bytes': 4000,
  'active': true,
  'activated': true,
  'keep': true,
  'can_activate': true,
};
Map<String, Object?> _config() => {
  'id': 1,
  'fromemail': 'sender@example.test',
  'fromname': 'NAS',
  'outgoingserver': 'smtp.example.test',
  'port': 587,
  'security': 'TLS',
  'smtp': true,
  'user': 'smtp-user',
  'pass': _secret,
  'oauth': null,
};

class _Wire implements RpcTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final methods = <String>{..._all};
  final metadata = <String, Map<String, Object?>>{};
  final counts = <String, int>{};
  final values = <String, Object?>{
    'system.version_short': '25.10.1',
    'system.host_id': _host,
    'system.reboot.info': {'boot_id': _boot, 'reboot_required_reasons': []},
    'system.state': 'READY',
    'failover.licensed': false,
    'boot.get_state': {
      'name': 'boot-pool',
      'healthy': true,
      'status': 'ONLINE',
      'scan': null,
    },
    'boot.environment.query': [_env()],
    'core.get_jobs': [],
    'auth.me': {
      'privilege': {
        'roles': ['FULL_ADMIN'],
      },
      'private': _secret,
    },
    'mail.config': _config(),
  };
  String version = '25.10.1';
  bool current = true, mutate = true, overrideReceipt = false;
  Object? receipt;
  Object? jobRows = [
    {'id': 71, 'method': 'mail.send', 'state': 'RUNNING', 'result': null},
  ];
  String? fault, throwMethod, hold;
  Completer<void>? held;
  void Function(String, int)? beforeReply;
  void Function(String)? afterWrite;
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final call = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(call);
    final method = call['method'] as String;
    counts[method] = (counts[method] ?? 0) + 1;
    beforeReply?.call(method, counts[method]!);
    if (method == hold) await held!.future;
    if (method == throwMethod) throw StateError(_secret);
    if (method == fault) {
      if (!inbound.isClosed) {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': call['id'],
            'error': {
              'code': -32000,
              'message': _secret,
              'data': {'pass': _secret},
            },
          }),
        );
      }
      return;
    }
    Object? value;
    if (method == 'mail.update') {
      value = {
        ...values['mail.config'] as Map,
        ...(call['params'] as List).single as Map,
      };
      if (mutate) values['mail.config'] = value;
      afterWrite?.call(method);
      if (overrideReceipt) value = receipt;
    } else if (method == 'mail.send') {
      value = overrideReceipt ? receipt : 71;
      afterWrite?.call(method);
    } else if (method == 'core.get_jobs' &&
        jsonEncode(call['params']).contains('"result"')) {
      value = jobRows;
    } else {
      value = switch (method) {
        'auth.login_ex' => {'response_type': 'SUCCESS'},
        'system.info' => {'version': version},
        'core.get_methods' => {
          for (final name in methods)
            name: {
              'job': name == 'mail.send',
              'uploadable': name == 'mail.send',
              'downloadable': false,
              'check_pipes': false,
              'no_auth_required': false,
              ...?metadata[name],
            },
        },
        _ => values[method],
      };
    }
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({'jsonrpc': '2.0', 'id': call['id'], 'result': value}),
      );
    }
  }

  @override
  Future<void> close() async {
    if (!inbound.isClosed) await inbound.close();
  }
}

class _Connector implements RpcConnector {
  const _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class _Harness {
  _Harness(this.wire) {
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      emailSettingsNow: () => now,
      managementRequestTimeout: const Duration(milliseconds: 100),
    );
  }
  final _Wire wire;
  late final TrueNasSessionRepository repo;
  DateTime now = DateTime.utc(2026, 9, 14);
  bool authorized = true;
}

Future<_Harness> _connected({void Function(_Wire)? configure}) async {
  final w = _Wire();
  configure?.call(w);
  final h = _Harness(w);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
    isConnectionCurrent: () => w.current,
  );
  return h;
}

EmailSmtpSettings _settings(
  EmailSettingsInventory i, {
  bool? auth,
  String? name,
  String? user,
}) => EmailSmtpSettings(
  fromEmail: i.config.settings.fromEmail,
  fromName: name ?? 'Reviewed NAS',
  outgoingServer: i.config.settings.outgoingServer,
  port: i.config.settings.port,
  security: i.config.settings.security,
  smtpAuth: auth ?? i.config.settings.smtpAuth,
  username: user ?? i.config.settings.username,
);
Future<EmailSettingsReview> _review(
  _Harness h, {
  bool test = false,
  EmailPasswordChange? password,
}) async {
  final i = await h.repo.loadEmailSettings();
  return h.repo.reviewEmailSettings(
    EmailSettingsRequest(
      inventory: i,
      action: test ? EmailSettingsAction.test : EmailSettingsAction.configure,
      settings: test ? null : _settings(i),
      recipient: test ? 'recipient@example.test' : null,
      password: password ?? const EmailPasswordChange.keep(),
    ),
  );
}

Future<EmailSettingsResult> _execute(_Harness h, EmailSettingsReview r) =>
    h.repo.executeEmailSettings(r, r.target, isCurrent: () => h.authorized);
Iterable<Map<String, dynamic>> _sent(_Harness h) => h.wire.calls.where(
  (c) => ['mail.send', 'mail.update'].contains(c['method']),
);
Matcher _reason(EmailSettingsExceptionReason r) =>
    isA<EmailSettingsException>().having((e) => e.reason, 'reason', r);
void _safe(EmailSettingsResult r) {
  expect(r.message, isNot(contains(_secret)));
  expect(r.message, isNot(contains(_replacement)));
}

void main() {
  test('email disconnected API fails closed', () async {
    final h = _Harness(_Wire());
    addTearDown(h.repo.close);
    expect(h.repo.emailSettingsCapabilities.supported, isFalse);
    await expectLater(
      h.repo.loadEmailSettings(),
      throwsA(_reason(EmailSettingsExceptionReason.notAuthenticated)),
    );
  });
  for (final version in [
    '25.04.2',
    '25.10-RC.1',
    '25.10.1-MASTER',
    '26.04.0',
    'unknown',
  ]) {
    test('email version $version is unsupported', () async {
      final h = await _connected(configure: (w) => w.version = version);
      expect(h.repo.emailSettingsCapabilities.supported, isFalse);
      await expectLater(
        h.repo.loadEmailSettings(),
        throwsA(_reason(EmailSettingsExceptionReason.unsupportedVersion)),
      );
    });
  }
  for (final method in _reads) {
    test('email missing public $method blocks reads', () async {
      final h = await _connected(configure: (w) => w.methods.remove(method));
      expect(h.repo.emailSettingsCapabilities.supported, isFalse);
      await expectLater(
        h.repo.loadEmailSettings(),
        throwsA(_reason(EmailSettingsExceptionReason.unavailableMethod)),
      );
    });
    for (final flag in [
      'job',
      'uploadable',
      'downloadable',
      'no_auth_required',
      'private',
      '_private',
      'check_pipes',
    ]) {
      test('email unsafe read $method $flag metadata blocks', () async {
        final h = await _connected(
          configure: (w) => w.metadata[method] = {flag: true},
        );
        expect(h.repo.emailSettingsCapabilities.supported, isFalse);
      });
    }
  }
  test(
    'email immutable projection retains presence only and no provider tokens',
    () async {
      final h = await _connected();
      final i = await h.repo.loadEmailSettings();
      expect(i.config.passwordPresent, isTrue);
      expect(i.config.oauthPresent, isFalse);
      expect(i.blockedReason, isNull);
      expect(i.config.settings.username, 'smtp-user');
      expect(() => i.environments.clear(), throwsUnsupportedError);
      expect(() => i.rebootReasonCodes.clear(), throwsUnsupportedError);
      expect(_sent(h), isEmpty);
    },
  );
  test(
    'email changed-field update keeps omitted secret and no SMTP send',
    () async {
      final h = await _connected();
      final r = await _review(h);
      final result = await _execute(h, r);
      expect(result.outcome, EmailSettingsOutcome.completed);
      _safe(result);
      expect(result.jobId, isNull);
      expect(_sent(h).single['method'], 'mail.update');
      expect(_sent(h).single['params'], [
        {'fromname': 'Reviewed NAS'},
      ]);
      expect(h.wire.counts['mail.config'], 4);
      expect((await h.repo.loadEmailSettings()).config.passwordPresent, isTrue);
      expect((await _execute(h, r)).outcome, EmailSettingsOutcome.rejected);
    },
  );
  test(
    'email replace password private capsule wiped after exact readback',
    () async {
      final h = await _connected();
      final p = EmailPasswordChange.replace(_replacement);
      final r = await _review(h, password: p);
      expect(p.toString(), isNot(contains(_replacement)));
      final result = await _execute(h, r);
      expect(result.outcome, EmailSettingsOutcome.completed);
      _safe(result);
      expect(p.isDisposed, isTrue);
      expect(_sent(h).single['params'], [
        {'fromname': 'Reviewed NAS', 'pass': _replacement},
      ]);
    },
  );
  test(
    'email explicit disable and Clear writes pass null not implicit erase',
    () async {
      final h = await _connected();
      final i = await h.repo.loadEmailSettings();
      final r = await h.repo.reviewEmailSettings(
        EmailSettingsRequest(
          inventory: i,
          action: EmailSettingsAction.configure,
          settings: _settings(i, auth: false),
          password: const EmailPasswordChange.clear(),
        ),
      );
      expect((await _execute(h, r)).outcome, EmailSettingsOutcome.completed);
      expect(_sent(h).single['params'], [
        {'fromname': 'Reviewed NAS', 'smtp': false, 'pass': null},
      ]);
      expect((h.wire.values['mail.config'] as Map)['user'], 'smtp-user');
    },
  );
  test('initial null username and empty OAuth are preserved by changed-field patch', () async {
    final h = await _connected(
      configure: (w) => w.values['mail.config'] = {
        ..._config(),
        'user': null,
        'smtp': false,
        'pass': null,
        'oauth': {},
      },
    );
    final r = await _review(h);
    expect((await _execute(h, r)).outcome, EmailSettingsOutcome.completed);
    expect(_sent(h).single['params'], [
      {'fromname': 'Reviewed NAS'},
    ]);
    final raw = h.wire.values['mail.config'] as Map;
    expect(raw['user'], isNull);
    expect(raw['oauth'], isEmpty);
  });
  for (final drift in [
    'password',
    'oauth-empty',
    'username-null',
    'fromname',
    'host',
  ]) {
    test('private and public readback drift $drift is unknown', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.afterWrite = (_) {
        final raw = h.wire.values['mail.config'] as Map;
        switch (drift) {
          case 'password':
            raw['pass'] = 'OTHER_SECRET';
          case 'oauth-empty':
            raw['oauth'] = {};
          case 'username-null':
            raw['user'] = null;
          case 'fromname':
            raw['fromname'] = 'Other administrator';
          case 'host':
            h.wire.values['system.host_id'] = 'f' * 64;
        }
      };
      final result = await _execute(h, r);
      expect(result.outcome, EmailSettingsOutcome.unknown);
      _safe(result);
      await expectLater(
        h.repo.loadEmailSettings(),
        throwsA(_reason(EmailSettingsExceptionReason.busy)),
      );
    });
  }
  for (final testSend in [false, true]) {
    for (final failure in [
      'error',
      'throw',
      'timeout',
      'bad-receipt',
      'session',
      'foreground',
    ]) {
      test(
        'email ${testSend ? 'send' : 'update'} dispatched $failure stays unknown',
        () async {
          final h = await _connected();
          final r = await _review(h, test: testSend);
          final method = testSend ? 'mail.send' : 'mail.update';
          switch (failure) {
            case 'error':
              h.wire.fault = method;
            case 'throw':
              h.wire.throwMethod = method;
            case 'timeout':
              h.wire.hold = method;
              h.wire.held = Completer<void>();
            case 'bad-receipt':
              h.wire.overrideReceipt = true;
            case 'session':
              h.wire.afterWrite = (_) => h.wire.current = false;
            case 'foreground':
              h.wire.afterWrite = (_) => h.authorized = false;
          }
          final result = await _execute(h, r);
          expect(result.outcome, EmailSettingsOutcome.unknown);
          _safe(result);
          h.wire.current = true;
          h.authorized = true;
          h.wire.held?.complete();
          await Future<void>.delayed(Duration.zero);
          expect(_sent(h), hasLength(1));
          await expectLater(
            h.repo.loadEmailSettings(),
            throwsA(_reason(EmailSettingsExceptionReason.busy)),
          );
        },
      );
    }
  }
  _leaseTests();
  _jobTests();
  _projectionTests();
}

void _leaseTests() {
  for (final change in [
    'confirmation',
    'forged',
    'reload',
    'disposed',
    'expiry',
    'clock-back',
    'session',
    'foreground',
    'throw-callback',
  ]) {
    test(
      'email lease $change rejects and wipes replacement without sending',
      () async {
        final h = await _connected();
        final p = EmailPasswordChange.replace(_replacement);
        var r = await _review(h, password: p);
        var target = r.target;
        switch (change) {
          case 'confirmation':
            target = 'EMAIL CONFIG';
          case 'forged':
            r = EmailSettingsReview(
              request: r.request,
              endpoint: r.endpoint,
              warnings: [],
            );
          case 'reload':
            await h.repo.loadEmailSettings();
          case 'disposed':
            p.dispose();
          case 'expiry':
            h.now = h.now.add(const Duration(minutes: 6));
          case 'clock-back':
            h.now = h.now.subtract(const Duration(seconds: 1));
          case 'session':
            h.wire.current = false;
          case 'foreground':
            h.authorized = false;
        }
        final result = await h.repo.executeEmailSettings(
          r,
          target,
          isCurrent: () {
            if (change == 'throw-callback') throw StateError(_secret);
            return h.authorized;
          },
        );
        expect(result.outcome, EmailSettingsOutcome.rejected);
        _safe(result);
        expect(p.isDisposed, isTrue);
        h.wire.current = true;
        h.authorized = true;
        h.now = DateTime.utc(2026, 9, 14);
        expect((await _execute(h, r)).outcome, EmailSettingsOutcome.rejected);
        expect(_sent(h), isEmpty);
      },
    );
  }
  for (final method in _reads) {
    for (final change in ['foreground', 'expiry', 'capsule', 'session']) {
      test('email preflight $method then $change prevents dispatch', () async {
        final h = await _connected();
        final p = EmailPasswordChange.replace(_replacement);
        final r = await _review(h, password: p);
        h.wire.beforeReply = (name, _) {
          if (name != method) return;
          switch (change) {
            case 'foreground':
              h.authorized = false;
            case 'expiry':
              h.now = h.now.add(const Duration(minutes: 6));
            case 'capsule':
              p.dispose();
            case 'session':
              h.wire.current = false;
          }
        };
        final result = await _execute(h, r);
        expect(result.outcome, EmailSettingsOutcome.rejected);
        _safe(result);
        expect(_sent(h), isEmpty);
        expect(p.isDisposed, isTrue);
      });
    }
  }
  test('last awaited reply still enforces email lease age', () async {
    final h = await _connected();
    final r = await _review(h);
    final before = h.wire.counts['system.state']!;
    h.wire.beforeReply = (name, count) {
      if (name == 'system.state' && count == before + 3) {
        h.now = h.now.add(const Duration(minutes: 6));
      }
    };
    expect((await _execute(h, r)).outcome, EmailSettingsOutcome.rejected);
    expect(_sent(h), isEmpty);
  });
  test(
    'stored password changes privately between review and execution reject',
    () async {
      final h = await _connected();
      final r = await _review(h);
      (h.wire.values['mail.config'] as Map)['pass'] = 'CHANGED_SECRET';
      expect((await _execute(h, r)).outcome, EmailSettingsOutcome.rejected);
      expect(_sent(h), isEmpty);
    },
  );
  test('other session cannot forge mail inventory/review', () async {
    final a = await _connected(), b = await _connected();
    final r = await _review(a);
    await expectLater(
      b.repo.reviewEmailSettings(r.request),
      throwsA(_reason(EmailSettingsExceptionReason.staleReview)),
    );
    expect((await _execute(b, r)).outcome, EmailSettingsOutcome.rejected);
    expect(_sent(b), isEmpty);
  });
  test('new review disposes old capsule and close disposes new', () async {
    final h = await _connected();
    final p = EmailPasswordChange.replace(_replacement);
    final old = await _review(h, password: p);
    final replacement = EmailPasswordChange.replace('ANOTHER_SECRET');
    await h.repo.reviewEmailSettings(
      EmailSettingsRequest(
        inventory: old.request.inventory,
        action: EmailSettingsAction.configure,
        settings: old.request.settings,
        password: replacement,
      ),
    );
    expect(p.isDisposed, isTrue);
    await h.repo.close();
    expect(replacement.isDisposed, isTrue);
    expect(h.repo.emailSettingsCapabilities.connected, isFalse);
  });
}

void _jobTests() {
  test('test acceptance never polls; only explicit owned job check reports success', () async {
    final h = await _connected();
    final r = await _review(h, test: true);
    final pending = await _execute(h, r);
    expect(pending.outcome, EmailSettingsOutcome.pending);
    expect(pending.jobId, 71);
    expect(h.wire.calls.last['method'], 'mail.send');
    final before = h.wire.calls.length;
    final alien = await h.repo.checkEmailSettingsJob(72, isCurrent: () => true);
    expect(alien.outcome, EmailSettingsOutcome.rejected);
    expect(h.wire.calls, hasLength(before));
    final still = await h.repo.checkEmailSettingsJob(71, isCurrent: () => true);
    expect(still.outcome, EmailSettingsOutcome.pending);
    expect(still.jobId, 71);
    final specific = h.wire.calls.last;
    expect(specific['params'], [
      [
        ['id', '=', 71],
      ],
      {
        'limit': 2,
        'select': ['id', 'method', 'state', 'result'],
      },
    ]);
    h.wire.jobRows = [
      {
        'id': 71,
        'method': 'mail.send',
        'state': 'SUCCESS',
        'result': true,
        'error': _secret,
        'arguments': [_secret],
      },
    ];
    final done = await h.repo.checkEmailSettingsJob(71, isCurrent: () => true);
    expect(done.outcome, EmailSettingsOutcome.completed);
    expect(done.jobId, 71);
    expect(done.message, contains('not confirmation'));
    _safe(done);
    expect(_sent(h), hasLength(1));
    expect(
      (await h.repo.checkEmailSettingsJob(71, isCurrent: () => true)).outcome,
      EmailSettingsOutcome.rejected,
    );
    expect((await h.repo.loadEmailSettings()).blockedReason, isNull);
  });
  final invalid = <String, Object?>{
    'missing': [],
    'duplicates': [
      {'id': 71, 'method': 'mail.send', 'state': 'SUCCESS', 'result': true},
      {'id': 71, 'method': 'mail.send', 'state': 'SUCCESS', 'result': true},
    ],
    'alien-id': [
      {'id': 72, 'method': 'mail.send', 'state': 'SUCCESS', 'result': true},
    ],
    'alien-method': [
      {'id': 71, 'method': 'system.reboot', 'state': 'SUCCESS', 'result': true},
    ],
    for (final state in ['FAILED', 'ABORTED', 'UNKNOWN'])
      state: [
        {
          'id': 71,
          'method': 'mail.send',
          'state': state,
          'result': true,
          'error': _secret,
        },
      ],
    for (final result in [false, null, 'true', 1, {}, []])
      'success-${result.runtimeType}': [
        {'id': 71, 'method': 'mail.send', 'state': 'SUCCESS', 'result': result},
      ],
  };
  for (final entry in invalid.entries) {
    test('owned email job ${entry.key} is unknown never resend', () async {
      final h = await _connected();
      await _execute(h, await _review(h, test: true));
      h.wire.jobRows = entry.value;
      final result = await h.repo.checkEmailSettingsJob(
        71,
        isCurrent: () => true,
      );
      expect(result.outcome, EmailSettingsOutcome.unknown);
      expect(result.jobId, 71);
      _safe(result);
      final before = h.wire.calls.length;
      expect(
        (await h.repo.checkEmailSettingsJob(71, isCurrent: () => true)).outcome,
        EmailSettingsOutcome.rejected,
      );
      expect(h.wire.calls, hasLength(before));
      expect(_sent(h), hasLength(1));
    });
  }
  for (final mode in [
    'error',
    'session',
    'foreground',
    'config-drift',
    'boot-drift',
  ]) {
    test('owned email check $mode cannot release fence', () async {
      final h = await _connected();
      await _execute(h, await _review(h, test: true));
      switch (mode) {
        case 'error':
          h.wire.fault = 'core.get_jobs';
        case 'session':
          h.wire.current = false;
        case 'foreground':
          h.authorized = false;
        case 'config-drift':
          (h.wire.values['mail.config'] as Map)['port'] = 465;
        case 'boot-drift':
          h.wire.values['system.reboot.info'] = {
            'boot_id': '11111111-2222-4333-8444-666666666666',
            'reboot_required_reasons': [],
          };
      }
      final result = await h.repo.checkEmailSettingsJob(
        71,
        isCurrent: () => h.authorized,
      );
      expect(result.outcome, EmailSettingsOutcome.unknown);
      _safe(result);
      expect(_sent(h), hasLength(1));
    });
  }
  test(
    'an owned running test may appear in visible jobs during explicit check',
    () async {
      final h = await _connected();
      await _execute(h, await _review(h, test: true));
      h.wire.values['core.get_jobs'] = [
        {'id': 71, 'method': 'mail.send', 'state': 'RUNNING'},
      ];
      expect(
        (await h.repo.checkEmailSettingsJob(71, isCurrent: () => true)).outcome,
        EmailSettingsOutcome.pending,
      );
    },
  );
}

void _projectionTests() {
  for (final field in ['fromemail', 'fromname', 'outgoingserver', 'user']) {
    test('email $field control injection never projected', () async {
      final h = await _connected();
      (h.wire.values['mail.config'] as Map)[field] =
          'value\r\nBcc: other@example.test';
      await expectLater(
        h.repo.loadEmailSettings(),
        throwsA(isA<EmailSettingsException>()),
      );
      expect(_sent(h), isEmpty);
    });
  }
  for (final pass in <Object?>[
    '********',
    '<redacted>',
    '[redacted]',
    'x' * 1025,
    true,
    {},
    'secret\n',
  ]) {
    test('unknown mail secret ${pass.runtimeType} cannot be reused', () async {
      final h = await _connected();
      (h.wire.values['mail.config'] as Map)['pass'] = pass;
      final i = await h.repo.loadEmailSettings();
      expect(i.config.passwordPresent, isNull);
      expect(i.blockedReason, isNotNull);
      expect(i.readinessBlockedReason, isNull);
      expect(_sent(h), isEmpty);
    });
  }
  test('read-only role can view safe metadata but not write or test', () async {
    final h = await _connected(
      configure: (w) => w.values['auth.me'] = {
        'privilege': {
          'roles': ['READONLY_ADMIN'],
        },
      },
    );
    final i = await h.repo.loadEmailSettings();
    expect(i.fullAdmin, isFalse);
    expect(i.blockedReason, isNotNull);
    await expectLater(
      h.repo.reviewEmailSettings(
        EmailSettingsRequest(
          inventory: i,
          action: EmailSettingsAction.test,
          recipient: 'recipient@example.test',
        ),
      ),
      throwsA(_reason(EmailSettingsExceptionReason.invalidRequest)),
    );
    expect(_sent(h), isEmpty);
  });
  test(
    'review disclosures are fixed and do not expose stored or entered secret',
    () async {
      final h = await _connected();
      final r = await _review(h, test: true);
      final text = r.warnings.join(' ');
      for (final term in [
        'hostname/domain',
        'EHLO',
        'queue:false',
        'current settings',
        'does not configure certificate/hostname verification',
        'never recipient delivery',
      ]) {
        expect(text, contains(term));
      }
      expect(text, isNot(contains(_secret)));
      expect(() => r.warnings.clear(), throwsUnsupportedError);
      expect(_sent(h), isEmpty);
    },
  );
}
