import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_subsystem_create_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_subsystem_delete_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_subsystem_delete_editor.dart';
import 'package:trueraid/features/nvme/nvme_subsystem_restrict_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_subsystem_restrict_editor.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _queries = [
  'nvmet.subsys.query',
  'nvmet.port.query',
  'nvmet.namespace.query',
  'nvmet.port_subsys.query',
];

Map<String, Object?> _method() => {
  'accepts': <Object?>[],
  'returns': [
    {
      'type': 'array',
      'items': {'type': 'object'},
    },
  ],
  'job': false,
  'filterable': true,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'roles': ['FULL_ADMIN'],
};

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession {
  _Fake({this.advertiseDelete = true}) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        for (final name in _queries) name: _method(),
        'nvmet.host.query': _method(),
        'nvmet.host_subsys.query': _method(),
        if (advertiseDelete) 'nvmet.subsys.delete': _method(),
        'nvmet.subsys.update': _method(),
      },
    );
  }

  final bool advertiseDelete;
  @override
  late final AdminCatalog adminCatalog;
  final calls = <AdminRequest>[];
  int hostReads = 0;
  final subsystems = <Map<String, Object?>>[
    {'id': 1, 'name': 'empty', 'allow_any_host': false},
    {'id': 2, 'name': 'other', 'allow_any_host': false},
  ];
  final ports = <Map<String, Object?>>[];
  final namespaces = <Map<String, Object?>>[];
  final portMappings = <Map<String, Object?>>[];
  final hostMappings = <Map<String, Object?>>[];
  bool unknownDelete = false;
  bool unknownUpdate = false;
  bool driftAfterUpdate = false;
  bool nqnDriftAfterUpdate = false;
  bool driftBeforeDelete = false;
  bool driftAfterDelete = false;
  int subsysReads = 0;

  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    hostReads++;
    return NvmeHostPublicRows.project(
      [
        {'id': 8, 'hostnqn': 'nqn.fixture:host', 'dhchap_key': 'private-key'},
      ],
      [for (final row in hostMappings) Map.of(row)],
    );
  }

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'nvmet.subsys.query':
        subsysReads++;
        if (driftBeforeDelete && subsysReads == 2) {
          subsystems.add({'id': 3, 'name': 'changed', 'allow_any_host': false});
        }
        return AdminCompleted(
          request,
          value: [for (final row in subsystems) Map.of(row)],
        );
      case 'nvmet.port.query':
        return AdminCompleted(
          request,
          value: [for (final row in ports) Map.of(row)],
        );
      case 'nvmet.namespace.query':
        return AdminCompleted(
          request,
          value: [for (final row in namespaces) Map.of(row)],
        );
      case 'nvmet.port_subsys.query':
        return AdminCompleted(
          request,
          value: [for (final row in portMappings) Map.of(row)],
        );
      case 'nvmet.subsys.delete':
        if (unknownDelete) return AdminOutcomeUnknown(request);
        subsystems.removeWhere((row) => row['id'] == request.arguments.first);
        if (driftAfterDelete) {
          subsystems.add({
            'id': 4,
            'name': 'other-admin',
            'allow_any_host': false,
          });
        }
        return AdminCompleted(request, value: true);
      case 'nvmet.subsys.update':
        if (unknownUpdate) return AdminOutcomeUnknown(request);
        final id = request.arguments.first;
        final payload = request.arguments[1] as Map;
        final row = subsystems.singleWhere((row) => row['id'] == id);
        row['allow_any_host'] = payload['allow_any_host'];
        if (nqnDriftAfterUpdate) {
          row['subnqn'] = 'nqn.2026-09.example:unexpected';
        }
        if (driftAfterUpdate) {
          subsystems.add({
            'id': 4,
            'name': 'other-admin',
            'allow_any_host': false,
          });
        }
        return AdminCompleted(request, value: Map.of(row));
      default:
        throw StateError('Unexpected fake call');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({bool advertiseDelete = true})
    : api = _Fake(advertiseDelete: advertiseDelete) {
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    coordinator = NvmeSubsystemDeleteCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
    restrictCoordinator = NvmeSubsystemRestrictCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }

  final _Fake api;
  late final AuthenticatedSession session;
  late final NvmeSubsystemDeleteCoordinator coordinator;
  late final NvmeSubsystemRestrictCoordinator restrictCoordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'nvmet.subsys.delete')
      .length;
  int get updates => api.calls
      .where((call) => call.method.name == 'nvmet.subsys.update')
      .length;
}

void main() {
  test('deletes only an empty restricted subsystem with force false and fresh readback', () async {
    final h = _Harness();
    final review = await h.coordinator.prepare(1);
    expect(review.confirmation, 'DELETE NVME SUBSYSTEM 1 empty');
    expect(h.writes, 0);
    final result = await h.coordinator.execute(review, review.confirmation);
    expect(result.outcome, NvmeDeleteOutcome.completed);
    expect(h.writes, 1);
    expect(h.api.hostReads, 3);
    expect(h.api.calls.map((call) => call.method.name), [
      ..._queries,
      ..._queries,
      'nvmet.subsys.delete',
      ..._queries,
    ]);
    expect(h.api.calls[8].arguments, [
      1,
      {'force': false},
    ]);
    expect(h.api.subsystems.any((row) => row['id'] == 1), false);
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmeDeleteOutcome.rejected,
    );
  });

  test(
    'missing method and all three dependency types block deletion',
    () async {
      final missing = _Harness(advertiseDelete: false);
      expect(missing.coordinator.available, false);
      await expectLater(missing.coordinator.prepare(1), throwsStateError);

      final host = _Harness();
      host.api.hostMappings.add({
        'id': 9,
        'host': {'id': 8},
        'subsys': {'id': 1},
      });
      await expectLater(host.coordinator.prepare(1), throwsStateError);
      expect(host.writes, 0);

      final port = _Harness();
      port.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': true});
      port.api.portMappings.add({
        'id': 10,
        'port': {'id': 7},
        'subsys': {'id': 1},
      });
      await expectLater(port.coordinator.prepare(1), throwsStateError);
      expect(port.writes, 0);

      final namespace = _Harness();
      namespace.api.namespaces.add({
        'id': 11,
        'nsid': 1,
        'subsys': {'id': 1},
        'device_type': 'ZVOL',
        'enabled': true,
        'locked': false,
      });
      await expectLater(namespace.coordinator.prepare(1), throwsStateError);
      expect(namespace.writes, 0);

      final open = _Harness();
      open.api.subsystems[0]['allow_any_host'] = true;
      await expectLater(open.coordinator.prepare(1), throwsStateError);
      expect(open.writes, 0);
    },
  );

  test(
    'wrong phrase, expiry, session change and drift reject before submission',
    () async {
      final h = _Harness();
      final first = await h.coordinator.prepare(1);
      expect(
        (await h.coordinator.execute(first, 'wrong')).outcome,
        NvmeDeleteOutcome.rejected,
      );
      final second = await h.coordinator.prepare(1);
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.coordinator.execute(second, second.confirmation)).outcome,
        NvmeDeleteOutcome.rejected,
      );
      final third = await h.coordinator.prepare(1);
      h.current = false;
      expect(
        (await h.coordinator.execute(third, third.confirmation)).outcome,
        NvmeDeleteOutcome.rejected,
      );
      h.current = true;
      final fourth = await h.coordinator.prepare(1);
      h.api.hostMappings.add({
        'id': 9,
        'host': {'id': 8},
        'subsys': {'id': 1},
      });
      expect(
        (await h.coordinator.execute(fourth, fourth.confirmation)).outcome,
        NvmeDeleteOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  test('ambiguous response or postwrite drift fences NVMe edits', () async {
    final h = _Harness();
    h.api.unknownDelete = true;
    final review = await h.coordinator.prepare(1);
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmeDeleteOutcome.unknown,
    );
    expect(h.coordinator.locked, true);
    expect(NvmeWriteFence.isUncertain(h.session), true);
    await expectLater(h.coordinator.prepare(2), throwsStateError);
    expect(h.writes, 1);

    final other = _Harness();
    other.api.driftAfterDelete = true;
    final otherReview = await other.coordinator.prepare(1);
    expect(
      (await other.coordinator.execute(
        otherReview,
        otherReview.confirmation,
      )).outcome,
      NvmeDeleteOutcome.unknown,
    );
    expect(other.coordinator.locked, true);
  });

  testWidgets('editor confirms exact ID and name before fake delete', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmeSubsystemDeleteEditor()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-delete-id')),
      '1',
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-delete-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.text('Delete subsystem #1: empty'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-delete-confirmation')),
      'DELETE NVME SUBSYSTEM 1 empty',
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-delete-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(h.api.subsystems.any((row) => row['id'] == 1), false);
  });

  test(
    'restriction updates only allow_any_host after complete rereads',
    () async {
      final h = _Harness();
      h.api.subsystems[0]['allow_any_host'] = true;
      final review = await h.restrictCoordinator.prepare(1);
      expect(review.confirmation, 'RESTRICT NVME SUBSYSTEM 1 empty');
      expect(h.updates, 0);
      final result = await h.restrictCoordinator.execute(
        review,
        review.confirmation,
      );
      expect(result.outcome, NvmeRestrictOutcome.completed);
      expect(h.updates, 1);
      expect(h.api.calls.map((c) => c.method.name), [
        ..._queries,
        ..._queries,
        'nvmet.subsys.update',
        ..._queries,
      ]);
      expect(h.api.calls[8].arguments, [
        1,
        {'allow_any_host': false},
      ]);
      expect(h.api.hostReads, 3);
      expect(
        (await h.restrictCoordinator.execute(
          review,
          review.confirmation,
        )).outcome,
        NvmeRestrictOutcome.rejected,
      );
    },
  );

  test(
    'restriction rejects already restricted and all association types',
    () async {
      final already = _Harness();
      await expectLater(
        already.restrictCoordinator.prepare(1),
        throwsStateError,
      );
      expect(already.updates, 0);

      final host = _Harness();
      host.api.subsystems[0]['allow_any_host'] = true;
      host.api.hostMappings.add({
        'id': 9,
        'host': {'id': 8},
        'subsys': {'id': 1},
      });
      await expectLater(host.restrictCoordinator.prepare(1), throwsStateError);
      expect(host.updates, 0);

      final port = _Harness();
      port.api.subsystems[0]['allow_any_host'] = true;
      port.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': true});
      port.api.portMappings.add({
        'id': 10,
        'port': {'id': 7},
        'subsys': {'id': 1},
      });
      await expectLater(port.restrictCoordinator.prepare(1), throwsStateError);
      expect(port.updates, 0);

      final namespace = _Harness();
      namespace.api.subsystems[0]['allow_any_host'] = true;
      namespace.api.namespaces.add({
        'id': 11,
        'nsid': 1,
        'subsys': {'id': 1},
        'device_type': 'ZVOL',
        'enabled': true,
        'locked': false,
      });
      await expectLater(
        namespace.restrictCoordinator.prepare(1),
        throwsStateError,
      );
      expect(namespace.updates, 0);
    },
  );

  test(
    'restriction rejects wrong phrase, expiration and changed host state',
    () async {
      final h = _Harness();
      h.api.subsystems[0]['allow_any_host'] = true;
      final first = await h.restrictCoordinator.prepare(1);
      expect(
        (await h.restrictCoordinator.execute(first, 'wrong')).outcome,
        NvmeRestrictOutcome.rejected,
      );
      final second = await h.restrictCoordinator.prepare(1);
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.restrictCoordinator.execute(
          second,
          second.confirmation,
        )).outcome,
        NvmeRestrictOutcome.rejected,
      );
      final third = await h.restrictCoordinator.prepare(1);
      h.api.hostMappings.add({
        'id': 9,
        'host': {'id': 8},
        'subsys': {'id': 1},
      });
      expect(
        (await h.restrictCoordinator.execute(
          third,
          third.confirmation,
        )).outcome,
        NvmeRestrictOutcome.rejected,
      );
      expect(h.updates, 0);
    },
  );

  test(
    'restriction uncertain response and readback drift fence NVMe edits',
    () async {
      final h = _Harness();
      h.api.subsystems[0]['allow_any_host'] = true;
      h.api.unknownUpdate = true;
      final review = await h.restrictCoordinator.prepare(1);
      expect(
        (await h.restrictCoordinator.execute(
          review,
          review.confirmation,
        )).outcome,
        NvmeRestrictOutcome.unknown,
      );
      expect(h.restrictCoordinator.locked, true);
      expect(h.coordinator.locked, true);

      final other = _Harness();
      other.api.subsystems[0]['allow_any_host'] = true;
      other.api.driftAfterUpdate = true;
      final otherReview = await other.restrictCoordinator.prepare(1);
      expect(
        (await other.restrictCoordinator.execute(
          otherReview,
          otherReview.confirmation,
        )).outcome,
        NvmeRestrictOutcome.unknown,
      );
      expect(other.restrictCoordinator.locked, true);

      final nqnDrift = _Harness();
      nqnDrift.api.subsystems[0]['allow_any_host'] = true;
      nqnDrift.api.subsystems[0]['subnqn'] = 'nqn.2026-09.example:stable';
      nqnDrift.api.nqnDriftAfterUpdate = true;
      final nqnReview = await nqnDrift.restrictCoordinator.prepare(1);
      expect(
        (await nqnDrift.restrictCoordinator.execute(
          nqnReview,
          nqnReview.confirmation,
        )).outcome,
        NvmeRestrictOutcome.unknown,
      );
      expect(nqnDrift.restrictCoordinator.locked, true);
    },
  );

  testWidgets('restriction editor requires exact ID and phrase', (
    tester,
  ) async {
    final h = _Harness();
    h.api.subsystems[0]['allow_any_host'] = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmeSubsystemRestrictEditor()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-restrict-id')),
      '1',
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-restrict-review')));
    await tester.pumpAndSettle();
    expect(h.updates, 0);
    expect(find.text('Restrict subsystem #1: empty'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-restrict-confirmation')),
      'RESTRICT NVME SUBSYSTEM 1 empty',
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-restrict-submit')));
    await tester.pumpAndSettle();
    expect(h.updates, 1);
    expect(h.api.subsystems[0]['allow_any_host'], false);
  });
}
