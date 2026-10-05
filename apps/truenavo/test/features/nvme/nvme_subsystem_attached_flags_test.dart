import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_attached_flags_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_attached_flags_editor.dart';

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession {
  @override
  AdminCatalog adminCatalog = AdminCatalog.fromMetadata(
    version: '25.10.1',
    metadata: {
      for (final name in [
        'nvmet.subsys.query',
        'nvmet.port.query',
        'nvmet.namespace.query',
        'nvmet.port_subsys.query',
        'nvmet.host.query',
        'nvmet.host_subsys.query',
        'nvmet.subsys.update',
      ])
        name: {
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
        },
    },
  );
  final calls = <AdminRequest>[];
  final subsystem = <String, Object?>{
    'id': 2,
    'name': 'unused',
    'subnqn': 'nqn.2026-09.example:unused',
    'allow_any_host': false,
    'ana': false,
    'pi_enable': false,
  };
  final namespace = <String, Object?>{
    'id': 7,
    'nsid': 1,
    'subsys': {'id': 2},
    'device_type': 'ZVOL',
    'enabled': false,
    'locked': false,
  };
  final other = <String, Object?>{
    'id': 8,
    'nsid': 2,
    'subsys': {'id': 4},
    'device_type': 'FILE',
    'enabled': false,
    'locked': false,
  };
  final ports = <Map<String, Object?>>[
    {'id': 3, 'addr_trtype': 'TCP', 'enabled': false},
  ];
  final mappings = <Map<String, Object?>>[
        {
          'id': 11,
          'port': {'id': 3},
          'subsys': {'id': 2},
        },
      ],
      hostMappings = <Map<String, Object?>>[];
  void Function()? onDispatch;
  String? failure;
  bool malformed = false;
  bool extraSubsystem = true;
  Completer<void>? gate;
  final started = Completer<void>();
  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    if (gate != null) {
      if (!started.isCompleted) started.complete();
      await gate!.future;
    }
    return NvmeHostPublicRows.project([
      {'id': 9, 'hostnqn': 'nqn.2026-09.example:host'},
    ], hostMappings);
  }

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    final rows = switch (request.method.name) {
      'nvmet.subsys.query' => [
        Map.of(subsystem),
        if (extraSubsystem)
          {
            'id': 4,
            'name': 'other',
            'subnqn': 'nqn.2026-09.example:other',
            'allow_any_host': false,
          },
      ],
      'nvmet.port.query' => [for (final p in ports) Map.of(p)],
      'nvmet.namespace.query' => [
        malformed ? {'id': 7} : Map.of(namespace),
        Map.of(other),
      ],
      'nvmet.port_subsys.query' => [for (final m in mappings) Map.of(m)],
      _ => null,
    };
    if (rows != null) return AdminCompleted(request, value: rows);
    if (request.method.name != 'nvmet.subsys.update') {
      throw StateError('Unexpected method');
    }
    onDispatch?.call();
    if (failure == 'throw') throw StateError('private-server-error');
    if (failure == 'denied') {
      return AdminFailed(request, reason: AdminFailureReason.denied);
    }
    if (failure == 'unknown') return AdminOutcomeUnknown(request);
    final update = request.arguments[1] as Map;
    final selected = update.keys.single as String;
    subsystem[selected] = update[selected];
    final returned = Map.of(subsystem);
    if (failure == 'response ID') returned['id'] = 999;
    if (failure == 'response NQN') {
      returned['subnqn'] = 'nqn.2026-09.example:wrong';
    }
    if (failure == 'response name') returned['name'] = 'changed';
    if (failure == 'namespace enabled') namespace['enabled'] = true;
    if (failure == 'namespace NSID') namespace['nsid'] = 4;
    if (failure == 'response access') returned['allow_any_host'] = true;
    if (failure == 'response missing flag') returned.remove(selected);
    if (failure == 'readback missing flag') subsystem.remove(selected);
    if (failure == 'response invalid flag') returned[selected] = 'ON';
    if (failure == 'readback invalid flag') subsystem[selected] = 'ON';
    for (final field in ['ana', 'pi_enable', 'qid_max', 'ieee_oui']) {
      if (failure == 'response missing $field') returned.remove(field);
      if (failure == 'readback missing $field') subsystem.remove(field);
      if (failure == 'response $field') {
        returned[field] = subsystem[field] == null
            ? (field == 'qid_max'
                  ? 5
                  : field == 'ieee_oui'
                  ? 'changed'
                  : true)
            : null;
      }
      if (failure == 'readback $field') {
        subsystem[field] = field == 'qid_max'
            ? 5
            : field == 'ieee_oui'
            ? 'changed'
            : subsystem[field] == true
            ? false
            : true;
      }
    }
    if (failure == 'readback NQN') {
      subsystem['subnqn'] = 'nqn.2026-09.example:wrong';
    }
    if (failure == 'readback name') subsystem['name'] = 'changed';
    if (failure == 'other drift') other['nsid'] = 3;
    if (failure == 'namespace attached') namespace['subsys'] = {'id': 4};
    if (failure == 'association') {
      hostMappings.add({
        'id': 10,
        'host': {'id': 9},
        'subsys': {'id': 2},
      });
    }
    if (failure == 'port enabled') ports.single['enabled'] = true;
    if (failure == 'port transport') ports.single['addr_trtype'] = 'FC';
    if (failure == 'port settings') ports.single['pi_enable'] = null;
    if (failure == 'mapping removed') mappings.clear();
    if (failure == 'mapping ID') mappings.single['id'] = 12;
    if (failure == 'mapping pair') mappings.single['subsys'] = {'id': 4};
    if (failure == 'namespace locked') namespace['locked'] = true;
    if (failure == 'namespace FILE') namespace['device_type'] = 'FILE';
    if (failure == 'malformed readback') malformed = true;
    return AdminCompleted(request, value: returned);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness() {
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      endpoint: 'https://fixture.example',
    );
    coordinator = NvmeSubsystemAttachedFlagsCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      lock: lock,
      isCurrent: () => current,
      now: () => now,
    );
  }
  final api = _Fake(), lock = ServerOperationLock();
  late final AuthenticatedSession session;
  late final NvmeSubsystemAttachedFlagsCoordinator coordinator;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  int get writes =>
      api.calls.where((r) => r.method.name == 'nvmet.subsys.update').length;
  Future<NvmeSubsystemAttachedFlagsResult> execute(
    NvmeSubsystemAttachedFlagsReview r, {
    String? phrase,
    bool reload = true,
    bool limitations = true,
    bool client = true,
  }) => coordinator.execute(
    r,
    phrase ?? r.confirmation,
    acknowledgeReload: reload,
    acknowledgeLimitations: limitations,
    acknowledgeClientRisk: client,
  );
}

class _Active extends Notifier<AuthenticatedSession?> {
  @override
  AuthenticatedSession? build() => null;
  void select(AuthenticatedSession session) => state = session;
}

final _active = NotifierProvider<_Active, AuthenticatedSession?>(_Active.new);

const _choice = NvmeAttachedFlagChoice.on;
Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Harness h,
  NvmeAttachedSubsystemFlag field,
) async {
  final container = ProviderContainer(
    overrides: [
      dashboardActiveSessionProvider.overrideWith((ref) => ref.watch(_active)),
      // Keep saved-setting review time deterministic.
      nvmeSubsystemAttachedFlagsCoordinatorProvider.overrideWithValue(
        h.coordinator,
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(_active.notifier).select(h.session);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: TrueNavoTheme.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: NvmeSubsystemAttachedFlagsEditor(),
          ),
        ),
      ),
    ),
  );
  await tester.enterText(
    find.byKey(const Key('nvme-subsystem-attached-flags-id')),
    '2',
  );
  if (field == NvmeAttachedSubsystemFlag.pi) {
    await _select(tester, 'nvme-subsystem-attached-flags-field', 'PI setting');
  }
  await tester.pumpAndSettle();
  return container;
}

Future<void> _select(WidgetTester tester, String key, String label) async {
  final picker = find.byKey(Key(key));
  await tester.ensureVisible(picker);
  await tester.tap(picker);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  for (final field in NvmeAttachedSubsystemFlag.values) {
    group(field.name, () => _tests(field));
  }
}

void _tests(NvmeAttachedSubsystemFlag field) {
  test(
    'RDMA flag preserves populated residents and optional settings',
    () async {
      final h = _Harness();
      h.api.ports.single['addr_trtype'] = 'RDMA';
      h.api.subsystem.addAll({
        'ana': false,
        'pi_enable': null,
        'qid_max': null,
        'ieee_oui': '00:11:22',
      });
      final r = await h.coordinator.prepare(2, field: field, choice: _choice);
      expect(r.port.transport, 'RDMA');
      expect(r.mapping.id, 11);
      expect(
        (await h.execute(r)).outcome,
        NvmeSubsystemAttachedFlagsOutcome.completed,
      );
      expect(h.api.ports.single['enabled'], false);
      expect(h.api.namespace['enabled'], false);
      expect(
        h.api.subsystem['ana'],
        field == NvmeAttachedSubsystemFlag.ana ? true : false,
      );
      expect(
        h.api.subsystem['pi_enable'],
        field == NvmeAttachedSubsystemFlag.pi ? true : null,
      );
      expect(h.api.subsystem['qid_max'], null);
      expect(h.writes, 1);
    },
  );
  for (final transport in ['TCP', 'RDMA']) {
    test('$transport empty attached subsystem keeps its association', () async {
      final h = _Harness();
      h.api.ports.single['addr_trtype'] = transport;
      h.api.namespace['subsys'] = {'id': 4};
      final r = await h.coordinator.prepare(2, field: field, choice: _choice);
      expect(r.namespaces, isEmpty);
      expect(
        (await h.execute(r)).outcome,
        NvmeSubsystemAttachedFlagsOutcome.completed,
      );
      expect(h.api.namespace['subsys'], {'id': 4});
      expect(h.api.mappings.single['id'], 11);
      expect(h.api.ports.single['enabled'], false);
      expect(h.writes, 1);
    });
  }
  test('new review supersedes earlier review', () async {
    final h = _Harness();
    final old = await h.coordinator.prepare(2, field: field, choice: _choice);
    final current = await h.coordinator.prepare(
      2,
      field: field,
      choice: _choice,
    );
    expect(
      (await h.execute(old)).outcome,
      NvmeSubsystemAttachedFlagsOutcome.rejected,
    );
    expect(h.writes, 0);
    expect(
      (await h.execute(current)).outcome,
      NvmeSubsystemAttachedFlagsOutcome.completed,
    );
    expect(h.writes, 1);
  });
  test('oversized port inventory rejects review and fresh preflight', () async {
    void overflow(_Fake a) => a.ports.addAll([
      for (var id = 100; id < 200; id++)
        {'id': id, 'addr_trtype': 'TCP', 'enabled': false},
    ]);
    final a = _Harness();
    overflow(a.api);
    await expectLater(
      a.coordinator.prepare(2, field: field, choice: _choice),
      throwsStateError,
    );
    expect(a.writes, 0);
    final b = _Harness();
    final r = await b.coordinator.prepare(2, field: field, choice: _choice);
    overflow(b.api);
    expect(
      (await b.execute(r)).outcome,
      NvmeSubsystemAttachedFlagsOutcome.rejected,
    );
    expect(b.writes, 0);
  });
  for (final capability in [
    'nvmet.subsys.query',
    'nvmet.port.query',
    'nvmet.namespace.query',
    'nvmet.port_subsys.query',
    'nvmet.host.query',
    'nvmet.host_subsys.query',
    'nvmet.subsys.update',
  ]) {
    test('missing $capability prevents all requests', () async {
      final h = _Harness();
      h.api.adminCatalog = AdminCatalog.fromMetadata(
        version: '25.10.1',
        metadata: {
          for (final name in [
            'nvmet.subsys.query',
            'nvmet.port.query',
            'nvmet.namespace.query',
            'nvmet.port_subsys.query',
            'nvmet.host.query',
            'nvmet.host_subsys.query',
            'nvmet.subsys.update',
          ])
            if (name != capability)
              name: {
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
              },
        },
      );
      expect(h.coordinator.available, false);
      await expectLater(
        h.coordinator.prepare(2, field: field, choice: _choice),
        throwsStateError,
      );
      expect(h.api.calls, isEmpty);
    });
  }
  for (final reason in ['session', 'dispose']) {
    test('$reason after dispatch fences the original session', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(2, field: field, choice: _choice);
      h.api.onDispatch = () {
        if (reason == 'session') h.current = false;
        if (reason == 'dispose') h.coordinator.dispose();
      };
      expect(
        (await h.execute(r)).outcome,
        NvmeSubsystemAttachedFlagsOutcome.unknown,
      );
      expect(h.coordinator.locked, true);
      expect(h.writes, 1);
    });
  }
  test(
    'multiple namespaces are reviewed immutably and remain unchanged',
    () async {
      final h = _Harness();
      h.api.other['subsys'] = {'id': 2};
      h.api.other['device_type'] = 'ZVOL';
      final before = Map.of(h.api.other);
      final review = await h.coordinator.prepare(
        2,
        field: field,
        choice: _choice,
      );
      expect(review.namespaces.map((n) => n.id), [7, 8]);
      expect(() => review.namespaces.clear(), throwsUnsupportedError);
      expect(
        (await h.execute(review)).outcome,
        NvmeSubsystemAttachedFlagsOutcome.completed,
      );
      expect(h.api.other, before);
      expect(h.writes, 1);
    },
  );
  for (final transport in ['TCP', 'RDMA']) {
    for (final populated in [true, false]) {
      for (final initial in [null, true, false]) {
        for (final choice in NvmeAttachedFlagChoice.values) {
          test(
            'one-field $transport populated=$populated $initial to $choice',
            () async {
              final h = _Harness();
              h.api.ports.single['addr_trtype'] = transport;
              if (!populated) h.api.namespace['subsys'] = {'id': 4};
              h.api.subsystem.addAll({
                'ana': false,
                'pi_enable': false,
                'qid_max': 16,
                'ieee_oui': '00:11:22',
                field.wireField: initial,
              });
              if (initial == choice.wireValue) {
                await expectLater(
                  h.coordinator.prepare(2, field: field, choice: choice),
                  throwsStateError,
                );
                expect(h.writes, 0);
                return;
              }
              final before = Map.of(h.api.subsystem);
              final nsBefore = Map.of(h.api.namespace);
              final r = await h.coordinator.prepare(
                2,
                field: field,
                choice: choice,
              );
              expect(r.field, field);
              expect(
                (await h.execute(r)).outcome,
                NvmeSubsystemAttachedFlagsOutcome.completed,
              );
              expect(
                h.api.calls
                    .singleWhere((r) => r.method.name == 'nvmet.subsys.update')
                    .arguments,
                [
                  2,
                  {field.wireField: choice.wireValue},
                ],
              );
              before[field.wireField] = choice.wireValue;
              expect(h.api.subsystem, before);
              expect(h.api.namespace, nsBefore);
              expect(h.api.mappings.single['id'], 11);
              expect(h.api.ports.single['enabled'], false);
              expect(
                (await h.execute(r)).outcome,
                NvmeSubsystemAttachedFlagsOutcome.rejected,
              );
              expect(h.writes, 1);
            },
          );
        }
      }
    }
  }
  test('unreported unselected flag stays absent', () async {
    final h = _Harness();
    final other = field == NvmeAttachedSubsystemFlag.ana ? 'pi_enable' : 'ana';
    h.api.subsystem.remove(other);
    final r = await h.coordinator.prepare(2, field: field, choice: _choice);
    expect(
      (await h.execute(r)).outcome,
      NvmeSubsystemAttachedFlagsOutcome.completed,
    );
    expect(h.api.subsystem.containsKey(other), false);
  });
  for (final id in [-1, 0, 999]) {
    test('invalid or missing subsystem ID $id cannot write', () async {
      final h = _Harness();
      await expectLater(
        h.coordinator.prepare(id, field: field, choice: _choice),
        throwsStateError,
      );
      expect(h.writes, 0);
    });
  }
  final unsafe = <String, void Function(_Fake)>{
    'missing association': (a) => a.mappings.clear(),
    'enabled port': (a) => a.ports.single['enabled'] = true,
    'FC port': (a) => a.ports.single['addr_trtype'] = 'FC',
    'unknown port flag': (a) => a.ports.single.remove('enabled'),
    'shared port': (a) => a.mappings.add({
      'id': 12,
      'port': {'id': 3},
      'subsys': {'id': 4},
    }),
    'shared subsystem': (a) {
      a.ports.add({'id': 6, 'addr_trtype': 'TCP', 'enabled': false});
      a.mappings.add({
        'id': 12,
        'port': {'id': 6},
        'subsys': {'id': 2},
      });
    },

    'any host': (a) => a.subsystem['allow_any_host'] = true,
    'unknown NQN': (a) => a.subsystem.remove('subnqn'),
    'no-op': (a) => a.subsystem[field.wireField] = true,
    'missing flag': (a) => a.subsystem.remove(field.wireField),
    'invalid flag': (a) => a.subsystem[field.wireField] = 'ON',
    'zero NSID': (a) => a.namespace['nsid'] = 0,
    'FILE': (a) => a.namespace['device_type'] = 'FILE',
    'enabled': (a) => a.namespace['enabled'] = true,
    'locked': (a) => a.namespace['locked'] = true,
    'unknown lock': (a) => a.namespace.remove('locked'),
    'unknown NSID': (a) => a.namespace.remove('nsid'),
    'reserved NSID': (a) => a.namespace['nsid'] = 4294967295,
    'duplicate NSID': (a) {
      a.other['subsys'] = {'id': 2};
      a.other['device_type'] = 'ZVOL';
      a.other['nsid'] = 1;
    },
    'port association': (a) => a.mappings.add({
      'id': 10,
      'port': {'id': 3},
      'subsys': {'id': 2},
    }),
    'host association': (a) => a.hostMappings.add({
      'id': 10,
      'host': {'id': 9},
      'subsys': {'id': 2},
    }),
    'malformed': (a) => a.malformed = true,
  };
  for (final entry in unsafe.entries) {
    test('$entry rejects review and fresh preflight', () async {
      final a = _Harness();
      entry.value(a.api);
      await expectLater(
        a.coordinator.prepare(2, field: field, choice: _choice),
        throwsStateError,
      );
      expect(a.writes, 0);
      final b = _Harness();
      final review = await b.coordinator.prepare(
        2,
        field: field,
        choice: _choice,
      );
      entry.value(b.api);
      expect(
        (await b.execute(review)).outcome,
        NvmeSubsystemAttachedFlagsOutcome.rejected,
      );
      expect(b.writes, 0);
    });
  }
  for (final reason in [
    'phrase',
    'reload',
    'limitations',
    'client',
    'expired',
    'backwards',
    'session',
    'dispose',
    'cancel',
    'lock',
    'drift',
  ]) {
    test('$reason consumes review without dispatch', () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(
        2,
        field: field,
        choice: _choice,
      );
      Object? owner;
      if (reason == 'expired') h.now = h.now.add(const Duration(minutes: 5));
      if (reason == 'backwards') {
        h.now = h.now.subtract(const Duration(seconds: 1));
      }
      if (reason == 'session') h.current = false;
      if (reason == 'dispose') h.coordinator.dispose();
      if (reason == 'cancel') h.coordinator.cancel(review);
      if (reason == 'lock') owner = h.lock.acquire();
      if (reason == 'drift') h.api.other['nsid'] = 3;
      expect(
        (await h.execute(
          review,
          phrase: reason == 'phrase' ? 'wrong' : null,
          reload: reason != 'reload',
          limitations: reason != 'limitations',
          client: reason != 'client',
        )).outcome,
        NvmeSubsystemAttachedFlagsOutcome.rejected,
      );
      expect(h.writes, 0);
      if (owner != null) h.lock.release(owner);
      expect(
        (await h.execute(review)).outcome,
        NvmeSubsystemAttachedFlagsOutcome.rejected,
      );
    });
  }
  for (final failure in [
    'port enabled',
    'port transport',
    'port settings',
    'mapping removed',
    'mapping ID',
    'mapping pair',
    'namespace locked',
    'namespace FILE',

    'throw',
    'denied',
    'unknown',
    'response missing flag',
    'readback missing flag',
    'response invalid flag',
    'readback invalid flag',
    'response ID',
    'response NQN',
    'response name',
    'response access',
    'response ana',
    'response pi_enable',
    'response qid_max',
    'response ieee_oui',
    'readback NQN',
    'readback name',
    'readback ana',
    'readback pi_enable',
    'readback qid_max',
    'readback ieee_oui',
    'other drift',
    'namespace attached',
    'namespace enabled',
    'namespace NSID',
    'association',
    'malformed readback',
  ]) {
    test(
      '$failure fences original session without retry or rollback',
      () async {
        final h = _Harness();
        final review = await h.coordinator.prepare(
          2,
          field: field,
          choice: _choice,
        );
        h.api.failure = failure;
        final result = await h.execute(review);
        expect(result.outcome, NvmeSubsystemAttachedFlagsOutcome.unknown);
        expect(result.message, isNot(contains('private-server-error')));
        expect(h.coordinator.locked, true);
        expect(h.writes, 1);
        await expectLater(
          h.coordinator.prepare(
            2,
            field: field,
            choice: NvmeAttachedFlagChoice.off,
          ),
          throwsStateError,
        );
        expect(h.writes, 1);
      },
    );
  }
  for (final unselected in [
    field == NvmeAttachedSubsystemFlag.ana ? 'pi_enable' : 'ana',
    'qid_max',
    'ieee_oui',
  ]) {
    for (final phase in ['response', 'readback']) {
      test(
        '$phase missing reported $unselected fences the original session',
        () async {
          final h = _Harness();
          h.api.subsystem.addAll({
            'ana': false,
            'pi_enable': false,
            'qid_max': null,
            'ieee_oui': null,
          });
          final r = await h.coordinator.prepare(
            2,
            field: field,
            choice: _choice,
          );
          h.api.failure = '$phase missing $unselected';
          expect(
            (await h.execute(r)).outcome,
            NvmeSubsystemAttachedFlagsOutcome.unknown,
          );
          expect(h.coordinator.locked, true);
          expect(h.writes, 1);
        },
      );
    }
  }
  test('foreign review cannot be cancelled or consumed', () async {
    final a = _Harness(), b = _Harness();
    final review = await a.coordinator.prepare(
      2,
      field: field,
      choice: _choice,
    );
    b.coordinator.cancel(review);
    expect(
      (await b.execute(review)).outcome,
      NvmeSubsystemAttachedFlagsOutcome.rejected,
    );
    expect(
      (await a.execute(review)).outcome,
      NvmeSubsystemAttachedFlagsOutcome.completed,
    );
  });
  for (final reason in ['expire', 'session', 'dispose']) {
    test('$reason during slow preflight cannot dispatch', () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(
        2,
        field: field,
        choice: _choice,
      );
      h.api.gate = Completer<void>();
      final result = h.execute(review);
      await h.api.started.future;
      if (reason == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      if (reason == 'session') h.current = false;
      if (reason == 'dispose') h.coordinator.dispose();
      h.api.gate!.complete();
      expect(
        (await result).outcome,
        NvmeSubsystemAttachedFlagsOutcome.rejected,
      );
      expect(h.writes, 0);
    });
  }
  for (final change in ['ID', 'field', 'choice', 'session', 'cancel']) {
    testWidgets('$change discards native flag review without writes', (
      tester,
    ) async {
      final h = _Harness();
      final container = await _mount(tester, h, field);
      final review = find.byKey(
        const Key('nvme-subsystem-attached-flags-review'),
      );
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nvme-subsystem-attached-flags-phrase')),
        findsOneWidget,
      );
      if (change == 'ID') {
        await tester.enterText(
          find.byKey(const Key('nvme-subsystem-attached-flags-id')),
          '4',
        );
      } else if (change == 'field') {
        await _select(
          tester,
          'nvme-subsystem-attached-flags-field',
          field == NvmeAttachedSubsystemFlag.ana ? 'PI setting' : 'ANA setting',
        );
      } else if (change == 'choice') {
        await _select(
          tester,
          'nvme-subsystem-attached-flags-choice-${field.name}',
          'OFF',
        );
      } else if (change == 'session') {
        container.read(_active.notifier).select(_Harness().session);
      } else {
        final cancel = find.byKey(
          const Key('nvme-subsystem-attached-flags-cancel'),
        );
        await tester.ensureVisible(cancel);
        await tester.tap(cancel);
      }
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nvme-subsystem-attached-flags-phrase')),
        findsNothing,
      );
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('disposed page cannot restore a late flag review', (
    tester,
  ) async {
    final h = _Harness();
    await _mount(tester, h, field);
    h.api.gate = Completer<void>();
    final review = find.byKey(
      const Key('nvme-subsystem-attached-flags-review'),
    );
    await tester.ensureVisible(review);
    await tester.tap(review);
    await tester.pump();
    await h.api.started.future;
    await tester.pumpWidget(const SizedBox());
    h.api.gate!.complete();
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('nvme-subsystem-attached-flags-phrase')),
      findsNothing,
    );
  });
  for (final selected in NvmeAttachedFlagChoice.values) {
    for (final dark in [true, false]) {
      for (final width in [320.0, 430.0]) {
        testWidgets(
          'Attached flag editor $selected $width dark=$dark 200% with keyboard',
          (tester) async {
            final h = _Harness();
            final old = selected == NvmeAttachedFlagChoice.on ? false : true;
            h.api.subsystem[field.wireField] = old;
            tester.view.physicalSize = Size(width, 960);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final container = ProviderContainer(
              overrides: [
                dashboardActiveSessionProvider.overrideWith(
                  (ref) => ref.watch(_active),
                ),
                // Keep saved-setting review time deterministic.
                nvmeSubsystemAttachedFlagsCoordinatorProvider.overrideWithValue(
                  h.coordinator,
                ),
              ],
            );
            addTearDown(container.dispose);
            container.read(_active.notifier).select(h.session);
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: container,
                child: MaterialApp(
                  theme: dark ? TrueNavoTheme.dark() : TrueNavoTheme.light(),
                  home: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 960),
                      textScaler: const TextScaler.linear(2),
                      viewInsets: const EdgeInsets.only(bottom: 200),
                    ),
                    child: const Scaffold(
                      body: SingleChildScrollView(
                        child: NvmeSubsystemAttachedFlagsEditor(),
                      ),
                    ),
                  ),
                ),
              ),
            );
            Future<void> tap(String key) async {
              final f = find.byKey(Key(key));
              await tester.ensureVisible(f);
              await tester.tap(f);
              await tester.pumpAndSettle();
            }

            expect(h.api.calls, isEmpty);
            await tester.enterText(
              find.byKey(const Key('nvme-subsystem-attached-flags-id')),
              '2',
            );
            if (field == NvmeAttachedSubsystemFlag.pi) {
              await _select(
                tester,
                'nvme-subsystem-attached-flags-field',
                'PI setting',
              );
            }
            await _select(
              tester,
              'nvme-subsystem-attached-flags-choice-${field.name}',
              field.valueLabel(selected.wireValue),
            );
            await tester.pumpAndSettle();
            await tap('nvme-subsystem-attached-flags-review');
            expect(h.writes, 0);
            expect(
              tester
                  .widget<FilledButton>(
                    find.byKey(
                      const Key('nvme-subsystem-attached-flags-submit'),
                    ),
                  )
                  .onPressed,
              isNull,
            );
            await tap('nvme-subsystem-attached-flags-reload');
            await tap('nvme-subsystem-attached-flags-limitations');
            final phrase = find.byKey(
              const Key('nvme-subsystem-attached-flags-phrase'),
            );
            await tester.ensureVisible(phrase);
            await tester.enterText(
              phrase,
              'SET ATTACHED NVME SUBSYSTEM 2 ${field.label} FROM ${field.valueLabel(old)} TO ${field.valueLabel(selected.wireValue)} KEEP NQN nqn.2026-09.example:unused KEEP ASSOCIATION 11 PORT 3',
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<FilledButton>(
                    find.byKey(
                      const Key('nvme-subsystem-attached-flags-submit'),
                    ),
                  )
                  .onPressed,
              isNull,
            );
            await tap('nvme-subsystem-attached-flags-client');
            await tap('nvme-subsystem-attached-flags-submit');
            expect(h.writes, 1);
            expect(h.api.subsystem[field.wireField], selected.wireValue);
            expect(h.api.subsystem['subnqn'], 'nqn.2026-09.example:unused');
            await _select(
              tester,
              'nvme-subsystem-attached-flags-choice-${field.name}',
              selected == NvmeAttachedFlagChoice.off ? 'ON' : 'OFF',
            );
            await tester.pumpAndSettle();
            await tap('nvme-subsystem-attached-flags-review');
            for (final consent in ['reload', 'limitations', 'client']) {
              expect(
                tester
                    .widget<Checkbox>(
                      find.byKey(Key('nvme-subsystem-attached-flags-$consent')),
                    )
                    .value,
                false,
              );
            }
            expect(h.writes, 1);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
