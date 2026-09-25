import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

// In-memory synthetic RPC only. No NAS, SMTP, files or provider contacts.
const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _secret = 'SYNTHETIC_PROVIDER_PRIVATE_ATTRIBUTE';
const _mutations = {
  'alertservice.create',
  'alertservice.update',
  'alertservice.delete',
};
const _forbidden = {
  'alertservice.test',
  'mail.config',
  'mail.update',
  'mail.send',
  'mail.send_raw',
  'mail.send_mail_queue',
  'mail.local_administrators_emails',
  'alert.send_alerts',
  'alert.process_alerts',
  'alertclasses.update',
  'alert.dismiss',
  'alert.restore',
  'core.job_abort',
  'service.control',
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
  'alertservice.query',
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
};

void main() {
  test('all-provider overview excludes nested union credentials before serialization', () async {
    final h = await _connected();
    final inventory = await h.repo.loadAlertSettings();
    expect(inventory.services, hasLength(4));
    final other = inventory.services.where((s) => !s.isEmail).toList();
    expect(other, hasLength(3));
    for (final row in other) {
      expect(row.recipient, isNull);
      expect(row.supportedEmail, isFalse);
      expect(row.blockedReason, isNotNull);
      expect(
        '${row.name} ${row.type} ${row.blockedReason}',
        isNot(contains(_secret)),
      );
    }
    final queries = h.wire.calls
        .where((c) => c['method'] == 'alertservice.query')
        .toList();
    expect(queries, hasLength(2));
    final headOptions = (queries.first['params'] as List).last as Map;
    expect(headOptions['select'], [
      'id',
      'name',
      'level',
      'enabled',
      'type__title',
    ]);
    expect(headOptions['limit'], 129);
    expect(headOptions['force_sql_filters'], isNot(true));
    final details = queries.last['params'] as List;
    expect(
      details.first as List,
      contains(equals(['attributes.type', '=', 'Mail'])),
    );
    final detailOptions = details.last as Map;
    expect(detailOptions['select'], contains('attributes'));
    expect(detailOptions['force_sql_filters'], isNot(true));
    expect(
      inventory.services.singleWhere((s) => s.isEmail).recipient,
      'one@example.org',
    );
    expect(h.wire.writes, isEmpty);
    _noEffects(h.wire);
    expect(() => inventory.services.clear(), throwsUnsupportedError);
  });
  test(
    'no Mail service does not require or return other provider attributes',
    () async {
      final h = await _connected(configure: (w) => w.rows.removeAt(0));
      final inventory = await h.repo.loadAlertSettings();
      expect(
        inventory.services.every((s) => !s.isEmail && s.recipient == null),
        isTrue,
      );
      _noEffects(h.wire);
      expect(h.wire.detailProviderTypes.expand((v) => v), isEmpty);
    },
  );
  test('an Email display-title collision never fetches unsupported provider credentials', () async {
    final h = await _connected(
      configure: (w) => w.rows[1]['type__title'] = 'Email',
    );
    await expectLater(
      h.repo.loadAlertSettings(),
      throwsA(isA<AlertSettingsException>()),
    );
    expect(h.wire.detailProviderTypes.expand((v) => v), everyElement('Mail'));
    expect(h.wire.writes, isEmpty);
    _noEffects(h.wire);
  });
  for (final action in AlertSettingsAction.values) {
    test(
      '$action sends exactly one source-valid Mail lifecycle payload and never a test',
      () async {
        final h = await _connected(
          configure: (w) {
            if (action == AlertSettingsAction.disableEmail) {
              w.rows.first['enabled'] = true;
            }
          },
        );
        final review = await _review(h, action);
        expect(h.wire.writes, isEmpty);
        final warnings = review.warnings.join(' ');
        expect(warnings, contains('queued'));
        expect(warnings, contains('not a guarantee'));
        final result = await h.repo.executeAlertSettings(
          review,
          review.target,
          isCurrent: () => true,
        );
        expect(result.outcome, AlertSettingsOutcome.completed);
        final write = h.wire.writes.single;
        expect(write['method'], _method(action));
        final desired =
            action == AlertSettingsAction.createEmail ||
                action == AlertSettingsAction.editEmail
            ? {
                'name': 'New mail path',
                'attributes': {'type': 'Mail', 'email': 'new@example.org'},
                'level': 'CRITICAL',
                'enabled': false,
              }
            : {
                'name': 'Mail path',
                'attributes': {'type': 'Mail', 'email': 'one@example.org'},
                'level': 'WARNING',
                'enabled': action == AlertSettingsAction.enableEmail,
              };
        expect(write['params'], switch (action) {
          AlertSettingsAction.createEmail => [desired],
          AlertSettingsAction.deleteEmail => [1],
          _ => [1, desired],
        });
        expect(
          h.wire.rows
              .where((r) => r['id'] != 1 && r['id'] != 5)
              .map((r) => r['attributes']),
          [
            {'type': 'Slack', 'url': _secret},
            {'type': 'SNMPTrap', 'community': _secret, 'v3_authkey': _secret},
            {
              'type': 'AWSSNS',
              'aws_access_key_id': _secret,
              'aws_secret_access_key': _secret,
            },
          ],
        );
        expect(result.message, isNot(contains(_secret)));
        expect(result.message, contains('not notification coverage'));
        _noEffects(h.wire);
        final before = h.wire.calls.length;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          h.wire.calls.length,
          before,
          reason: 'No implicit test, dispatch, polling or queue cancellation.',
        );
      },
    );
  }
  for (final action in [
    AlertSettingsAction.editEmail,
    AlertSettingsAction.deleteEmail,
  ]) {
    test(
      'enabled service must be explicitly disabled before $action',
      () async {
        final h = await _connected(
          configure: (w) => w.rows.first['enabled'] = true,
        );
        final inventory = await h.repo.loadAlertSettings();
        final before = h.wire.calls.length;
        await expectLater(
          h.repo.reviewAlertSettings(_request(inventory, action)),
          throwsA(isA<AlertSettingsException>()),
        );
        expect(h.wire.calls.length, before);
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  for (final recipient in [
    '',
    'first@example.org,other@example.org',
    'Name <first@example.org>',
    'first@example.org\n',
    'first@example.org\r\nBcc: victim@example.org',
    'first@localhost',
  ]) {
    test(
      'invalid explicit recipient cannot create an administrator fallback: ${jsonEncode(recipient)}',
      () async {
        final h = await _connected();
        final inventory = await h.repo.loadAlertSettings();
        final before = h.wire.calls.length;
        final settings = EmailAlertServiceSettings(
          name: 'New mail path',
          recipient: recipient,
        );
        expect(settings.validationError, isNotNull);
        await expectLater(
          h.repo.reviewAlertSettings(
            AlertSettingsRequest(
              inventory: inventory,
              action: AlertSettingsAction.createEmail,
              settings: settings,
            ),
          ),
          throwsA(isA<AlertSettingsException>()),
        );
        expect(h.wire.calls.length, before);
        _noEffects(h.wire);
      },
    );
  }
  for (final name in [
    '',
    ' name',
    'name ',
    'bad\nname',
    'bad\u0000name',
    'x' * 121,
  ]) {
    test(
      'invalid service name rejected locally: ${jsonEncode(name)}',
      () async {
        final h = await _connected();
        final inventory = await h.repo.loadAlertSettings();
        final before = h.wire.calls.length;
        await expectLater(
          h.repo.reviewAlertSettings(
            AlertSettingsRequest(
              inventory: inventory,
              action: AlertSettingsAction.createEmail,
              settings: EmailAlertServiceSettings(
                name: name,
                recipient: 'new@example.org',
              ),
            ),
          ),
          throwsA(isA<AlertSettingsException>()),
        );
        expect(h.wire.calls.length, before);
      },
    );
  }
  for (final action in [
    AlertSettingsAction.disableEmail,
    AlertSettingsAction.deleteEmail,
  ]) {
    test(
      'legacy blank recipient can $action without filling or sending an address',
      () async {
        final h = await _connected(
          configure: (w) {
            (w.rows.first['attributes'] as Map)['email'] = '';
            w.rows.first['enabled'] =
                action == AlertSettingsAction.disableEmail;
          },
        );
        final review = await _review(h, action);
        expect(review.request.service!.usesAdministratorFallback, isTrue);
        final result = await h.repo.executeAlertSettings(
          review,
          review.target,
          isCurrent: () => true,
        );
        expect(result.outcome, AlertSettingsOutcome.completed);
        final params = h.wire.writes.single['params'] as List;
        if (action == AlertSettingsAction.disableEmail) {
          expect(params.last, {
            'name': 'Mail path',
            'attributes': {'type': 'Mail', 'email': ''},
            'level': 'WARNING',
            'enabled': false,
          });
        } else {
          expect(params, [1]);
        }
        _noEffects(h.wire);
      },
    );
  }
  test('legacy administrator fallback cannot be enabled', () async {
    final h = await _connected(
      configure: (w) => (w.rows.first['attributes'] as Map)['email'] = '',
    );
    final inventory = await h.repo.loadAlertSettings();
    final before = h.wire.calls.length;
    await expectLater(
      h.repo.reviewAlertSettings(
        _request(inventory, AlertSettingsAction.enableEmail),
      ),
      throwsA(isA<AlertSettingsException>()),
    );
    expect(h.wire.calls.length, before);
  });
  for (final action in [
    AlertSettingsAction.editEmail,
    AlertSettingsAction.enableEmail,
    AlertSettingsAction.disableEmail,
    AlertSettingsAction.deleteEmail,
  ]) {
    test(
      'unsupported providers cannot acquire Mail lifecycle authority: $action',
      () async {
        final h = await _connected();
        final inventory = await h.repo.loadAlertSettings();
        final before = h.wire.calls.length;
        for (final other in inventory.services.where((s) => !s.isEmail)) {
          await expectLater(
            h.repo.reviewAlertSettings(
              AlertSettingsRequest(
                inventory: inventory,
                action: action,
                service: other,
                settings: action == AlertSettingsAction.editEmail
                    ? const EmailAlertServiceSettings(
                        name: 'Converted',
                        recipient: 'new@example.org',
                      )
                    : null,
              ),
            ),
            throwsA(isA<AlertSettingsException>()),
          );
        }
        expect(h.wire.calls.length, before);
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  for (final attributes in [
    {'type': 'Mail', 'email': 'one@example.org', 'password': _secret},
    {'type': 'Mail'},
    {'type': 'Mail', 'email': null},
    {
      'type': 'Mail',
      'email': {'private': _secret},
    },
  ]) {
    test(
      'unsupported Mail attributes never become a lossy replacement',
      () async {
        final h = await _connected(
          configure: (w) => w.rows.first['attributes'] = attributes,
        );
        final inventory = await h.repo.loadAlertSettings();
        final row = inventory.services.singleWhere((s) => s.isEmail);
        expect(row.supportedEmail, isFalse);
        expect(row.blockedReason, isNotNull);
        final before = h.wire.calls.length;
        await expectLater(
          h.repo.reviewAlertSettings(
            _request(inventory, AlertSettingsAction.editEmail),
          ),
          throwsA(isA<AlertSettingsException>()),
        );
        expect(h.wire.calls.length, before);
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  test(
    'read-only inventory does not authorize creating even a disabled service',
    () async {
      final h = await _connected(configure: (w) => w.admin = false);
      final inventory = await h.repo.loadAlertSettings();
      expect(inventory.fullAdmin, isFalse);
      final before = h.wire.calls.length;
      await expectLater(
        h.repo.reviewAlertSettings(
          _request(inventory, AlertSettingsAction.createEmail),
        ),
        throwsA(isA<AlertSettingsException>()),
      );
      expect(h.wire.calls.length, before);
    },
  );
  for (final action in AlertSettingsAction.values) {
    test(
      '$action pending and post-commit error fence other native workspaces',
      () async {
        final h = await _connected(
          configure: (w) {
            if (action == AlertSettingsAction.disableEmail) {
              w.rows.first['enabled'] = true;
            }
          },
        );
        final review = await _review(h, action);
        h.wire.holdMethod = _method(action);
        final submission = h.repo.executeAlertSettings(
          review,
          review.target,
          isCurrent: () => true,
        );
        await h.wire.entered.future.timeout(const Duration(seconds: 2));
        final before = h.wire.calls.length;
        await _fenced(h);
        expect(h.wire.calls.length, before);
        h.wire.release.complete();
        final result = await submission;
        expect(result.outcome, AlertSettingsOutcome.unknown);
        expect(result.message, isNot(contains(_secret)));
        await _fenced(h);
        expect(
          (await h.repo.executeAlertSettings(
            review,
            review.target,
            isCurrent: () => true,
          )).outcome,
          AlertSettingsOutcome.rejected,
        );
        expect(h.wire.calls.length, before);
        expect(h.wire.writes, hasLength(1));
        _noEffects(h.wire);
      },
    );
  }
}

AlertSettingsRequest _request(
  AlertSettingsInventory inventory,
  AlertSettingsAction action,
) => AlertSettingsRequest(
  inventory: inventory,
  action: action,
  service: action == AlertSettingsAction.createEmail
      ? null
      : inventory.services.singleWhere((s) => s.isEmail),
  settings:
      action == AlertSettingsAction.createEmail ||
          action == AlertSettingsAction.editEmail
      ? const EmailAlertServiceSettings(
          name: 'New mail path',
          recipient: 'new@example.org',
          level: AlertDeliveryLevel.critical,
        )
      : null,
);
Future<AlertSettingsReview> _review(
  _Harness h,
  AlertSettingsAction action,
) async => h.repo.reviewAlertSettings(
  _request(await h.repo.loadAlertSettings(), action),
);
String _method(AlertSettingsAction action) => switch (action) {
  AlertSettingsAction.createEmail => 'alertservice.create',
  AlertSettingsAction.deleteEmail => 'alertservice.delete',
  _ => 'alertservice.update',
};
void _noEffects(_Wire w) =>
    expect(w.calls.where((c) => _forbidden.contains(c['method'])), isEmpty);
Future<void> _fenced(_Harness h) async {
  await expectLater(
    h.repo.loadEmailSettings(),
    throwsA(isA<EmailSettingsException>()),
  );
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

Map<String, Object?> _row(
  int id,
  String name,
  String title,
  Map<String, Object?> attributes,
) => {
  'id': id,
  'name': name,
  'level': 'WARNING',
  'enabled': false,
  'type__title': title,
  'attributes': attributes,
};

class _Wire
    implements
        RpcTransport,
        ConfigurationBackupDownloadTransport,
        ConfigurationRestoreUploadTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final detailProviderTypes = <List<Object?>>[];
  final rows = [
    _row(1, 'Mail path', 'Email', {'type': 'Mail', 'email': 'one@example.org'}),
    _row(2, 'Slack path', 'Slack', {'type': 'Slack', 'url': _secret}),
    _row(3, 'SNMP path', 'SNMP Trap', {
      'type': 'SNMPTrap',
      'community': _secret,
      'v3_authkey': _secret,
    }),
    _row(4, 'SNS path', 'AWS SNS', {
      'type': 'AWSSNS',
      'aws_access_key_id': _secret,
      'aws_secret_access_key': _secret,
    }),
  ];
  bool admin = true;
  String? holdMethod;
  final entered = Completer<void>(), release = Completer<void>();
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
  }) => throw StateError('No transfer');
  @override
  Future<int> uploadConfigurationRestore({
    required String token,
    required Uint8List bytes,
  }) {
    bytes.fillRange(0, bytes.length, 0);
    throw StateError('No transfer');
  }

  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(request);
    final method = request['method'] as String,
        params = request['params'] as List? ?? [];
    if (method == holdMethod) {
      entered.complete();
      await release.future;
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
              'private': false,
              'no_auth_required': false,
            },
        };
      case 'auth.me':
        value = {
          'privilege': {
            'roles': [admin ? 'FULL_ADMIN' : 'READONLY_ADMIN'],
          },
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
      case 'alertservice.query':
        final filters = params.first as List, options = params.last as Map;
        final select = options['select'] as List;
        if (options['force_sql_filters'] == true) {
          throw StateError('Mail filtering must follow datastore extension');
        }
        final detail = select.contains('attributes');
        if (detail &&
            !filters.any(
              (f) => jsonEncode(f) == '["attributes.type","=","Mail"]',
            )) {
          throw StateError('Private provider attributes must be Mail-filtered');
        }
        if (!detail &&
            select.any((s) => s.toString().startsWith('attributes'))) {
          throw StateError(
            'Nested provider union cannot serialize missing credential fields',
          );
        }
        var selected = rows.toList();
        for (final raw in filters) {
          final f = raw as List;
          if (f[0] == 'attributes.type' && f[1] == '=') {
            selected = selected
                .where((r) => (r['attributes'] as Map)['type'] == f[2])
                .toList();
          } else if (f[0] == 'id' && f[1] == 'in') {
            selected = selected
                .where((r) => (f[2] as List).contains(r['id']))
                .toList();
          } else {
            throw StateError('Unexpected synthetic filter');
          }
        }
        if (detail) {
          detailProviderTypes.add(
            selected.map((r) => (r['attributes'] as Map)['type']).toList(),
          );
        }
        value = [
          for (final r in selected)
            {
              for (final key in select)
                if (r.containsKey(key)) key as String: r[key],
            },
        ];
      case 'alertservice.create':
        final created = Map<String, Object?>.from(params.single as Map)
          ..addAll({'id': 5, 'type__title': 'Email'});
        rows.add(created);
        value = created;
      case 'alertservice.update':
        final updated = rows.singleWhere((r) => r['id'] == params.first);
        updated.addAll(Map<String, Object?>.from(params.last as Map));
        value = updated;
      case 'alertservice.delete':
        rows.removeWhere((r) => r['id'] == params.single);
        value = true;
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
    if (!inbound.isClosed) await inbound.close();
  }
}
