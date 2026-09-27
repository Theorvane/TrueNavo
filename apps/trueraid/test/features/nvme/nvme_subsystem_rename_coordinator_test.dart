import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_subsystem_rename_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_subsystem_rename_editor.dart';
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
    {'type': 'object'},
  ],
  'job': false,
  'filterable': false,
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
  _Fake() {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        for (final name in _queries) name: _method(),
        'nvmet.host.query': _method(),
        'nvmet.host_subsys.query': _method(),
        'nvmet.subsys.update': _method(),
      },
    );
  }

  @override
  late final AdminCatalog adminCatalog;
  final calls = <AdminRequest>[];
  final subsystems = <Map<String, Object?>>[
    {
      'id': 1,
      'name': 'old',
      'subnqn': 'nqn.2026-09.example:stable',
      'allow_any_host': false,
      'ana': null,
    },
    {'id': 2, 'name': 'other', 'allow_any_host': false},
  ];
  final hostMappings = <Map<String, Object?>>[];
  bool ambiguous = false;
  bool changeNqnAfterWrite = false;
  bool changeAnaAfterWrite = false;
  bool attachHostAfterWrite = false;
  int hostReads = 0;

  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    hostReads++;
    return NvmeHostPublicRows.project(
      [
        {'id': 8, 'hostnqn': 'nqn.2026-09.example:host'},
      ],
      [for (final row in hostMappings) Map.of(row)],
    );
  }

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'nvmet.subsys.query':
        return AdminCompleted(
          request,
          value: [for (final row in subsystems) Map.of(row)],
        );
      case 'nvmet.port.query':
      case 'nvmet.namespace.query':
      case 'nvmet.port_subsys.query':
        return AdminCompleted(request, value: <Object?>[]);
      case 'nvmet.subsys.update':
        if (ambiguous) return AdminOutcomeUnknown(request);
        final id = request.arguments.first;
        final payload = request.arguments[1] as Map;
        final row = subsystems.singleWhere((row) => row['id'] == id);
        row['name'] = payload['name'];
        row['subnqn'] = payload['subnqn'];
        final returned = Map.of(row);
        if (changeNqnAfterWrite) {
          row['subnqn'] = 'nqn.2026-09.example:drift';
        }
        if (changeAnaAfterWrite) {
          row['ana'] = true;
        }
        if (attachHostAfterWrite) {
          hostMappings.add({
            'id': 9,
            'host': {'id': 8},
            'subsys': {'id': 1},
          });
        }
        return AdminCompleted(request, value: returned);
      default:
        throw StateError('Unexpected method');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness() : api = _Fake() {
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    coordinator = NvmeSubsystemRenameCoordinator(
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
  late final NvmeSubsystemRenameCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes =>
      api.calls.where((c) => c.method.name == 'nvmet.subsys.update').length;
}

void main() {
  test(
    'renames only the reviewed unbound subsystem while preserving NQN',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(1, 'new');
      expect(h.writes, 0);
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, NvmeRenameOutcome.completed);
      expect(h.writes, 1);
      expect(h.api.hostReads, 3);
      expect(
        h.api.calls
            .where((c) => c.method.name == 'nvmet.subsys.update')
            .single
            .arguments,
        [
          1,
          {'name': 'new', 'subnqn': 'nqn.2026-09.example:stable'},
        ],
      );
      expect(h.api.subsystems.first['subnqn'], 'nqn.2026-09.example:stable');
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmeRenameOutcome.rejected,
      );
    },
  );

  test(
    'missing NQN, associations, any-host and duplicate names block review',
    () async {
      final missing = _Harness();
      missing.api.subsystems.first.remove('subnqn');
      await expectLater(
        missing.coordinator.prepare(1, 'new'),
        throwsStateError,
      );
      final anyHost = _Harness();
      anyHost.api.subsystems.first['allow_any_host'] = true;
      await expectLater(
        anyHost.coordinator.prepare(1, 'new'),
        throwsStateError,
      );
      final mapped = _Harness();
      mapped.api.hostMappings.add({
        'id': 9,
        'host': {'id': 8},
        'subsys': {'id': 1},
      });
      await expectLater(mapped.coordinator.prepare(1, 'new'), throwsStateError);
      final duplicate = _Harness();
      await expectLater(
        duplicate.coordinator.prepare(1, 'OTHER'),
        throwsStateError,
      );
      expect(
        missing.writes + anyHost.writes + mapped.writes + duplicate.writes,
        0,
      );
    },
  );

  test('stale review and config drift never submit', () async {
    final h = _Harness();
    final wrong = await h.coordinator.prepare(1, 'new');
    expect(
      (await h.coordinator.execute(wrong, 'wrong')).outcome,
      NvmeRenameOutcome.rejected,
    );
    final expired = await h.coordinator.prepare(1, 'new');
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(expired, expired.confirmation)).outcome,
      NvmeRenameOutcome.rejected,
    );
    final changed = await h.coordinator.prepare(1, 'new');
    h.api.subsystems.first['subnqn'] = 'nqn.2026-09.example:changed';
    expect(
      (await h.coordinator.execute(changed, changed.confirmation)).outcome,
      NvmeRenameOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('ambiguous result and NQN readback drift fence further edits', () async {
    final h = _Harness();
    h.api.ambiguous = true;
    final review = await h.coordinator.prepare(1, 'new');
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmeRenameOutcome.unknown,
    );
    expect(h.coordinator.locked, true);
    final other = _Harness();
    other.api.changeNqnAfterWrite = true;
    final next = await other.coordinator.prepare(1, 'new');
    expect(
      (await other.coordinator.execute(next, next.confirmation)).outcome,
      NvmeRenameOutcome.unknown,
    );
    expect(other.coordinator.locked, true);

    final linked = _Harness();
    linked.api.attachHostAfterWrite = true;
    final linkedReview = await linked.coordinator.prepare(1, 'new');
    expect(
      (await linked.coordinator.execute(
        linkedReview,
        linkedReview.confirmation,
      )).outcome,
      NvmeRenameOutcome.unknown,
    );
    expect(linked.coordinator.locked, true);
  });

  test('ANA override drift after rename fences further edits', () async {
    final h = _Harness();
    h.api.changeAnaAfterWrite = true;
    final review = await h.coordinator.prepare(1, 'new');
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmeRenameOutcome.unknown,
    );
    expect(h.writes, 1);
    expect(h.coordinator.locked, true);
  });

  testWidgets('editor requires exact confirmation before fake write', (
    tester,
  ) async {
    final fake = _Fake();
    final session = AuthenticatedSession(
      profileId: 'fixture',
      repository: fake,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => session),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmeSubsystemRenameEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-rename-id')),
      '1',
    );
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-rename-name')),
      'new',
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-rename-review')));
    await tester.pumpAndSettle();
    expect(find.text('Subsystem #1: old → new'), findsOneWidget);
    expect(
      fake.calls.where((c) => c.method.name == 'nvmet.subsys.update'),
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-rename-confirmation')),
      'RENAME NVME SUBSYSTEM 1 old TO new',
    );
    await tester.ensureVisible(
      find.byKey(const Key('nvme-subsystem-rename-submit')),
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-rename-submit')));
    await tester.pumpAndSettle();
    expect(
      fake.calls.where((c) => c.method.name == 'nvmet.subsys.update').length,
      1,
    );
    expect(tester.takeException(), isNull);
  });
}
