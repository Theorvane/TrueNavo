import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

// Independent synthetic transport. Never opens a NAS/provider connection.
const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _secret = 'SYNTHETIC_PRIVATE_SUPPORT_CONTACT';
const _forbidden = {
  'support.config',
  'support.fields',
  'support.new_ticket',
  'support.update',
  'system.license',
  'system.dmidecode_info',
  'alert.list',
  'alert.send_alerts',
  'alert.process_alerts',
  'alertservice.test',
  'alertservice.create',
  'alertservice.update',
  'alertservice.delete',
  'mail.send',
  'mail.config',
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
  'alert.list_categories',
  'alert.list_policies',
  'alertclasses.config',
  'alertclasses.update',
  'support.is_available',
  'support.is_available_and_enabled',
  ..._forbidden,
  'alertservice.query',
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
  'mail.update',
  'service.control',
};

void main() {
  test('single visible class edit preserves every hidden map key and exact defaults', () async {
    final h = await _connected();
    final review = await _review(
      h,
      'Ordinary',
      overrides: const AlertClassOverrides(
        level: AlertDeliveryLevel.critical,
        policy: AlertPolicyFrequency.hourly,
      ),
    );
    expect(review.request.inventory.unlistedOverrideCount, 2);
    expect(h.wire.writes, isEmpty);
    final result = await h.repo.executeAlertPolicies(
      review,
      review.target,
      isCurrent: () => true,
    );
    expect(
      result.outcome,
      AlertPoliciesOutcome.completed,
      reason: result.message,
    );
    expect(h.wire.writes.single['params'], [
      {
        'classes': {
          'Ordinary': {'level': 'CRITICAL', 'policy': 'HOURLY'},
          'Proactive': {'policy': 'NEVER', 'proactive_support': false},
          'EmptyVisible': <String, Object?>{},
          'HiddenDefault': <String, Object?>{},
          'HiddenSupport': {
            'level': 'ALERT',
            'policy': 'DAILY',
            'proactive_support': true,
          },
        },
      },
    ]);
    expect(result.message, contains('Configuration only'));
    _noEffects(h.wire);
  });
  test('absent override and explicit empty override stay distinct', () async {
    final h = await _connected();
    final inventory = await h.repo.loadAlertPolicies();
    final empty = _class(inventory, 'EmptyVisible'),
        absent = _class(inventory, 'DefaultVisible');
    expect(empty.hasOverride, isTrue);
    expect(absent.hasOverride, isFalse);
    expect(empty.overrides.isEmpty, isTrue);
    expect(absent.overrides.isEmpty, isTrue);
    expect(empty.effectivePolicy, AlertPolicyFrequency.immediately);
    expect(absent.effectivePolicy, AlertPolicyFrequency.immediately);
    final review = await h.repo.reviewAlertPolicies(
      AlertPoliciesRequest(
        inventory: inventory,
        classPolicy: empty,
        action: AlertPoliciesAction.resetClass,
      ),
    );
    expect(
      (await h.repo.executeAlertPolicies(
        review,
        review.target,
        isCurrent: () => true,
      )).outcome,
      AlertPoliciesOutcome.completed,
    );
    expect(h.wire.classes.containsKey('EmptyVisible'), isFalse);
    expect(h.wire.classes.containsKey('DefaultVisible'), isFalse);
    expect(h.wire.classes['HiddenDefault'], isEmpty);
    expect(h.wire.classes, hasLength(4));
  });
  test(
    'choosing no explicit fields keeps target empty while reset removes it',
    () async {
      final h = await _connected();
      final review = await _review(
        h,
        'Ordinary',
        overrides: const AlertClassOverrides(),
      );
      expect(
        (await h.repo.executeAlertPolicies(
          review,
          review.target,
          isCurrent: () => true,
        )).outcome,
        AlertPoliciesOutcome.completed,
      );
      expect(h.wire.classes.containsKey('Ordinary'), isTrue);
      expect(h.wire.classes['Ordinary'], isEmpty);
      expect(h.wire.classes['HiddenSupport'], {
        'level': 'ALERT',
        'policy': 'DAILY',
        'proactive_support': true,
      });
      _noEffects(h.wire);
    },
  );
  test('NEVER plus explicit false reset needs disclosure despite ordinary suppression', () async {
    final h = await _connected();
    final inventory = await h.repo.loadAlertPolicies();
    final selected = _class(inventory, 'Proactive');
    expect(selected.effectivePolicy, AlertPolicyFrequency.never);
    expect(selected.effectiveProactiveSupport, isFalse);
    final request = AlertPoliciesRequest(
      inventory: inventory,
      classPolicy: selected,
      action: AlertPoliciesAction.resetClass,
    );
    expect(request.enablesProactiveSupport, isTrue);
    expect(request.validationError, isNotNull);
    final before = h.wire.calls.length;
    await expectLater(
      h.repo.reviewAlertPolicies(request),
      throwsA(isA<AlertPoliciesException>()),
    );
    expect(h.wire.calls.length, before);
    _noEffects(h.wire);
  });
  for (final state in [
    (false, false),
    (true, false),
    (null, null),
    (false, true),
  ]) {
    test(
      'proactive reset requires verified eligible and globally enabled state $state',
      () async {
        final h = await _connected(
          configure: (w) {
            w.available = state.$1;
            w.enabled = state.$2;
          },
        );
        final inventory = await h.repo.loadAlertPolicies();
        final request = AlertPoliciesRequest(
          inventory: inventory,
          classPolicy: _class(inventory, 'Proactive'),
          action: AlertPoliciesAction.resetClass,
          proactiveSupportDisclosureAccepted: true,
        );
        final before = h.wire.calls.length;
        expect(request.validationError, isNotNull);
        await expectLater(
          h.repo.reviewAlertPolicies(request),
          throwsA(isA<AlertPoliciesException>()),
        );
        expect(h.wire.calls.length, before);
        _noEffects(h.wire);
      },
    );
  }
  test(
    'consented reset restores defaults without support ticket or contact reads',
    () async {
      final h = await _connected();
      final review = await _review(
        h,
        'Proactive',
        action: AlertPoliciesAction.resetClass,
        consent: true,
      );
      expect(review.request.enablesProactiveSupport, isTrue);
      final warnings = review.warnings.join(' ');
      expect(warnings, contains('NEVER'));
      expect(warnings.toLowerCase(), contains('support'));
      expect(warnings, isNot(contains(_secret)));
      expect(
        (await h.repo.executeAlertPolicies(
          review,
          review.target,
          isCurrent: () => true,
        )).outcome,
        AlertPoliciesOutcome.completed,
      );
      expect(h.wire.classes.containsKey('Proactive'), isFalse);
      expect(h.wire.classes['HiddenSupport'], {
        'level': 'ALERT',
        'policy': 'DAILY',
        'proactive_support': true,
      });
      _noEffects(h.wire);
    },
  );
  test('missing eligibility methods preserve ordinary editing and block proactive changes', () async {
    final h = await _connected(configure: (w) => w.supportMetadata = false);
    final inventory = await h.repo.loadAlertPolicies();
    expect(inventory.supportAvailable, isNull);
    expect(inventory.supportEnabled, isNull);
    expect(
      h.wire.calls.where((c) => c['method'].toString().startsWith('support.')),
      isEmpty,
    );
    final review = await h.repo.reviewAlertPolicies(
      AlertPoliciesRequest(
        inventory: inventory,
        classPolicy: _class(inventory, 'Ordinary'),
        action: AlertPoliciesAction.configure,
        overrides: const AlertClassOverrides(level: AlertDeliveryLevel.error),
      ),
    );
    expect(
      (await h.repo.executeAlertPolicies(
        review,
        review.target,
        isCurrent: () => true,
      )).outcome,
      AlertPoliciesOutcome.completed,
    );
    _noEffects(h.wire);
  });
  for (final invalid in [
    'Ordinary\n',
    'Ordinary\r',
    'Ordinary Name',
    'Ordinary;other',
  ]) {
    test(
      'malformed hidden class key cannot be copied into full map: ${jsonEncode(invalid)}',
      () async {
        final h = await _connected(
          configure: (w) => w.classes[invalid] = <String, Object?>{},
        );
        await expectLater(
          h.repo.loadAlertPolicies(),
          throwsA(isA<AlertPoliciesException>()),
        );
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  for (final invalid in [
    {'policy': 'WEEKLY'},
    {'level': null},
    {'proactive_support': null},
    {'unknown': _secret},
  ]) {
    test('unknown hidden override fields are not silently dropped', () async {
      final h = await _connected(
        configure: (w) => w.classes['HiddenDefault'] = invalid,
      );
      await expectLater(
        h.repo.loadAlertPolicies(),
        throwsA(isA<AlertPoliciesException>()),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('readonly account cannot rewrite hidden class map', () async {
    final h = await _connected(configure: (w) => w.admin = false);
    final inventory = await h.repo.loadAlertPolicies();
    final before = h.wire.calls.length;
    await expectLater(
      h.repo.reviewAlertPolicies(
        AlertPoliciesRequest(
          inventory: inventory,
          classPolicy: _class(inventory, 'Ordinary'),
          action: AlertPoliciesAction.configure,
          overrides: const AlertClassOverrides(level: AlertDeliveryLevel.error),
        ),
      ),
      throwsA(isA<AlertPoliciesException>()),
    );
    expect(h.wire.calls.length, before);
  });
  test(
    'uncertain full-map write fences every representative peer without replay',
    () async {
      final h = await _connected();
      final review = await _review(
        h,
        'Ordinary',
        overrides: const AlertClassOverrides(
          policy: AlertPolicyFrequency.never,
        ),
      );
      h.wire.hold = true;
      final submission = h.repo.executeAlertPolicies(
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
      expect(result.outcome, AlertPoliciesOutcome.unknown);
      expect(result.message, isNot(contains(_secret)));
      await _fenced(h);
      expect(
        (await h.repo.executeAlertPolicies(
          review,
          review.target,
          isCurrent: () => true,
        )).outcome,
        AlertPoliciesOutcome.rejected,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.wire.calls.length, before);
      expect(h.wire.writes, hasLength(1));
      _noEffects(h.wire);
    },
  );
}

AlertClassPolicySnapshot _class(AlertPoliciesInventory i, String id) =>
    i.classes.singleWhere((c) => c.id == id);
Future<AlertPoliciesReview> _review(
  _Harness h,
  String id, {
  AlertPoliciesAction action = AlertPoliciesAction.configure,
  AlertClassOverrides? overrides,
  bool consent = false,
}) async {
  final inventory = await h.repo.loadAlertPolicies();
  return h.repo.reviewAlertPolicies(
    AlertPoliciesRequest(
      inventory: inventory,
      classPolicy: _class(inventory, id),
      action: action,
      overrides: overrides,
      proactiveSupportDisclosureAccepted: consent,
    ),
  );
}

void _noEffects(_Wire w) =>
    expect(w.calls.where((c) => _forbidden.contains(c['method'])), isEmpty);
Future<void> _fenced(_Harness h) async {
  await expectLater(
    h.repo.loadNotificationProviders(),
    throwsA(isA<NotificationProvidersException>()),
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
  final classes = <String, Object?>{
    'Ordinary': {'level': 'INFO', 'policy': 'HOURLY'},
    'Proactive': {'policy': 'NEVER', 'proactive_support': false},
    'EmptyVisible': <String, Object?>{},
    'HiddenDefault': <String, Object?>{},
    'HiddenSupport': {
      'level': 'ALERT',
      'policy': 'DAILY',
      'proactive_support': true,
    },
  };
  Object? available = true, enabled = true;
  bool admin = true, supportMetadata = true, hold = false;
  final entered = Completer<void>(), release = Completer<void>();
  List<Map<String, dynamic>> get writes =>
      calls.where((c) => c['method'] == 'alertclasses.update').toList();
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
    if (method == 'alertclasses.update' && hold) {
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
            if (supportMetadata || !name.startsWith('support.is_'))
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
      case 'alert.list_categories':
        value = [
          {
            'id': 'Storage',
            'title': 'Storage',
            'classes': [
              for (final id in [
                'Ordinary',
                'Proactive',
                'EmptyVisible',
                'DefaultVisible',
              ])
                {
                  'id': id,
                  'title': id,
                  'level': 'WARNING',
                  'proactive_support': id == 'Proactive',
                },
            ],
          },
        ];
      case 'alert.list_policies':
        value = ['IMMEDIATELY', 'HOURLY', 'DAILY', 'NEVER'];
      case 'alertclasses.config':
        value = {'id': 1, 'classes': classes};
      case 'support.is_available':
        value = available;
      case 'support.is_available_and_enabled':
        value = enabled;
      case 'alertclasses.update':
        classes
          ..clear()
          ..addAll(
            Map<String, Object?>.from((params.single as Map)['classes'] as Map),
          );
        value = {'id': 1, 'classes': classes};
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
