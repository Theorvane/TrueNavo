import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _boot = '11111111-2222-4333-8444-555555555555';
const _secret = 'SYNTHETIC_UNEXPOSED_REMOTE_ERROR';
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
  'alert.list_categories',
  'alert.list_policies',
  'alertclasses.config',
};
const _support = {'support.is_available', 'support.is_available_and_enabled'};
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
List<Object?> _categories() => [
  {
    'id': 'HARDWARE',
    'title': 'Hardware',
    'classes': [
      {
        'id': 'DiskTemp',
        'title': 'Disk temperature',
        'level': 'WARNING',
        'proactive_support': true,
      },
      {
        'id': 'SpaceLow',
        'title': 'Available space',
        'level': 'CRITICAL',
        'proactive_support': false,
      },
    ],
  },
];
Map<String, Object?> _config() => {
  'id': 1,
  'classes': {
    'DiskTemp': {'policy': 'HOURLY', 'proactive_support': false},
    'HiddenClass': {},
    'UnlistedClass': {
      'level': 'NOTICE',
      'policy': 'IMMEDIATELY',
      'proactive_support': true,
    },
  },
};

class _Wire implements RpcTransport {
  final inbound = StreamController<String>(), calls = <Map<String, dynamic>>[];
  final methods = <String>{..._reads, ..._support, 'alertclasses.update'};
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
    'alert.list_categories': _categories(),
    'alert.list_policies': ['IMMEDIATELY', 'HOURLY', 'DAILY', 'NEVER'],
    'alertclasses.config': _config(),
    'support.is_available': true,
    'support.is_available_and_enabled': true,
  };
  String version = '25.10.1';
  bool current = true, mutate = true, overrideReceipt = false;
  Object? receipt;
  String? fault, hold, throwMethod;
  Completer<void>? held;
  void Function(String, int)? beforeReply;
  void Function()? afterWrite;
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
            'error': {'code': -32000, 'message': _secret},
          }),
        );
      }
      return;
    }
    Object? value;
    if (method == 'alertclasses.update') {
      value = {'id': 1, ...((call['params'] as List).single as Map)};
      if (mutate) values['alertclasses.config'] = value;
      afterWrite?.call();
      if (overrideReceipt) value = receipt;
    } else {
      value = switch (method) {
        'auth.login_ex' => {'response_type': 'SUCCESS'},
        'system.info' => {'version': version},
        'core.get_methods' => {
          for (final name in methods)
            name: {
              'job': false,
              'uploadable': false,
              'downloadable': false,
              'no_auth_required': false,
              'check_pipes': false,
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
      alertPoliciesNow: () => now,
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

Future<AlertPoliciesReview> _review(
  _Harness h, {
  bool reset = false,
  AlertClassOverrides? overrides,
}) async {
  final i = await h.repo.loadAlertPolicies();
  final c = i.classes.first;
  return h.repo.reviewAlertPolicies(
    AlertPoliciesRequest(
      inventory: i,
      classPolicy: c,
      action: reset
          ? AlertPoliciesAction.resetClass
          : AlertPoliciesAction.configure,
      proactiveSupportDisclosureAccepted: true,
      overrides: reset
          ? null
          : overrides ??
                AlertClassOverrides(
                  level: AlertDeliveryLevel.error,
                  policy: c.overrides.policy,
                  proactiveSupport: c.overrides.proactiveSupport,
                ),
    ),
  );
}

Future<AlertPoliciesResult> _execute(_Harness h, AlertPoliciesReview r) =>
    h.repo.executeAlertPolicies(r, r.target, isCurrent: () => h.authorized);
List<Map<String, dynamic>> _sent(_Harness h) =>
    h.wire.calls.where((c) => c['method'] == 'alertclasses.update').toList();
Matcher _reason(AlertPoliciesExceptionReason r) =>
    isA<AlertPoliciesException>().having((e) => e.reason, 'reason', r);

void main() {
  test('full 1024-row map cannot add a 1025th override', () async {
    final h = await _connected(
      configure: (w) {
        w.values['alertclasses.config'] = {
          'id': 1,
          'classes': {
            for (var n = 0; n < 1024; n++) 'Hidden$n': <String, Object?>{},
          },
        };
      },
    );
    final inventory = await h.repo.loadAlertPolicies();
    expect(inventory.unlistedOverrideCount, 1024);
    await expectLater(
      h.repo.reviewAlertPolicies(
        AlertPoliciesRequest(
          inventory: inventory,
          classPolicy: inventory.classes.first,
          action: AlertPoliciesAction.configure,
          overrides: const AlertClassOverrides(level: AlertDeliveryLevel.error),
        ),
      ),
      throwsA(_reason(AlertPoliciesExceptionReason.invalidRequest)),
    );
    expect(_sent(h), isEmpty);
  });
  test('disconnected capability and load reject', () async {
    final r = TrueNasSessionRepository(connector: _Connector(_Wire()));
    addTearDown(r.close);
    expect(r.alertPoliciesCapabilities.supported, isFalse);
    await expectLater(
      r.loadAlertPolicies(),
      throwsA(_reason(AlertPoliciesExceptionReason.notAuthenticated)),
    );
  });
  test('public immutable metadata and only eligibility booleans', () async {
    final h = await _connected();
    final i = await h.repo.loadAlertPolicies();
    expect(i.classes, hasLength(2));
    expect(i.unlistedOverrideCount, 2);
    expect(i.configId, 1);
    expect(i.classes.first.effectiveLevel, AlertDeliveryLevel.warning);
    expect(i.classes.first.effectiveProactiveSupport, isFalse);
    expect(i.classes.last.hasOverride, isFalse);
    expect(i.classes.last.effectivePolicy, AlertPolicyFrequency.immediately);
    expect(i.supportAvailable, isTrue);
    expect(() => i.classes.clear(), throwsUnsupportedError);
    expect(i.readinessBlockedReason, isNull);
    expect(
      h.wire.calls.any(
        (c) => [
          'support.config',
          'support.new_ticket',
          'mail.send',
          'alert.send_alerts',
        ].contains(c['method']),
      ),
      isFalse,
    );
    expect(_sent(h), isEmpty);
  });
  for (final reset in [false, true]) {
    test(
      'exact full-map configure/reset $reset preserves unknown classes',
      () async {
        final h = await _connected();
        final r = await _review(h, reset: reset);
        expect(r.warnings.join(' '), contains('NEVER'));
        expect(r.warnings.join(' '), contains('serial'));
        expect(() => r.warnings.clear(), throwsUnsupportedError);
        expect((await _execute(h, r)).outcome, AlertPoliciesOutcome.completed);
        final payload = (_sent(h).single['params'] as List).single;
        expect(payload, {
          'classes': {
            if (!reset)
              'DiskTemp': {
                'level': 'ERROR',
                'policy': 'HOURLY',
                'proactive_support': false,
              },
            'HiddenClass': {},
            'UnlistedClass': {
              'level': 'NOTICE',
              'policy': 'IMMEDIATELY',
              'proactive_support': true,
            },
          },
        });
        expect((await _execute(h, r)).outcome, AlertPoliciesOutcome.rejected);
        expect(_sent(h), hasLength(1));
        await h.repo.loadAlertPolicies();
      },
    );
  }
  for (final level in <AlertDeliveryLevel?>[
    null,
    ...AlertDeliveryLevel.values,
  ]) {
    for (final policy in <AlertPolicyFrequency?>[
      null,
      ...AlertPolicyFrequency.values,
    ]) {
      test('absence vs explicit level/policy $level/$policy', () async {
        final h = await _connected();
        final r = await _review(
          h,
          overrides: AlertClassOverrides(level: level, policy: policy),
        );
        expect((await _execute(h, r)).outcome, AlertPoliciesOutcome.completed);
        final fields =
            (((_sent(h).single['params'] as List).single as Map)['classes']
                as Map)['DiskTemp'];
        expect(fields, {
          if (level != null) 'level': level.name.toUpperCase(),
          if (policy != null) 'policy': policy.name.toUpperCase(),
        });
      });
    }
  }
  for (final method in _reads) {
    for (final defect in ['missing', 'job', 'private', 'pipes']) {
      test('required read metadata $method/$defect', () async {
        final h = await _connected(
          configure: (w) {
            if (defect == 'missing') {
              w.methods.remove(method);
            } else {
              w.metadata[method] = {
                defect == 'pipes' ? 'check_pipes' : defect: defect == 'pipes'
                    ? ['input']
                    : true,
              };
            }
          },
        );
        expect(h.repo.alertPoliciesCapabilities.supported, isFalse);
        await expectLater(
          h.repo.loadAlertPolicies(),
          throwsA(_reason(AlertPoliciesExceptionReason.unavailableMethod)),
        );
        expect(_sent(h), isEmpty);
      });
    }
  }
  for (final method in {..._reads, ..._support}) {
    for (final event in ['cancel', 'expire', 'disconnect']) {
      test('final read $method $event fails before dispatch', () async {
        final h = await _connected();
        final r = await _review(h);
        h.wire.beforeReply = (m, n) {
          if (m == method) {
            switch (event) {
              case 'cancel':
                h.authorized = false;
              case 'expire':
                h.now = h.now.add(const Duration(minutes: 6));
              case 'disconnect':
                h.wire.current = false;
            }
          }
        };
        expect((await _execute(h, r)).outcome, AlertPoliciesOutcome.rejected);
        expect(_sent(h), isEmpty);
      });
    }
  }
  for (final reason in [
    'clone',
    'wrong target',
    'callback false',
    'callback throws',
    'past',
    'future',
  ]) {
    test('single-use lease rejection $reason', () async {
      final h = await _connected();
      var r = await _review(h);
      if (reason == 'clone') {
        r = AlertPoliciesReview(
          request: r.request,
          endpoint: r.endpoint,
          warnings: r.warnings,
        );
      }
      if (reason == 'past') {
        h.now = h.now.subtract(const Duration(microseconds: 1));
      }
      if (reason == 'future') {
        h.now = h.now.add(const Duration(minutes: 5, microseconds: 1));
      }
      final result = await h.repo.executeAlertPolicies(
        r,
        reason == 'wrong target' ? 'UPDATE ALERT POLICY' : r.target,
        isCurrent: () {
          if (reason == 'callback throws') throw StateError(_secret);
          return reason != 'callback false';
        },
      );
      expect(result.outcome, AlertPoliciesOutcome.rejected);
      expect(result.message, isNot(contains(_secret)));
      expect(_sent(h), isEmpty);
      expect((await _execute(h, r)).outcome, AlertPoliciesOutcome.rejected);
    });
  }
  test('exact expiry boundary accepts', () async {
    final h = await _connected();
    final r = await _review(h);
    h.now = h.now.add(const Duration(minutes: 5));
    expect((await _execute(h, r)).outcome, AlertPoliciesOutcome.completed);
  });
  for (final fault in [
    'error',
    'throw',
    'timeout',
    'invalidreceipt',
    'nowrite',
    'readerror',
    'background',
    'othermap',
    'metadata',
    'support',
  ]) {
    test('post-dispatch $fault unknown and terminal', () async {
      final h = await _connected();
      final r = await _review(h);
      switch (fault) {
        case 'error':
          h.wire.fault = 'alertclasses.update';
        case 'throw':
          h.wire.throwMethod = 'alertclasses.update';
        case 'timeout':
          h.wire.hold = 'alertclasses.update';
          h.wire.held = Completer<void>();
        case 'invalidreceipt':
          h.wire.overrideReceipt = true;
          h.wire.receipt = {'id': 1, 'classes': {}};
        case 'nowrite':
          h.wire.mutate = false;
        case 'readerror':
          h.wire.afterWrite = () => h.wire.fault = 'alertclasses.config';
        case 'background':
          h.wire.afterWrite = () => h.authorized = false;
        case 'othermap':
          h.wire.afterWrite = () =>
              ((h.wire.values['alertclasses.config'] as Map)['classes'] as Map)
                  .remove('HiddenClass');
        case 'metadata':
          h.wire.afterWrite = () => h.wire.values['alert.list_categories'] = [];
        case 'support':
          h.wire.afterWrite = () =>
              h.wire.values['support.is_available_and_enabled'] = false;
      }
      final result = await _execute(h, r);
      expect(result.outcome, AlertPoliciesOutcome.unknown);
      expect(result.message, isNot(contains(_secret)));
      expect(_sent(h), hasLength(1));
      h.authorized = true;
      h.wire.fault = null;
      h.wire.throwMethod = null;
      await expectLater(
        h.repo.loadAlertPolicies(),
        throwsA(_reason(AlertPoliciesExceptionReason.busy)),
      );
      expect((await _execute(h, r)).outcome, AlertPoliciesOutcome.rejected);
      h.wire.held?.complete();
      await Future<void>.delayed(Duration.zero);
    });
  }
  for (final change in [
    'metadata',
    'defaultlevel',
    'classsupport',
    'id',
    'hidden empty',
    'absentlevel',
    'support',
    'host',
    'admin',
    'jobs',
  ]) {
    test('full before proof detects $change', () async {
      final h = await _connected();
      final r = await _review(h);
      switch (change) {
        case 'metadata':
          h.wire.values['alert.list_categories'] = [];
        case 'defaultlevel':
          (((h.wire.values['alert.list_categories'] as List).first
                          as Map)['classes']
                      as List)
                  .first['level'] =
              'CRITICAL';
        case 'classsupport':
          (((h.wire.values['alert.list_categories'] as List).first
                          as Map)['classes']
                      as List)
                  .first['proactive_support'] =
              false;
        case 'id':
          (h.wire.values['alertclasses.config'] as Map)['id'] = 2;
        case 'hidden empty':
          ((h.wire.values['alertclasses.config'] as Map)['classes'] as Map)
              .remove('HiddenClass');
        case 'absentlevel':
          ((h.wire.values['alertclasses.config'] as Map)['classes']
                  as Map)['DiskTemp']['level'] =
              'WARNING';
        case 'support':
          h.wire.values['support.is_available_and_enabled'] = false;
        case 'host':
          h.wire.values['system.host_id'] = 'f' * 64;
        case 'admin':
          h.wire.values['auth.me'] = {
            'privilege': {
              'roles': ['READONLY_ADMIN'],
            },
          };
        case 'jobs':
          h.wire.values['core.get_jobs'] = [
            {'id': 33, 'method': 'other.job', 'state': 'RUNNING'},
          ];
      }
      expect((await _execute(h, r)).outcome, AlertPoliciesOutcome.rejected);
      expect(_sent(h), isEmpty);
    });
  }
  for (final bad in [
    null,
    [],
    {'id': 0, 'classes': {}},
    {'id': 1, 'classes': []},
    {
      'id': 1,
      'classes': {
        'A': {'level': null},
      },
    },
    {
      'id': 1,
      'classes': {
        'A': {'policy': null},
      },
    },
    {
      'id': 1,
      'classes': {
        'A': {'proactive_support': null},
      },
    },
    {
      'id': 1,
      'classes': {
        'A': {'future': 'field'},
      },
    },
    {
      'id': 1,
      'classes': {'A\n': {}},
    },
  ]) {
    test('malformed configuration ${jsonEncode(bad)}', () async {
      final h = await _connected(
        configure: (w) => w.values['alertclasses.config'] = bad,
      );
      await expectLater(
        h.repo.loadAlertPolicies(),
        throwsA(isA<AlertPoliciesException>()),
      );
      expect(_sent(h), isEmpty);
    });
  }
  for (final value in [
    null,
    [],
    ['IMMEDIATELY'],
    ['IMMEDIATELY', 'HOURLY', 'DAILY', 'DAILY'],
    ['IMMEDIATELY', 'HOURLY', 'DAILY', 'FUTURE'],
  ]) {
    test('policy vocabulary malformed ${jsonEncode(value)}', () async {
      final h = await _connected(
        configure: (w) => w.values['alert.list_policies'] = value,
      );
      await expectLater(
        h.repo.loadAlertPolicies(),
        throwsA(isA<AlertPoliciesException>()),
      );
    });
  }
  test('missing support reads do not remove severity editing but block proactive reset', () async {
    final h = await _connected(configure: (w) => w.methods.removeAll(_support));
    final r = await _review(h);
    expect(r.request.inventory.supportAvailable, isNull);
    expect((await _execute(h, r)).outcome, AlertPoliciesOutcome.completed);
    await expectLater(
      _review(h, reset: true),
      throwsA(_reason(AlertPoliciesExceptionReason.invalidRequest)),
    );
  });
  test('support error privately projects unknown and allows unchanged support override', () async {
    final h = await _connected(
      configure: (w) => w.fault = 'support.is_available',
    );
    final r = await _review(h);
    expect(r.request.inventory.supportAvailable, isNull);
    expect((await _execute(h, r)).outcome, AlertPoliciesOutcome.completed);
  });
  test('closing drops all public capabilities and old reviews', () async {
    final h = await _connected();
    final r = await _review(h);
    await h.repo.close();
    expect(h.repo.alertPoliciesCapabilities.supported, isFalse);
    await expectLater(
      _execute(h, r),
      throwsA(_reason(AlertPoliciesExceptionReason.notAuthenticated)),
    );
  });
}
