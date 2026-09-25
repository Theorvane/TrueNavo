import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _boot = '11111111-2222-4333-8444-555555555555';
const _secret = 'SYNTHETIC_PRIVATE_RESET_ERROR';
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
};
const _methods = {..._reads, 'config.reset'};
Map<String, Object?> _environment() => {
  'id': '25.10.1',
  'dataset': 'boot-pool/ROOT/25.10.1',
  'created': '2026-09-14T01:00:00',
  'used_bytes': 4000,
  'active': true,
  'activated': true,
  'keep': true,
  'can_activate': true,
};

class _Wire implements RpcTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
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
    'boot.environment.query': [_environment()],
    'core.get_jobs': [],
    'auth.me': {
      'privilege': {
        'roles': ['FULL_ADMIN'],
      },
      'pw_gecos': _secret,
    },
    'config.reset': 71,
  };
  final methods = <String>{..._methods};
  final metadata = <String, Map<String, Object?>>{};
  final counts = <String, int>{};
  String version = '25.10.1';
  bool current = true;
  String? faultMethod, heldMethod, throwMethod;
  Completer<void>? heldRpc;
  void Function(String method, int count)? beforeReply;
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(request);
    final method = request['method'] as String;
    counts[method] = (counts[method] ?? 0) + 1;
    beforeReply?.call(method, counts[method]!);
    if (method == throwMethod) throw StateError(_secret);
    if (method == heldMethod) await heldRpc!.future;
    if (method == faultMethod) {
      if (!inbound.isClosed) {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': request['id'],
            'error': {
              'code': -32000,
              'message': _secret,
              'data': {'trace': _secret},
            },
          }),
        );
      }
      return;
    }
    final Object? value = switch (method) {
      'auth.login_ex' => {'response_type': 'SUCCESS'},
      'system.info' => {'version': version},
      'core.get_methods' => {
        for (final name in methods)
          name: {
            'job': name == 'config.reset',
            'uploadable': false,
            'downloadable': false,
            'no_auth_required': false,
            ...?metadata[name],
          },
      },
      _ => values[method],
    };
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': value}),
      );
    }
  }

  @override
  Future<void> close() async {
    if (!inbound.isClosed) await inbound.close();
  }
}

class _Connector implements RpcConnector {
  const _Connector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

class _Harness {
  _Harness(this.wire) {
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      configurationResetNow: () => now,
      managementRequestTimeout: const Duration(milliseconds: 100),
    );
  }
  final _Wire wire;
  late final TrueNasSessionRepository repo;
  DateTime now = DateTime.utc(2026, 9, 14);
  bool authorized = true;
}

Future<_Harness> _connected({void Function(_Wire)? configure}) async {
  final wire = _Wire();
  configure?.call(wire);
  final h = _Harness(wire);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
    isConnectionCurrent: () => wire.current,
  );
  return h;
}

Future<ConfigurationResetReview> _review(_Harness h) async =>
    h.repo.reviewConfigurationReset(
      ConfigurationResetRequest(
        inventory: await h.repo.loadConfigurationReset(),
      ),
    );
Future<ConfigurationResetResult> _execute(
  _Harness h, [
  ConfigurationResetReview? review,
]) async {
  final issued = review ?? await _review(h);
  return h.repo.executeConfigurationReset(
    issued,
    issued.target,
    isCurrent: () => h.authorized,
  );
}

Iterable<Map<String, dynamic>> _submissions(_Harness h) =>
    h.wire.calls.where((call) => call['method'] == 'config.reset');
Matcher _reason(ConfigurationResetExceptionReason reason) =>
    isA<ConfigurationResetException>().having(
      (e) => e.reason,
      'reason',
      reason,
    );
Future<void> _waitForCall(_Harness h, String method) async {
  for (var count = 0; count < 1000; count++) {
    if (h.wire.calls.any((call) => call['method'] == method)) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Synthetic method did not dispatch.');
}

void main() {
  test('disconnected reset API is unavailable', () async {
    final h = _Harness(_Wire());
    addTearDown(h.repo.close);
    expect(h.repo.configurationResetCapabilities.supported, isFalse);
    expect(h.repo.configurationResetCapabilities.blockedReason, isNotNull);
    await expectLater(
      h.repo.loadConfigurationReset(),
      throwsA(_reason(ConfigurationResetExceptionReason.notAuthenticated)),
    );
  });
  test('ordinary authenticated transport supports exact reset without file capability', () async {
    final h = await _connected();
    final caps = h.repo.configurationResetCapabilities;
    expect(caps.supported, isTrue);
    expect(caps.canReset, isTrue);
    expect(caps.blockedReason, isNull);
    final inventory = await h.repo.loadConfigurationReset();
    expect(inventory.fullAdmin, isTrue);
    expect(inventory.blockedReason, isNull);
    expect(inventory.currentEnvironment!.id, '25.10.1');
    expect(inventory.nextEnvironment!.id, '25.10.1');
    expect(() => inventory.environments.clear(), throwsUnsupportedError);
    expect(
      () => inventory.rebootReasonCodes.add('evil'),
      throwsUnsupportedError,
    );
    expect(h.wire.calls.last['method'], 'auth.me');
    expect(_submissions(h), isEmpty);
  });
  for (final version in [
    '25.04.2',
    '25.10-RC.1',
    '25.10.1-MASTER',
    '26.04.0',
    'unknown',
  ]) {
    test('reset rejects unsupported version $version', () async {
      final h = await _connected(configure: (w) => w.version = version);
      expect(h.repo.configurationResetCapabilities.supported, isFalse);
      await expectLater(
        h.repo.loadConfigurationReset(),
        throwsA(_reason(ConfigurationResetExceptionReason.unsupportedVersion)),
      );
      expect(_submissions(h), isEmpty);
    });
  }
  for (final method in _methods) {
    test('reset requires public metadata $method', () async {
      final h = await _connected(configure: (w) => w.methods.remove(method));
      expect(h.repo.configurationResetCapabilities.canReset, isFalse);
      await expectLater(
        h.repo.loadConfigurationReset(),
        throwsA(_reason(ConfigurationResetExceptionReason.unavailableMethod)),
      );
    });
    for (final flag in [
      'job',
      'uploadable',
      'downloadable',
      'no_auth_required',
      'private',
      '_private',
    ]) {
      test('unsafe $method $flag metadata fails closed', () async {
        final h = await _connected(
          configure: (w) => w.metadata[method] = {
            flag: flag == 'job' ? method != 'config.reset' : true,
          },
        );
        expect(h.repo.configurationResetCapabilities.canReset, isFalse);
        await expectLater(
          h.repo.loadConfigurationReset(),
          throwsA(_reason(ConfigurationResetExceptionReason.unavailableMethod)),
        );
      });
    }
    for (final flag in [
      'job',
      'uploadable',
      'downloadable',
      'no_auth_required',
    ]) {
      test('unproven $method $flag metadata fails closed', () async {
        final h = await _connected(
          configure: (w) => w.metadata[method] = {flag: null},
        );
        expect(h.repo.configurationResetCapabilities.canReset, isFalse);
      });
    }
  }
  test(
    'reset exact fixed reboot true once, positive receipt is acceptance only',
    () async {
      final h = await _connected();
      final review = await _review(h);
      expect(review.target, 'RESET $_host');
      final result = await _execute(h, review);
      expect(result.outcome, ConfigurationResetOutcome.accepted);
      expect(result.jobId, 71);
      expect(result.message, contains('unverified'));
      expect(_submissions(h), hasLength(1));
      expect(_submissions(h).single['params'], [
        {'reboot': true},
      ]);
      expect(h.wire.calls.last['method'], 'config.reset');
      expect(
        h.wire.calls.where(
          (c) => !{
            ..._methods,
            'auth.login_ex',
            'system.info',
            'core.get_methods',
            'core.ping',
          }.contains(c['method']),
        ),
        isEmpty,
      );
      await expectLater(
        h.repo.loadConfigurationReset(),
        throwsA(_reason(ConfigurationResetExceptionReason.busy)),
      );
      expect(
        (await _execute(h, review)).outcome,
        ConfigurationResetOutcome.rejected,
      );
      expect(_submissions(h), hasLength(1));
    },
  );
  test('maximum safe positive job ID is accepted', () async {
    final h = await _connected();
    h.wire.values['config.reset'] = 9007199254740991;
    expect((await _execute(h)).jobId, 9007199254740991);
  });
  for (final receipt in <Object?>[
    null,
    true,
    false,
    0,
    -1,
    9007199254740992,
    '71',
    71.0,
    {},
    [],
    {'job_id': 71},
    _secret,
  ]) {
    test(
      'invalid reset receipt ${receipt.runtimeType} $receipt fences as unknown',
      () async {
        final h = await _connected();
        h.wire.values['config.reset'] = receipt;
        final result = await _execute(h);
        expect(result.outcome, ConfigurationResetOutcome.unknown);
        expect(result.jobId, isNull);
        expect(result.message, isNot(contains(_secret)));
        expect(_submissions(h), hasLength(1));
        expect(h.wire.calls.last['method'], 'config.reset');
        await expectLater(
          h.repo.loadConfigurationReset(),
          throwsA(_reason(ConfigurationResetExceptionReason.busy)),
        );
      },
    );
  }
  for (final mode in [
    'error',
    'send-throw',
    'timeout',
    'session',
    'foreground',
    'disconnect',
  ]) {
    test(
      'post-dispatch $mode is unknown, never retry or rollback claim',
      () async {
        final h = await _connected();
        final review = await _review(h);
        if (mode == 'error') h.wire.faultMethod = 'config.reset';
        if (mode == 'send-throw') h.wire.throwMethod = 'config.reset';
        if (mode == 'timeout') {
          h.wire.heldMethod = 'config.reset';
          h.wire.heldRpc = Completer<void>();
        }
        h.wire.beforeReply = (method, _) {
          if (method != 'config.reset') return;
          if (mode == 'session') h.wire.current = false;
          if (mode == 'foreground') h.authorized = false;
          if (mode == 'disconnect') unawaited(h.wire.close());
        };
        final result = await _execute(h, review);
        expect(result.outcome, ConfigurationResetOutcome.unknown);
        expect(result.message, contains('does not prove rollback'));
        expect(result.message, isNot(contains(_secret)));
        expect(_submissions(h), hasLength(1));
        h.wire.current = true;
        h.authorized = true;
        h.wire.heldRpc?.complete();
        await Future<void>.delayed(Duration.zero);
        expect(
          (await _execute(h, review)).outcome,
          ConfigurationResetOutcome.rejected,
        );
        expect(_submissions(h), hasLength(1));
      },
    );
  }
  _readinessTests();
  _leaseTests();
}

void _leaseTests() {
  for (final change in [
    'confirmation',
    'forged-review',
    'reload',
    'expired',
    'backwards-clock',
    'session',
    'foreground',
    'throw-callback',
  ]) {
    test('single-use reset lease rejects $change without submission', () async {
      final h = await _connected();
      var review = await _review(h);
      var confirmation = review.target;
      switch (change) {
        case 'confirmation':
          confirmation = 'RESET';
        case 'forged-review':
          review = ConfigurationResetReview(
            request: review.request,
            endpoint: review.endpoint,
            warnings: [],
          );
        case 'reload':
          await h.repo.loadConfigurationReset();
        case 'expired':
          h.now = h.now.add(const Duration(minutes: 6));
        case 'backwards-clock':
          h.now = h.now.subtract(const Duration(seconds: 1));
        case 'session':
          h.wire.current = false;
        case 'foreground':
          h.authorized = false;
      }
      final result = await h.repo.executeConfigurationReset(
        review,
        confirmation,
        isCurrent: () {
          if (change == 'throw-callback') throw StateError(_secret);
          return h.authorized;
        },
      );
      expect(result.outcome, ConfigurationResetOutcome.rejected);
      expect(result.message, isNot(contains(_secret)));
      h.wire.current = true;
      h.authorized = true;
      h.now = DateTime.utc(2026, 9, 14);
      expect(
        (await _execute(h, review)).outcome,
        ConfigurationResetOutcome.rejected,
      );
      expect(_submissions(h), isEmpty);
    });
  }
  test('exact five-minute reset lease remains valid', () async {
    final h = await _connected();
    final review = await _review(h);
    h.now = h.now.add(const Duration(minutes: 5));
    expect(
      (await _execute(h, review)).outcome,
      ConfigurationResetOutcome.accepted,
    );
  });
  for (final method in _reads) {
    for (final cancel in ['foreground', 'session', 'expiry', 'throw']) {
      test('reset $method preflight then $cancel never dispatches', () async {
        final h = await _connected();
        final review = await _review(h);
        var callbackThrows = false;
        h.wire.beforeReply = (name, _) {
          if (name != method) return;
          switch (cancel) {
            case 'foreground':
              h.authorized = false;
            case 'session':
              h.wire.current = false;
            case 'expiry':
              h.now = h.now.add(const Duration(minutes: 6));
            case 'throw':
              callbackThrows = true;
          }
        };
        final result = await h.repo.executeConfigurationReset(
          review,
          review.target,
          isCurrent: () {
            if (callbackThrows) throw StateError(_secret);
            return h.authorized;
          },
        );
        expect(result.outcome, ConfigurationResetOutcome.rejected);
        expect(result.message, isNot(contains(_secret)));
        expect(_submissions(h), isEmpty);
      });
    }
  }
  for (final cancel in ['foreground', 'expiry']) {
    test('final auth.me before dispatch rechecks $cancel', () async {
      final h = await _connected();
      final review = await _review(h);
      final countBefore = h.wire.counts['auth.me']!;
      h.wire.beforeReply = (method, count) {
        if (method != 'auth.me' || count != countBefore + 2) return;
        if (cancel == 'foreground') h.authorized = false;
        if (cancel == 'expiry') h.now = h.now.add(const Duration(minutes: 6));
      };
      expect(
        (await _execute(h, review)).outcome,
        ConfigurationResetOutcome.rejected,
      );
      expect(_submissions(h), isEmpty);
    });
  }
  for (final method in _reads) {
    test(
      'sanitized reset preflight error in $method cannot dispatch',
      () async {
        final h = await _connected();
        final review = await _review(h);
        h.wire.faultMethod = method;
        final result = await _execute(h, review);
        expect(result.outcome, ConfigurationResetOutcome.rejected);
        expect(result.message, isNot(contains(_secret)));
        expect(_submissions(h), isEmpty);
      },
    );
  }
  test('preflight timeout remains rejected with no late dispatch', () async {
    final h = await _connected();
    final review = await _review(h);
    h.wire.heldMethod = 'auth.me';
    h.wire.heldRpc = Completer<void>();
    final result = await _execute(h, review);
    expect(result.outcome, ConfigurationResetOutcome.rejected);
    h.wire.heldRpc!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(_submissions(h), isEmpty);
  });
  test(
    'duplicate execution cannot consume or replace in-flight operation',
    () async {
      final h = await _connected();
      final review = await _review(h);
      h.wire.heldMethod = 'config.reset';
      h.wire.heldRpc = Completer<void>();
      final pending = _execute(h, review);
      await _waitForCall(h, 'config.reset');
      expect(
        (await _execute(h, review)).outcome,
        ConfigurationResetOutcome.rejected,
      );
      h.wire.heldRpc!.complete();
      expect((await pending).outcome, ConfigurationResetOutcome.accepted);
      expect(_submissions(h), hasLength(1));
    },
  );
  test('inventory from another session cannot issue reset lease', () async {
    final a = await _connected(), b = await _connected();
    final inventory = await a.repo.loadConfigurationReset();
    await expectLater(
      b.repo.reviewConfigurationReset(
        ConfigurationResetRequest(inventory: inventory),
      ),
      throwsA(_reason(ConfigurationResetExceptionReason.staleReview)),
    );
    final review = await a.repo.reviewConfigurationReset(
      ConfigurationResetRequest(inventory: inventory),
    );
    expect(
      (await _execute(b, review)).outcome,
      ConfigurationResetOutcome.rejected,
    );
    expect(_submissions(a), isEmpty);
    expect(_submissions(b), isEmpty);
  });
  test('new review invalidates earlier review', () async {
    final h = await _connected();
    final old = await _review(h);
    final fresh = await h.repo.reviewConfigurationReset(old.request);
    expect(
      (await _execute(h, old)).outcome,
      ConfigurationResetOutcome.rejected,
    );
    expect(
      (await _execute(h, fresh)).outcome,
      ConfigurationResetOutcome.accepted,
    );
  });
  test(
    'closing repository invalidates capabilities and issued review',
    () async {
      final h = await _connected();
      final review = await _review(h);
      await h.repo.close();
      expect(h.repo.configurationResetCapabilities.connected, isFalse);
      await expectLater(
        _execute(h, review),
        throwsA(_reason(ConfigurationResetExceptionReason.notAuthenticated)),
      );
      expect(_submissions(h), isEmpty);
    },
  );
  test('failed reconnect also invalidates old reset workspace', () async {
    final h = await _connected();
    final review = await _review(h);
    await expectLater(
      h.repo.connect(
        serverInput: 'http://insecure.example',
        apiKey: 'synthetic',
        username: 'admin',
      ),
      throwsA(anything),
    );
    expect(h.repo.configurationResetCapabilities.connected, isFalse);
    await expectLater(
      _execute(h, review),
      throwsA(_reason(ConfigurationResetExceptionReason.notAuthenticated)),
    );
    expect(_submissions(h), isEmpty);
  });
}

void _readinessTests() {
  final invalid = <String, Object?>{
    'auth.me': {
      'privilege': {'roles': null},
    },
    'system.host_id': '$_host\n',
    'system.reboot.info': {'boot_id': _secret, 'reboot_required_reasons': []},
    'system.version_short': '25.10.2',
    'system.state': 'ready',
    'failover.licensed': null,
    'boot.get_state': {
      'name': 'boot-pool',
      'healthy': true,
      'status': 'ONLINE',
      'scan': {'state': null},
    },
    'boot.environment.query': [{}],
    'core.get_jobs': [
      {'id': 0, 'method': 'config.reset', 'state': 'RUNNING'},
    ],
  };
  for (final entry in invalid.entries) {
    test(
      'invalid reset readiness ${entry.key} fails closed and sanitized',
      () async {
        final h = await _connected();
        h.wire.values[entry.key] = entry.value;
        await expectLater(
          h.repo.loadConfigurationReset(),
          throwsA(
            isA<ConfigurationResetException>().having(
              (e) => e.toString(),
              'sanitized',
              isNot(contains(_secret)),
            ),
          ),
        );
        expect(_submissions(h), isEmpty);
      },
    );
  }
  final blocked = <String, Map<String, Object?>>{
    'readonly': {
      'auth.me': {
        'privilege': {
          'roles': ['READONLY_ADMIN'],
        },
      },
    },
    'HA': {'failover.licensed': true},
    'booting': {'system.state': 'BOOTING'},
    'job': {
      'core.get_jobs': [
        {'id': 4, 'method': 'config.upload', 'state': 'RUNNING'},
      ],
    },
    'waiting': {
      'core.get_jobs': [
        {'id': 4, 'method': 'config.reset', 'state': 'WAITING'},
      ],
    },
    'boot-unhealthy': {
      'boot.get_state': {
        'name': 'boot-pool',
        'healthy': false,
        'status': 'DEGRADED',
        'scan': null,
      },
    },
    'boot-scanning': {
      'boot.get_state': {
        'name': 'boot-pool',
        'healthy': true,
        'status': 'ONLINE',
        'scan': {'state': 'SCANNING'},
      },
    },
    'not-bootable': {
      'boot.environment.query': [
        {..._environment(), 'can_activate': false},
      ],
    },
    'next-boot': {
      'boot.environment.query': [
        {..._environment(), 'activated': false},
        {
          ..._environment(),
          'id': 'older',
          'dataset': 'boot-pool/ROOT/older',
          'active': false,
        },
      ],
    },
  };
  for (final entry in blocked.entries) {
    test('blocked reset ${entry.key} cannot issue review', () async {
      final h = await _connected();
      h.wire.values.addAll(entry.value);
      final inventory = await h.repo.loadConfigurationReset();
      expect(inventory.blockedReason, isNotNull);
      await expectLater(
        h.repo.reviewConfigurationReset(
          ConfigurationResetRequest(inventory: inventory),
        ),
        throwsA(_reason(ConfigurationResetExceptionReason.invalidRequest)),
      );
      expect(_submissions(h), isEmpty);
    });
  }
  final changed = <String, Object?>{
    'system.host_id': 'f' * 64,
    'system.reboot.info': {
      'boot_id': '11111111-2222-4333-8444-666666666666',
      'reboot_required_reasons': [],
    },
    'auth.me': {
      'privilege': {
        'roles': ['READONLY_ADMIN'],
      },
    },
    'boot.get_state': {
      'name': 'other-boot',
      'healthy': true,
      'status': 'ONLINE',
      'scan': null,
    },
    'boot.environment.query': [
      {..._environment(), 'keep': false},
    ],
    'core.get_jobs': [
      {'id': 8, 'method': 'config.reset', 'state': 'WAITING'},
    ],
    'system.state': 'BOOTING',
    'failover.licensed': true,
  };
  for (final entry in changed.entries) {
    for (final phase in ['review', 'execute']) {
      test('changed ${entry.key} between reset snapshots rejects $phase', () async {
        final h = await _connected();
        if (phase == 'review') {
          final inventory = await h.repo.loadConfigurationReset();
          h.wire.values[entry.key] = entry.value;
          await expectLater(
            h.repo.reviewConfigurationReset(
              ConfigurationResetRequest(inventory: inventory),
            ),
            throwsA(
              _reason(
                entry.key == 'boot.get_state'
                    // A different pool also makes the old environment dataset
                    // inconsistent, so parsing rejects before proof comparison.
                    ? ConfigurationResetExceptionReason.unavailable
                    : ConfigurationResetExceptionReason.staleReview,
              ),
            ),
          );
        } else {
          final review = await _review(h);
          h.wire.values[entry.key] = entry.value;
          expect(
            (await _execute(h, review)).outcome,
            ConfigurationResetOutcome.rejected,
          );
        }
        expect(_submissions(h), isEmpty);
      });
    }
  }
  for (final method in ['system.host_id', 'system.reboot.info', 'auth.me']) {
    test(
      'mid-read $method identity privilege drift invalidates reset snapshot',
      () async {
        final h = await _connected();
        final initial = h.wire.counts[method] ?? 0;
        h.wire.beforeReply = (name, count) {
          if (name == method && count == initial + 2) {
            h.wire.values[name] = changed[name];
          }
        };
        await expectLater(
          h.repo.loadConfigurationReset(),
          throwsA(isA<ConfigurationResetException>()),
        );
        expect(_submissions(h), isEmpty);
      },
    );
  }
  test(
    'reboot reason proof cannot drift between review and dispatch',
    () async {
      final h = await _connected();
      final review = await _review(h);
      h.wire.values['system.reboot.info'] = {
        'boot_id': _boot,
        'reboot_required_reasons': [
          {'code': 'CONFIG', 'reason': _secret},
        ],
      };
      expect(
        (await _execute(h, review)).outcome,
        ConfigurationResetOutcome.rejected,
      );
      expect(_submissions(h), isEmpty);
    },
  );
  test('review explicitly warns direct changes, pending restore and unknown completion', () async {
    final h = await _connected();
    final review = await _review(h);
    final text = review.warnings.join(' ');
    for (final warning in [
      'immediately replaces',
      'not a dry run',
      '10-second',
      'before later hooks',
      'None proves rollback',
      'encryption keys',
      'physical access',
      'not disk wiping',
      'secure erasure',
      'pending uploaded',
      'Reset does not clear those files',
      'instead of factory defaults',
      'acceptance only',
      'No polling',
    ]) {
      expect(text, contains(warning));
    }
    expect(text, isNot(contains(_secret)));
    expect(() => review.warnings.clear(), throwsUnsupportedError);
    expect(_submissions(h), isEmpty);
  });
}
