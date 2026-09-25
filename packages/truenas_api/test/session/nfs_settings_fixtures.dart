import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const nfsSettingsHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const nfsSettingsBoot = '11111111-2222-4333-8444-555555555555';
const nfsSettingsPrivate = 'SYNTHETIC_PRIVATE_DIRECTORY_CREDENTIAL';
const nfsSettingsReads = {
  'system.version_short',
  'system.host_id',
  'system.reboot.info',
  'system.state',
  'failover.licensed',
  'boot.get_state',
  'boot.environment.query',
  'core.get_jobs',
  'auth.me',
  'nfs.config',
  'nfs.bindip_choices',
  'service.query',
  'sharing.nfs.query',
  'directoryservices.config',
};
Map<String, Object?> nfsSettingsConfig() => {
  'id': 1,
  'servers': 8,
  'managed_nfsd': true,
  'protocols': ['NFSV3', 'NFSV4'],
  'bindip': ['192.0.2.10'],
  'allow_nonroot': false,
  'v4_krb': false,
  'v4_domain': '',
  'mountd_port': null,
  'rpcstatd_port': null,
  'rpclockd_port': null,
  'mountd_log': true,
  'statd_lockd_log': false,
  'v4_krb_enabled': false,
  'userd_manage_gids': false,
  'keytab_has_nfs_spn': false,
  'rdma': false,
};
Map<String, Object?> nfsSettingsEnvironment() => {
  'id': '25.10.1',
  'dataset': 'boot-pool/ROOT/25.10.1',
  'created': '2026-09-14T01:00:00',
  'used_bytes': 4000,
  'active': true,
  'activated': true,
  'keep': true,
  'can_activate': true,
};

class NfsSettingsWire implements RpcTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final methods = <String>{...nfsSettingsReads, 'nfs.update'},
      metadata = <String, Map<String, Object?>>{},
      counts = <String, int>{};
  Map<String, Object?> config = nfsSettingsConfig();
  List<Map<String, Object?>> exports = [
    {
      'id': 4,
      'enabled': false,
      'security': ['SYS'],
    },
  ];
  Object? service = [
    {'id': 7, 'service': 'nfs', 'state': 'STOPPED', 'enable': false},
  ];
  final values = <String, Object?>{
    'system.version_short': '25.10.1',
    'system.host_id': nfsSettingsHost,
    'system.reboot.info': {
      'boot_id': nfsSettingsBoot,
      'reboot_required_reasons': [],
    },
    'system.state': 'READY',
    'failover.licensed': false,
    'boot.get_state': {
      'name': 'boot-pool',
      'healthy': true,
      'status': 'ONLINE',
      'scan': null,
    },
    'boot.environment.query': [nfsSettingsEnvironment()],
    'core.get_jobs': [],
    'auth.me': {
      'privilege': {
        'roles': ['FULL_ADMIN'],
      },
      'private': nfsSettingsPrivate,
    },
    'directoryservices.config': {
      'id': 1,
      'enable': false,
      'service_type': null,
      'credential': null,
      'configuration': null,
      'kerberos_realm': null,
    },
    'nfs.bindip_choices': {
      '192.0.2.10': '192.0.2.10',
      '192.0.2.11': '192.0.2.11',
      '2001:db8::10': '2001:db8::10',
    },
  };
  String version = '25.10.1';
  bool mutate = true, overrideReceipt = false;
  Object? receipt, configOverride, exportsOverride;
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
    if (method == throwMethod) throw StateError(nfsSettingsPrivate);
    if (method == fault) {
      if (!inbound.isClosed) {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': call['id'],
            'error': {'code': -32000, 'message': nfsSettingsPrivate},
          }),
        );
      }
      return;
    }
    Object? value;
    switch (method) {
      case 'nfs.config':
        value = configOverride ?? config;
      case 'service.query':
        expect(call['params'], [
          [
            ['service', '=', 'nfs'],
          ],
          {
            'limit': 2,
            'select': ['id', 'service', 'state', 'enable'],
          },
        ]);
        value = service;
      case 'sharing.nfs.query':
        expect(call['params'], [
          [],
          {
            'limit': 257,
            'select': ['id', 'enabled', 'security'],
            'extra': {'retrieve_locked_info': false},
          },
        ]);
        value = exportsOverride ?? exports;
      case 'nfs.update':
        final patch = (call['params'] as List).single as Map;
        if (mutate) {
          config = {...config, ...patch.cast<String, Object?>()};
          if (patch.containsKey('servers')) {
            config['managed_nfsd'] = patch['servers'] == null;
            config['servers'] = patch['servers'] ?? 8;
          }
        }
        value = Map<String, Object?>.from(config);
        afterWrite?.call();
        if (overrideReceipt) value = receipt;
      default:
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

class NfsSettingsConnector implements RpcConnector {
  const NfsSettingsConnector(this.wire);
  final NfsSettingsWire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class NfsSettingsHarness {
  NfsSettingsHarness(this.wire) {
    repo = TrueNasSessionRepository(
      connector: NfsSettingsConnector(wire),
      nfsSettingsNow: () => now,
      managementRequestTimeout: const Duration(milliseconds: 300),
    );
  }
  final NfsSettingsWire wire;
  late final TrueNasSessionRepository repo;
  DateTime now = DateTime.utc(2026, 9, 14);
  bool authorized = true;
}

Future<NfsSettingsHarness> nfsSettingsConnected({
  void Function(NfsSettingsWire)? configure,
}) async {
  final wire = NfsSettingsWire();
  configure?.call(wire);
  final h = NfsSettingsHarness(wire);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
  );
  return h;
}

NfsGlobalSettings nfsChanged(
  NfsSettingsInventory i, {
  int? threads = 12,
  List<String>? protocols,
  List<String>? bindings,
  bool? mountdLog,
  bool? statdLockdLog,
}) => NfsGlobalSettings(
  serverThreads: threads,
  protocols: protocols ?? i.config.settings.protocols,
  bindAddresses: bindings ?? i.config.settings.bindAddresses,
  mountdLog: mountdLog ?? i.config.settings.mountdLog,
  statdLockdLog: statdLockdLog ?? i.config.settings.statdLockdLog,
);
Future<NfsSettingsReview> nfsSettingsReview(
  NfsSettingsHarness h, {
  NfsGlobalSettings Function(NfsSettingsInventory)? settings,
}) async {
  final i = await h.repo.loadNfsSettings();
  return h.repo.reviewNfsSettings(
    NfsSettingsRequest(
      inventory: i,
      settings: settings?.call(i) ?? nfsChanged(i),
    ),
  );
}

Future<NfsSettingsResult> nfsSettingsExecute(
  NfsSettingsHarness h,
  NfsSettingsReview r, {
  String? target,
}) => h.repo.executeNfsSettings(
  r,
  target ?? r.target,
  isCurrent: () => h.authorized,
);
