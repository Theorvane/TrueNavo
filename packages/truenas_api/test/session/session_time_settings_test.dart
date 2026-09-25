import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _boot = '11111111-2222-4333-8444-555555555555';
const _secret = 'SYNTHETIC_CERTIFICATE_PRIVATE_KEY';
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
  'system.general.config',
  'system.general.timezone_choices',
  'system.ntpserver.query',
};
const _writes = [
  'system.general.update',
  'system.ntpserver.create',
  'system.ntpserver.update',
  'system.ntpserver.delete',
];
const _all = {..._reads, ..._writes, 'system.general.checkin_waiting'};
Map<String, Object?> _row(int id, [String? address]) => {
  'id': id,
  'address': address ?? '$id.pool.example',
  'burst': false,
  'iburst': true,
  'prefer': false,
  'minpoll': 6,
  'maxpoll': 10,
};
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
      'private': _secret,
    },
    'system.general.config': {
      'timezone': 'UTC',
      'ui_certificate': {'privatekey': _secret},
    },
    'system.general.timezone_choices': {
      'UTC': 'UTC',
      'Asia/Seoul': 'Asia/Seoul',
      'America/New_York': 'America/New_York',
    },
    'system.general.checkin_waiting': null,
    'system.ntpserver.query': [_row(1), _row(2)],
  };
  final methods = <String>{..._all};
  final metadata = <String, Map<String, Object?>>{};
  final counts = <String, int>{};
  String version = '25.10.1';
  bool current = true, mutate = true, overrideReceipt = false;
  Object? receipt;
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
    final name = call['method'] as String;
    counts[name] = (counts[name] ?? 0) + 1;
    beforeReply?.call(name, counts[name]!);
    if (name == hold) await held!.future;
    if (name == throwMethod) throw StateError(_secret);
    if (name == fault) {
      if (!inbound.isClosed) {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': call['id'],
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
    Object? value;
    if (_writes.contains(name)) {
      final p = call['params'] as List;
      final rows = (values['system.ntpserver.query'] as List)
          .map((e) => Map<String, Object?>.from(e as Map))
          .toList();
      switch (name) {
        case 'system.general.update':
          value = {
            'timezone': (p.single as Map)['timezone'],
            'ui_certificate': {'privatekey': _secret},
          };
          if (mutate) values['system.general.config'] = value;
        case 'system.ntpserver.create':
          value = {'id': 3, ...Map<String, Object?>.from(p.single as Map)}
            ..remove('force');
          rows.add(value as Map<String, Object?>);
          if (mutate) values['system.ntpserver.query'] = rows;
        case 'system.ntpserver.update':
          value = {'id': p[0], ...Map<String, Object?>.from(p[1] as Map)}
            ..remove('force');
          rows.removeWhere((r) => r['id'] == p[0]);
          rows.add(value as Map<String, Object?>);
          if (mutate) values['system.ntpserver.query'] = rows;
        case 'system.ntpserver.delete':
          rows.removeWhere((r) => r['id'] == p[0]);
          value = true;
          if (mutate) values['system.ntpserver.query'] = rows;
      }
      afterWrite?.call(name);
      if (overrideReceipt) value = receipt;
    } else {
      value = switch (name) {
        'auth.login_ex' => {'response_type': 'SUCCESS'},
        'system.info' => {'version': version},
        'core.get_methods' => {
          for (final method in methods)
            method: {
              'job': false,
              'uploadable': false,
              'downloadable': false,
              'no_auth_required': false,
              ...?metadata[method],
            },
        },
        _ => values[name],
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
      timeSettingsNow: () => now,
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

TimeSettingsRequest _request(
  TimeSettingsInventory i,
  TimeSettingsAction action,
) => switch (action) {
  TimeSettingsAction.timezone => TimeSettingsRequest(
    inventory: i,
    action: action,
    timezone: 'Asia/Seoul',
  ),
  TimeSettingsAction.createNtp => TimeSettingsRequest(
    inventory: i,
    action: action,
    settings: const NtpServerSettings(address: 'new.pool.example'),
  ),
  TimeSettingsAction.updateNtp => TimeSettingsRequest(
    inventory: i,
    action: action,
    server: i.servers.first,
    settings: const NtpServerSettings(
      address: 'changed.pool.example',
      prefer: true,
    ),
  ),
  TimeSettingsAction.deleteNtp => TimeSettingsRequest(
    inventory: i,
    action: action,
    server: i.servers.first,
  ),
};
Future<TimeSettingsReview> _review(
  _Harness h, [
  TimeSettingsAction action = TimeSettingsAction.timezone,
]) async => h.repo.reviewTimeSettings(
  _request(await h.repo.loadTimeSettings(), action),
);
Future<TimeSettingsResult> _execute(_Harness h, TimeSettingsReview review) => h
    .repo
    .executeTimeSettings(review, review.target, isCurrent: () => h.authorized);
Iterable<Map<String, dynamic>> _sent(_Harness h) =>
    h.wire.calls.where((c) => _writes.contains(c['method']));
Matcher _reason(TimeSettingsExceptionReason reason) =>
    isA<TimeSettingsException>().having((e) => e.reason, 'reason', reason);

void main() {
  test('time disconnected requires authentication', () async {
    final h = _Harness(_Wire());
    addTearDown(h.repo.close);
    expect(h.repo.timeSettingsCapabilities.supported, isFalse);
    await expectLater(
      h.repo.loadTimeSettings(),
      throwsA(_reason(TimeSettingsExceptionReason.notAuthenticated)),
    );
  });
  for (final version in [
    '25.04.2',
    '25.10-RC.1',
    '25.10.1-MASTER',
    '26.04.0',
    'unknown',
  ]) {
    test('time stable version rejects $version', () async {
      final h = await _connected(configure: (w) => w.version = version);
      expect(h.repo.timeSettingsCapabilities.supported, isFalse);
      await expectLater(
        h.repo.loadTimeSettings(),
        throwsA(_reason(TimeSettingsExceptionReason.unsupportedVersion)),
      );
    });
  }
  for (final method in _reads) {
    test('time missing public read $method disables inventory', () async {
      final h = await _connected(configure: (w) => w.methods.remove(method));
      expect(h.repo.timeSettingsCapabilities.supported, isFalse);
      await expectLater(
        h.repo.loadTimeSettings(),
        throwsA(_reason(TimeSettingsExceptionReason.unavailableMethod)),
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
      test('time unsafe public read $method $flag fails closed', () async {
        final h = await _connected(
          configure: (w) => w.metadata[method] = {flag: true},
        );
        expect(h.repo.timeSettingsCapabilities.supported, isFalse);
      });
    }
  }
  for (final action in TimeSettingsAction.values) {
    final method = _writes[action.index];
    test(
      'time action-specific missing $method keeps readonly inventory',
      () async {
        final h = await _connected(configure: (w) => w.methods.remove(method));
        expect(h.repo.timeSettingsCapabilities.supported, isTrue);
        expect(h.repo.timeSettingsCapabilities.supports(action), isFalse);
        final inventory = await h.repo.loadTimeSettings();
        await expectLater(
          h.repo.reviewTimeSettings(_request(inventory, action)),
          throwsA(_reason(TimeSettingsExceptionReason.unavailableMethod)),
        );
        expect(_sent(h), isEmpty);
      },
    );
    for (final flag in [
      'job',
      'uploadable',
      'downloadable',
      'no_auth_required',
      'private',
      '_private',
      'check_pipes',
    ]) {
      test('time action $action unsafe $flag cannot dispatch', () async {
        final h = await _connected(
          configure: (w) => w.metadata[method] = {flag: true},
        );
        expect(h.repo.timeSettingsCapabilities.supports(action), isFalse);
        expect((await h.repo.loadTimeSettings()).timezone, 'UTC');
      });
    }
    test(
      'time $action exact response and independent readback completes',
      () async {
        final h = await _connected();
        final review = await _review(h, action);
        expect(review.target, contains(_host));
        expect(_sent(h), isEmpty);
        final priorQueries = h.wire.counts['system.ntpserver.query']!;
        final result = await _execute(h, review);
        expect(result.outcome, TimeSettingsOutcome.completed);
        expect(result.message, contains('not NTP synchronization'));
        expect(result.message, isNot(contains(_secret)));
        expect(_sent(h), hasLength(1));
        expect(_sent(h).single['method'], method);
        final params = _sent(h).single['params'];
        switch (action) {
          case TimeSettingsAction.timezone:
            expect(params, [
              {'timezone': 'Asia/Seoul'},
            ]);
          case TimeSettingsAction.createNtp:
            expect(params, [
              {
                'address': 'new.pool.example',
                'burst': false,
                'iburst': true,
                'prefer': false,
                'minpoll': 6,
                'maxpoll': 10,
                'force': false,
              },
            ]);
          case TimeSettingsAction.updateNtp:
            expect(params, [
              1,
              {
                'address': 'changed.pool.example',
                'burst': false,
                'iburst': true,
                'prefer': true,
                'minpoll': 6,
                'maxpoll': 10,
                'force': false,
              },
            ]);
          case TimeSettingsAction.deleteNtp:
            expect(params, [1]);
        }
        expect(h.wire.counts['system.ntpserver.query'], priorQueries + 2);
        expect(
          h.wire.calls.where(
            (c) => !{
              ..._all,
              'auth.login_ex',
              'system.info',
              'core.get_methods',
              'core.ping',
            }.contains(c['method']),
          ),
          isEmpty,
        );
        expect(
          (await _execute(h, review)).outcome,
          TimeSettingsOutcome.rejected,
        );
        expect((await h.repo.loadTimeSettings()).blockedReason, isNull);
      },
    );
    for (final mode in [
      'error',
      'throw',
      'timeout',
      'stale-readback',
      'session',
      'foreground',
      'null-receipt',
    ]) {
      test('time $action postdispatch $mode is terminal unknown', () async {
        final h = await _connected();
        final review = await _review(h, action);
        switch (mode) {
          case 'error':
            h.wire.fault = method;
          case 'throw':
            h.wire.throwMethod = method;
          case 'timeout':
            h.wire.hold = method;
            h.wire.held = Completer<void>();
          case 'stale-readback':
            h.wire.mutate = false;
          case 'session':
            h.wire.afterWrite = (_) => h.wire.current = false;
          case 'foreground':
            h.wire.afterWrite = (_) => h.authorized = false;
          case 'null-receipt':
            h.wire.overrideReceipt = true;
        }
        final result = await _execute(h, review);
        expect(result.outcome, TimeSettingsOutcome.unknown);
        expect(result.message, isNot(contains(_secret)));
        h.wire.current = true;
        h.authorized = true;
        h.wire.held?.complete();
        await Future<void>.delayed(Duration.zero);
        await expectLater(
          h.repo.loadTimeSettings(),
          throwsA(_reason(TimeSettingsExceptionReason.busy)),
        );
        expect(
          (await _execute(h, review)).outcome,
          TimeSettingsOutcome.rejected,
        );
        expect(_sent(h), hasLength(1));
      });
    }
  }
  _projectionTests();
  _leaseTests();
  _readbackTests();
}

void _projectionTests() {
  test('time snapshot bounded immutable projection omits nested private certificate', () async {
    final h = await _connected();
    final i = await h.repo.loadTimeSettings();
    expect(i.timezone, 'UTC');
    expect(i.timezones, ['America/New_York', 'Asia/Seoul', 'UTC']);
    expect(i.guiRollbackKnown, isTrue);
    expect(i.guiRollbackSeconds, isNull);
    expect(() => i.servers.clear(), throwsUnsupportedError);
    expect(() => i.timezones.clear(), throwsUnsupportedError);
    expect(() => i.environments.clear(), throwsUnsupportedError);
    expect(() => i.rebootReasonCodes.add('evil'), throwsUnsupportedError);
    final query = h.wire.calls.lastWhere(
      (c) => c['method'] == 'system.ntpserver.query',
    );
    expect(query['params'], [
      [],
      {
        'limit': 129,
        'select': [
          'id',
          'address',
          'burst',
          'iburst',
          'prefer',
          'minpoll',
          'maxpoll',
        ],
      },
    ]);
    expect(_sent(h), isEmpty);
  });
  test('readonly role never attempts write-role GUI rollback read', () async {
    final h = await _connected(
      configure: (w) => w.values['auth.me'] = {
        'privilege': {
          'roles': ['READONLY_ADMIN'],
        },
      },
    );
    final i = await h.repo.loadTimeSettings();
    expect(i.fullAdmin, isFalse);
    expect(i.guiRollbackKnown, isFalse);
    expect(i.timezoneBlockedReason, isNotNull);
    expect(h.wire.counts['system.general.checkin_waiting'], isNull);
    await expectLater(
      h.repo.reviewTimeSettings(_request(i, TimeSettingsAction.createNtp)),
      throwsA(_reason(TimeSettingsExceptionReason.invalidRequest)),
    );
  });
  test(
    'missing rollback metadata permits NTP and disables timezone only',
    () async {
      final h = await _connected(
        configure: (w) => w.methods.remove('system.general.checkin_waiting'),
      );
      final i = await h.repo.loadTimeSettings();
      expect(i.guiRollbackKnown, isFalse);
      expect(i.timezoneBlockedReason, isNotNull);
      expect(i.blockedReason, isNull);
      expect(h.repo.timeSettingsCapabilities.canChangeTimezone, isFalse);
      final review = await h.repo.reviewTimeSettings(
        _request(i, TimeSettingsAction.createNtp),
      );
      expect(
        (await _execute(h, review)).outcome,
        TimeSettingsOutcome.completed,
      );
      expect(h.wire.counts['system.general.checkin_waiting'], isNull);
    },
  );
  for (final pending in [0, 1, 300]) {
    test('pending GUI rollback $pending blocks timezone but not NTP', () async {
      final h = await _connected();
      h.wire.values['system.general.checkin_waiting'] = pending;
      final i = await h.repo.loadTimeSettings();
      expect(i.timezoneBlockedReason, isNotNull);
      await expectLater(
        h.repo.reviewTimeSettings(_request(i, TimeSettingsAction.timezone)),
        throwsA(_reason(TimeSettingsExceptionReason.invalidRequest)),
      );
      final review = await h.repo.reviewTimeSettings(
        _request(i, TimeSettingsAction.deleteNtp),
      );
      expect(
        (await _execute(h, review)).outcome,
        TimeSettingsOutcome.completed,
      );
    });
  }
  final malformed = <String, Object?>{
    'system.general.config': {
      'timezone': 'UTC\n',
      'ui_certificate': {'privatekey': _secret},
    },
    'system.general.timezone_choices': {'UTC': 'notUTC'},
    'system.ntpserver.query': [_row(1), _row(1)],
    'system.general.checkin_waiting': true,
    'auth.me': {
      'privilege': {'roles': null},
    },
    'system.host_id': '$_host\n',
    'system.reboot.info': {'boot_id': _secret, 'reboot_required_reasons': []},
  };
  for (final entry in malformed.entries) {
    test('malformed time projection ${entry.key} is sanitized', () async {
      final h = await _connected();
      h.wire.values[entry.key] = entry.value;
      await expectLater(
        h.repo.loadTimeSettings(),
        throwsA(
          isA<TimeSettingsException>().having(
            (e) => e.toString(),
            'safe',
            isNot(contains(_secret)),
          ),
        ),
      );
      expect(_sent(h), isEmpty);
    });
  }
  for (final resource in [
    'rows',
    'zones',
    'row-id',
    'row-address',
    'row-type',
    'poll',
    'rollback',
  ]) {
    test('time projection bounds reject hostile $resource', () async {
      final h = await _connected();
      switch (resource) {
        case 'rows':
          h.wire.values['system.ntpserver.query'] = List.generate(
            129,
            (i) => _row(i + 1),
          );
        case 'zones':
          h.wire.values['system.general.timezone_choices'] = {
            for (var i = 0; i < 2049; i++) 'Zone$i': 'Zone$i',
          };
        case 'row-id':
          h.wire.values['system.ntpserver.query'] = [
            {..._row(1), 'id': 9007199254740992},
          ];
        case 'row-address':
          h.wire.values['system.ntpserver.query'] = [
            _row(1, 'host\npool attacker'),
          ];
        case 'row-type':
          h.wire.values['system.ntpserver.query'] = [
            {..._row(1), 'burst': 'false'},
          ];
        case 'poll':
          h.wire.values['system.ntpserver.query'] = [
            {..._row(1), 'minpoll': -65},
          ];
        case 'rollback':
          h.wire.values['system.general.checkin_waiting'] = -1;
      }
      await expectLater(
        h.repo.loadTimeSettings(),
        throwsA(isA<TimeSettingsException>()),
      );
    });
  }
  test(
    'legacy IPv6 and poll bounds remain readonly or removable, not editable',
    () async {
      final h = await _connected();
      h.wire.values['system.ntpserver.query'] = [
        {..._row(1, '2001:db8::1'), 'minpoll': 2},
        _row(2),
      ];
      final i = await h.repo.loadTimeSettings();
      expect(i.servers.first.settings.validationError, isNotNull);
      final request = TimeSettingsRequest(
        inventory: i,
        action: TimeSettingsAction.updateNtp,
        server: i.servers.first,
        settings: i.servers.first.settings,
      );
      await expectLater(
        h.repo.reviewTimeSettings(request),
        throwsA(_reason(TimeSettingsExceptionReason.invalidRequest)),
      );
      final review = await h.repo.reviewTimeSettings(
        _request(i, TimeSettingsAction.deleteNtp),
      );
      expect(
        (await _execute(h, review)).outcome,
        TimeSettingsOutcome.completed,
      );
    },
  );
  for (final change in ['host', 'boot', 'admin', 'state']) {
    test('identity drift after time data read fails closed $change', () async {
      final h = await _connected();
      h.wire.beforeReply = (method, count) {
        if (method != 'system.ntpserver.query') return;
        switch (change) {
          case 'host':
            h.wire.values['system.host_id'] = 'f' * 64;
          case 'boot':
            h.wire.values['system.reboot.info'] = {
              'boot_id': '11111111-2222-4333-8444-666666666666',
              'reboot_required_reasons': [],
            };
          case 'admin':
            h.wire.values['auth.me'] = {
              'privilege': {'roles': []},
            };
          case 'state':
            h.wire.values['system.state'] = 'BOOTING';
        }
      };
      await expectLater(
        h.repo.loadTimeSettings(),
        throwsA(_reason(TimeSettingsExceptionReason.staleReview)),
      );
    });
  }
}

void _leaseTests() {
  for (final mode in [
    'wrong-target',
    'forged',
    'reload',
    'expiry',
    'clock-back',
    'session',
    'foreground',
    'throw-callback',
  ]) {
    test('one-use time review rejects $mode without mutation', () async {
      final h = await _connected();
      var review = await _review(h);
      var target = review.target;
      switch (mode) {
        case 'wrong-target':
          target = 'TIMEZONE';
        case 'forged':
          review = TimeSettingsReview(
            request: review.request,
            endpoint: review.endpoint,
            warnings: [],
          );
        case 'reload':
          await h.repo.loadTimeSettings();
        case 'expiry':
          h.now = h.now.add(const Duration(minutes: 6));
        case 'clock-back':
          h.now = h.now.subtract(const Duration(seconds: 1));
        case 'session':
          h.wire.current = false;
        case 'foreground':
          h.authorized = false;
      }
      final result = await h.repo.executeTimeSettings(
        review,
        target,
        isCurrent: () {
          if (mode == 'throw-callback') throw StateError(_secret);
          return h.authorized;
        },
      );
      expect(result.outcome, TimeSettingsOutcome.rejected);
      expect(result.message, isNot(contains(_secret)));
      h.now = DateTime.utc(2026, 9, 14);
      h.wire.current = true;
      h.authorized = true;
      expect((await _execute(h, review)).outcome, TimeSettingsOutcome.rejected);
      expect(_sent(h), isEmpty);
    });
  }
  for (final method in {..._reads, 'system.general.checkin_waiting'}) {
    for (final cancel in ['foreground', 'session', 'expiry']) {
      test('time preflight $method cancellation $cancel never sends', () async {
        final h = await _connected();
        final review = await _review(h);
        h.wire.beforeReply = (name, _) {
          if (name != method) return;
          switch (cancel) {
            case 'foreground':
              h.authorized = false;
            case 'session':
              h.wire.current = false;
            case 'expiry':
              h.now = h.now.add(const Duration(minutes: 6));
          }
        };
        expect(
          (await _execute(h, review)).outcome,
          TimeSettingsOutcome.rejected,
        );
        expect(_sent(h), isEmpty);
      });
    }
  }
  test(
    'final readiness reply must still have foreground and five minute lease',
    () async {
      final h = await _connected();
      final review = await _review(h);
      final initial = h.wire.counts['system.state']!;
      h.wire.beforeReply = (method, count) {
        if (method == 'system.state' && count == initial + 3) {
          h.now = h.now.add(const Duration(minutes: 6));
        }
      };
      expect((await _execute(h, review)).outcome, TimeSettingsOutcome.rejected);
      expect(_sent(h), isEmpty);
    },
  );
  for (final method in {..._reads, 'system.general.checkin_waiting'}) {
    test(
      'time preflight remote error $method sanitized with zero writes',
      () async {
        final h = await _connected();
        final review = await _review(h);
        h.wire.fault = method;
        final result = await _execute(h, review);
        expect(result.outcome, TimeSettingsOutcome.rejected);
        expect(result.message, isNot(contains(_secret)));
        expect(_sent(h), isEmpty);
      },
    );
  }
  test('time preflight timeout late reply never dispatches', () async {
    final h = await _connected();
    final review = await _review(h);
    h.wire.hold = 'system.ntpserver.query';
    h.wire.held = Completer<void>();
    expect((await _execute(h, review)).outcome, TimeSettingsOutcome.rejected);
    h.wire.held!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(_sent(h), isEmpty);
  });
  test('another session cannot reuse time inventory or review', () async {
    final a = await _connected(), b = await _connected();
    final i = await a.repo.loadTimeSettings();
    await expectLater(
      b.repo.reviewTimeSettings(_request(i, TimeSettingsAction.timezone)),
      throwsA(_reason(TimeSettingsExceptionReason.staleReview)),
    );
    final review = await a.repo.reviewTimeSettings(
      _request(i, TimeSettingsAction.timezone),
    );
    expect((await _execute(b, review)).outcome, TimeSettingsOutcome.rejected);
    expect(_sent(a), isEmpty);
    expect(_sent(b), isEmpty);
  });
  test(
    'new review invalidates old time review and close clears workspace',
    () async {
      final h = await _connected();
      final old = await _review(h);
      final fresh = await h.repo.reviewTimeSettings(old.request);
      expect((await _execute(h, old)).outcome, TimeSettingsOutcome.rejected);
      await h.repo.close();
      expect(h.repo.timeSettingsCapabilities.supported, isFalse);
      await expectLater(
        _execute(h, fresh),
        throwsA(_reason(TimeSettingsExceptionReason.notAuthenticated)),
      );
    },
  );
}

void _readbackTests() {
  for (final action in TimeSettingsAction.values) {
    for (final change in [
      'extra-row',
      'missing-row',
      'other-row',
      'timezone',
      'host',
      'gui-pending',
      'read-fault',
    ]) {
      test('time $action unexpected postwrite $change is unknown', () async {
        final h = await _connected();
        final review = await _review(h, action);
        h.wire.afterWrite = (_) {
          final rows = h.wire.values['system.ntpserver.query'] as List;
          switch (change) {
            case 'extra-row':
              rows.add(_row(99));
            case 'missing-row':
              rows.removeLast();
            case 'other-row':
              (rows.last as Map)['address'] = 'unexpected.pool.example';
            case 'timezone':
              h.wire.values['system.general.config'] = {
                'timezone': 'America/New_York',
                'ui_certificate': {'privatekey': _secret},
              };
            case 'host':
              h.wire.values['system.host_id'] = 'f' * 64;
            case 'gui-pending':
              h.wire.values['system.general.checkin_waiting'] = 0;
            case 'read-fault':
              h.wire.fault = 'system.ntpserver.query';
          }
        };
        expect(
          (await _execute(h, review)).outcome,
          TimeSettingsOutcome.unknown,
        );
        expect(_sent(h), hasLength(1));
      });
    }
  }
  for (final action in [
    TimeSettingsAction.createNtp,
    TimeSettingsAction.updateNtp,
  ]) {
    for (final receipt in <Object?>[
      true,
      71,
      {},
      _row(2),
      {..._row(3), 'minpoll': '6'},
      {'id': 3, ..._row(3, 'wrong.pool.example')},
    ]) {
      test(
        'time $action malformed or mismatched receipt ${receipt.hashCode} unknown',
        () async {
          final h = await _connected();
          final review = await _review(h, action);
          h.wire.overrideReceipt = true;
          h.wire.receipt = receipt;
          expect(
            (await _execute(h, review)).outcome,
            TimeSettingsOutcome.unknown,
          );
          expect(_sent(h), hasLength(1));
        },
      );
    }
  }
  test('snapshot order does not matter but IDs/settings must match', () async {
    final h = await _connected();
    final review = await _review(h, TimeSettingsAction.createNtp);
    h.wire.afterWrite = (_) => h.wire.values['system.ntpserver.query'] =
        (h.wire.values['system.ntpserver.query'] as List).reversed.toList();
    expect((await _execute(h, review)).outcome, TimeSettingsOutcome.completed);
  });
  test('review says probe, partial service failures and configuration-only sources', () async {
    final h = await _connected();
    final review = await _review(h, TimeSettingsAction.createNtp);
    final text = review.warnings.join(' ');
    for (final warning in [
      'IPv4 NTP request',
      'Force is always false',
      'never public servers',
      'database change',
      'DHCP',
      'sources.d',
      'not prove time synchronization',
      'No private peer/probe',
    ]) {
      expect(text, contains(warning));
    }
    expect(text, isNot(contains(_secret)));
    expect(() => review.warnings.clear(), throwsUnsupportedError);
    expect(_sent(h), isEmpty);
  });
}
