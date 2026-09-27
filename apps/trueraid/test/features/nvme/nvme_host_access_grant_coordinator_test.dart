import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_host_access_grant_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_port_access_grant_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_port_access_grant_editor.dart';
import 'package:trueraid/features/nvme/nvme_port_delete_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_port_delete_editor.dart';
import 'package:trueraid/features/nvme/nvme_subsystem_create_coordinator.dart';
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
        AuthenticatedNvmeHostSession,
        AuthenticatedNvmeHostAccessSession,
        AuthenticatedNvmePortAccessSession {
  _Fake({this.advertiseCreate = true, this.advertisePortCreate = true}) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        for (final name in _queries) name: _method(),
        'nvmet.host.query': _method(),
        'nvmet.host_subsys.query': _method(),
        if (advertiseCreate) 'nvmet.host_subsys.create': _method(),
        if (advertisePortCreate) 'nvmet.port_subsys.create': _method(),
        'nvmet.port.delete': _method(),
      },
    );
  }

  final bool advertiseCreate;
  final bool advertisePortCreate;
  @override
  late final AdminCatalog adminCatalog;
  final calls = <AdminRequest>[];
  final subsystems = <Map<String, Object?>>[
    {
      'id': 1,
      'name': 'empty',
      'subnqn': 'nqn.2026-09.example:empty',
      'allow_any_host': false,
    },
  ];
  final ports = <Map<String, Object?>>[];
  final namespaces = <Map<String, Object?>>[];
  final portMappings = <Map<String, Object?>>[];
  final hostMappings = <Map<String, Object?>>[];
  int hostReads = 0;
  int writes = 0;
  int portWrites = 0;
  bool unknown = false;
  bool driftAfterWrite = false;
  bool driftBeforeWrite = false;
  bool unknownPortWrite = false;
  bool driftAfterPortWrite = false;
  bool unknownPortDelete = false;
  bool driftAfterPortDelete = false;

  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    hostReads++;
    return NvmeHostPublicRows.project(
      [
        {'id': 8, 'hostnqn': 'nqn.fixture:host', 'dhchap_key': 'secret'},
      ],
      [for (final row in hostMappings) Map.of(row)],
    );
  }

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    final name = request.method.name;
    if (name == 'nvmet.port.delete') {
      if (unknownPortDelete) return AdminOutcomeUnknown(request);
      ports.removeWhere((row) => row['id'] == request.arguments.first);
      if (driftAfterPortDelete) subsystems.first['name'] = 'changed';
      return AdminCompleted(request, value: true);
    }
    if (driftBeforeWrite && name == 'nvmet.subsys.query') {
      subsystems.first['name'] = 'changed';
    }
    final rows = switch (name) {
      'nvmet.subsys.query' => subsystems,
      'nvmet.port.query' => ports,
      'nvmet.namespace.query' => namespaces,
      'nvmet.port_subsys.query' => portMappings,
      _ => throw StateError('Unexpected fake call: $name'),
    };
    return AdminCompleted(
      request,
      value: [for (final row in rows) Map.of(row)],
    );
  }

  @override
  Future<NvmeHostAssociationCreated> createNvmeHostAssociation({
    required int hostId,
    required int subsystemId,
  }) async {
    writes++;
    if (unknown) throw StateError('lost response');
    hostMappings.add({
      'id': 10,
      'host': {'id': hostId},
      'subsys': {'id': subsystemId},
    });
    if (driftAfterWrite) subsystems.first['name'] = 'changed';
    return NvmeHostAssociationCreated(10, hostId, subsystemId);
  }

  @override
  Future<NvmePortAssociationCreated> createNvmePortAssociation({
    required int portId,
    required int subsystemId,
  }) async {
    portWrites++;
    if (unknownPortWrite) throw StateError('lost response');
    portMappings.add({
      'id': 11,
      'port': {'id': portId},
      'subsys': {'id': subsystemId},
    });
    if (driftAfterPortWrite) subsystems.first['name'] = 'changed';
    return NvmePortAssociationCreated(11, portId, subsystemId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({bool advertiseCreate = true, bool advertisePortCreate = true})
    : api = _Fake(
        advertiseCreate: advertiseCreate,
        advertisePortCreate: advertisePortCreate,
      ) {
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    coordinator = NvmeHostAccessGrantCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      accessApi: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
    portCoordinator = NvmePortAccessGrantCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      accessApi: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
    portDeleteCoordinator = NvmePortDeleteCoordinator(
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
  late final NvmeHostAccessGrantCoordinator coordinator;
  late final NvmePortAccessGrantCoordinator portCoordinator;
  late final NvmePortDeleteCoordinator portDeleteCoordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
}

void main() {
  test('grants once after two matching reviews and fresh readback', () async {
    final h = _Harness();
    expect(h.coordinator.available, isTrue);
    final review = await h.coordinator.prepare(8, 1);
    expect(review.hostNqn, 'nqn.fixture:host');
    expect(review.subnqn, 'nqn.2026-09.example:empty');
    expect(h.api.writes, 0);
    final result = await h.coordinator.execute(review, review.confirmation);
    expect(result.outcome, NvmeHostGrantOutcome.completed);
    expect(h.api.writes, 1);
    expect(h.api.hostReads, 3);
    expect(h.api.calls.map((c) => c.method.name), [
      ..._queries,
      ..._queries,
      ..._queries,
    ]);
    expect(h.api.hostMappings.single['id'], 10);
  });

  test(
    'rejects unsafe target and missing advertised method without writes',
    () async {
      final missing = _Harness(advertiseCreate: false);
      expect(missing.coordinator.available, isFalse);
      await expectLater(missing.coordinator.prepare(8, 1), throwsStateError);
      final open = _Harness();
      open.api.subsystems.first['allow_any_host'] = true;
      await expectLater(open.coordinator.prepare(8, 1), throwsStateError);
      final duplicate = _Harness();
      duplicate.api.hostMappings.add({
        'id': 9,
        'host': {'id': 8},
        'subsys': {'id': 1},
      });
      await expectLater(duplicate.coordinator.prepare(8, 1), throwsStateError);
      expect(missing.api.writes + open.api.writes + duplicate.api.writes, 0);
    },
  );

  test('rejects namespace or port association before write', () async {
    final namespace = _Harness();
    namespace.api.namespaces.add({
      'id': 1,
      'nsid': 1,
      'subsys': {'id': 1},
      'device_type': 'ZVOL',
      'enabled': true,
    });
    await expectLater(namespace.coordinator.prepare(8, 1), throwsStateError);
    final port = _Harness();
    port.api.ports.add({'id': 2, 'addr_trtype': 'TCP', 'enabled': true});
    port.api.portMappings.add({
      'id': 3,
      'port': {'id': 2},
      'subsys': {'id': 1},
    });
    await expectLater(port.coordinator.prepare(8, 1), throwsStateError);
    expect(namespace.api.writes + port.api.writes, 0);
  });

  test('confirmation, expiry and prewrite drift all prevent write', () async {
    final h = _Harness();
    final first = await h.coordinator.prepare(8, 1);
    expect(
      (await h.coordinator.execute(first, 'wrong')).outcome,
      NvmeHostGrantOutcome.rejected,
    );
    final second = await h.coordinator.prepare(8, 1);
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(second, second.confirmation)).outcome,
      NvmeHostGrantOutcome.rejected,
    );
    final third = await h.coordinator.prepare(8, 1);
    h.api.driftBeforeWrite = true;
    expect(
      (await h.coordinator.execute(third, third.confirmation)).outcome,
      NvmeHostGrantOutcome.rejected,
    );
    expect(h.api.writes, 0);
  });

  test('ambiguous result and readback drift fence further edits', () async {
    for (final drift in [false, true]) {
      final h = _Harness();
      final review = await h.coordinator.prepare(8, 1);
      h.api.unknown = !drift;
      h.api.driftAfterWrite = drift;
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, NvmeHostGrantOutcome.unknown);
      expect(h.api.writes, 1);
      expect(NvmeWriteFence.isUncertain(h.session), isTrue);
      expect(h.coordinator.locked, isTrue);
    }
  });

  test(
    'maps one disabled unused port to an empty restricted subsystem',
    () async {
      final h = _Harness();
      h.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
      final review = await h.portCoordinator.prepare(7, 1);
      expect(review.confirmation, 'MAP NVME PORT 7 TO SUBSYSTEM 1');
      expect(h.api.portWrites, 0);
      final result = await h.portCoordinator.execute(
        review,
        review.confirmation,
      );
      expect(result.outcome, NvmePortGrantOutcome.completed);
      expect(h.api.portWrites, 1);
      expect(h.api.hostReads, 3);
      expect(h.api.portMappings.single['id'], 11);
    },
  );

  test('enabled or mapped port, namespace, host grant and unavailable method block mapping', () async {
    final enabled = _Harness();
    enabled.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': true});
    await expectLater(enabled.portCoordinator.prepare(7, 1), throwsStateError);
    final mapped = _Harness();
    mapped.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
    mapped.api.portMappings.add({
      'id': 5,
      'port': {'id': 7},
      'subsys': {'id': 1},
    });
    await expectLater(mapped.portCoordinator.prepare(7, 1), throwsStateError);
    final namespace = _Harness();
    namespace.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
    namespace.api.namespaces.add({
      'id': 5,
      'nsid': 1,
      'subsys': {'id': 1},
      'device_type': 'ZVOL',
      'enabled': true,
    });
    await expectLater(
      namespace.portCoordinator.prepare(7, 1),
      throwsStateError,
    );
    final host = _Harness();
    host.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
    host.api.hostMappings.add({
      'id': 5,
      'host': {'id': 8},
      'subsys': {'id': 1},
    });
    await expectLater(host.portCoordinator.prepare(7, 1), throwsStateError);
    final missing = _Harness(advertisePortCreate: false);
    missing.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
    expect(missing.portCoordinator.available, false);
    await expectLater(missing.portCoordinator.prepare(7, 1), throwsStateError);
    expect(
      enabled.api.portWrites +
          mapped.api.portWrites +
          namespace.api.portWrites +
          host.api.portWrites +
          missing.api.portWrites,
      0,
    );
  });

  test(
    'port mapping confirmation, expiry and prewrite drift prevent writes',
    () async {
      final h = _Harness();
      h.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
      final first = await h.portCoordinator.prepare(7, 1);
      expect(
        (await h.portCoordinator.execute(first, 'wrong')).outcome,
        NvmePortGrantOutcome.rejected,
      );
      final second = await h.portCoordinator.prepare(7, 1);
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.portCoordinator.execute(second, second.confirmation)).outcome,
        NvmePortGrantOutcome.rejected,
      );
      final third = await h.portCoordinator.prepare(7, 1);
      h.api.ports.first['enabled'] = true;
      expect(
        (await h.portCoordinator.execute(third, third.confirmation)).outcome,
        NvmePortGrantOutcome.rejected,
      );
      expect(h.api.portWrites, 0);
    },
  );

  test('ambiguous port mapping or divergent readback fences edits', () async {
    for (final drift in [false, true]) {
      final h = _Harness();
      h.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
      final review = await h.portCoordinator.prepare(7, 1);
      h.api.unknownPortWrite = !drift;
      h.api.driftAfterPortWrite = drift;
      final result = await h.portCoordinator.execute(
        review,
        review.confirmation,
      );
      expect(result.outcome, NvmePortGrantOutcome.unknown);
      expect(h.api.portWrites, 1);
      expect(h.portCoordinator.locked, true);
      expect(NvmeWriteFence.isUncertain(h.session), true);
    }
  });

  testWidgets('port mapping editor requires exact phrase and hides secrets', (
    tester,
  ) async {
    final h = _Harness();
    h.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmePortAccessGrantEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('nvme-port-grant-port-id')),
      '7',
    );
    await tester.enterText(
      find.byKey(const Key('nvme-port-grant-subsystem-id')),
      '1',
    );
    await tester.tap(find.byKey(const Key('nvme-port-grant-review')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Disabled port #7'), findsOneWidget);
    expect(find.textContaining('nqn.2026-09.example:empty'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    expect(h.api.portWrites, 0);
    await tester.enterText(
      find.byKey(const Key('nvme-port-grant-confirmation')),
      'MAP NVME PORT 7 TO SUBSYSTEM 1',
    );
    await tester.ensureVisible(find.byKey(const Key('nvme-port-grant-submit')));
    await tester.tap(find.byKey(const Key('nvme-port-grant-submit')));
    await tester.pumpAndSettle();
    expect(h.api.portWrites, 1);
    expect(tester.takeException(), isNull);
  });

  test(
    'deletes only disabled unused port with force false and fresh readback',
    () async {
      final h = _Harness();
      h.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
      final review = await h.portDeleteCoordinator.prepare(7);
      expect(review.confirmation, 'DELETE DISABLED NVME PORT 7 TCP');
      expect(h.api.calls.length, 4);
      final result = await h.portDeleteCoordinator.execute(
        review,
        review.confirmation,
      );
      expect(result.outcome, NvmePortDeleteOutcome.completed);
      expect(h.api.calls[8].method.name, 'nvmet.port.delete');
      expect(h.api.calls[8].arguments, [
        7,
        {'force': false},
      ]);
      expect(h.api.ports, isEmpty);
      expect(h.api.hostReads, 3);
    },
  );

  test(
    'enabled and mapped ports plus wrong phrase and drift block deletion',
    () async {
      final enabled = _Harness();
      enabled.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': true});
      await expectLater(
        enabled.portDeleteCoordinator.prepare(7),
        throwsStateError,
      );
      final mapped = _Harness();
      mapped.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
      mapped.api.portMappings.add({
        'id': 4,
        'port': {'id': 7},
        'subsys': {'id': 1},
      });
      await expectLater(
        mapped.portDeleteCoordinator.prepare(7),
        throwsStateError,
      );
      final h = _Harness();
      h.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
      final first = await h.portDeleteCoordinator.prepare(7);
      expect(
        (await h.portDeleteCoordinator.execute(first, 'wrong')).outcome,
        NvmePortDeleteOutcome.rejected,
      );
      final second = await h.portDeleteCoordinator.prepare(7);
      h.api.ports.first['enabled'] = true;
      expect(
        (await h.portDeleteCoordinator.execute(
          second,
          second.confirmation,
        )).outcome,
        NvmePortDeleteOutcome.rejected,
      );
      expect(
        h.api.calls.where((c) => c.method.name == 'nvmet.port.delete'),
        isEmpty,
      );
    },
  );

  test('ambiguous or divergent port deletion fences further edits', () async {
    for (final drift in [false, true]) {
      final h = _Harness();
      h.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
      final review = await h.portDeleteCoordinator.prepare(7);
      h.api.unknownPortDelete = !drift;
      h.api.driftAfterPortDelete = drift;
      final result = await h.portDeleteCoordinator.execute(
        review,
        review.confirmation,
      );
      expect(result.outcome, NvmePortDeleteOutcome.unknown);
      expect(h.portDeleteCoordinator.locked, true);
      expect(NvmeWriteFence.isUncertain(h.session), true);
    }
  });

  testWidgets('port delete editor reviews target before fake delete', (
    tester,
  ) async {
    final h = _Harness();
    h.api.ports.add({'id': 7, 'addr_trtype': 'TCP', 'enabled': false});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmePortDeleteEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('nvme-port-delete-id')), '7');
    await tester.tap(find.byKey(const Key('nvme-port-delete-review')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Disabled port #7'), findsOneWidget);
    expect(
      h.api.calls.where((c) => c.method.name == 'nvmet.port.delete'),
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('nvme-port-delete-confirmation')),
      'DELETE DISABLED NVME PORT 7 TCP',
    );
    await tester.ensureVisible(
      find.byKey(const Key('nvme-port-delete-submit')),
    );
    await tester.tap(find.byKey(const Key('nvme-port-delete-submit')));
    await tester.pumpAndSettle();
    expect(
      h.api.calls.where((c) => c.method.name == 'nvmet.port.delete'),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });
}
