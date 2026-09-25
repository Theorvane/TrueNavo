import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/boot_environments/boot_environments_controller.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

const bootMethods = {
  'failover.licensed',
  'core.get_jobs',
  'boot.environment.query',
  'boot.environment.clone',
  'boot.environment.keep',
  'boot.environment.activate',
  'boot.environment.destroy',
};
const bootEndpoint = 'wss://fixture.example/api/current';

/// All authentication and RPC replies are synthetic and remain in memory.
/// A real SDK adapter issues the private review objects for these UI tests.
class BootHarness {
  BootHarness._(this.transport, this.sdk) {
    api = BootFakeRepository(sdk, transport);
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }

  static Future<BootHarness> create({
    Set<String> methods = bootMethods,
    String version = '25.10.1',
    bool licensed = false,
    bool conflicting = false,
  }) async {
    final transport = BootMemoryTransport(methods, version)
      ..licensed = licensed
      ..conflicting = conflicting;
    final sdk = TrueNasSessionRepository(
      connector: _MemoryConnector(transport),
    );
    await sdk.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture',
      apiKey: 'synthetic-fixture-only',
      rememberApiKey: false,
    );
    return BootHarness._(transport, sdk);
  }

  final BootMemoryTransport transport;
  final TrueNasSessionRepository sdk;
  late final BootFakeRepository api;
  late final AuthenticatedSession session;
  late final ProviderContainer container;
  AuthenticatedSession? active;

  BootEnvironmentsController get controller =>
      container.read(bootEnvironmentsControllerProvider.notifier);
  BootEnvironmentsState get state =>
      container.read(bootEnvironmentsControllerProvider);
  ServerOperationLock get lock => container.read(serverOperationLockProvider);

  AuthenticatedSession newSession({String? endpoint = bootEndpoint}) =>
      AuthenticatedSession(
        profileId: 'boot-fixture',
        repository: api,
        availableMethodNames: transport.methods,
        version: transport.version,
        endpoint: endpoint,
      );

  void select(AuthenticatedSession? selected) {
    active = selected;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  Future<BootEnvironmentReview> review({
    BootEnvironmentAction action = BootEnvironmentAction.delete,
  }) async {
    final inventory = await container.read(
      bootEnvironmentsInventoryProvider.future,
    );
    return api.reviewBootEnvironment(
      BootEnvironmentRequest(
        inventory: inventory,
        snapshot: inventory.environments.firstWhere((item) => item.id == 'old'),
        action: action,
        targetName: action == BootEnvironmentAction.clone ? 'safe-copy' : null,
        keep: action == BootEnvironmentAction.keep ? true : null,
      ),
    );
  }

  Future<void> dispose() async {
    container.dispose();
    await sdk.close();
  }
}

class BootFakeRepository
    implements SessionRepository, AuthenticatedBootEnvironmentsSession {
  BootFakeRepository(this.sdk, this.transport);
  final TrueNasSessionRepository sdk;
  final BootMemoryTransport transport;
  var reads = 0, reviews = 0, executions = 0;
  BootEnvironmentReview? executedReview;
  Future<BootEnvironmentResult> Function()? onExecute;
  Future<BootEnvironmentInventory>? pendingRead;
  Object? readError;

  @override
  BootEnvironmentsCapabilities get bootEnvironmentsCapabilities =>
      sdk.bootEnvironmentsCapabilities;
  @override
  Future<BootEnvironmentInventory> loadBootEnvironments() async {
    reads++;
    if (readError case final Object error) throw error;
    return pendingRead ?? sdk.loadBootEnvironments();
  }

  @override
  Future<BootEnvironmentReview> reviewBootEnvironment(
    BootEnvironmentRequest request,
  ) {
    reviews++;
    return sdk.reviewBootEnvironment(request);
  }

  @override
  Future<BootEnvironmentResult> executeBootEnvironment(
    BootEnvironmentReview review,
  ) {
    executions++;
    executedReview = review;
    return onExecute?.call() ?? sdk.executeBootEnvironment(review);
  }

  @override
  Future<void> close() => sdk.close();
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnimplementedError('Use only the in-memory fixture connection.');
}

class _MemoryConnector implements RpcConnector {
  _MemoryConnector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

class BootMemoryTransport implements RpcTransport {
  BootMemoryTransport(this.methods, this.version);
  final Set<String> methods;
  final String version;
  final _inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  final rows = [
    _row('current', active: true, activated: true, keep: true),
    _row('old'),
    _row('kept', keep: true),
    _row('incompatible', canActivate: false),
  ];
  var licensed = false, conflicting = false;

  List<Map<String, Object?>> get mutations => requests
      .where(
        (r) =>
            (r['method'] as String).startsWith('boot.environment.') &&
            r['method'] != 'boot.environment.query',
      )
      .toList();

  @override
  Stream<String> get inboundFrames => _inbound.stream;

  @override
  Future<void> send(String frame) async {
    final request = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(request);
    Object? result;
    switch (request['method']) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'username': 'fixture'};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final method in methods)
            method: {
              'job': false,
              'private': false,
              'no_auth_required': false,
              'uploadable': false,
              'downloadable': false,
            },
        };
      case 'failover.licensed':
        result = licensed;
      case 'core.get_jobs':
        result = conflicting
            ? [
                {'id': 1, 'method': 'update.update', 'state': 'RUNNING'},
              ]
            : [];
      case 'boot.environment.query':
        result = rows;
      case 'boot.environment.clone':
        final argument = (request['params'] as List).single as Map;
        final row = _row(argument['target'] as String);
        rows.add(row);
        result = row;
      case 'boot.environment.keep':
        final argument = (request['params'] as List).single as Map;
        final row = rows.firstWhere((row) => row['id'] == argument['id']);
        row['keep'] = argument['value'];
        result = row;
      case 'boot.environment.activate':
        final argument = (request['params'] as List).single as Map;
        for (final row in rows) {
          row['activated'] = row['id'] == argument['id'];
        }
        result = rows.firstWhere((row) => row['id'] == argument['id']);
      case 'boot.environment.destroy':
        final argument = (request['params'] as List).single as Map;
        rows.removeWhere((row) => row['id'] == argument['id']);
        result = null;
      default:
        throw StateError('Unexpected fixture RPC: ${request['method']}');
    }
    _inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    if (!_inbound.isClosed) await _inbound.close();
  }
}

Map<String, Object?> _row(
  String name, {
  bool active = false,
  bool activated = false,
  bool keep = false,
  bool canActivate = true,
}) => {
  'id': name,
  'dataset': 'boot-pool/ROOT/$name',
  'created': '2026-09-10T12:00:00',
  'used_bytes': 1073741824,
  'used': '1 GiB',
  'active': active,
  'activated': activated,
  'keep': keep,
  'can_activate': canActivate,
};
