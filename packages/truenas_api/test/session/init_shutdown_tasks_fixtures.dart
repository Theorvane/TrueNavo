import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const istHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const istBoot = '11111111-2222-4333-8444-555555555555';
const istSecret = 'SYNTHETIC_PRIVATE_COMMAND_TOKEN';
const istBody = 'printf %s SYNTHETIC_PRIVATE_COMMAND_TOKEN';
const istReads = {
  'system.version_short',
  'system.host_id',
  'system.reboot.info',
  'system.state',
  'failover.licensed',
  'boot.get_state',
  'boot.environment.query',
  'core.get_jobs',
  'auth.me',
  'initshutdownscript.query',
};
const istWrites = {
  'initshutdownscript.create',
  'initshutdownscript.update',
  'initshutdownscript.delete',
};
Map<String, Object?> istRow({
  int id = 1,
  String type = 'COMMAND',
  String phase = 'POSTINIT',
  bool enabled = false,
  int timeout = 10,
}) => {
  'id': id,
  'type': type,
  'command': type == 'COMMAND' ? istBody : '',
  'script': type == 'SCRIPT' ? '/mnt/private/$istSecret' : '',
  'comment': 'Private comment $istSecret',
  'when': phase,
  'enabled': enabled,
  'timeout': timeout,
};
Map<String, Object?> istEnvironment() => {
  'id': '25.10.1',
  'dataset': 'boot-pool/ROOT/25.10.1',
  'created': '2026-09-14T01:00:00',
  'used_bytes': 4000,
  'active': true,
  'activated': true,
  'keep': true,
  'can_activate': true,
};

class InitShutdownWire implements RpcTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final methods = <String>{...istReads, ...istWrites},
      metadata = <String, Map<String, Object?>>{},
      counts = <String, int>{};
  List<Map<String, Object?>> rows = [
    istRow(),
    istRow(id: 2, enabled: true, phase: 'SHUTDOWN'),
    istRow(id: 3, type: 'SCRIPT', phase: 'PREINIT'),
  ];
  final values = <String, Object?>{
    'system.version_short': '25.10.1',
    'system.host_id': istHost,
    'system.reboot.info': {'boot_id': istBoot, 'reboot_required_reasons': []},
    'system.state': 'READY',
    'failover.licensed': false,
    'boot.get_state': {
      'name': 'boot-pool',
      'healthy': true,
      'status': 'ONLINE',
      'scan': null,
    },
    'boot.environment.query': [istEnvironment()],
    'core.get_jobs': [],
    'auth.me': {
      'privilege': {
        'roles': ['FULL_ADMIN'],
      },
      'private': istSecret,
    },
  };
  String version = '25.10.1';
  bool mutate = true, overrideReceipt = false;
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
    if (method == throwMethod) throw StateError(istSecret);
    if (method == fault) {
      if (!inbound.isClosed) {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': call['id'],
            'error': {'code': -32000, 'message': istSecret},
          }),
        );
      }
      return;
    }
    Object? value;
    if (method == 'initshutdownscript.query') {
      final params = call['params'] as List,
          filters = params[0] as List,
          options = params[1] as Map,
          select = (options['select'] as List).cast<String>();
      expect(options['force_sql_filters'], isNot(true));
      if (filters.isEmpty) {
        expect(options['limit'], 129);
        expect(select, ['id', 'type', 'when', 'enabled', 'timeout']);
      } else {
        expect(options['limit'], 2);
        expect(select, [
          'id',
          'type',
          'when',
          'enabled',
          'timeout',
          'command',
          'script',
          'comment',
        ]);
        expect(filters[0][0], 'id');
        expect(filters[1], ['type', '=', 'COMMAND']);
      }
      final selected = rows.where(
        (r) =>
            filters.isEmpty ||
            r['id'] == filters[0][2] && r['type'] == 'COMMAND',
      );
      value =
          queryOverride ??
          [
            for (final row in selected)
              {for (final key in select) key: row[key]},
          ];
    } else if (istWrites.contains(method)) {
      final params = call['params'] as List;
      if (method == 'initshutdownscript.delete') {
        value = true;
        if (mutate) rows.removeWhere((r) => r['id'] == params[0]);
      } else {
        final id = method == 'initshutdownscript.create'
                ? 91
                : params[0] as int,
            patch = (params.last as Map).cast<String, Object?>();
        final row = <String, Object?>{
          if (method == 'initshutdownscript.update')
            ...rows.singleWhere((r) => r['id'] == id),
          ...patch,
          'id': id,
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
          for (final m in methods)
            m: {
              'job': false,
              'uploadable': false,
              'downloadable': false,
              'no_auth_required': false,
              'check_pipes': false,
              ...?metadata[m],
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

class InitShutdownConnector implements RpcConnector {
  const InitShutdownConnector(this.wire);
  final InitShutdownWire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class InitShutdownHarness {
  InitShutdownHarness(this.wire) {
    repo = TrueNasSessionRepository(
      connector: InitShutdownConnector(wire),
      initShutdownTasksNow: () => now,
      managementRequestTimeout: const Duration(milliseconds: 300),
    );
  }
  final InitShutdownWire wire;
  late final TrueNasSessionRepository repo;
  DateTime now = DateTime.utc(2026, 9, 14);
  bool authorized = true;
}

Future<InitShutdownHarness> istConnected({
  void Function(InitShutdownWire)? configure,
}) async {
  final wire = InitShutdownWire();
  configure?.call(wire);
  final h = InitShutdownHarness(wire);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
  );
  return h;
}

InitShutdownTasksRequest istRequest(
  InitShutdownTasksInventory i,
  InitShutdownTasksAction action, {
  InitShutdownTaskCommand? command,
  InitShutdownTaskPhase phase = InitShutdownTaskPhase.postinit,
  int timeout = 20,
  InitShutdownTaskSnapshot? task,
}) => InitShutdownTasksRequest(
  inventory: i,
  action: action,
  task: action == InitShutdownTasksAction.create
      ? null
      : task ??
            i.tasks.firstWhere(
              (t) =>
                  t.isCommand &&
                  t.enabled == (action == InitShutdownTasksAction.disable),
            ),
  settings:
      action == InitShutdownTasksAction.create ||
          action == InitShutdownTasksAction.replace
      ? InitShutdownTaskSettings(phase: phase, timeoutSeconds: timeout)
      : null,
  command:
      action == InitShutdownTasksAction.create ||
          action == InitShutdownTasksAction.replace
      ? command ?? InitShutdownTaskCommand('$istBody replaced')
      : null,
);
Future<InitShutdownTasksReview> istReview(
  InitShutdownHarness h,
  InitShutdownTasksAction action, {
  InitShutdownTaskPhase phase = InitShutdownTaskPhase.postinit,
}) async {
  final i = await h.repo.loadInitShutdownTasks();
  return h.repo.reviewInitShutdownTasks(istRequest(i, action, phase: phase));
}

Future<InitShutdownTasksResult> istExecute(
  InitShutdownHarness h,
  InitShutdownTasksReview r, {
  String? target,
}) => h.repo.executeInitShutdownTasks(
  r,
  target ?? r.target,
  isCurrent: () => h.authorized,
);
