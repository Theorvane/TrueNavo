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
import 'package:trueraid/features/nvme/nvme_host_access_revoke_editor.dart';
import 'package:trueraid/features/nvme/nvme_host_delete_editor.dart';
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
        'nvmet.host_subsys.delete': _method(),
        'nvmet.host.delete': _method(),
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
  bool unknownHostDelete = false;
  bool unknownOrphanDelete = false;
  bool driftAfterOrphanDelete = false;
  bool driftAfterHostDelete = false;
  bool driftAfterUpdate = false;
  bool nqnDriftAfterUpdate = false;
  bool driftBeforeDelete = false;
  bool driftAfterDelete = false;
  int subsysReads = 0;
  final hosts = <Map<String, Object?>>[
    {'id': 8, 'hostnqn': 'nqn.fixture:host', 'dhchap_key': 'private-key'},
  ];

  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    hostReads++;
    return NvmeHostPublicRows.project(
      [for (final row in hosts) Map.of(row)],
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
      case 'nvmet.host_subsys.delete':
        if (unknownHostDelete) return AdminOutcomeUnknown(request);
        hostMappings.removeWhere(
          (row) => row['id'] == request.arguments.single,
        );
        if (driftAfterHostDelete) {
          subsystems.add({
            'id': 4,
            'name': 'other-admin',
            'allow_any_host': false,
          });
        }
        return AdminCompleted(request, value: true);
      case 'nvmet.host.delete':
        if (unknownOrphanDelete) return AdminOutcomeUnknown(request);
        final id = request.arguments.first;
        hosts.removeWhere((row) => row['id'] == id);
        if (driftAfterOrphanDelete) {
          subsystems.add({
            'id': 4,
            'name': 'other-admin',
            'allow_any_host': false,
          });
        }
        return AdminCompleted(request, value: true);
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
    hostRevokeCoordinator = NvmeHostAccessRevokeCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
    hostDeleteCoordinator = NvmeHostDeleteCoordinator(
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
  late final NvmeHostAccessRevokeCoordinator hostRevokeCoordinator;
  late final NvmeHostDeleteCoordinator hostDeleteCoordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'nvmet.subsys.delete')
      .length;
  int get updates => api.calls
      .where((call) => call.method.name == 'nvmet.subsys.update')
      .length;
  int get hostRevokes => api.calls
      .where((call) => call.method.name == 'nvmet.host_subsys.delete')
      .length;
  int get hostDeletes =>
      api.calls.where((call) => call.method.name == 'nvmet.host.delete').length;
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

  test(
    'revokes only one reviewed host association from a restricted subsystem',
    () async {
      final h = _Harness();
      h.api.hostMappings.addAll([
        {
          'id': 10,
          'host': {'id': 8},
          'subsys': {'id': 1},
        },
        {
          'id': 11,
          'host': {'id': 8},
          'subsys': {'id': 2},
        },
      ]);
      final review = await h.hostRevokeCoordinator.prepare(10);
      expect(review.hostNqn, 'nqn.fixture:host');
      expect(review.subsystemName, 'empty');
      expect(h.hostRevokes, 0);
      final result = await h.hostRevokeCoordinator.execute(
        review,
        review.confirmation,
      );
      expect(result.outcome, NvmeHostRevokeOutcome.completed);
      expect(h.hostRevokes, 1);
      expect(h.api.hostReads, 3);
      expect(
        h.api.calls
            .where((c) => c.method.name == 'nvmet.host_subsys.delete')
            .single
            .arguments,
        [10],
      );
      expect(h.api.hostMappings.single['id'], 11);
      expect(
        (await h.hostRevokeCoordinator.execute(
          review,
          review.confirmation,
        )).outcome,
        NvmeHostRevokeOutcome.rejected,
      );
    },
  );

  test(
    'host revoke rejects missing mapping, any-host policy and prewrite drift',
    () async {
      final missing = _Harness();
      await expectLater(
        missing.hostRevokeCoordinator.prepare(10),
        throwsStateError,
      );
      final anyHost = _Harness();
      anyHost.api.subsystems.first['allow_any_host'] = true;
      anyHost.api.hostMappings.add({
        'id': 10,
        'host': {'id': 8},
        'subsys': {'id': 1},
      });
      await expectLater(
        anyHost.hostRevokeCoordinator.prepare(10),
        throwsStateError,
      );
      final h = _Harness();
      h.api.hostMappings.add({
        'id': 10,
        'host': {'id': 8},
        'subsys': {'id': 1},
      });
      final wrong = await h.hostRevokeCoordinator.prepare(10);
      expect(
        (await h.hostRevokeCoordinator.execute(wrong, 'wrong')).outcome,
        NvmeHostRevokeOutcome.rejected,
      );
      final changed = await h.hostRevokeCoordinator.prepare(10);
      h.api.subsystems.first['name'] = 'changed';
      expect(
        (await h.hostRevokeCoordinator.execute(
          changed,
          changed.confirmation,
        )).outcome,
        NvmeHostRevokeOutcome.rejected,
      );
      expect(h.hostRevokes, 0);
    },
  );

  test('ambiguous host revoke and readback drift fence NVMe writes', () async {
    final unknown = _Harness();
    unknown.api.hostMappings.add({
      'id': 10,
      'host': {'id': 8},
      'subsys': {'id': 1},
    });
    unknown.api.unknownHostDelete = true;
    final review = await unknown.hostRevokeCoordinator.prepare(10);
    expect(
      (await unknown.hostRevokeCoordinator.execute(
        review,
        review.confirmation,
      )).outcome,
      NvmeHostRevokeOutcome.unknown,
    );
    expect(unknown.hostRevokeCoordinator.locked, true);
    expect(unknown.coordinator.locked, true);

    final drift = _Harness();
    drift.api.hostMappings.add({
      'id': 10,
      'host': {'id': 8},
      'subsys': {'id': 1},
    });
    drift.api.driftAfterHostDelete = true;
    final next = await drift.hostRevokeCoordinator.prepare(10);
    expect(
      (await drift.hostRevokeCoordinator.execute(
        next,
        next.confirmation,
      )).outcome,
      NvmeHostRevokeOutcome.unknown,
    );
    expect(drift.hostRevokeCoordinator.locked, true);
  });

  testWidgets('host revoke editor requires exact association confirmation', (
    tester,
  ) async {
    final h = _Harness();
    h.api.hostMappings.add({
      'id': 10,
      'host': {'id': 8},
      'subsys': {'id': 1},
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmeHostAccessRevokeEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('nvme-host-revoke-id')), '10');
    await tester.tap(find.byKey(const Key('nvme-host-revoke-review')));
    await tester.pumpAndSettle();
    expect(find.text('Association #10'), findsOneWidget);
    expect(find.textContaining('nqn.fixture:host'), findsOneWidget);
    expect(find.textContaining('private-key'), findsNothing);
    expect(h.hostRevokes, 0);
    await tester.enterText(
      find.byKey(const Key('nvme-host-revoke-confirmation')),
      'REVOKE NVME HOST 8 FROM SUBSYSTEM 1 MAPPING 10',
    );
    await tester.ensureVisible(
      find.byKey(const Key('nvme-host-revoke-submit')),
    );
    await tester.tap(find.byKey(const Key('nvme-host-revoke-submit')));
    await tester.pumpAndSettle();
    expect(h.hostRevokes, 1);
    expect(tester.takeException(), isNull);
  });

  test(
    'unassociated host deletion uses force false and verified readback',
    () async {
      final h = _Harness();
      final review = await h.hostDeleteCoordinator.prepare(8);
      expect(review.confirmation, 'DELETE NVME HOST 8 nqn.fixture:host');
      expect(h.hostDeletes, 0);
      final result = await h.hostDeleteCoordinator.execute(
        review,
        review.confirmation,
      );
      expect(result.outcome, NvmeHostDeleteOutcome.completed);
      expect(h.hostDeletes, 1);
      expect(h.api.calls[8].arguments, [
        8,
        {'force': false},
      ]);
      expect(h.api.hostReads, 3);
      expect(h.api.hosts, isEmpty);
    },
  );

  test(
    'association, missing identity, wrong phrase and drift block host deletion',
    () async {
      final associated = _Harness();
      associated.api.hostMappings.add({
        'id': 9,
        'host': {'id': 8},
        'subsys': {'id': 1},
      });
      await expectLater(
        associated.hostDeleteCoordinator.prepare(8),
        throwsStateError,
      );
      final missing = _Harness();
      await expectLater(
        missing.hostDeleteCoordinator.prepare(9),
        throwsStateError,
      );
      final h = _Harness();
      final first = await h.hostDeleteCoordinator.prepare(8);
      expect(
        (await h.hostDeleteCoordinator.execute(first, 'wrong')).outcome,
        NvmeHostDeleteOutcome.rejected,
      );
      final second = await h.hostDeleteCoordinator.prepare(8);
      h.api.hosts.first['hostnqn'] = 'nqn.fixture:changed';
      expect(
        (await h.hostDeleteCoordinator.execute(
          second,
          second.confirmation,
        )).outcome,
        NvmeHostDeleteOutcome.rejected,
      );
      expect(associated.hostDeletes + missing.hostDeletes + h.hostDeletes, 0);
    },
  );

  test('ambiguous or divergent host deletion fences NVMe edits', () async {
    for (final drift in [false, true]) {
      final h = _Harness();
      final review = await h.hostDeleteCoordinator.prepare(8);
      h.api.unknownOrphanDelete = !drift;
      h.api.driftAfterOrphanDelete = drift;
      final result = await h.hostDeleteCoordinator.execute(
        review,
        review.confirmation,
      );
      expect(result.outcome, NvmeHostDeleteOutcome.unknown);
      expect(h.hostDeletes, 1);
      expect(h.hostDeleteCoordinator.locked, true);
      expect(NvmeWriteFence.isUncertain(h.session), true);
    }
  });

  testWidgets(
    'host deletion editor shows public NQN only and requires phrase',
    (tester) async {
      final h = _Harness();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          ],
          child: MaterialApp(
            theme: TrueRAIDTheme.dark(),
            home: const Scaffold(
              body: SingleChildScrollView(child: NvmeHostDeleteEditor()),
            ),
          ),
        ),
      );
      await tester.enterText(find.byKey(const Key('nvme-host-delete-id')), '8');
      await tester.tap(find.byKey(const Key('nvme-host-delete-review')));
      await tester.pumpAndSettle();
      expect(find.textContaining('nqn.fixture:host'), findsWidgets);
      expect(find.textContaining('private-key'), findsNothing);
      expect(h.hostDeletes, 0);
      await tester.enterText(
        find.byKey(const Key('nvme-host-delete-confirmation')),
        'DELETE NVME HOST 8 nqn.fixture:host',
      );
      await tester.ensureVisible(
        find.byKey(const Key('nvme-host-delete-submit')),
      );
      await tester.tap(find.byKey(const Key('nvme-host-delete-submit')));
      await tester.pumpAndSettle();
      expect(h.hostDeletes, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
