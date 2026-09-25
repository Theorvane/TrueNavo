import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _secret = 'SYNTHETIC_CERTIFICATE_PRIVATE_MATERIAL';
const _mutations = {
  'system.general.update',
  'system.ntpserver.create',
  'system.ntpserver.update',
  'system.ntpserver.delete',
};
const _forbidden = {
  'system.ntpserver.test_ntp_server',
  'system.ntpserver.peers',
  'system.general.checkin',
  'system.general.rollback',
  'system.general.ui_restart',
  'service.control',
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
  'system.general.config',
  'system.general.timezone_choices',
  'system.general.checkin_waiting',
  'system.ntpserver.query',
  ..._mutations,
  ..._forbidden,
  'config.reset',
  'system.reboot',
  'system.shutdown',
  'config.save',
  'core.download',
  'config.upload',
  'auth.generate_token',
};

void main() {
  for (final address in [
    'server.example\n',
    'server.example extra',
    'server.example\tiburst',
    'https://server.example',
    'server.example:123',
    'user@server.example',
    'server.example/path',
    'server.example#comment',
    '*.example',
    '2001:db8::1',
    '[2001:db8::1]',
    'fe80::1%eth0',
  ]) {
    test(
      'unsupported NTP address fails before every review RPC: ${address.length}',
      () async {
        final h = await _connected();
        final inventory = await h.repo.loadTimeSettings();
        final settings = NtpServerSettings(address: address);
        expect(settings.validationError, isNotNull);
        final before = h.wire.calls.length;
        await expectLater(
          h.repo.reviewTimeSettings(
            TimeSettingsRequest(
              inventory: inventory,
              action: TimeSettingsAction.createNtp,
              settings: settings,
            ),
          ),
          throwsA(_timeReason(TimeSettingsExceptionReason.invalidRequest)),
        );
        expect(h.wire.calls.length, before);
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  for (final polls in [(3, 10), (4, 4), (10, 6), (6, 18), (-1, 10)]) {
    test('poll exponents ${polls.$1}/${polls.$2} rejected locally', () async {
      final h = await _connected();
      final inventory = await h.repo.loadTimeSettings();
      final before = h.wire.calls.length;
      await expectLater(
        h.repo.reviewTimeSettings(
          TimeSettingsRequest(
            inventory: inventory,
            action: TimeSettingsAction.createNtp,
            settings: NtpServerSettings(
              address: 'new.example',
              minPoll: polls.$1,
              maxPoll: polls.$2,
            ),
          ),
        ),
        throwsA(_timeReason(TimeSettingsExceptionReason.invalidRequest)),
      );
      expect(h.wire.calls.length, before);
    });
  }
  test('read-only inventory skips WRITE-role GUI check and drops nested certificate material', () async {
    final h = await _connected();
    h.wire.admin = false;
    final inventory = await h.repo.loadTimeSettings();
    expect(inventory.fullAdmin, isFalse);
    expect(inventory.guiRollbackKnown, isFalse);
    expect(inventory.timezone, 'UTC');
    expect(inventory.timezones, ['Asia/Seoul', 'UTC']);
    expect(inventory.servers.map((s) => s.settings.address), [
      'one.example',
      'two.example',
    ]);
    expect(
      h.wire.calls.where(
        (c) => c['method'] == 'system.general.checkin_waiting',
      ),
      isEmpty,
    );
    expect(h.wire.writes, isEmpty);
    _expectNoForbidden(h.wire);
  });
  for (final remaining in [0, 1, 60]) {
    test(
      'GUI rollback remaining $remaining is pending not safe timezone state',
      () async {
        final h = await _connected();
        h.wire.rollback = remaining;
        final inventory = await h.repo.loadTimeSettings();
        expect(inventory.guiRollbackKnown, isTrue);
        expect(inventory.guiRollbackSeconds, remaining);
        expect(inventory.timezoneBlockedReason, isNotNull);
        final before = h.wire.calls.length;
        await expectLater(
          h.repo.reviewTimeSettings(
            TimeSettingsRequest(
              inventory: inventory,
              action: TimeSettingsAction.timezone,
              timezone: 'Asia/Seoul',
            ),
          ),
          throwsA(_timeReason(TimeSettingsExceptionReason.invalidRequest)),
        );
        expect(h.wire.calls.length, before);
        _expectNoForbidden(h.wire);
      },
    );
  }
  test('GUI rollback permission error never becomes an all-clear or a checkin mutation', () async {
    final h = await _connected();
    h.wire.errorMethod = 'system.general.checkin_waiting';
    await expectLater(
      h.repo.loadTimeSettings(),
      throwsA(isA<TimeSettingsException>()),
    );
    expect(h.wire.writes, isEmpty);
    _expectNoForbidden(h.wire);
  });
  test(
    'missing GUI-check metadata disables timezone but preserves NTP inventory',
    () async {
      final h = await _connected(
        configure: (wire) =>
            wire.methods.remove('system.general.checkin_waiting'),
      );
      final inventory = await h.repo.loadTimeSettings();
      expect(h.repo.timeSettingsCapabilities.canChangeTimezone, isFalse);
      expect(h.repo.timeSettingsCapabilities.canCreateNtp, isTrue);
      expect(inventory.guiRollbackKnown, isFalse);
      expect(inventory.guiRollbackSeconds, isNull);
      _expectNoForbidden(h.wire);
      expect(h.wire.writes, isEmpty);
    },
  );
  test('timezone dispatch contains only timezone and secret-bearing receipt stays private', () async {
    final h = await _connected();
    final review = await _review(h, TimeSettingsAction.timezone);
    expect(h.wire.writes, isEmpty);
    final result = await h.repo.executeTimeSettings(
      review,
      review.target,
      isCurrent: () => true,
    );
    expect(result.outcome, TimeSettingsOutcome.completed);
    expect(h.wire.writes.single['params'], [
      {'timezone': 'Asia/Seoul'},
    ]);
    expect(result.message, isNot(contains(_secret)));
    expect(result.message, contains('not NTP synchronization'));
    expect((await h.repo.loadTimeSettings()).timezone, 'Asia/Seoul');
    _expectNoForbidden(h.wire);
  });
  for (final action in [
    TimeSettingsAction.createNtp,
    TimeSettingsAction.updateNtp,
  ]) {
    test(
      '$action uses exact exponents and forced-false only at explicit dispatch',
      () async {
        final h = await _connected();
        final review = await _review(h, action);
        expect(h.wire.writes, isEmpty);
        _expectNoForbidden(h.wire);
        final result = await h.repo.executeTimeSettings(
          review,
          review.target,
          isCurrent: () => true,
        );
        expect(result.outcome, TimeSettingsOutcome.completed);
        final parameters = h.wire.writes.single['params'] as List;
        expect(parameters.last, {
          'address': 'new.example',
          'burst': false,
          'iburst': true,
          'prefer': false,
          'minpoll': 4,
          'maxpoll': 17,
          'force': false,
        });
        if (action == TimeSettingsAction.updateNtp) expect(parameters.first, 1);
        _expectNoForbidden(h.wire);
      },
    );
  }
  test('existing IPv6 row remains bounded display data but cannot be edited unchanged', () async {
    final h = await _connected();
    h.wire.rows[0]['address'] = '2001:db8::1';
    final inventory = await h.repo.loadTimeSettings();
    expect(inventory.servers.first.settings.address, '2001:db8::1');
    expect(inventory.servers.first.settings.validationError, isNotNull);
    final request = TimeSettingsRequest(
      inventory: inventory,
      action: TimeSettingsAction.deleteNtp,
      server: inventory.servers.first,
    );
    expect(request.validationError, isNull);
    expect(h.wire.writes, isEmpty);
    _expectNoForbidden(h.wire);
  });
  test('last configured source cannot be deleted and no peer check is used to override', () async {
    final h = await _connected();
    h.wire.rows.removeLast();
    final inventory = await h.repo.loadTimeSettings();
    final before = h.wire.calls.length;
    await expectLater(
      h.repo.reviewTimeSettings(
        TimeSettingsRequest(
          inventory: inventory,
          action: TimeSettingsAction.deleteNtp,
          server: inventory.servers.single,
        ),
      ),
      throwsA(_timeReason(TimeSettingsExceptionReason.invalidRequest)),
    );
    expect(h.wire.calls.length, before);
    _expectNoForbidden(h.wire);
  });
  for (final action in TimeSettingsAction.values) {
    test(
      '$action post-dispatch error fences reset backup restore power and service',
      () async {
        final h = await _connected();
        final review = await _review(h, action);
        h.wire.errorMethod = _method(action);
        final result = await h.repo.executeTimeSettings(
          review,
          review.target,
          isCurrent: () => true,
        );
        expect(result.outcome, TimeSettingsOutcome.unknown);
        expect(result.message, isNot(contains(_secret)));
        final before = h.wire.calls.length;
        await expectLater(
          h.repo.loadConfigurationReset(),
          throwsA(
            isA<ConfigurationResetException>().having(
              (e) => e.reason,
              'reason',
              ConfigurationResetExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.loadConfigurationBackup(),
          throwsA(
            isA<ConfigurationBackupException>().having(
              (e) => e.reason,
              'reason',
              ConfigurationBackupExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.loadConfigurationRestore(),
          throwsA(
            isA<ConfigurationRestoreException>().having(
              (e) => e.reason,
              'reason',
              ConfigurationRestoreExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.loadSystemPower(),
          throwsA(
            isA<SystemPowerException>().having(
              (e) => e.reason,
              'reason',
              SystemPowerExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.execute(
            const ServiceControlCommand(
              service: 'smb',
              action: ServiceControlAction.start,
            ),
          ),
          throwsA(
            isA<ManagementException>().having(
              (e) => e.reason,
              'reason',
              ManagementExceptionReason.busy,
            ),
          ),
        );
        expect(
          (await h.repo.executeTimeSettings(
            review,
            review.target,
            isCurrent: () => true,
          )).outcome,
          TimeSettingsOutcome.rejected,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(h.wire.calls.length, before);
        expect(h.wire.writes, hasLength(1));
        _expectNoForbidden(h.wire);
      },
    );
  }
  test(
    'terminal reset blocks a pre-issued time review without a time mutation',
    () async {
      final h = await _connected();
      final time = await _review(h, TimeSettingsAction.createNtp);
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
        (await h.repo.executeTimeSettings(
          time,
          time.target,
          isCurrent: () => true,
        )).outcome,
        TimeSettingsOutcome.rejected,
      );
      expect(h.wire.calls.length, before);
      expect(h.wire.writes, isEmpty);
    },
  );
}

Matcher _timeReason(TimeSettingsExceptionReason reason) =>
    isA<TimeSettingsException>().having((e) => e.reason, 'reason', reason);
void _expectNoForbidden(_Wire wire) =>
    expect(wire.calls.where((c) => _forbidden.contains(c['method'])), isEmpty);
String _method(TimeSettingsAction action) => switch (action) {
  TimeSettingsAction.timezone => 'system.general.update',
  TimeSettingsAction.createNtp => 'system.ntpserver.create',
  TimeSettingsAction.updateNtp => 'system.ntpserver.update',
  TimeSettingsAction.deleteNtp => 'system.ntpserver.delete',
};
Future<TimeSettingsReview> _review(
  _Harness h,
  TimeSettingsAction action,
) async {
  final inventory = await h.repo.loadTimeSettings();
  return h.repo.reviewTimeSettings(
    TimeSettingsRequest(
      inventory: inventory,
      action: action,
      timezone: action == TimeSettingsAction.timezone ? 'Asia/Seoul' : null,
      server:
          action == TimeSettingsAction.updateNtp ||
              action == TimeSettingsAction.deleteNtp
          ? inventory.servers.first
          : null,
      settings:
          action == TimeSettingsAction.createNtp ||
              action == TimeSettingsAction.updateNtp
          ? const NtpServerSettings(
              address: 'new.example',
              minPoll: 4,
              maxPoll: 17,
            )
          : null,
    ),
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

Map<String, Object?> _row(int id, String address) => {
  'id': id,
  'address': address,
  'burst': false,
  'iburst': true,
  'prefer': false,
  'minpoll': 6,
  'maxpoll': 10,
};

class _Wire
    implements
        RpcTransport,
        ConfigurationBackupDownloadTransport,
        ConfigurationRestoreUploadTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final methods = {..._methods};
  final rows = [_row(1, 'one.example'), _row(2, 'two.example')];
  bool admin = true;
  String timezone = 'UTC';
  Object? rollback;
  String? errorMethod;
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
  }) => throw StateError('Unexpected synthetic file transfer');
  @override
  Future<int> uploadConfigurationRestore({
    required String token,
    required Uint8List bytes,
  }) {
    bytes.fillRange(0, bytes.length, 0);
    throw StateError('Unexpected synthetic file transfer');
  }

  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(request);
    final method = request['method'] as String,
        params = request['params'] as List? ?? [];
    if (method == errorMethod) {
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
          for (final name in methods)
            name: {
              'job': [
                'config.reset',
                'system.reboot',
                'system.shutdown',
                'config.save',
                'config.upload',
                'service.control',
              ].contains(name),
              'uploadable': name == 'config.upload',
              'downloadable': name == 'config.save',
              'private':
                  name == 'system.ntpserver.peers' ||
                  name == 'system.ntpserver.test_ntp_server' ||
                  name == 'system.general.rollback',
              'no_auth_required': false,
            },
        };
      case 'auth.me':
        value = {
          'privilege': {
            'roles': [admin ? 'FULL_ADMIN' : 'READONLY_ADMIN'],
          },
          'private': _secret,
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
      case 'system.general.config':
        value = {
          'timezone': timezone,
          'ui_certificate': {'privatekey': _secret},
          'ui_address': [_secret],
          'pwenc_check': _secret,
        };
      case 'system.general.timezone_choices':
        value = {'UTC': 'UTC', 'Asia/Seoul': 'Asia/Seoul'};
      case 'system.general.checkin_waiting':
        value = rollback;
      case 'system.ntpserver.query':
        value = rows;
      case 'system.general.update':
        timezone = (params.single as Map)['timezone'] as String;
        value = {
          'timezone': timezone,
          'ui_certificate': {'privatekey': _secret},
        };
      case 'system.ntpserver.create':
        final created = Map<String, Object?>.from(params.single as Map)
          ..remove('force');
        created['id'] = 3;
        rows.add(created);
        value = created;
      case 'system.ntpserver.update':
        final edited = Map<String, Object?>.from(params.last as Map)
          ..remove('force');
        edited['id'] = params.first;
        rows[rows.indexWhere((r) => r['id'] == params.first)] = edited;
        value = edited;
      case 'system.ntpserver.delete':
        rows.removeWhere((r) => r['id'] == params.first);
        value = true;
      case 'config.reset':
        value = 71;
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
