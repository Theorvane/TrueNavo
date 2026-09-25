import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _boot = '11111111-2222-4333-8444-555555555555';
const _secret = 'SYNTHETIC_OTHER_PROVIDER_SECRET';
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
  'alertservice.query',
};
const _writes = {
  'alertservice.create',
  'alertservice.update',
  'alertservice.delete',
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
Map<String, Object?> _mail({
  int id = 1,
  bool enabled = false,
  String recipient = 'owner@example.test',
}) => {
  'id': id,
  'name': 'Operations',
  'level': 'WARNING',
  'enabled': enabled,
  'type__title': 'Email',
  'attributes': {'type': 'Mail', 'email': recipient},
};
Map<String, Object?> _other() => {
  'id': 2,
  'name': 'Chat',
  'level': 'CRITICAL',
  'enabled': true,
  'type__title': 'Slack',
  'attributes': {'type': 'Slack', 'url': _secret},
};

class _Wire implements RpcTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final methods = <String>{..._reads, ..._writes};
  final metadata = <String, Map<String, Object?>>{};
  final counts = <String, int>{};
  List<Map<String, Object?>> rows = [_mail(), _other()];
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
  };
  String version = '25.10.1';
  bool current = true, mutate = true, overrideReceipt = false, reverse = false;
  Object? receipt, queryOverride;
  String? fault, throwMethod, hold;
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
            'error': {
              'code': -32000,
              'message': _secret,
              'data': {'credentials': _secret},
            },
          }),
        );
      }
      return;
    }
    Object? value;
    if (method == 'alertservice.query') {
      final params = call['params'] as List,
          filters = params[0] as List,
          options = params[1] as Map;
      final select = (options['select'] as List).cast<String>();
      expect(options['limit'], 129);
      expect(options['force_sql_filters'], isNot(true));
      if (filters.isEmpty) {
        expect(select, ['id', 'name', 'level', 'enabled', 'type__title']);
      } else {
        expect(filters, [
          ['attributes.type', '=', 'Mail'],
        ]);
        expect(select, ['id', 'name', 'level', 'enabled', 'attributes']);
      }
      final selected = rows.where(
        (r) => filters.isEmpty || (r['attributes'] as Map)['type'] == 'Mail',
      );
      value =
          queryOverride ??
          [
            for (final r in reverse ? selected.toList().reversed : selected)
              {for (final key in select) key: r[key]},
          ];
    } else if (_writes.contains(method)) {
      final params = call['params'] as List;
      if (method == 'alertservice.delete') {
        value = true;
        if (mutate) rows.removeWhere((r) => r['id'] == params[0]);
      } else {
        final id = method == 'alertservice.create' ? 91 : params[0] as int;
        final row = <String, Object?>{
          'id': id,
          'type__title': 'Email',
          ...(params.last as Map).cast<String, Object?>(),
        };
        value = row;
        if (mutate) {
          rows.removeWhere((r) => r['id'] == id);
          rows.add(row);
        }
      }
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
      alertSettingsNow: () => now,
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

const _newSettings = EmailAlertServiceSettings(
  name: 'Reviewed notifications',
  recipient: 'reviewed@example.test',
  level: AlertDeliveryLevel.error,
);
Future<AlertSettingsReview> _review(
  _Harness h, {
  AlertSettingsAction action = AlertSettingsAction.editEmail,
}) async {
  final i = await h.repo.loadAlertSettings();
  return h.repo.reviewAlertSettings(
    AlertSettingsRequest(
      inventory: i,
      action: action,
      service: action == AlertSettingsAction.createEmail
          ? null
          : i.services.firstWhere((s) => s.id == 1),
      settings:
          action == AlertSettingsAction.createEmail ||
              action == AlertSettingsAction.editEmail
          ? _newSettings
          : null,
    ),
  );
}

Future<AlertSettingsResult> _execute(_Harness h, AlertSettingsReview r) =>
    h.repo.executeAlertSettings(r, r.target, isCurrent: () => h.authorized);
List<Map<String, dynamic>> _sent(_Harness h) =>
    h.wire.calls.where((c) => _writes.contains(c['method'])).toList();
Matcher _reason(AlertSettingsExceptionReason reason) =>
    isA<AlertSettingsException>().having((e) => e.reason, 'reason', reason);

void main() {
  test('disconnected capability and load reject without connecting', () async {
    final r = TrueNasSessionRepository(connector: _Connector(_Wire()));
    addTearDown(r.close);
    expect(r.alertSettingsCapabilities.supported, isFalse);
    await expectLater(
      r.loadAlertSettings(),
      throwsA(_reason(AlertSettingsExceptionReason.notAuthenticated)),
    );
  });
  test(
    'safe projections expose only Mail recipient and immutable summaries',
    () async {
      final h = await _connected();
      final i = await h.repo.loadAlertSettings();
      expect(i.services.map((s) => s.type), ['Mail', 'Slack']);
      expect(i.services.first.recipient, 'owner@example.test');
      expect(i.services.last.recipient, isNull);
      expect(i.services.last.supportedEmail, isFalse);
      expect(i.readinessBlockedReason, isNull);
      expect(i.hostId, _host);
      expect(i.bootId, _boot);
      expect(() => i.services.clear(), throwsUnsupportedError);
      expect(() => i.environments.clear(), throwsUnsupportedError);
      expect(() => i.rebootReasonCodes.clear(), throwsUnsupportedError);
      expect(_sent(h), isEmpty);
      expect(
        h.wire.calls.where((c) => c['method'] == 'alertservice.query'),
        hasLength(2),
      );
    },
  );
  for (final action in AlertSettingsAction.values) {
    test(
      'exact full envelope and independent complete readback $action',
      () async {
        final h = await _connected(
          configure: (w) {
            if (action == AlertSettingsAction.disableEmail) {
              w.rows[0] = _mail(enabled: true);
            }
          },
        );
        final r = await _review(h, action: action);
        expect(r.warnings.join(' '), contains('queued'));
        expect(() => r.warnings.clear(), throwsUnsupportedError);
        final result = await _execute(h, r);
        expect(result.outcome, AlertSettingsOutcome.completed);
        expect(result.message, contains('configuration only'));
        final call = _sent(h).single;
        if (action == AlertSettingsAction.deleteEmail) {
          expect(call['params'], [1]);
        } else {
          final payload = (call['params'] as List).last as Map;
          final edited =
              action == AlertSettingsAction.createEmail ||
              action == AlertSettingsAction.editEmail;
          expect(payload, {
            'name': edited ? _newSettings.name : 'Operations',
            'attributes': {
              'type': 'Mail',
              'email': edited ? _newSettings.recipient : 'owner@example.test',
            },
            'level': edited ? 'ERROR' : 'WARNING',
            'enabled': action == AlertSettingsAction.enableEmail,
          });
        }
        expect(_sent(h), hasLength(1));
        expect((await _execute(h, r)).outcome, AlertSettingsOutcome.rejected);
        expect(_sent(h), hasLength(1));
        await h.repo.loadAlertSettings();
        expect(
          h.wire.calls.any(
            (c) => [
              'alertservice.test',
              'mail.send',
              'alert.send_alerts',
            ].contains(c['method']),
          ),
          isFalse,
        );
      },
    );
  }
  for (final level in AlertDeliveryLevel.values) {
    test('minimum severity roundtrip $level', () async {
      final h = await _connected();
      final i = await h.repo.loadAlertSettings();
      final r = await h.repo.reviewAlertSettings(
        AlertSettingsRequest(
          inventory: i,
          action: AlertSettingsAction.editEmail,
          service: i.services.first,
          settings: EmailAlertServiceSettings(
            name: 'Changed',
            recipient: 'r@example.test',
            level: level,
          ),
        ),
      );
      expect((await _execute(h, r)).outcome, AlertSettingsOutcome.completed);
      expect(
        ((_sent(h).single['params'] as List).last as Map)['level'],
        level.name.toUpperCase(),
      );
    });
  }
  for (final reason in [
    'lease',
    'endpoint',
    'confirmation',
    'clock forward',
    'clock backward',
    'callback false',
    'callback throws',
  ]) {
    test('single-use rejected before dispatch: $reason', () async {
      final h = await _connected();
      var r = await _review(h);
      var confirmation = r.target;
      if (reason == 'lease' || reason == 'endpoint') {
        r = AlertSettingsReview(
          request: r.request,
          endpoint: reason == 'endpoint' ? 'https://other.example' : r.endpoint,
          warnings: r.warnings,
        );
      }
      if (reason == 'confirmation') confirmation = 'EDIT EMAIL ALERT';
      if (reason == 'clock forward') {
        h.now = h.now.add(const Duration(minutes: 5, microseconds: 1));
      }
      if (reason == 'clock backward') {
        h.now = h.now.subtract(const Duration(microseconds: 1));
      }
      final result = await h.repo.executeAlertSettings(
        r,
        confirmation,
        isCurrent: () {
          if (reason == 'callback throws') throw StateError(_secret);
          return reason != 'callback false';
        },
      );
      expect(result.outcome, AlertSettingsOutcome.rejected);
      expect(result.message, isNot(contains(_secret)));
      expect(_sent(h), isEmpty);
      expect((await _execute(h, r)).outcome, AlertSettingsOutcome.rejected);
      expect(_sent(h), isEmpty);
    });
  }
  test(
    'exact five minute boundary accepted, final-await expiry rejected',
    () async {
      final h = await _connected();
      final r = await _review(h);
      h.now = h.now.add(const Duration(minutes: 5));
      expect((await _execute(h, r)).outcome, AlertSettingsOutcome.completed);
      final newer = await _review(h, action: AlertSettingsAction.enableEmail);
      h.wire.beforeReply = (method, count) {
        if (method == 'system.state') {
          h.now = h.now.add(const Duration(minutes: 6));
        }
      };
      expect((await _execute(h, newer)).outcome, AlertSettingsOutcome.rejected);
      expect(_sent(h), hasLength(1));
    },
  );
  for (final method in _reads) {
    for (final fault in ['cancel', 'disconnect', 'error', 'throw', 'expire']) {
      test('final preflight $method $fault never dispatches', () async {
        final h = await _connected();
        final r = await _review(h);
        if (fault == 'error') {
          h.wire.fault = method;
        } else if (fault == 'throw') {
          h.wire.throwMethod = method;
        } else {
          h.wire.beforeReply = (m, n) {
            if (m == method) {
              if (fault == 'cancel') {
                h.authorized = false;
              } else if (fault == 'disconnect') {
                h.wire.current = false;
              } else {
                h.now = h.now.add(const Duration(minutes: 6));
              }
            }
          };
        }
        final result = await _execute(h, r);
        expect(result.outcome, AlertSettingsOutcome.rejected);
        expect(result.message, isNot(contains(_secret)));
        expect(_sent(h), isEmpty);
      });
    }
  }
  for (final method in _reads) {
    for (final defect in [
      'missing',
      'job',
      'upload',
      'download',
      'unauthenticated',
      'private',
      'pipes',
    ]) {
      test('read capability fail closed $method $defect', () async {
        final h = await _connected(
          configure: (w) {
            if (defect == 'missing') {
              w.methods.remove(method);
            } else {
              w.metadata[method] = {
                switch (defect) {
                  'job' => 'job',
                  'upload' => 'uploadable',
                  'download' => 'downloadable',
                  'unauthenticated' => 'no_auth_required',
                  'private' => 'private',
                  _ => 'check_pipes',
                }: defect == 'pipes'
                    ? ['input']
                    : true,
              };
            }
          },
        );
        expect(h.repo.alertSettingsCapabilities.supported, isFalse);
        await expectLater(
          h.repo.loadAlertSettings(),
          throwsA(_reason(AlertSettingsExceptionReason.unavailableMethod)),
        );
        expect(_sent(h), isEmpty);
      });
    }
  }
  for (final method in _writes) {
    test('missing $method gates only related action', () async {
      final h = await _connected(configure: (w) => w.methods.remove(method));
      expect(h.repo.alertSettingsCapabilities.supported, isTrue);
      expect(
        h.repo.alertSettingsCapabilities.supports(
          method == 'alertservice.create'
              ? AlertSettingsAction.createEmail
              : method == 'alertservice.delete'
              ? AlertSettingsAction.deleteEmail
              : AlertSettingsAction.editEmail,
        ),
        isFalse,
      );
      await h.repo.loadAlertSettings();
      expect(_sent(h), isEmpty);
    });
  }
  for (final version in [
    '24.10.2',
    '25.04.2',
    '25.10-BETA',
    '25.10.1-MASTER',
    '26.04.0',
  ]) {
    test('unsupported version $version', () async {
      final h = await _connected(configure: (w) => w.version = version);
      expect(h.repo.alertSettingsCapabilities.supported, isFalse);
      await expectLater(
        h.repo.loadAlertSettings(),
        throwsA(_reason(AlertSettingsExceptionReason.unsupportedVersion)),
      );
    });
  }
  for (final method in _writes) {
    for (final defect in [
      'error',
      'throw',
      'timeout',
      'bad receipt',
      'no write',
      'cancel after write',
      'read error',
    ]) {
      test('post-dispatch $method $defect is terminal unknown', () async {
        final h = await _connected();
        final action = method == 'alertservice.create'
            ? AlertSettingsAction.createEmail
            : method == 'alertservice.delete'
            ? AlertSettingsAction.deleteEmail
            : AlertSettingsAction.editEmail;
        final r = await _review(h, action: action);
        switch (defect) {
          case 'error':
            h.wire.fault = method;
          case 'throw':
            h.wire.throwMethod = method;
          case 'timeout':
            h.wire.hold = method;
            h.wire.held = Completer<void>();
          case 'bad receipt':
            h.wire.overrideReceipt = true;
            h.wire.receipt = {'secret': _secret};
          case 'no write':
            h.wire.mutate = false;
          case 'cancel after write':
            h.wire.afterWrite = () => h.authorized = false;
          case 'read error':
            h.wire.afterWrite = () => h.wire.fault = 'alertservice.query';
        }
        final result = await _execute(h, r);
        expect(result.outcome, AlertSettingsOutcome.unknown);
        expect(result.message, isNot(contains(_secret)));
        expect(_sent(h), hasLength(1));
        h.authorized = true;
        h.wire.fault = null;
        h.wire.throwMethod = null;
        await expectLater(
          h.repo.loadAlertSettings(),
          throwsA(_reason(AlertSettingsExceptionReason.busy)),
        );
        expect((await _execute(h, r)).outcome, AlertSettingsOutcome.rejected);
        expect(_sent(h), hasLength(1));
        h.wire.held?.complete();
        await Future<void>.delayed(Duration.zero);
      });
    }
  }
  for (final change in [
    'host',
    'boot',
    'version',
    'state',
    'admin',
    'ha',
    'job',
    'boot pool',
    'environment',
    'reason',
    'add',
    'remove',
    'recipient',
    'name',
    'level',
    'enabled',
    'provider',
    'unknown provider title',
  ]) {
    test('full before proof detects $change', () async {
      final h = await _connected();
      final r = await _review(h);
      switch (change) {
        case 'host':
          h.wire.values['system.host_id'] = 'f' * 64;
        case 'boot':
          h.wire.values['system.reboot.info'] = {
            'boot_id': 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
            'reboot_required_reasons': [],
          };
        case 'version':
          h.wire.values['system.version_short'] = '25.10.2';
        case 'state':
          h.wire.values['system.state'] = 'BOOTING';
        case 'admin':
          h.wire.values['auth.me'] = {
            'privilege': {
              'roles': ['READONLY_ADMIN'],
            },
          };
        case 'ha':
          h.wire.values['failover.licensed'] = true;
        case 'job':
          h.wire.values['core.get_jobs'] = [
            {'id': 40, 'method': 'other.job', 'state': 'RUNNING'},
          ];
        case 'boot pool':
          h.wire.values['boot.get_state'] = {
            'name': 'other',
            'healthy': true,
            'status': 'ONLINE',
            'scan': null,
          };
        case 'environment':
          h.wire.values['boot.environment.query'] = [
            {..._environment(), 'keep': false},
          ];
        case 'reason':
          h.wire.values['system.reboot.info'] = {
            'boot_id': _boot,
            'reboot_required_reasons': [
              {'code': 'TEST', 'reason': 'Test'},
            ],
          };
        case 'add':
          h.wire.rows.add({..._other(), 'id': 7});
        case 'remove':
          h.wire.rows.removeLast();
        case 'recipient':
          h.wire.rows[0]['attributes'] = {
            'type': 'Mail',
            'email': 'changed@example.test',
          };
        case 'name':
          h.wire.rows[1]['name'] = 'Changed';
        case 'level':
          h.wire.rows[1]['level'] = 'INFO';
        case 'enabled':
          h.wire.rows[1]['enabled'] = false;
        case 'provider':
          h.wire.rows[0] = {..._other(), 'id': 1, 'name': 'Operations'};
        case 'unknown provider title':
          h.wire.rows[1]['type__title'] = 'UnknownFutureProvider';
      }
      expect((await _execute(h, r)).outcome, AlertSettingsOutcome.rejected);
      expect(_sent(h), isEmpty);
    });
  }
  for (final change in [
    'added row',
    'removed other',
    'changed other',
    'title drift',
    'host',
    'jobs',
    'same name extra',
  ]) {
    test('independent post-read detects $change without retry', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.afterWrite = () {
        switch (change) {
          case 'added row':
            h.wire.rows.add({..._other(), 'id': 9});
          case 'removed other':
            h.wire.rows.removeWhere((v) => v['id'] == 2);
          case 'changed other':
            h.wire.rows.firstWhere((v) => v['id'] == 2)['enabled'] = false;
          case 'title drift':
            h.wire.rows.firstWhere((v) => v['id'] == 2)['type__title'] =
                'FutureProvider';
          case 'host':
            h.wire.values['system.host_id'] = 'f' * 64;
          case 'jobs':
            h.wire.values['core.get_jobs'] = [
              {'id': 30, 'method': 'other.job', 'state': 'RUNNING'},
            ];
          case 'same name extra':
            h.wire.rows.add({..._mail(id: 9), 'name': _newSettings.name});
        }
      };
      expect((await _execute(h, r)).outcome, AlertSettingsOutcome.unknown);
      expect(_sent(h), hasLength(1));
    });
  }
  for (final bad in [
    null,
    true,
    {},
    [null],
    [_mail(), _mail()],
    List.generate(129, (n) => _mail(id: n + 1)),
  ]) {
    test(
      'malformed bounded query ${bad.runtimeType} ${bad is List ? bad.length : 0}',
      () async {
        final h = await _connected();
        h.wire.queryOverride = bad ?? false;
        await expectLater(
          h.repo.loadAlertSettings(),
          throwsA(isA<AlertSettingsException>()),
        );
        expect(_sent(h), isEmpty);
      },
    );
  }
  for (final change in [
    'id',
    'name',
    'level',
    'enabled',
    'title',
    'type',
    'recipient controls',
    'extra attrs',
  ]) {
    test('malformed or unsupported row $change', () async {
      final h = await _connected(
        configure: (w) {
          switch (change) {
            case 'id':
              w.rows[0]['id'] = 0;
            case 'name':
              w.rows[0]['name'] = 'bad\nname';
            case 'level':
              w.rows[0]['level'] = 'warning';
            case 'enabled':
              w.rows[0]['enabled'] = 'false';
            case 'title':
              w.rows[0]['type__title'] = null;
            case 'type':
              w.rows[0]['attributes'] = {'type': 'Slack', 'url': _secret};
            case 'recipient controls':
              w.rows[0]['attributes'] = {
                'type': 'Mail',
                'email': 'bad\nrecipient',
              };
            case 'extra attrs':
              w.rows[0]['attributes'] = {
                'type': 'Mail',
                'email': 'owner@example.test',
                'password': _secret,
              };
          }
        },
      );
      if (change == 'recipient controls' || change == 'extra attrs') {
        final i = await h.repo.loadAlertSettings();
        expect(i.services.first.supportedEmail, isFalse);
        expect(
          AlertSettingsRequest(
            inventory: i,
            action: AlertSettingsAction.deleteEmail,
            service: i.services.first,
          ).validationError,
          isNotNull,
        );
      } else {
        await expectLater(
          h.repo.loadAlertSettings(),
          throwsA(isA<AlertSettingsException>()),
        );
      }
      expect(_sent(h), isEmpty);
    });
  }
  test('query ordering is immaterial; non-Mail secrets are never requested or compared', () async {
    final h = await _connected();
    final r = await _review(h);
    h.wire.reverse = true;
    (h.wire.rows[1]['attributes'] as Map)['url'] = 'CHANGED_PRIVATE_VALUE';
    expect((await _execute(h, r)).outcome, AlertSettingsOutcome.completed);
  });
  test('Mail title alone cannot authorize a non-Mail row', () async {
    final h = await _connected(
      configure: (w) => w.rows[1]['type__title'] = 'Email',
    );
    await expectLater(
      h.repo.loadAlertSettings(),
      throwsA(_reason(AlertSettingsExceptionReason.staleReview)),
    );
  });
  test(
    'actual Mail without source Email title cannot disappear from details',
    () async {
      final h = await _connected(
        configure: (w) => w.rows[0]['type__title'] = 'Other',
      );
      await expectLater(
        h.repo.loadAlertSettings(),
        throwsA(_reason(AlertSettingsExceptionReason.staleReview)),
      );
    },
  );
  test('no Mail rows still issues safe Mail-only query and permits disabled create', () async {
    final h = await _connected(configure: (w) => w.rows = [_other()]);
    final r = await _review(h, action: AlertSettingsAction.createEmail);
    expect((await _execute(h, r)).outcome, AlertSettingsOutcome.completed);
  });
  test(
    'overlapping read rejects and old reviewed inventory becomes stale',
    () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.hold = 'alertservice.query';
      h.wire.held = Completer<void>();
      final load = h.repo.loadAlertSettings();
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        h.repo.loadAlertSettings(),
        throwsA(_reason(AlertSettingsExceptionReason.busy)),
      );
      expect((await _execute(h, r)).outcome, AlertSettingsOutcome.rejected);
      h.wire.hold = null;
      h.wire.held!.complete();
      await load;
      expect((await _execute(h, r)).outcome, AlertSettingsOutcome.rejected);
      expect(_sent(h), isEmpty);
    },
  );
  test('closing clears capability and prevents old review execution', () async {
    final h = await _connected();
    final r = await _review(h);
    await h.repo.close();
    expect(h.repo.alertSettingsCapabilities.supported, isFalse);
    await expectLater(
      _execute(h, r),
      throwsA(_reason(AlertSettingsExceptionReason.notAuthenticated)),
    );
  });
}
