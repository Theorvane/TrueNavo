import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/admin/admin_controller.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/management_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const _serverLabel = 'wss://original.example/api/current';
const _quickCommand = ServiceControlCommand(
  service: 'ssh',
  action: ServiceControlAction.restart,
);

void main() {
  for (final method in [
    'cronjob.query',
    'cronjob.create',
    'cronjob.update',
    'cronjob.delete',
    'cronjob.run',
    'initshutdownscript.query',
    'initshutdownscript.create',
    'system.reboot',
    'system.shutdown',
    'rsynctask.query',
    'rsynctask.create',
    'rsynctask.update',
    'rsynctask.delete',
    'rsynctask.run',
    'alert.list',
    'alert.dismiss',
    'alert.restore',
    'disk.query',
    'disk.update',
    'iscsi.portal.update',
    'iscsi.portal.listen_ip_choices',
    'iscsi.extent.get_instance',
    'iscsi.extent.update',
    'iscsi.target.validate_name',
    'iscsi.target.create',
    'iscsi.initiator.create',
    'iscsi.target.delete',
    'iscsi.target.update',
    'iscsi.target.get_instance',
    'disk.temperatures',
    'pool.scrub.query',
    'pool.scrub.create',
    'pool.scrub.update',
    'pool.scrub.delete',
    'pool.scrub.run',
    'pool.scrub.scrub',
  ]) {
    test('$method cannot bypass its native gateway', () async {
      final harness = _Harness(_AdminManager());
      addTearDown(harness.dispose);
      await harness.execute(method);
      expect(harness.manager.requests, isEmpty);
      expect(harness.state.phase, AdminPhase.failed);
    });
  }
  test(
    'read operation retains current result and original server label',
    () async {
      final harness = _Harness(
        _AdminManager(
          onInvoke: (request) async => AdminCompleted(
            request,
            value: const [
              {'id': 7, 'name': 'tank', 'status': 'ONLINE'},
            ],
          ),
        ),
      );
      addTearDown(harness.dispose);
      await harness.execute('pool.query');
      expect(harness.state.phase, AdminPhase.completed);
      expect(harness.state.operation!.risk, AdminRisk.read);
      expect(harness.state.serverLabel, _serverLabel);
      expect((harness.state.result as AdminCompleted).value, [
        {'id': 7, 'name': 'tank', 'status': 'ONLINE'},
      ]);
      expect(harness.manager.requests.single.method.name, 'pool.query');
      expect(harness.manager.polledJobs, isEmpty);
    },
  );

  test(
    'same-profile replacement session invalidates an existing confirmation',
    () async {
      final harness = _Harness(_AdminManager());
      addTearDown(harness.dispose);
      harness.switchSession(_session(harness.manager));
      await harness.execute('iscsi.portal.delete');
      expect(harness.manager.requests, isEmpty);
      expect(harness.state.phase, AdminPhase.failed);
      expect(harness.state.message, contains('connection changed'));
    },
  );

  test(
    'disconnection invalidates an existing confirmation without sending',
    () async {
      final harness = _Harness(_AdminManager());
      addTearDown(harness.dispose);
      harness.switchSession(null);
      await harness.execute('iscsi.portal.delete');
      expect(harness.manager.requests, isEmpty);
      expect(harness.state.phase, AdminPhase.failed);
    },
  );

  test(
    'policy and request method mismatch is rejected before invocation',
    () async {
      final harness = _Harness(_AdminManager());
      addTearDown(harness.dispose);
      await harness.execute(
        'pool.query',
        operation: _operation('iscsi.portal.delete'),
      );
      expect(harness.manager.requests, isEmpty);
      expect(harness.state.phase, AdminPhase.failed);
      expect(harness.state.message, contains('Nothing was sent'));
    },
  );

  test(
    'dedicated-workflow policy is never submitted through administration',
    () async {
      final harness = _Harness(_AdminManager());
      addTearDown(harness.dispose);
      await harness.execute('pool.dataset.delete');
      expect(harness.manager.requests, isEmpty);
      expect(harness.state.phase, AdminPhase.failed);
    },
  );

  test(
    'caller-supplied policy cannot downgrade a reviewed mutation to read',
    () async {
      final harness = _Harness(_AdminManager());
      addTearDown(harness.dispose);
      const forged = AdminOperationDefinition(
        id: 'iscsi.portal.delete',
        domain: AdminDomain.shares,
        title: 'Read portal',
        method: 'iscsi.portal.delete',
        risk: AdminRisk.read,
        description: 'This is not the compiled policy.',
      );
      await harness.execute('iscsi.portal.delete', operation: forged);
      expect(harness.manager.requests, isEmpty);
      expect(harness.state.phase, AdminPhase.failed);
      expect(harness.state.message, contains('Nothing was sent'));
    },
  );

  test('duplicate submission while invocation is pending is ignored', () async {
    final completion = Completer<AdminResult>();
    final harness = _Harness(_AdminManager(onInvoke: (_) => completion.future));
    addTearDown(harness.dispose);
    final first = harness.execute('iscsi.portal.delete');
    expect(harness.state.busy, isTrue);
    await harness.execute('iscsi.portal.delete');
    expect(harness.manager.requests, hasLength(1));
    completion.complete(
      AdminCompleted(harness.manager.requests.single, value: null),
    );
    await first;
    expect(harness.state.phase, AdminPhase.completed);
  });

  test(
    'administration holds the global lock against Quick management writes',
    () async {
      final completion = Completer<AdminResult>();
      final harness = _Harness(
        _AdminManager(onInvoke: (_) => completion.future),
      );
      addTearDown(harness.dispose);
      final first = harness.execute('iscsi.portal.delete');
      await harness.quickExecute();
      expect(harness.manager.quickCommands, isEmpty);
      expect(harness.quickState.phase, ManagementPhase.failed);
      expect(harness.quickState.message, contains('Another server operation'));
      completion.complete(
        AdminCompleted(harness.manager.requests.single, value: null),
      );
      await first;
      await harness.quickExecute();
      expect(harness.manager.quickCommands, [_quickCommand]);
    },
  );

  test(
    'Quick management holds the same lock against administration writes',
    () async {
      final completion = Completer<ManagementResult>();
      final harness = _Harness(
        _AdminManager(onQuickExecute: (_) => completion.future),
      );
      addTearDown(harness.dispose);
      final quick = harness.quickExecute();
      await harness.execute('iscsi.portal.delete');
      expect(harness.manager.requests, isEmpty);
      expect(harness.state.phase, AdminPhase.failed);
      expect(harness.state.message, contains('Another server operation'));
      completion.complete(const ManagementCompleted(_quickCommand));
      await quick;
      await harness.execute('iscsi.portal.delete');
      expect(harness.manager.requests, hasLength(1));
      expect(harness.state.phase, AdminPhase.completed);
    },
  );

  test(
    'accepted job is polled by identity and retains ID after completion',
    () async {
      var polls = 0;
      final harness = _Harness(
        _AdminManager(
          onInvoke: (request) async => AdminJobSubmitted(request, jobId: 71),
          onPoll: (job) async =>
              ++polls == 1 ? job : AdminCompleted(job.request, value: true),
        ),
      );
      addTearDown(harness.dispose);
      await harness.execute('app.start');
      expect(harness.state.phase, AdminPhase.completed);
      expect(harness.state.jobId, 71);
      expect(harness.manager.requests, hasLength(1));
      expect(harness.manager.polledJobs, hasLength(2));
      expect(
        harness.manager.polledJobs[0],
        same(harness.manager.polledJobs[1]),
      );
    },
  );

  test(
    'pending jobs stop after bounded polling with no mutation retry',
    () async {
      final harness = _Harness(
        _AdminManager(
          onInvoke: (request) async => AdminJobSubmitted(request, jobId: 72),
          onPoll: (job) async => job,
        ),
      );
      addTearDown(harness.dispose);
      await harness.execute('app.start');
      expect(harness.state.phase, AdminPhase.unknown);
      expect(harness.state.jobId, 72);
      expect(harness.state.message, contains('Job #72 is still pending'));
      expect(harness.state.message, contains('No command was resent'));
      expect(harness.manager.requests, hasLength(1));
      expect(harness.manager.polledJobs, hasLength(30));
    },
  );

  test('unknown job result retains the accepted identifier', () async {
    final harness = _Harness(
      _AdminManager(
        onInvoke: (request) async => AdminJobSubmitted(request, jobId: 73),
        onPoll: (job) async =>
            AdminOutcomeUnknown(job.request, jobId: job.jobId),
      ),
    );
    addTearDown(harness.dispose);
    await harness.execute('app.start');
    expect(harness.state.phase, AdminPhase.unknown);
    expect(harness.state.jobId, 73);
    expect(harness.state.result, isA<AdminOutcomeUnknown>());
    expect(harness.manager.requests, hasLength(1));
    expect(harness.manager.polledJobs, hasLength(1));
  });

  test(
    'unknown submission containing job ID preserves the identifier',
    () async {
      final harness = _Harness(
        _AdminManager(
          onInvoke: (request) async => AdminOutcomeUnknown(request, jobId: 74),
        ),
      );
      addTearDown(harness.dispose);
      await harness.execute('app.start');
      expect(harness.state.phase, AdminPhase.unknown);
      expect(harness.state.jobId, 74);
      expect(harness.manager.polledJobs, isEmpty);
    },
  );

  test(
    'switching before the next poll stops reads on the old session',
    () async {
      final delay = Completer<void>();
      final enteredDelay = Completer<void>();
      final harness = _Harness(
        _AdminManager(
          onInvoke: (request) async => AdminJobSubmitted(request, jobId: 75),
        ),
        delay: () {
          enteredDelay.complete();
          return delay.future;
        },
      );
      addTearDown(harness.dispose);
      final execution = harness.execute('app.start');
      await enteredDelay.future;
      final nextManager = _AdminManager();
      harness.switchSession(_session(nextManager, profileId: 'other-server'));
      delay.complete();
      await execution;
      expect(harness.state.phase, AdminPhase.unknown);
      expect(harness.state.jobId, 75);
      expect(harness.state.serverLabel, _serverLabel);
      expect(harness.state.message, contains('original server'));
      expect(harness.manager.requests, hasLength(1));
      expect(harness.manager.polledJobs, isEmpty);
      expect(nextManager.requests, isEmpty);
    },
  );

  test(
    'switching during an in-flight poll causes no subsequent poll or resend',
    () async {
      final pendingPoll = Completer<AdminResult>();
      final enteredPoll = Completer<AdminJobSubmitted>();
      final harness = _Harness(
        _AdminManager(
          onInvoke: (request) async => AdminJobSubmitted(request, jobId: 76),
          onPoll: (job) {
            enteredPoll.complete(job);
            return pendingPoll.future;
          },
        ),
      );
      addTearDown(harness.dispose);
      final execution = harness.execute('app.start');
      final job = await enteredPoll.future;
      harness.switchSession(null);
      pendingPoll.complete(job);
      await execution;
      expect(harness.state.phase, AdminPhase.unknown);
      expect(harness.state.jobId, 76);
      expect(harness.manager.requests, hasLength(1));
      expect(harness.manager.polledJobs, [job]);
    },
  );

  for (final throwTyped in [false, true]) {
    test(
      'poll ${throwTyped ? 'typed' : 'unexpected'} exception retains job without secrets',
      () async {
        final harness = _Harness(
          _AdminManager(
            onInvoke: (request) async => AdminJobSubmitted(request, jobId: 77),
            onPoll: (_) async {
              if (throwTyped) {
                throw const AdminException(AdminExceptionReason.staleSession);
              }
              throw StateError('Private transport detail token=TEST-SECRET');
            },
          ),
        );
        addTearDown(harness.dispose);
        await harness.execute('app.start');
        expect(harness.state.phase, AdminPhase.unknown);
        expect(harness.state.jobId, 77);
        expect(harness.state.result, isA<AdminJobSubmitted>());
        expect(harness.state.message, isNot(contains('TEST-SECRET')));
        expect(harness.state.message, isNot(contains('Private transport')));
        expect(harness.manager.requests, hasLength(1));
        expect(harness.manager.polledJobs, hasLength(1));
        await harness.quickExecute();
        expect(harness.manager.quickCommands, [_quickCommand]);
      },
    );
  }

  test(
    'unexpected submit exception is uncertain and redacted with released lock',
    () async {
      final harness = _Harness(
        _AdminManager(
          onInvoke: (_) async {
            throw StateError('authorization=TEST-SECRET payload=private');
          },
        ),
      );
      addTearDown(harness.dispose);
      await harness.execute('iscsi.portal.delete');
      expect(harness.state.phase, AdminPhase.unknown);
      expect(harness.state.message, isNot(contains('TEST-SECRET')));
      expect(harness.state.message, isNot(contains('payload')));
      expect(harness.manager.requests, hasLength(1));
      expect(harness.manager.polledJobs, isEmpty);
      await harness.quickExecute();
      expect(harness.manager.quickCommands, [_quickCommand]);
    },
  );

  test(
    'typed preflight rejection is failed rather than successful or retried',
    () async {
      final harness = _Harness(
        _AdminManager(
          onInvoke: (_) async {
            throw const AdminException(AdminExceptionReason.unsupportedVersion);
          },
        ),
      );
      addTearDown(harness.dispose);
      await harness.execute('iscsi.portal.delete');
      expect(harness.state.phase, AdminPhase.failed);
      expect(harness.state.message, contains('25.10'));
      expect(harness.manager.requests, hasLength(1));
      expect(harness.manager.polledJobs, isEmpty);
    },
  );

  test('permission rejection is shown without an automatic retry', () async {
    final harness = _Harness(
      _AdminManager(
        onInvoke: (request) async =>
            AdminFailed(request, reason: AdminFailureReason.denied),
      ),
    );
    addTearDown(harness.dispose);
    await harness.execute('iscsi.portal.delete');
    expect(harness.state.phase, AdminPhase.failed);
    expect(harness.state.message, contains('permission'));
    expect(harness.manager.requests, hasLength(1));
    expect(harness.manager.polledJobs, isEmpty);
  });
}

AdminOperationDefinition _operation(String method) => adminOperationDefinitions
    .singleWhere((operation) => operation.method == method);

AuthenticatedSession _session(
  _AdminManager manager, {
  String profileId = 'nas',
}) => AuthenticatedSession(
  profileId: profileId,
  repository: manager,
  availableMethodNames: manager.adminCatalog.methods.keys.toSet(),
  version: '25.10.1',
);

class _Harness {
  _Harness(this.manager, {Future<void> Function()? delay}) {
    session = _session(manager);
    active = session;
    container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith((ref) => active),
        adminPollDelayProvider.overrideWithValue(delay ?? () async {}),
        managementPollDelayProvider.overrideWithValue(() async {}),
      ],
    );
  }
  final _AdminManager manager;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AdminOperationState get state => container.read(adminControllerProvider);
  ManagementState get quickState =>
      container.read(managementControllerProvider);

  Future<void> execute(String method, {AdminOperationDefinition? operation}) {
    final spec = manager.adminCatalog.method(method)!;
    return container
        .read(adminControllerProvider.notifier)
        .execute(
          expectedSession: session,
          operation: operation ?? _operation(method),
          request: AdminRequest(
            method: spec,
            arguments: spec.parameters.isEmpty
                ? const []
                : method == 'iscsi.portal.delete'
                ? const [7]
                : const ['fixture-target'],
          ),
          serverLabel: _serverLabel,
        );
  }

  Future<void> quickExecute() => container
      .read(managementControllerProvider.notifier)
      .execute(
        expectedSession: session,
        serverLabel: _serverLabel,
        command: _quickCommand,
      );

  void switchSession(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
  }

  void dispose() => container.dispose();
}

Map<String, Object?> _method({bool job = false, bool target = false}) => {
  'accepts': [
    if (target) {'_name_': 'id', '_required_': true, 'type': 'string'},
  ],
  'returns': [
    {'type': 'null'},
  ],
  'job': job,
  'no_auth_required': false,
  'filterable': false,
  'uploadable': false,
  'downloadable': false,
  'roles': ['FULL_ADMIN'],
};

class _AdminManager
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedSessionManagement {
  _AdminManager({this.onInvoke, this.onPoll, this.onQuickExecute});
  final Future<AdminResult> Function(AdminRequest)? onInvoke;
  final Future<AdminResult> Function(AdminJobSubmitted)? onPoll;
  final Future<ManagementResult> Function(ManagementCommand)? onQuickExecute;
  final requests = <AdminRequest>[];
  final polledJobs = <AdminJobSubmitted>[];
  final quickCommands = <ManagementCommand>[];

  @override
  final adminCatalog = AdminCatalog.fromMetadata(
    version: '25.10.1',
    metadata: {
      'pool.query': _method(),
      // Synthetic generic lifecycle fixture. Alerts and cron now require
      // native gateways; these tests verify controller locking, not iSCSI RPC.
      'iscsi.portal.delete': {
        ..._method(),
        'accepts': [
          {'_name_': 'id', '_required_': true, 'type': 'integer'},
        ],
      },
      'iscsi.portal.update': _method(),
      'iscsi.portal.listen_ip_choices': _method(),
      'iscsi.extent.get_instance': _method(),
      'iscsi.extent.update': _method(),
      'iscsi.target.validate_name': _method(),
      'iscsi.target.create': _method(),
      'iscsi.initiator.create': _method(),
      'iscsi.target.delete': _method(),
      'iscsi.target.update': _method(),
      'iscsi.target.get_instance': _method(),
      'alert.list': _method(),
      for (final name in [
        'cronjob.query',
        'cronjob.create',
        'cronjob.update',
        'cronjob.delete',
        'cronjob.run',
        'initshutdownscript.query',
        'initshutdownscript.create',
        'system.reboot',
        'system.shutdown',
        'rsynctask.query',
        'rsynctask.create',
        'rsynctask.update',
        'rsynctask.delete',
        'rsynctask.run',
        'disk.query',
        'disk.update',
        'disk.temperatures',
        'pool.scrub.query',
        'pool.scrub.create',
        'pool.scrub.update',
        'pool.scrub.delete',
        'pool.scrub.run',
        'pool.scrub.scrub',
      ])
        name: _method(),
      'alert.dismiss': _method(target: true),
      'alert.restore': _method(target: true),
      'app.start': _method(job: true, target: true),
      'core.get_jobs': _method(),
      'pool.dataset.delete': _method(target: true),
    },
  );

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    requests.add(request);
    return onInvoke == null
        ? AdminCompleted(request, value: null)
        : await onInvoke!(request);
  }

  @override
  Future<AdminResult> pollAdminJob(AdminJobSubmitted job) async {
    polledJobs.add(job);
    return onPoll == null
        ? AdminCompleted(job.request, value: true)
        : await onPoll!(job);
  }

  @override
  ManagementCapabilities get managementCapabilities => ManagementCapabilities(
    connected: true,
    versionSupported: true,
    availableActions: ManagementAction.values.toSet(),
  );
  @override
  Future<ManagementResult> execute(ManagementCommand command) async {
    quickCommands.add(command);
    return onQuickExecute == null
        ? ManagementCompleted(command)
        : await onQuickExecute!(command);
  }

  @override
  Future<ManagementResult> pollJob(ManagementJobSubmitted job) async =>
      ManagementCompleted(job.command);
  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnsupportedError('Tests never contact a TrueNAS server.');
}
