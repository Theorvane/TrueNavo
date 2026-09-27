import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_host_access_grant_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_subsystem_create_coordinator.dart';
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
        AuthenticatedNvmeHostAccessSession {
  _Fake({this.advertiseCreate = true}) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        for (final name in _queries) name: _method(),
        'nvmet.host.query': _method(),
        'nvmet.host_subsys.query': _method(),
        if (advertiseCreate) 'nvmet.host_subsys.create': _method(),
      },
    );
  }

  final bool advertiseCreate;
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
  bool unknown = false;
  bool driftAfterWrite = false;
  bool driftBeforeWrite = false;

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({bool advertiseCreate = true})
    : api = _Fake(advertiseCreate: advertiseCreate) {
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
  }

  final _Fake api;
  late final AuthenticatedSession session;
  late final NvmeHostAccessGrantCoordinator coordinator;
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
}
