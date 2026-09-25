import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

// Synthetic public-schema fixtures only; no provider or NAS connection.
const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _secret = 'SYNTHETIC_PROVIDER_SECRET';
const _mutations = {
  'alertservice.create',
  'alertservice.update',
  'alertservice.delete',
};
const _forbidden = {
  'alertservice.test',
  'mail.send',
  'mail.config',
  'mail.update',
  'mail.send_mail_queue',
  'alert.send_alerts',
  'alert.process_alerts',
  'alertclasses.update',
  'support.new_ticket',
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
  'alertservice.query',
  ..._mutations,
  ..._forbidden,
  'config.reset',
  'config.save',
  'core.download',
  'config.upload',
  'auth.generate_token',
  'system.reboot',
  'system.shutdown',
  'system.general.config',
  'system.general.timezone_choices',
  'system.general.checkin_waiting',
  'system.ntpserver.query',
  'system.ntpserver.create',
  'system.ntpserver.update',
  'system.ntpserver.delete',
  'system.general.update',
  'service.control',
  'alertclasses.config',
  'alert.list_categories',
  'alert.list_policies',
  'support.is_available',
  'support.is_available_and_enabled',
};

void main() {
  test('all nine provider inventory headers never request credentials or return protected fields', () async {
    final h = await _connected();
    final inventory = await h.repo.loadNotificationProviders();
    expect(inventory.services, hasLength(9));
    expect(
      inventory.services.map((s) => s.provider).toSet(),
      NotificationProviderType.values.toSet(),
    );
    expect(h.wire.detailTypes, isEmpty);
    for (final row in inventory.services) {
      expect('${row.name} ${row.type}', isNot(contains(_secret)));
    }
    final requests = h.wire.calls.where(
      (c) => c['method'] == 'alertservice.query',
    );
    expect(requests, isNotEmpty);
    for (final request in requests) {
      expect((request['params'] as List).first, isEmpty);
      final options = (request['params'] as List).last as Map;
      expect(options['select'], [
        'id',
        'name',
        'level',
        'enabled',
        'type__title',
      ]);
      expect(options['limit'], 129);
    }
    expect(() => inventory.services.clear(), throwsUnsupportedError);
    _noEffects(h.wire);
  });
  for (final provider in NotificationProviderType.values) {
    for (final action in [
      NotificationProvidersAction.create,
      NotificationProvidersAction.replace,
    ]) {
      test(
        '${provider.wireName} $action uses full disabled envelope and write-only fresh capsule',
        () async {
          final h = await _connected();
          final inventory = await h.repo.loadNotificationProviders();
          final credentials = NotificationProviderCredentials(
            provider: provider,
            values: _credentials(provider, fresh: true),
          );
          final request = NotificationProvidersRequest(
            inventory: inventory,
            action: action,
            service: action == NotificationProvidersAction.replace
                ? _service(inventory, provider)
                : null,
            settings: NotificationProviderSettings(
              provider: provider,
              name: 'New ${provider.wireName}',
              level: AlertDeliveryLevel.critical,
              fields: _fields(provider),
            ),
            credentials: credentials,
          );
          expect(request.validationError, isNull);
          final review = await h.repo.reviewNotificationProviders(request);
          final public =
              '${review.destinationSummary} ${review.publicFields} ${review.warnings} ${review.target} $credentials';
          for (final value in _credentials(
            provider,
            fresh: true,
          ).values.where((v) => v.isNotEmpty)) {
            expect(public, isNot(contains(value)));
          }
          expect(h.wire.writes, isEmpty);
          final result = await h.repo.executeNotificationProviders(
            review,
            review.target,
            isCurrent: () => true,
          );
          expect(result.outcome, NotificationProvidersOutcome.completed);
          expect(credentials.isDisposed, isTrue);
          final envelope = {
            'name': 'New ${provider.wireName}',
            'level': 'CRITICAL',
            'enabled': false,
            'attributes': _attributes(provider, fresh: true),
          };
          final params = h.wire.writes.single['params'];
          expect(
            params,
            action == NotificationProvidersAction.create
                ? [envelope]
                : [provider.index + 1, envelope],
          );
          expect(result.message, isNot(contains(_secret)));
          _noEffects(h.wire);
        },
      );
    }
  }
  for (final provider in NotificationProviderType.values) {
    test(
      '${provider.wireName} masked stored secret cannot authorize enable or echo details',
      () async {
        final h = await _connected(
          configure: (w) {
            final attrs = w.rows[provider.index]['attributes'] as Map;
            attrs[_credentials(provider).keys.first] = '********';
          },
        );
        final inventory = await h.repo.loadNotificationProviders();
        await expectLater(
          h.repo.reviewNotificationProviders(
            NotificationProvidersRequest(
              inventory: inventory,
              action: NotificationProvidersAction.enable,
              service: _service(inventory, provider),
            ),
          ),
          throwsA(isA<NotificationProvidersException>()),
        );
        expect(h.wire.writes, isEmpty);
        _noEffects(h.wire);
      },
    );
  }
  for (final provider in NotificationProviderType.values) {
    test(
      '${provider.wireName} unknown attributes are never silently dropped on full update',
      () async {
        final h = await _connected(
          configure: (w) =>
              (w.rows[provider.index]['attributes'] as Map)['future_secret'] =
                  _secret,
        );
        final inventory = await h.repo.loadNotificationProviders();
        await expectLater(
          h.repo.reviewNotificationProviders(
            NotificationProvidersRequest(
              inventory: inventory,
              action: NotificationProvidersAction.enable,
              service: _service(inventory, provider),
            ),
          ),
          throwsA(isA<NotificationProvidersException>()),
        );
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  test('selected private detail requires both exact ID and actual provider discriminator', () async {
    final h = await _connected();
    final inventory = await h.repo.loadNotificationProviders();
    final review = await h.repo.reviewNotificationProviders(
      NotificationProvidersRequest(
        inventory: inventory,
        action: NotificationProvidersAction.enable,
        service: _service(inventory, NotificationProviderType.slack),
      ),
    );
    final details = h.wire.calls.where(
      (c) =>
          c['method'] == 'alertservice.query' &&
          (((c['params'] as List).last as Map)['select'] as List).contains(
            'attributes',
          ),
    );
    expect(details, isNotEmpty);
    for (final request in details) {
      final params = request['params'] as List;
      expect(params.first, [
        ['id', '=', 1],
        ['attributes.type', '=', 'Slack'],
      ]);
      expect((params.last as Map)['limit'], 2);
      expect((params.last as Map)['force_sql_filters'], isNot(true));
    }
    expect(review.publicFields.values.join(' '), isNot(contains(_secret)));
    expect(h.wire.detailTypes, everyElement('Slack'));
    _noEffects(h.wire);
  });
  test('provider type changes behind a matching display title cannot gain Mail or other provider authority', () async {
    final h = await _connected();
    final inventory = await h.repo.loadNotificationProviders();
    h.wire.rows.first['attributes'] = {
      'type': 'Mail',
      'email': 'different@example.org',
    };
    await expectLater(
      h.repo.reviewNotificationProviders(
        NotificationProvidersRequest(
          inventory: inventory,
          action: NotificationProvidersAction.enable,
          service: _service(inventory, NotificationProviderType.slack),
        ),
      ),
      throwsA(isA<NotificationProvidersException>()),
    );
    expect(h.wire.writes, isEmpty);
    expect(h.wire.detailTypes, isEmpty);
  });
  for (final action in [
    NotificationProvidersAction.disable,
    NotificationProvidersAction.delete,
  ]) {
    test(
      'legacy HTTP Slack can $action without conversion, test or credential disclosure',
      () async {
        final h = await _connected(
          configure: (w) {
            w.rows.first['enabled'] =
                action == NotificationProvidersAction.disable;
            (w.rows.first['attributes'] as Map)['url'] =
                'http://hooks.example.invalid/$_secret';
          },
        );
        final inventory = await h.repo.loadNotificationProviders();
        final review = await h.repo.reviewNotificationProviders(
          NotificationProvidersRequest(
            inventory: inventory,
            action: action,
            service: _service(inventory, NotificationProviderType.slack),
          ),
        );
        expect(
          (await h.repo.executeNotificationProviders(
            review,
            review.target,
            isCurrent: () => true,
          )).outcome,
          NotificationProvidersOutcome.completed,
        );
        if (action == NotificationProvidersAction.disable) {
          expect((h.wire.writes.single['params'] as List).last, {
            'name': 'Slack path',
            'level': 'WARNING',
            'enabled': false,
            'attributes': {
              'type': 'Slack',
              'url': 'http://hooks.example.invalid/$_secret',
            },
          });
        }
        _noEffects(h.wire);
      },
    );
  }
  test('legacy HTTP webhook cannot be enabled', () async {
    final h = await _connected(
      configure: (w) => (w.rows.first['attributes'] as Map)['url'] =
          'http://hooks.example.invalid/$_secret',
    );
    final inventory = await h.repo.loadNotificationProviders();
    await expectLater(
      h.repo.reviewNotificationProviders(
        NotificationProvidersRequest(
          inventory: inventory,
          action: NotificationProvidersAction.enable,
          service: _service(inventory, NotificationProviderType.slack),
        ),
      ),
      throwsA(isA<NotificationProvidersException>()),
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'SNMPv3 stays read-only instead of silently down-converting authentication',
    () async {
      final h = await _connected(
        configure: (w) =>
            (w.rows.last['attributes'] as Map).addAll(<String, Object?>{
              'v3': true,
              'v3_username': 'user',
              'v3_authkey': _secret,
              'v3_authprotocol': 'SHA',
              'v3_privkey': _secret,
              'v3_privprotocol': 'AESCFB128',
            }),
      );
      final inventory = await h.repo.loadNotificationProviders();
      await expectLater(
        h.repo.reviewNotificationProviders(
          NotificationProvidersRequest(
            inventory: inventory,
            action: NotificationProvidersAction.enable,
            service: _service(inventory, NotificationProviderType.snmpTrap),
          ),
        ),
        throwsA(isA<NotificationProvidersException>()),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test(
    'source credential limit is rejected locally before any review RPC',
    () async {
      final h = await _connected();
      final inventory = await h.repo.loadNotificationProviders();
      final credentials = NotificationProviderCredentials(
        provider: NotificationProviderType.influxDb,
        values: {'password': 'x' * 1025},
      );
      addTearDown(credentials.dispose);
      final request = NotificationProvidersRequest(
        inventory: inventory,
        action: NotificationProvidersAction.create,
        settings: NotificationProviderSettings(
          provider: NotificationProviderType.influxDb,
          name: 'New Influx',
          fields: _fields(NotificationProviderType.influxDb),
        ),
        credentials: credentials,
      );
      expect(request.validationError, isNotNull);
      final before = h.wire.calls.length;
      await expectLater(
        h.repo.reviewNotificationProviders(request),
        throwsA(isA<NotificationProvidersException>()),
      );
      expect(h.wire.calls.length, before);
    },
  );
  test('disposing issued credentials during preflight cannot dispatch an earlier private copy', () async {
    final h = await _connected();
    final inventory = await h.repo.loadNotificationProviders();
    final credentials = NotificationProviderCredentials(
      provider: NotificationProviderType.slack,
      values: _credentials(NotificationProviderType.slack, fresh: true),
    );
    final review = await h.repo.reviewNotificationProviders(
      NotificationProvidersRequest(
        inventory: inventory,
        action: NotificationProvidersAction.create,
        settings: NotificationProviderSettings(
          provider: NotificationProviderType.slack,
          name: 'New Slack',
          fields: _fields(NotificationProviderType.slack),
        ),
        credentials: credentials,
      ),
    );
    h.wire.onCall = (method) {
      if (method == 'auth.me') {
        credentials.dispose();
      }
    };
    final result = await h.repo.executeNotificationProviders(
      review,
      review.target,
      isCurrent: () => true,
    );
    expect(credentials.isDisposed, isTrue);
    expect(result.outcome, NotificationProvidersOutcome.rejected);
    expect(h.wire.writes, isEmpty);
  });
  test('unknown provider submission fences policies, Mail, SMTP and destructive workspaces', () async {
    final h = await _connected();
    final inventory = await h.repo.loadNotificationProviders();
    final review = await h.repo.reviewNotificationProviders(
      NotificationProvidersRequest(
        inventory: inventory,
        action: NotificationProvidersAction.enable,
        service: _service(inventory, NotificationProviderType.slack),
      ),
    );
    h.wire.hold = true;
    final submission = h.repo.executeNotificationProviders(
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
    expect(result.outcome, NotificationProvidersOutcome.unknown);
    expect(result.message, isNot(contains(_secret)));
    await _fenced(h);
    expect(
      (await h.repo.executeNotificationProviders(
        review,
        review.target,
        isCurrent: () => true,
      )).outcome,
      NotificationProvidersOutcome.rejected,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(h.wire.calls.length, before);
    expect(h.wire.writes, hasLength(1));
    _noEffects(h.wire);
  });
}

NotificationProviderSnapshot _service(
  NotificationProvidersInventory i,
  NotificationProviderType p,
) => i.services.singleWhere((s) => s.provider == p);
Map<String, Object?> _fields(NotificationProviderType p) => switch (p) {
  NotificationProviderType.slack => {},
  NotificationProviderType.mattermost => {
    'username': 'Synthetic alerts',
    'channel': '',
  },
  NotificationProviderType.telegram => {
    'chat_ids': [12345, -100000123],
  },
  NotificationProviderType.pagerDuty => {'client_name': 'Synthetic NAS'},
  NotificationProviderType.opsGenie => {},
  NotificationProviderType.victorOps => {},
  NotificationProviderType.awsSns => {
    'region': 'us-east-1',
    'topic_arn': 'arn:aws:sns:us-east-1:123456789012:synthetic',
  },
  NotificationProviderType.influxDb => {
    'host': '192.0.2.10',
    'username': 'synthetic',
    'database': 'alerts',
    'series_name': 'events',
  },
  NotificationProviderType.snmpTrap => {'host': '192.0.2.11', 'port': 162},
};
Map<String, String> _credentials(
  NotificationProviderType p, {
  bool fresh = false,
}) {
  final token = fresh ? '${_secret}_NEW' : _secret;
  return switch (p) {
    NotificationProviderType.slack => {
      'url': 'https://hooks.example.invalid/$token',
    },
    NotificationProviderType.mattermost => {
      'url': 'https://chat.example.invalid/$token',
      'icon_url': '',
    },
    NotificationProviderType.telegram => {'bot_token': '123456:$token'},
    NotificationProviderType.pagerDuty => {'service_key': token},
    NotificationProviderType.opsGenie => {'api_key': token, 'api_url': ''},
    NotificationProviderType.victorOps => {
      'api_key': token,
      'routing_key': '${token}_ROUTE',
    },
    NotificationProviderType.awsSns => {
      'aws_access_key_id': '${token}_ACCESS',
      'aws_secret_access_key': token,
    },
    NotificationProviderType.influxDb => {'password': token},
    NotificationProviderType.snmpTrap => {'community': token},
  };
}

Map<String, Object?> _attributes(
  NotificationProviderType p, {
  bool fresh = false,
}) => {
  'type': p.wireName,
  ..._fields(p),
  ..._credentials(p, fresh: fresh),
  if (p == NotificationProviderType.snmpTrap) ...{
    'v3': false,
    'v3_username': null,
    'v3_authkey': null,
    'v3_privkey': null,
    'v3_authprotocol': null,
    'v3_privprotocol': null,
  },
};
String _title(NotificationProviderType p) => switch (p) {
  NotificationProviderType.awsSns => 'AWS SNS',
  NotificationProviderType.snmpTrap => 'SNMP Trap',
  _ => p.wireName,
};
void _noEffects(_Wire w) =>
    expect(w.calls.where((c) => _forbidden.contains(c['method'])), isEmpty);
Future<void> _fenced(_Harness h) async {
  await expectLater(
    h.repo.loadAlertPolicies(),
    throwsA(isA<AlertPoliciesException>()),
  );
  await expectLater(
    h.repo.loadAlertSettings(),
    throwsA(isA<AlertSettingsException>()),
  );
  await expectLater(
    h.repo.loadEmailSettings(),
    throwsA(isA<EmailSettingsException>()),
  );
  await expectLater(
    h.repo.loadTimeSettings(),
    throwsA(isA<TimeSettingsException>()),
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
    h.repo.loadConfigurationReset(),
    throwsA(isA<ConfigurationResetException>()),
  );
  await expectLater(
    h.repo.loadSystemPower(),
    throwsA(isA<SystemPowerException>()),
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
  final detailTypes = <String>[];
  final rows = <Map<String, Object?>>[
    for (final p in NotificationProviderType.values)
      {
        'id': p.index + 1,
        'name': '${p.wireName} path',
        'type__title': _title(p),
        'level': 'WARNING',
        'enabled': false,
        'attributes': _attributes(p),
      },
  ];
  bool hold = false;
  void Function(String)? onCall;
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
    onCall?.call(method);
    if (method == 'alertservice.update' && hold) {
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
            'roles': ['FULL_ADMIN'],
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
        final filters = params.first as List,
            options = params.last as Map,
            select = options['select'] as List;
        final detail = select.contains('attributes');
        if (options['force_sql_filters'] == true) {
          throw StateError('Unsupported SQL filtering');
        }
        if (detail &&
            (filters.length != 2 ||
                (filters[0] as List)[0] != 'id' ||
                (filters[0] as List)[1] != '=' ||
                (filters[1] as List)[0] != 'attributes.type' ||
                (filters[1] as List)[1] != '=')) {
          throw StateError(
            'Private query must select one exact provider ID and type',
          );
        }
        if (!detail &&
            select.any((v) => v.toString().startsWith('attributes'))) {
          throw StateError('No union partial projection');
        }
        var selected = rows.toList();
        for (final raw in filters) {
          final f = raw as List;
          if (f[0] == 'id') {
            selected = selected.where((r) => r['id'] == f[2]).toList();
          } else if (f[0] == 'attributes.type') {
            selected = selected
                .where((r) => (r['attributes'] as Map)['type'] == f[2])
                .toList();
          } else {
            throw StateError('Unexpected filter');
          }
        }
        if (detail) {
          detailTypes.addAll(
            selected.map((r) => (r['attributes'] as Map)['type'] as String),
          );
        }
        value = [
          for (final row in selected)
            {
              for (final key in select)
                if (row.containsKey(key)) key as String: row[key],
            },
        ];
      case 'alertservice.create':
        final created = Map<String, Object?>.from(params.single as Map);
        final provider = NotificationProviderType.values.singleWhere(
          (p) => p.wireName == (created['attributes'] as Map)['type'],
        );
        created.addAll({'id': 10, 'type__title': _title(provider)});
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
    if (!inbound.isClosed) {
      await inbound.close();
    }
  }
}
