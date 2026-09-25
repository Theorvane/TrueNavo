import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const host = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const boot = '11111111-2222-4333-8444-555555555555';
const secret = 'SYNTHETIC_PRIVATE_AUXILIARY';
const reads = {
  'system.version_short',
  'system.host_id',
  'system.reboot.info',
  'system.state',
  'failover.licensed',
  'boot.get_state',
  'boot.environment.query',
  'core.get_jobs',
  'auth.me',
  'smb.config',
  'directoryservices.config',
  'system.security.config',
  'sharing.smb.query',
};
Map<String, Object?> smbConfig() => {
  'id': 1,
  'netbiosname': 'NAS',
  'netbiosalias': ['ALIAS'],
  'workgroup': 'WORKGROUP',
  'description': 'Storage',
  'enable_smb1': false,
  'unixcharset': 'UTF-8',
  'localmaster': false,
  'syslog': false,
  'aapl_extensions': true,
  'admin_group': null,
  'guest': 'nobody',
  'filemask': 'DEFAULT',
  'dirmask': 'DEFAULT',
  'ntlmv1_auth': false,
  'multichannel': false,
  'encryption': 'DEFAULT',
  'bindip': <String>[],
  'server_sid': 'S-1-5-21-123-456-789',
  'smb_options': '',
  'debug': false,
};

class SmbWire implements RpcTransport {
  final inbound = StreamController<String>(), calls = <Map<String, dynamic>>[];
  final methods = <String>{...reads, 'smb.update'},
      metadata = <String, Map<String, Object?>>{},
      counts = <String, int>{};
  final values = <String, Object?>{
    'system.version_short': '25.10.1',
    'system.host_id': host,
    'system.reboot.info': {'boot_id': boot, 'reboot_required_reasons': []},
    'system.state': 'READY',
    'failover.licensed': false,
    'boot.get_state': {
      'name': 'boot-pool',
      'healthy': true,
      'status': 'ONLINE',
      'scan': null,
    },
    'boot.environment.query': [
      {
        'id': '25.10.1',
        'dataset': 'boot-pool/ROOT/25.10.1',
        'created': '2026-09-14T01:00:00',
        'used_bytes': 4000,
        'active': true,
        'activated': true,
        'keep': true,
        'can_activate': true,
      },
    ],
    'core.get_jobs': <Object?>[],
    'auth.me': {
      'privilege': {
        'roles': ['FULL_ADMIN'],
      },
      'private': secret,
    },
    'smb.config': smbConfig(),
    'directoryservices.config': <String, Object?>{
      'enable': false,
      'service_type': null,
      'credential': null,
      'configuration': null,
      'kerberos_realm': null,
    },
    'system.security.config': {'enable_fips': false, 'enable_gpos_stig': false},
  };
  Object? shares = <Object?>[
        {'id': 1, 'enabled': true},
        {'id': 2, 'enabled': false},
      ],
      appleCount = 0;
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
    if (method == throwMethod) throw StateError(secret);
    if (method == fault) {
      if (!inbound.isClosed) {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': call['id'],
            'error': {'code': -32000, 'message': secret},
          }),
        );
      }
      return;
    }
    Object? value;
    if (method == 'smb.update') {
      value = {
        ...(values['smb.config'] as Map),
        ...((call['params'] as List).single as Map),
      };
      if (mutate) values['smb.config'] = value;
      afterWrite?.call();
      if (overrideReceipt) value = receipt;
    } else if (method == 'sharing.smb.query') {
      final options = (call['params'] as List)[1] as Map;
      value = options['count'] == true ? appleCount : shares;
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
  final SmbWire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class SmbHarness {
  SmbHarness(this.wire) {
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      smbSettingsNow: () => now,
      managementRequestTimeout: const Duration(milliseconds: 150),
    );
  }
  final SmbWire wire;
  late final TrueNasSessionRepository repo;
  DateTime now = DateTime.utc(2026, 9, 14);
  bool authorized = true;
}

Future<SmbHarness> connected({void Function(SmbWire)? configure}) async {
  final w = SmbWire();
  configure?.call(w);
  final h = SmbHarness(w);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
    isConnectionCurrent: () => w.current,
  );
  return h;
}

SmbGlobalSettings settings(
  SmbSettingsInventory i, {
  String? name,
  String? workgroup,
  String? description,
  bool? multichannel,
  SmbTransportEncryption? encryption,
}) => SmbGlobalSettings(
  netbiosName: name ?? i.config.settings.netbiosName,
  workgroup: workgroup ?? i.config.settings.workgroup,
  description: description ?? 'New description',
  multichannel: multichannel ?? i.config.settings.multichannel,
  encryption: encryption ?? i.config.settings.encryption,
);
Future<SmbSettingsReview> review(
  SmbHarness h, {
  SmbGlobalSettings Function(SmbSettingsInventory)? change,
}) async {
  final i = await h.repo.loadSmbSettings();
  return h.repo.reviewSmbSettings(
    SmbSettingsRequest(inventory: i, settings: change?.call(i) ?? settings(i)),
  );
}

Future<SmbSettingsResult> execute(
  SmbHarness h,
  SmbSettingsReview r, {
  String? confirmation,
}) => h.repo.executeSmbSettings(
  r,
  confirmation ?? r.target,
  isCurrent: () => h.authorized,
);
int writes(SmbHarness h) =>
    h.wire.calls.where((c) => c['method'] == 'smb.update').length;
void main() {
  for (final method in ['directoryservices.config', 'system.security.config']) {
    for (final phase in ['review', 'execute', 'readback']) {
      test('full private $method hidden drift at $phase', () async {
        final h = await connected(
          configure: (w) {
            w.values[method] = <String, Object?>{
              ...(w.values[method] as Map),
              'unprojected': {
                'token': secret,
                'nested': ['first'],
              },
            };
          },
        );
        final i = await h.repo.loadSmbSettings(),
            request = SmbSettingsRequest(inventory: i, settings: settings(i));
        void drift() {
          ((h.wire.values[method] as Map)['unprojected'] as Map)['nested'] = [
            'changed',
          ];
        }

        if (phase == 'review') {
          drift();
          expect(
            h.repo.reviewSmbSettings(request),
            throwsA(isA<SmbSettingsException>()),
          );
          expect(writes(h), 0);
        } else {
          final r = await h.repo.reviewSmbSettings(request);
          if (phase == 'execute') {
            drift();
          } else {
            h.wire.afterWrite = drift;
          }
          final result = await execute(h, r);
          expect(
            result.outcome,
            phase == 'execute'
                ? SmbSettingsOutcome.rejected
                : SmbSettingsOutcome.unknown,
          );
          expect(result.message, isNot(contains(secret)));
          expect(writes(h), phase == 'execute' ? 0 : 1);
        }
      });
    }
    for (final kind in ['depth', 'nodes', 'characters', 'map', 'key']) {
      test('private $method $kind bound rejects safely', () async {
        Object? hostile;
        switch (kind) {
          case 'depth':
            hostile = null;
            for (var n = 0; n < 15; n++) {
              hostile = [hostile];
            }
          case 'nodes':
            hostile = List.generate(5, (_) => List.filled(1000, null));
          case 'characters':
            hostile = 'x' * 131073;
          case 'map':
            hostile = {for (var n = 0; n < 257; n++) '$n': null};
          case 'key':
            hostile = {'x' * 257: null};
        }
        final h = await connected(
          configure: (w) => w.values[method] = <String, Object?>{
            ...(w.values[method] as Map),
            'malformed': hostile,
          },
        );
        expect(
          h.repo.loadSmbSettings(),
          throwsA(
            isA<SmbSettingsException>().having(
              (e) => e.toString(),
              'sanitized',
              isNot(contains(secret)),
            ),
          ),
        );
        expect(writes(h), 0);
      });
    }
  }
  for (final mode in [
    'host',
    'boot',
    'admin',
    'ha',
    'jobs',
    'bootHealth',
    'shareEnabled',
    'shareExtra',
    'appleCount',
  ]) {
    test('fresh $mode drift rejects before mutation', () async {
      final h = await connected();
      final r = await review(h);
      switch (mode) {
        case 'host':
          h.wire.values['system.host_id'] = 'f' * 64;
        case 'boot':
          h.wire.values['system.reboot.info'] = {
            'boot_id': '21111111-2222-4333-8444-555555555555',
            'reboot_required_reasons': [],
          };
        case 'admin':
          h.wire.values['auth.me'] = {
            'privilege': {
              'roles': ['READONLY_ADMIN'],
            },
          };
        case 'ha':
          h.wire.values['failover.licensed'] = true;
        case 'jobs':
          h.wire.values['core.get_jobs'] = [
            {'id': 1, 'method': 'pool.import_pool', 'state': 'RUNNING'},
          ];
        case 'bootHealth':
          (h.wire.values['boot.get_state'] as Map)['healthy'] = false;
        case 'shareEnabled':
          h.wire.shares = [
            {'id': 1, 'enabled': false},
            {'id': 2, 'enabled': false},
          ];
        case 'shareExtra':
          h.wire.shares = [
            {'id': 1, 'enabled': true},
            {'id': 2, 'enabled': false},
            {'id': 3, 'enabled': true},
          ];
        case 'appleCount':
          h.wire.appleCount = 1;
      }
      expect((await execute(h, r)).outcome, SmbSettingsOutcome.rejected);
      expect(writes(h), 0);
    });
  }
  test('forged inventory and cloned review cannot write', () async {
    final h = await connected();
    final i = await h.repo.loadSmbSettings();
    final forged = SmbSettingsInventory(
      readiness: i.readiness,
      config: i.config,
      shares: i.shares,
      directoryConfigured: false,
      securityManaged: false,
      appleDependentShareCount: 0,
    );
    expect(
      h.repo.reviewSmbSettings(
        SmbSettingsRequest(inventory: forged, settings: settings(i)),
      ),
      throwsA(isA<SmbSettingsException>()),
    );
    final r = await h.repo.reviewSmbSettings(
      SmbSettingsRequest(inventory: i, settings: settings(i)),
    );
    expect(
      (await execute(
        h,
        SmbSettingsReview(
          request: r.request,
          endpoint: r.endpoint,
          warnings: r.warnings,
        ),
      )).outcome,
      SmbSettingsOutcome.rejected,
    );
    expect(writes(h), 0);
  });
  test('safe projected inventory and immutable lists', () async {
    final h = await connected();
    final i = await h.repo.loadSmbSettings();
    expect(i.blockedReason, isNull);
    expect(i.config.settings.netbiosName, 'NAS');
    expect(i.shares.length, 2);
    expect(() => i.shares.clear(), throwsUnsupportedError);
    expect(() => i.config.aliases.clear(), throwsUnsupportedError);
    expect(jsonEncode(i.config.aliases), isNot(contains(secret)));
    expect(
      h.wire.calls.map((c) => c['method']),
      isNot(contains('directoryservices.status')),
    );
  });
  test('changed-field-only response and independent readback', () async {
    final h = await connected();
    final r = await review(h);
    expect(r.target, 'UPDATE SMB $host NAS');
    expect((await execute(h, r)).outcome, SmbSettingsOutcome.completed);
    expect(
      h.wire.calls.singleWhere((c) => c['method'] == 'smb.update')['params'],
      [
        {'description': 'New description'},
      ],
    );
    expect(h.wire.counts['smb.config'], 4);
    expect((await execute(h, r)).outcome, SmbSettingsOutcome.rejected);
    expect(writes(h), 1);
  });
  for (final change
      in <String, SmbGlobalSettings Function(SmbSettingsInventory)>{
        'name': (i) => settings(i, name: 'NEWNAS', description: 'Storage'),
        'workgroup': (i) =>
            settings(i, workgroup: 'TEAM', description: 'Storage'),
        'multichannel': (i) =>
            settings(i, multichannel: true, description: 'Storage'),
        'desired': (i) => settings(
          i,
          encryption: SmbTransportEncryption.desired,
          description: 'Storage',
        ),
        'required': (i) => settings(
          i,
          encryption: SmbTransportEncryption.required,
          description: 'Storage',
        ),
      }.entries) {
    test('supports isolated ${change.key}', () async {
      final h = await connected();
      final r = await review(h, change: change.value);
      expect((await execute(h, r)).outcome, SmbSettingsOutcome.completed);
      expect(
        (h.wire.calls.singleWhere((c) => c['method'] == 'smb.update')['params']
                as List)
            .single,
        hasLength(1),
      );
    });
  }
  for (final version in ['24.10.2', '25.04.1', '25.10-BETA.1', '26.04.0']) {
    test('reject version $version', () async {
      final h = await connected(configure: (w) => w.version = version);
      expect(h.repo.smbSettingsCapabilities.supported, isFalse);
      expect(h.repo.loadSmbSettings(), throwsA(isA<SmbSettingsException>()));
      expect(writes(h), 0);
    });
  }
  for (final method in reads) {
    test('missing read $method fails closed', () async {
      final h = await connected(configure: (w) => w.methods.remove(method));
      expect(h.repo.smbSettingsCapabilities.supported, isFalse);
      expect(h.repo.loadSmbSettings(), throwsA(isA<SmbSettingsException>()));
    });
  }
  for (final bad in <String, Object?>{
    'job': true,
    'uploadable': true,
    'downloadable': true,
    'no_auth_required': true,
    'private': true,
    '_private': true,
    'check_pipes': ['input'],
  }.entries) {
    test('malformed update metadata ${bad.key}', () async {
      final h = await connected(
        configure: (w) => w.metadata['smb.update'] = {bad.key: bad.value},
      );
      expect(h.repo.smbSettingsCapabilities.canConfigure, isFalse);
      final i = await h.repo.loadSmbSettings();
      expect(
        h.repo.reviewSmbSettings(
          SmbSettingsRequest(inventory: i, settings: settings(i)),
        ),
        throwsA(isA<SmbSettingsException>()),
      );
      expect(writes(h), 0);
    });
  }
  for (final value in [
    '',
    '123',
    'NAS\n',
    'NAS.foo',
    'NAS/name',
    'NAS name',
    '-NAS',
    'abcdefghijklmnop',
    'BUILTIN',
    'WORLD',
    'NÁS',
  ]) {
    test('invalid name ${jsonEncode(value)} rejected locally', () async {
      final h = await connected();
      final i = await h.repo.loadSmbSettings();
      final n = h.wire.calls.length;
      expect(
        h.repo.reviewSmbSettings(
          SmbSettingsRequest(
            inventory: i,
            settings: settings(i, name: value),
          ),
        ),
        throwsA(isA<SmbSettingsException>()),
      );
      expect(h.wire.calls.length, n);
    });
  }
  for (final desc in ['bad\nline', 'bad\u0000line', 'x' * 121]) {
    test('description bounds ${desc.length}', () async {
      final h = await connected();
      final i = await h.repo.loadSmbSettings();
      expect(
        SmbSettingsRequest(
          inventory: i,
          settings: settings(i, description: desc),
        ).validationError,
        isNotNull,
      );
    });
  }
  for (final field in [
    'smb_options',
    'enable_smb1',
    'ntlmv1_auth',
    'server_sid',
    'guest',
    'admin_group',
  ]) {
    test('protected profile $field read only', () async {
      final h = await connected(
        configure: (w) {
          (w.values['smb.config'] as Map)[field] = switch (field) {
            'smb_options' => secret,
            'server_sid' => null,
            'guest' => 'custom',
            'admin_group' => 'admins',
            _ => true,
          };
        },
      );
      final i = await h.repo.loadSmbSettings();
      expect(i.blockedReason, isNotNull);
      expect(
        h.repo.reviewSmbSettings(
          SmbSettingsRequest(inventory: i, settings: settings(i)),
        ),
        throwsA(isA<SmbSettingsException>()),
      );
      expect(writes(h), 0);
    });
  }
  for (final field in [
    'enable',
    'service_type',
    'credential',
    'configuration',
    'kerberos_realm',
  ]) {
    test('dormant or active directory $field protected', () async {
      final h = await connected(
        configure: (w) => (w.values['directoryservices.config'] as Map)[field] =
            field == 'enable' ? true : secret,
      );
      final i = await h.repo.loadSmbSettings();
      expect(i.directoryConfigured, isTrue);
      expect(i.blockedReason, isNotNull);
    });
  }
  for (final field in ['enable_fips', 'enable_gpos_stig']) {
    test('security policy $field protected', () async {
      final h = await connected(
        configure: (w) =>
            (w.values['system.security.config'] as Map)[field] = true,
      );
      expect((await h.repo.loadSmbSettings()).blockedReason, isNotNull);
    });
  }
  for (final field in [
    'description',
    'netbiosname',
    'workgroup',
    'multichannel',
    'encryption',
    'server_sid',
    'smb_options',
    'admin_group',
    'bindip',
    'netbiosalias',
    'debug',
    'filemask',
  ]) {
    test('private configuration drift $field invalidates review', () async {
      final h = await connected();
      final r = await review(h);
      (h.wire.values['smb.config'] as Map)[field] = switch (field) {
        'multichannel' || 'debug' => true,
        'netbiosalias' => ['CHANGED'],
        'bindip' => ['192.0.2.1'],
        'encryption' => 'DESIRED',
        'server_sid' => 'S-1-5-21-123-456-790',
        _ => 'CHANGED',
      };
      expect((await execute(h, r)).outcome, SmbSettingsOutcome.rejected);
      expect(writes(h), 0);
    });
  }
  for (final seconds in [-1, 301]) {
    test('review age $seconds rejects', () async {
      final h = await connected();
      final r = await review(h);
      h.now = h.now.add(Duration(seconds: seconds));
      expect((await execute(h, r)).outcome, SmbSettingsOutcome.rejected);
      expect(writes(h), 0);
    });
  }
  test('five minute boundary and key-order independent proof', () async {
    final h = await connected();
    final r = await review(h);
    h.now = h.now.add(const Duration(minutes: 5));
    final old = h.wire.values['smb.config'] as Map;
    h.wire.values['smb.config'] = {
      for (final k in old.keys.toList().reversed) k: old[k],
    };
    expect((await execute(h, r)).outcome, SmbSettingsOutcome.completed);
  });
  for (final mode in ['age', 'route', 'session', 'callbackThrow']) {
    test('late final preflight $mode cancels before dispatch', () async {
      final h = await connected();
      final r = await review(h);
      final start = h.wire.counts['system.state']!;
      h.wire.beforeReply = (m, n) {
        if (m == 'system.state' && n == start + 3) {
          if (mode == 'age') {
            h.now = h.now.add(const Duration(minutes: 6));
          } else if (mode == 'session') {
            h.wire.current = false;
          } else {
            h.authorized = false;
          }
        }
      };
      final result = await h.repo.executeSmbSettings(
        r,
        r.target,
        isCurrent: () {
          if (mode == 'callbackThrow' && !h.authorized) {
            throw StateError(secret);
          }
          return h.authorized;
        },
      );
      expect(result.outcome, SmbSettingsOutcome.rejected);
      expect(writes(h), 0);
    });
  }
  test('confirmation exact and consumed', () async {
    final h = await connected();
    final r = await review(h);
    expect(
      (await execute(h, r, confirmation: '${r.target} ')).outcome,
      SmbSettingsOutcome.rejected,
    );
    expect((await execute(h, r)).outcome, SmbSettingsOutcome.rejected);
  });
  for (final mode in [
    'rpc',
    'transport',
    'null',
    'wrongField',
    'preservedField',
    'readback',
    'readbackFault',
    'route',
    'session',
  ]) {
    test('postdispatch $mode unknown and fenced', () async {
      final h = await connected();
      final r = await review(h);
      switch (mode) {
        case 'rpc':
          h.wire.fault = 'smb.update';
        case 'transport':
          h.wire.throwMethod = 'smb.update';
        case 'null':
          h.wire.overrideReceipt = true;
        case 'wrongField':
          h.wire.overrideReceipt = true;
          h.wire.receipt = smbConfig();
        case 'preservedField':
          h.wire.overrideReceipt = true;
          h.wire.receipt = {
            ...smbConfig(),
            'description': 'New description',
            'server_sid': 'S-1-5-21-1-2-3',
          };
        case 'readback':
          h.wire.mutate = false;
        case 'readbackFault':
          h.wire.afterWrite = () => h.wire.fault = 'smb.config';
        case 'route':
          h.wire.afterWrite = () => h.authorized = false;
        case 'session':
          h.wire.afterWrite = () => h.wire.current = false;
      }
      final result = await execute(h, r);
      expect(result.outcome, SmbSettingsOutcome.unknown);
      expect(result.message, isNot(contains(secret)));
      expect(writes(h), 1);
      expect(h.repo.loadSmbSettings(), throwsA(isA<SmbSettingsException>()));
      expect((await execute(h, r)).outcome, SmbSettingsOutcome.rejected);
    });
  }
  for (final method in reads) {
    test('preflight read failure $method sanitizes', () async {
      final h = await connected();
      h.wire.fault = method;
      expect(
        h.repo.loadSmbSettings(),
        throwsA(
          isA<SmbSettingsException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains(secret)),
          ),
        ),
      );
      expect(writes(h), 0);
    });
  }
  test('held execution blocks same workspace and late expiry', () async {
    final h = await connected();
    final r = await review(h);
    h.wire.hold = 'smb.config';
    h.wire.held = Completer<void>();
    final pending = execute(h, r);
    await Future<void>.delayed(Duration.zero);
    expect(h.repo.loadSmbSettings(), throwsA(isA<SmbSettingsException>()));
    h.authorized = false;
    h.wire.held!.complete();
    expect((await pending).outcome, SmbSettingsOutcome.rejected);
    expect(writes(h), 0);
  });
  for (final malformed in [
    null,
    {},
    [],
    {...smbConfig(), 'unexpected': secret},
    {...smbConfig(), 'id': 0},
    {...smbConfig(), 'multichannel': 'false'},
    {...smbConfig(), 'encryption': 'OFF'},
    {
      ...smbConfig(),
      'netbiosalias': [1],
    },
    {...smbConfig(), 'smb_options': 'x' * 65537},
  ]) {
    test('malformed config ${malformed.hashCode}', () async {
      final h = await connected(
        configure: (w) => w.values['smb.config'] = malformed,
      );
      expect(h.repo.loadSmbSettings(), throwsA(isA<SmbSettingsException>()));
    });
  }
  for (final malformed in [null, -1, 3, true, '0']) {
    test('bounded dependency count $malformed', () async {
      final h = await connected(configure: (w) => w.appleCount = malformed);
      expect(h.repo.loadSmbSettings(), throwsA(isA<SmbSettingsException>()));
    });
  }
  test(
    'configured-share cap, duplicate and malformed values rejected',
    () async {
      for (final rows in [
        List.generate(257, (i) => {'id': i + 1, 'enabled': true}),
        [
          {'id': 1, 'enabled': true},
          {'id': 1, 'enabled': false},
        ],
        [
          {'id': 1, 'enabled': 'true'},
        ],
      ]) {
        final h = await connected(configure: (w) => w.shares = rows);
        expect(h.repo.loadSmbSettings(), throwsA(isA<SmbSettingsException>()));
      }
    },
  );
}
