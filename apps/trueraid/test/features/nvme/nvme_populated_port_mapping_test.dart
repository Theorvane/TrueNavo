import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_populated_port_mapping_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_populated_port_mapping_editor.dart';

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession,
        AuthenticatedNvmePortAccessSession {
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
        'nvmet.port_subsys.create',
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
  final extraSubsystems = <Map<String, Object?>>[];
  final subsystem = <String, Object?>{
    'id': 2,
    'name': 'unused',
    'subnqn': 'nqn.2026-09.example:unused',
    'allow_any_host': false,
    'ana': false,
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
    {'id': 6, 'addr_trtype': 'TCP', 'enabled': false},
  ];
  final mappings = <Map<String, Object?>>[],
      hostMappings = <Map<String, Object?>>[];
  final mappingCalls = <(int, int)>[];
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
        for (final row in extraSubsystems) Map.of(row),
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
    throw StateError('Unexpected generic method');
  }

  @override
  Future<NvmePortAssociationCreated> createNvmePortAssociation({
    required int portId,
    required int subsystemId,
  }) async {
    mappingCalls.add((portId, subsystemId));
    onDispatch?.call();
    if (failure == 'throw') throw StateError('private-server-error');
    final mapping = <String, Object?>{
      'id': 11,
      'port': {'id': portId},
      'subsys': {'id': subsystemId},
    };
    if (failure != 'missing mapping') mappings.add(mapping);
    if (failure == 'wrong readback') mapping['port'] = {'id': 6};
    if (failure == 'extra mapping') {
      mappings.add({
        'id': 12,
        'port': {'id': 6},
        'subsys': {'id': 4},
      });
    }
    if (failure == 'port enabled') ports.first['enabled'] = true;
    if (failure == 'port transport') ports.first['addr_trtype'] = 'RDMA';
    if (failure == 'port settings') ports.first['inline_data_size'] = 1;
    if (failure == 'namespace enabled') namespace['enabled'] = true;
    if (failure == 'namespace NSID') namespace['nsid'] = 4;
    if (failure == 'namespace locked') namespace['locked'] = true;
    if (failure == 'namespace attached') namespace['subsys'] = {'id': 4};
    if (failure == 'subsystem name') subsystem['name'] = 'changed';
    if (failure == 'subsystem NQN') {
      subsystem['subnqn'] = 'nqn.2026-09.example:changed';
    }
    if (failure == 'subsystem access') subsystem['allow_any_host'] = true;
    if (failure == 'subsystem ANA') subsystem['ana'] = true;
    if (failure == 'subsystem PI') subsystem['pi_enable'] = true;
    if (failure == 'subsystem QID') subsystem['qid_max'] = 16;
    if (failure == 'subsystem OUI') subsystem['ieee_oui'] = 'AA:BB:CC';
    if (failure == 'other drift') other['nsid'] = 3;
    if (failure == 'host grant') {
      hostMappings.add({
        'id': 10,
        'host': {'id': 9},
        'subsys': {'id': subsystemId},
      });
    }
    if (failure == 'malformed readback') malformed = true;
    return NvmePortAssociationCreated(
      failure == 'response ID'
          ? 0
          : failure == 'existing response ID'
          ? 44
          : 11,
      failure == 'response port' ? 999 : portId,
      failure == 'response subsystem' ? 999 : subsystemId,
    );
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
    coordinator = NvmePopulatedPortMappingCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      accessApi: api,
      lock: lock,
      isCurrent: () => current,
      now: () => now,
    );
  }
  final api = _Fake(), lock = ServerOperationLock();
  late final AuthenticatedSession session;
  late final NvmePopulatedPortMappingCoordinator coordinator;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  int get writes => api.mappingCalls.length;
  Future<NvmePopulatedPortMappingResult> execute(
    NvmePopulatedPortMappingReview r, {
    String? phrase,
    bool reload = true,
    bool limitations = true,
    bool exposure = true,
  }) => coordinator.execute(
    r,
    phrase ?? r.confirmation,
    acknowledgeReload: reload,
    acknowledgeLimitations: limitations,
    acknowledgeExposure: exposure,
  );
}

class _Active extends Notifier<AuthenticatedSession?> {
  @override
  AuthenticatedSession? build() => null;
  void select(AuthenticatedSession session) => state = session;
}

final _active = NotifierProvider<_Active, AuthenticatedSession?>(_Active.new);

void main() {
  for (final missing in [
    'unsupported version',
    'nvmet.port_subsys.create',
    'nvmet.host.query',
  ]) {
    test('$missing fails closed before inventory reads', () async {
      final h = _Harness();
      h.api.adminCatalog = AdminCatalog.fromMetadata(
        version: missing == 'unsupported version' ? '24.10.2' : '25.10.1',
        metadata: {
          for (final name in [
            'nvmet.subsys.query',
            'nvmet.port.query',
            'nvmet.namespace.query',
            'nvmet.port_subsys.query',
            'nvmet.host.query',
            'nvmet.host_subsys.query',
            'nvmet.port_subsys.create',
          ])
            if (name != missing)
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
      await expectLater(h.coordinator.prepare(3, 2), throwsStateError);
      expect(h.api.calls, isEmpty);
      expect(h.writes, 0);
    });
  }
  for (final initialCount in [99, 100]) {
    test('association inventory capacity $initialCount is respected', () async {
      final h = _Harness();
      h.api.extraSubsystems.add({
        'id': 5,
        'name': 'other-five',
        'subnqn': 'nqn.2026-09.example:five',
        'allow_any_host': false,
      });
      for (var i = 0; i < 50; i++) {
        h.api.ports.add({
          'id': 100 + i,
          'addr_trtype': 'TCP',
          'enabled': false,
        });
      }
      for (var i = 0; i < initialCount; i++) {
        h.api.mappings.add({
          'id': 1000 + i,
          'port': {'id': 100 + i ~/ 2},
          'subsys': {'id': 4 + i % 2},
        });
      }
      if (initialCount == 100) {
        await expectLater(h.coordinator.prepare(3, 2), throwsStateError);
        expect(h.writes, 0);
      } else {
        final review = await h.coordinator.prepare(3, 2);
        expect(
          (await h.execute(review)).outcome,
          NvmePopulatedPortMappingOutcome.completed,
        );
        expect(h.api.mappings.length, 100);
        expect(h.writes, 1);
      }
    });
  }
  testWidgets('invalid port and subsystem ID inputs cannot trigger reads', (
    tester,
  ) async {
    final h = _Harness();
    final container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        // Keep review time deterministic, as in coordinator unit tests.
        nvmePopulatedPortMappingCoordinatorProvider.overrideWithValue(
          h.coordinator,
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: NvmePopulatedPortMappingEditor(),
            ),
          ),
        ),
      ),
    );
    final port = find.byKey(const Key('nvme-populated-port-mapping-port-id'));
    final subsystem = find.byKey(const Key('nvme-populated-port-mapping-id'));
    for (final field in [port, subsystem]) {
      await tester.enterText(port, '3');
      await tester.enterText(subsystem, '2');
      for (final invalid in ['', '0', '-1', '+1', ' 1', '1 ', '01', '1.5']) {
        await tester.ensureVisible(field);
        await tester.enterText(field, invalid);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('nvme-populated-port-mapping-review')),
              )
              .onPressed,
          isNull,
          reason: invalid,
        );
        expect(h.api.calls, isEmpty);
        expect(h.writes, 0);
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final transport in ['TCP', 'RDMA']) {
    for (final multiple in [false, true]) {
      test(
        'mapping $transport multiple=$multiple preserves disabled namespaces and settings',
        () async {
          final h = _Harness();
          h.api.ports.first['addr_trtype'] = transport;
          h.api.subsystem.addAll({
            'pi_enable': null,
            'qid_max': 16,
            'ieee_oui': '00:11:22',
          });
          h.api.ports.first.addAll({
            'inline_data_size': null,
            'max_queue_size': 16,
            'pi_enable': false,
          });
          if (multiple) {
            h.api.other['subsys'] = {'id': 2};
            h.api.other['device_type'] = 'ZVOL';
          }
          final namespaceBefore = Map.of(h.api.namespace);
          final targetBefore = Map.of(h.api.subsystem);
          final portBefore = Map.of(h.api.ports.first);
          final review = await h.coordinator.prepare(3, 2);
          expect(review.namespaces.map((n) => n.id), multiple ? [7, 8] : [7]);
          expect(() => review.namespaces.clear(), throwsUnsupportedError);
          expect(h.writes, 0);
          expect(
            (await h.execute(review)).outcome,
            NvmePopulatedPortMappingOutcome.completed,
          );
          expect(h.api.mappingCalls, [(3, 2)]);
          expect(h.api.namespace, namespaceBefore);
          expect(h.api.subsystem, targetBefore);
          expect(h.api.ports.first, portBefore);
          expect(h.api.hostMappings, isEmpty);
          expect(h.api.mappings, [
            {
              'id': 11,
              'port': {'id': 3},
              'subsys': {'id': 2},
            },
          ]);
          expect(
            h.api.calls.every((r) => r.method.name.endsWith('.query')),
            true,
          );
          expect(
            (await h.execute(review)).outcome,
            NvmePopulatedPortMappingOutcome.rejected,
          );
          expect(h.writes, 1);
        },
      );
    }
  }
  for (final ids in [(0, 2), (-1, 2), (3, 0), (3, -1), (999, 2), (3, 999)]) {
    test('missing or invalid IDs $ids cannot map', () async {
      final h = _Harness();
      await expectLater(
        h.coordinator.prepare(ids.$1, ids.$2),
        throwsStateError,
      );
      expect(h.writes, 0);
    });
  }
  final unsafe = <String, void Function(_Fake)>{
    'any host': (a) => a.subsystem['allow_any_host'] = true,
    'unknown NQN': (a) => a.subsystem.remove('subnqn'),
    'empty': (a) => a.namespace['subsys'] = {'id': 4},
    'FILE': (a) => a.namespace['device_type'] = 'FILE',
    'enabled': (a) => a.namespace['enabled'] = true,
    'locked': (a) => a.namespace['locked'] = true,
    'unknown lock': (a) => a.namespace.remove('locked'),
    'unknown NSID': (a) => a.namespace.remove('nsid'),
    'zero NSID': (a) => a.namespace['nsid'] = 0,
    'reserved NSID': (a) => a.namespace['nsid'] = 4294967295,
    'duplicate NSID': (a) {
      a.other['subsys'] = {'id': 2};
      a.other['device_type'] = 'ZVOL';
      a.other['nsid'] = 1;
    },
    'enabled port': (a) => a.ports.first['enabled'] = true,
    'FC port': (a) => a.ports.first['addr_trtype'] = 'FC',
    'unknown port flag': (a) => a.ports.first.remove('enabled'),
    'used port': (a) => a.mappings.add({
      'id': 10,
      'port': {'id': 3},
      'subsys': {'id': 4},
    }),
    'attached subsystem': (a) => a.mappings.add({
      'id': 10,
      'port': {'id': 6},
      'subsys': {'id': 2},
    }),
    'duplicate requested mapping': (a) => a.mappings.add({
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
    test('${entry.key} rejects review and fresh preflight', () async {
      final a = _Harness();
      entry.value(a.api);
      await expectLater(a.coordinator.prepare(3, 2), throwsStateError);
      expect(a.writes, 0);
      final b = _Harness();
      final review = await b.coordinator.prepare(3, 2);
      entry.value(b.api);
      expect(
        (await b.execute(review)).outcome,
        NvmePopulatedPortMappingOutcome.rejected,
      );
      expect(b.writes, 0);
    });
  }
  for (final reason in [
    'phrase',
    'reload',
    'limitations',
    'exposure',
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
      final review = await h.coordinator.prepare(3, 2);
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
          exposure: reason != 'exposure',
        )).outcome,
        NvmePopulatedPortMappingOutcome.rejected,
      );
      expect(h.writes, 0);
      if (owner != null) h.lock.release(owner);
      expect(
        (await h.execute(review)).outcome,
        NvmePopulatedPortMappingOutcome.rejected,
      );
    });
  }

  for (final failure in [
    'throw',
    'response ID',
    'response port',
    'response subsystem',
    'existing response ID',
    'missing mapping',
    'wrong readback',
    'extra mapping',
    'port enabled',
    'port transport',
    'port settings',
    'namespace enabled',
    'namespace NSID',
    'namespace locked',
    'namespace attached',
    'subsystem name',
    'subsystem NQN',
    'subsystem access',
    'subsystem ANA',
    'subsystem PI',
    'subsystem QID',
    'subsystem OUI',
    'other drift',
    'host grant',
    'malformed readback',
  ]) {
    test(
      '$failure fences original session without retry or rollback',
      () async {
        final h = _Harness();
        if (failure == 'existing response ID') {
          h.api.mappings.add({
            'id': 44,
            'port': {'id': 6},
            'subsys': {'id': 4},
          });
        }
        final review = await h.coordinator.prepare(3, 2);
        h.api.failure = failure;
        final result = await h.execute(review);
        expect(result.outcome, NvmePopulatedPortMappingOutcome.unknown);
        expect(result.message, isNot(contains('private-server-error')));
        expect(h.coordinator.locked, true);
        expect(h.writes, 1);
        await expectLater(h.coordinator.prepare(3, 2), throwsStateError);
        expect(h.writes, 1);
      },
    );
  }
  test('foreign review cannot be consumed or cancelled', () async {
    final a = _Harness(), b = _Harness();
    final review = await a.coordinator.prepare(3, 2);
    b.coordinator.cancel(review);
    expect(
      (await b.execute(review)).outcome,
      NvmePopulatedPortMappingOutcome.rejected,
    );
    expect(
      (await a.execute(review)).outcome,
      NvmePopulatedPortMappingOutcome.completed,
    );
  });
  test('new review invalidates previous review', () async {
    final h = _Harness();
    final old = await h.coordinator.prepare(3, 2);
    final replacement = await h.coordinator.prepare(3, 2);
    expect(
      (await h.execute(old)).outcome,
      NvmePopulatedPortMappingOutcome.rejected,
    );
    expect(
      (await h.execute(replacement)).outcome,
      NvmePopulatedPortMappingOutcome.completed,
    );
    expect(h.writes, 1);
  });
  for (final reason in ['expire', 'session', 'dispose']) {
    test('$reason during slow preflight cannot dispatch', () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(3, 2);
      h.api.gate = Completer<void>();
      final result = h.execute(review);
      await h.api.started.future;
      if (reason == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      if (reason == 'session') h.current = false;
      if (reason == 'dispose') h.coordinator.dispose();
      h.api.gate!.complete();
      expect((await result).outcome, NvmePopulatedPortMappingOutcome.rejected);
      expect(h.writes, 0);
    });
  }
  for (final reason in ['session', 'dispose']) {
    test('$reason after dispatch fences original session only', () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(3, 2);
      h.api.onDispatch = () {
        if (reason == 'session') h.current = false;
        if (reason == 'dispose') h.coordinator.dispose();
      };
      expect(
        (await h.execute(review)).outcome,
        NvmePopulatedPortMappingOutcome.unknown,
      );
      expect(h.writes, 1);
      expect(h.coordinator.locked, true);
      expect(_Harness().coordinator.locked, false);
    });
  }
  for (final transport in ['TCP', 'RDMA']) {
    for (final dark in [true, false]) {
      for (final width in [320.0, 430.0]) {
        testWidgets(
          'Populated port mapping $transport $width dark=$dark 200% with keyboard',
          (tester) async {
            final h = _Harness();
            h.api.ports.first['addr_trtype'] = transport;
            tester.view.physicalSize = Size(width, 960);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final container = ProviderContainer(
              overrides: [
                dashboardActiveSessionProvider.overrideWith(
                  (ref) => ref.watch(_active),
                ),
                // Keep review time deterministic, as in coordinator unit tests.
                nvmePopulatedPortMappingCoordinatorProvider.overrideWithValue(
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
                  theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
                  home: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 960),
                      textScaler: const TextScaler.linear(2),
                      viewInsets: const EdgeInsets.only(bottom: 200),
                    ),
                    child: const Scaffold(
                      body: SingleChildScrollView(
                        child: NvmePopulatedPortMappingEditor(),
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
              find.byKey(const Key('nvme-populated-port-mapping-id')),
              '2',
            );
            await tester.enterText(
              find.byKey(const Key('nvme-populated-port-mapping-port-id')),
              '3',
            );
            await tester.pumpAndSettle();
            await tap('nvme-populated-port-mapping-review');
            expect(h.writes, 0);
            expect(
              tester
                  .widget<FilledButton>(
                    find.byKey(const Key('nvme-populated-port-mapping-submit')),
                  )
                  .onPressed,
              isNull,
            );
            await tap('nvme-populated-port-mapping-reload');
            await tap('nvme-populated-port-mapping-limitations');
            final phrase = find.byKey(
              const Key('nvme-populated-port-mapping-phrase'),
            );
            await tester.ensureVisible(phrase);
            await tester.enterText(
              phrase,
              'MAP DISABLED NVME PORT 3 TO POPULATED SUBSYSTEM 2 KEEP NQN nqn.2026-09.example:unused',
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<FilledButton>(
                    find.byKey(const Key('nvme-populated-port-mapping-submit')),
                  )
                  .onPressed,
              isNull,
            );
            await tap('nvme-populated-port-mapping-exposure');
            await tap('nvme-populated-port-mapping-submit');
            expect(h.writes, 1);
            expect(h.api.mappingCalls, [(3, 2)]);
            expect(h.api.ports.first['enabled'], false);
            expect(h.api.namespace['enabled'], false);
            expect(h.api.subsystem['subnqn'], 'nqn.2026-09.example:unused');
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
