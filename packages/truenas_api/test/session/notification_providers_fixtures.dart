import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const npHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const npBoot = '11111111-2222-4333-8444-555555555555';
const npSecret = 'SYNTHETIC_PRIVATE_PROVIDER_SECRET';
const npReads = {
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
const npWrites = {
  'alertservice.create',
  'alertservice.update',
  'alertservice.delete',
};
String npTitle(NotificationProviderType provider) => switch (provider) {
  NotificationProviderType.awsSns => 'AWS SNS',
  NotificationProviderType.snmpTrap => 'SNMP Trap',
  _ => provider.wireName,
};
Map<String, Object?> npFields(NotificationProviderType p) => switch (p) {
  NotificationProviderType.slack || NotificationProviderType.opsGenie => {},
  NotificationProviderType.mattermost => {
    'username': 'TrueNavo',
    'channel': 'operations',
  },
  NotificationProviderType.telegram => {
    'chat_ids': [-1001234567890, 123456],
  },
  NotificationProviderType.pagerDuty => {'client_name': 'TrueNavo'},
  NotificationProviderType.victorOps => {},
  NotificationProviderType.awsSns => {
    'region': 'us-east-1',
    'topic_arn': 'arn:aws:sns:us-east-1:123456789012:operations',
  },
  NotificationProviderType.influxDb => {
    'host': 'metrics.example.test',
    'username': 'alerts',
    'database': 'alerts',
    'series_name': 'truenas',
  },
  NotificationProviderType.snmpTrap => {
    'host': 'traps.example.test',
    'port': 162,
  },
};
Map<String, String> npCredentials(
  NotificationProviderType p, {
  String suffix = '',
}) => switch (p) {
  NotificationProviderType.slack => {
    'url': 'https://hooks.example.test/private/$npSecret$suffix',
  },
  NotificationProviderType.mattermost => {
    'url': 'https://chat.example.test/private/$npSecret$suffix',
    'icon_url': '',
  },
  NotificationProviderType.telegram => {
    'bot_token': '123456:SYNTHETIC_TOKEN$suffix',
  },
  NotificationProviderType.pagerDuty => {'service_key': '$npSecret$suffix'},
  NotificationProviderType.opsGenie => {
    'api_key': '$npSecret$suffix',
    'api_url': '',
  },
  NotificationProviderType.victorOps => {
    'api_key': '$npSecret$suffix',
    'routing_key': 'operations',
  },
  NotificationProviderType.awsSns => {
    'aws_access_key_id': 'SYNTHETIC_ACCESS_ID',
    'aws_secret_access_key': '$npSecret$suffix',
  },
  NotificationProviderType.influxDb => {'password': '$npSecret$suffix'},
  NotificationProviderType.snmpTrap => {'community': '$npSecret$suffix'},
};
Map<String, Object?> npAttributes(
  NotificationProviderType p, {
  String suffix = '',
}) => {
  'type': p.wireName,
  ...npFields(p),
  ...npCredentials(p, suffix: suffix),
  if (p == NotificationProviderType.snmpTrap) ...{
    'v3': false,
    'v3_username': null,
    'v3_authkey': null,
    'v3_privkey': null,
    'v3_authprotocol': null,
    'v3_privprotocol': null,
  },
};
Map<String, Object?> npRow(
  NotificationProviderType p, {
  int id = 1,
  bool enabled = false,
}) => {
  'id': id,
  'name': 'Provider $id',
  'level': 'WARNING',
  'enabled': enabled,
  'type__title': npTitle(p),
  'attributes': npAttributes(p),
};
Map<String, Object?> npEnvironment() => {
  'id': '25.10.1',
  'dataset': 'boot-pool/ROOT/25.10.1',
  'created': '2026-09-14T01:00:00',
  'used_bytes': 4000,
  'active': true,
  'activated': true,
  'keep': true,
  'can_activate': true,
};

class ProvidersWire implements RpcTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final methods = <String>{...npReads, ...npWrites};
  final metadata = <String, Map<String, Object?>>{}, counts = <String, int>{};
  List<Map<String, Object?>> rows = [
    npRow(NotificationProviderType.slack),
    npRow(NotificationProviderType.telegram, id: 2, enabled: true),
  ];
  final values = <String, Object?>{
    'system.version_short': '25.10.1',
    'system.host_id': npHost,
    'system.reboot.info': {'boot_id': npBoot, 'reboot_required_reasons': []},
    'system.state': 'READY',
    'failover.licensed': false,
    'boot.get_state': {
      'name': 'boot-pool',
      'healthy': true,
      'status': 'ONLINE',
      'scan': null,
    },
    'boot.environment.query': [npEnvironment()],
    'core.get_jobs': [],
    'auth.me': {
      'privilege': {
        'roles': ['FULL_ADMIN'],
      },
      'private': npSecret,
    },
  };
  String version = '25.10.1';
  bool current = true, mutate = true, overrideReceipt = false;
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
    if (method == throwMethod) throw StateError(npSecret);
    if (method == fault) {
      if (!inbound.isClosed) {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': call['id'],
            'error': {'code': -32000, 'message': npSecret},
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
      expect(options['force_sql_filters'], isNot(true));
      if (filters.isEmpty) {
        expect(options['limit'], 129);
        expect(select, ['id', 'name', 'level', 'enabled', 'type__title']);
      } else {
        expect(options['limit'], 2);
        expect(select, ['id', 'name', 'level', 'enabled', 'attributes']);
        expect(filters[0][0], 'id');
        expect(filters[1][0], 'attributes.type');
      }
      final selected = rows.where(
        (r) =>
            filters.isEmpty ||
            r['id'] == filters[0][2] &&
                (r['attributes'] as Map)['type'] == filters[1][2],
      );
      value =
          queryOverride ??
          [
            for (final r in selected) {for (final key in select) key: r[key]},
          ];
    } else if (npWrites.contains(method)) {
      final params = call['params'] as List;
      if (method == 'alertservice.delete') {
        value = true;
        if (mutate) rows.removeWhere((r) => r['id'] == params[0]);
      } else {
        final id = method == 'alertservice.create' ? 91 : params[0] as int;
        final envelope = (params.last as Map).cast<String, Object?>(),
            provider = NotificationProviderType.values.singleWhere(
              (p) => p.wireName == (envelope['attributes'] as Map)['type'],
            );
        final row = <String, Object?>{
          'id': id,
          'type__title': npTitle(provider),
          ...envelope,
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

class ProvidersConnector implements RpcConnector {
  const ProvidersConnector(this.wire);
  final ProvidersWire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class ProvidersHarness {
  ProvidersHarness(this.wire) {
    repo = TrueNasSessionRepository(
      connector: ProvidersConnector(wire),
      notificationProvidersNow: () => now,
      managementRequestTimeout: const Duration(milliseconds: 200),
    );
  }
  final ProvidersWire wire;
  late final TrueNasSessionRepository repo;
  DateTime now = DateTime.utc(2026, 9, 14);
  bool authorized = true;
}

Future<ProvidersHarness> providersConnected({
  void Function(ProvidersWire)? configure,
}) async {
  final wire = ProvidersWire();
  configure?.call(wire);
  final h = ProvidersHarness(wire);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
    isConnectionCurrent: () => wire.current,
  );
  return h;
}

NotificationProvidersRequest providerRequest(
  NotificationProvidersInventory inventory,
  NotificationProviderType provider,
  NotificationProvidersAction action,
) => NotificationProvidersRequest(
  inventory: inventory,
  action: action,
  service: action == NotificationProvidersAction.create
      ? null
      : inventory.services.firstWhere((s) => s.id == 1),
  settings:
      action == NotificationProvidersAction.create ||
          action == NotificationProvidersAction.replace
      ? NotificationProviderSettings(
          provider: provider,
          name: 'Reviewed provider',
          level: AlertDeliveryLevel.error,
          fields: npFields(provider),
        )
      : null,
  credentials:
      action == NotificationProvidersAction.create ||
          action == NotificationProvidersAction.replace
      ? NotificationProviderCredentials(
          provider: provider,
          values: npCredentials(provider, suffix: '_NEW'),
        )
      : null,
);
Future<NotificationProvidersReview> providerReview(
  ProvidersHarness h, {
  NotificationProviderType provider = NotificationProviderType.slack,
  NotificationProvidersAction action = NotificationProvidersAction.replace,
}) async => h.repo.reviewNotificationProviders(
  providerRequest(await h.repo.loadNotificationProviders(), provider, action),
);
Future<NotificationProvidersResult> providerExecute(
  ProvidersHarness h,
  NotificationProvidersReview review,
) => h.repo.executeNotificationProviders(
  review,
  review.target,
  isCurrent: () => h.authorized,
);
List<Map<String, dynamic>> providerWrites(ProvidersHarness h) =>
    h.wire.calls.where((c) => npWrites.contains(c['method'])).toList();
Matcher providerReason(NotificationProvidersExceptionReason reason) =>
    isA<NotificationProvidersException>().having(
      (e) => e.reason,
      'reason',
      reason,
    );
