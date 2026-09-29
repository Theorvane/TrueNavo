import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_attached_namespace_move_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_attached_namespace_move_editor.dart';

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
        'nvmet.namespace.update',
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
    'subsys': {'id': 2},
    'device_type': 'ZVOL',
    'enabled': false,
    'locked': false,
  };
  final residents = <Map<String, Object?>>[];
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
  bool includeOther = true, reverseRows = false;
  final extraSubsystems = <Map<String, Object?>>[];
  final destination = <String, Object?>{
    'id': 4,
    'name': 'destination',
    'subnqn': 'nqn.2026-09.example:destination',
    'allow_any_host': false,
  };
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
        Map.of(destination),
        for (final s in extraSubsystems) Map.of(s),
      ],
      'nvmet.port.query' => [for (final p in ports) Map.of(p)],
      'nvmet.namespace.query' => [
        malformed ? {'id': 7} : Map.of(namespace),
        if (includeOther) Map.of(other),
        for (final resident in residents) Map.of(resident),
      ],
      'nvmet.port_subsys.query' => [for (final m in mappings) Map.of(m)],
      _ => null,
    };
    if (rows != null) {
      return AdminCompleted(
        request,
        value: reverseRows ? rows.reversed.toList() : rows,
      );
    }
    if (request.method.name != 'nvmet.namespace.update') {
      throw StateError('Unexpected method');
    }
    onDispatch?.call();
    if (failure == 'throw') throw StateError('private-server-error');
    if (failure == 'denied') {
      return AdminFailed(request, reason: AdminFailureReason.denied);
    }
    if (failure == 'unknown') return AdminOutcomeUnknown(request);
    namespace['subsys'] = {'id': (request.arguments[1] as Map)['subsys_id']};
    final returned = Map.of(namespace);
    for (final field in [
      'nsid',
      'subsys',
      'device_type',
      'locked',
      'enabled',
    ]) {
      if (failure == 'response missing $field') returned.remove(field);
      if (failure == 'readback missing $field') namespace.remove(field);
    }
    for (final field in ['ana', 'pi_enable', 'qid_max', 'ieee_oui']) {
      for (final endpoint in ['source', 'destination']) {
        final row = endpoint == 'source' ? subsystem : destination;
        if (failure == '$endpoint missing $field') row.remove(field);
        if (failure == '$endpoint added $field') row[field] = null;
      }
    }
    if (failure == 'resident NSID') residents.first['nsid'] = 5;
    if (failure == 'resident enabled') residents.first['enabled'] = true;
    if (failure == 'resident removed') residents.clear();
    if (failure == 'resident added') residents.add(_resident(14, 9));
    if (failure == 'resident collision') residents.first['nsid'] = 1;
    if (failure == 'port enabled') ports.single['enabled'] = true;
    if (failure == 'port transport') ports.single['addr_trtype'] = 'FC';
    if (failure == 'port settings') ports.single['pi_enable'] = null;
    if (failure == 'mapping removed') mappings.clear();
    if (failure == 'mapping ID') mappings.single['id'] = 12;
    if (failure == 'mapping pair') mappings.single['subsys'] = {'id': 4};
    if (failure == 'source resident enabled') other['enabled'] = true;
    if (failure == 'source resident FILE') other['device_type'] = 'FILE';
    if (failure == 'readback lock') namespace['locked'] = true;
    if (failure == 'readback type') namespace['device_type'] = 'FILE';
    if (failure == 'response type') returned['device_type'] = 'FILE';
    if (failure == 'response missing') returned.remove('enabled');
    if (failure == 'destination drift') destination['name'] = 'changed';
    if (failure == 'source drift') subsystem['name'] = 'changed';
    if (failure == 'destination occupied') {
      other['subsys'] = {'id': 4};
      other['device_type'] = 'FILE';
    }
    if (failure == 'destination association') {
      mappings.add({
        'id': 11,
        'port': {'id': 3},
        'subsys': {'id': 4},
      });
    }
    if (failure == 'response subsystem') returned['subsys'] = {'id': 2};
    if (failure == 'readback subsystem') namespace['subsys'] = {'id': 2};
    if (failure == 'response enabled') returned['enabled'] = true;
    if (failure == 'response ID') returned['id'] = 999;
    if (failure == 'response NSID') {
      returned['nsid'] = 999;
    }
    if (failure == 'response lock') returned['locked'] = true;
    if (failure == 'readback enabled') {
      namespace['enabled'] = true;
    }
    if (failure == 'readback NSID') namespace['nsid'] = 4;
    if (failure == 'other drift') other['nsid'] = 3;
    if (failure == 'association') {
      hostMappings.add({
        'id': 10,
        'host': {'id': 9},
        'subsys': {'id': 2},
      });
    }
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
    coordinator = NvmeAttachedNamespaceMoveCoordinator(
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
  late final NvmeAttachedNamespaceMoveCoordinator coordinator;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  int get writes =>
      api.calls.where((r) => r.method.name == 'nvmet.namespace.update').length;
  Future<NvmeAttachedNamespaceMoveResult> execute(
    NvmeAttachedNamespaceMoveReview r, {
    String? phrase,
    bool reload = true,
    bool limitations = true,
    bool identity = true,
  }) => coordinator.execute(
    r,
    phrase ?? r.confirmation,
    acknowledgeReload: reload,
    acknowledgeLimitations: limitations,
    acknowledgeIdentityRisk: identity,
  );
}

class _Active extends Notifier<AuthenticatedSession?> {
  @override
  AuthenticatedSession? build() => null;
  void select(AuthenticatedSession session) => state = session;
}

final _active = NotifierProvider<_Active, AuthenticatedSession?>(_Active.new);

Map<String, Object?> _resident(int id, int nsid) => {
  'id': id,
  'nsid': nsid,
  'subsys': {'id': 4},
  'device_type': 'ZVOL',
  'enabled': false,
  'locked': false,
};

Future<void> _tap(WidgetTester tester, String suffix) async {
  final f = find.byKey(Key('nvme-attached-namespace-move-$suffix'));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<ProviderContainer> _mount(WidgetTester tester, _Harness h) async {
  final c = ProviderContainer(
    overrides: [
      dashboardActiveSessionProvider.overrideWith((ref) => ref.watch(_active)),
      nvmeAttachedNamespaceMoveCoordinatorProvider.overrideWithValue(
        h.coordinator,
      ),
    ],
  );
  addTearDown(c.dispose);
  c.read(_active.notifier).select(h.session);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: TrueRAIDTheme.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(child: NvmeAttachedNamespaceMoveEditor()),
        ),
      ),
    ),
  );
  await tester.enterText(
    find.byKey(const Key('nvme-attached-namespace-move-id')),
    '7',
  );
  await tester.enterText(
    find.byKey(const Key('nvme-attached-namespace-move-new')),
    '4',
  );
  await tester.pumpAndSettle();
  return c;
}

void main() {
  test(
    'destination NSID collision is filtered independently per source',
    () async {
      final h = _Harness();
      h.api.residents.add(_resident(12, 1));
      final candidates = await h.coordinator.loadCandidates();
      expect(candidates.map((c) => c.target.id), [8]);
      expect(candidates.single.destinations.map((s) => s.id), [4]);
      expect(h.writes, 0);
    },
  );
  test('discovery results are not authority after port drift', () async {
    final h = _Harness();
    final candidates = await h.coordinator.loadCandidates();
    h.api.ports.single['enabled'] = true;
    await expectLater(
      h.coordinator.prepare(
        candidates.first.target.id,
        destinationId: candidates.first.destinations.first.id,
      ),
      throwsStateError,
    );
    expect(h.writes, 0);
  });
  test('discovery cannot overlap review or another discovery', () async {
    final h = _Harness();
    h.api.gate = Completer<void>();
    final pending = h.coordinator.loadCandidates();
    await h.api.started.future;
    await expectLater(h.coordinator.loadCandidates(), throwsStateError);
    await expectLater(
      h.coordinator.prepare(7, destinationId: 4),
      throwsStateError,
    );
    h.api.gate!.complete();
    expect(await pending, hasLength(2));
    final owner = h.lock.acquire();
    expect(owner, isNotNull);
    h.lock.release(owner!);
    expect(h.writes, 0);
  });

  testWidgets(
    'refresh and connection replacement clear selections and review',
    (tester) async {
      final h = _Harness();
      final container = await _mount(tester, h);
      Future<void> tap(String key) async {
        final f = find.byKey(Key(key));
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pumpAndSettle();
      }

      Future<void> select() async {
        tester
            .widget<DropdownButton<int>>(
              find.byKey(
                const Key('nvme-attached-namespace-move-source-choice'),
              ),
            )
            .onChanged!(7);
        await tester.pumpAndSettle();
        tester
            .widget<DropdownButton<int>>(
              find.byKey(
                const Key('nvme-attached-namespace-move-destination-choice'),
              ),
            )
            .onChanged!(4);
        await tester.pumpAndSettle();
        await tap('nvme-attached-namespace-move-review');
        expect(
          find.byKey(const Key('nvme-attached-namespace-move-submit')),
          findsOneWidget,
        );
        for (final consent in ['reload', 'limitations', 'identity']) {
          final checkbox = find.byKey(
            Key('nvme-attached-namespace-move-$consent'),
          );
          expect(tester.widget<Checkbox>(checkbox).value, false);
          await tap('nvme-attached-namespace-move-$consent');
          expect(tester.widget<Checkbox>(checkbox).value, true);
        }
      }

      expect(h.api.calls, isEmpty);
      await tap('nvme-attached-namespace-move-discover');
      await select();
      await tap('nvme-attached-namespace-move-discover');
      expect(
        find.byKey(const Key('nvme-attached-namespace-move-submit')),
        findsNothing,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('nvme-attached-namespace-move-id')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('nvme-attached-namespace-move-new')),
            )
            .controller!
            .text,
        isEmpty,
      );
      await select();
      final replacement = _Harness();
      container.read(_active.notifier).select(replacement.session);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nvme-attached-namespace-move-source-choice')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('nvme-attached-namespace-move-submit')),
        findsNothing,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('nvme-attached-namespace-move-id')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(replacement.api.calls, isEmpty);
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final reason in ['session', 'unmount']) {
    testWidgets('late discovery after $reason does not restore old options', (
      tester,
    ) async {
      final h = _Harness();
      h.api.gate = Completer<void>();
      final container = await _mount(tester, h);
      final discover = find.byKey(
        const Key('nvme-attached-namespace-move-discover'),
      );
      await tester.ensureVisible(discover);
      await tester.tap(discover);
      await tester.pump();
      await h.api.started.future;
      if (reason == 'session') {
        container.read(_active.notifier).select(_Harness().session);
        await tester.pump();
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      h.api.gate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nvme-attached-namespace-move-source-choice')),
        findsNothing,
      );
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final failure in [false, true]) {
    testWidgets(
      'discovery distinguishes empty inventory from failure=$failure',
      (tester) async {
        final h = _Harness();
        h.api.namespace['enabled'] = true;
        h.api.malformed = failure;
        await _mount(tester, h);
        final discover = find.byKey(
          const Key('nvme-attached-namespace-move-discover'),
        );
        await tester.ensureVisible(discover);
        await tester.tap(discover);
        await tester.pumpAndSettle();
        expect(
          find.text('No eligible namespace and destination pairs were found.'),
          failure ? findsNothing : findsOneWidget,
        );
        expect(
          find.text(
            'Move target discovery failed. No configuration request was sent.',
          ),
          failure ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const Key('nvme-attached-namespace-move-source-choice')),
          findsNothing,
        );
        expect(h.writes, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  test(
    'discovery is bounded public immutable metadata and never writes',
    () async {
      final h = _Harness();
      h.api.reverseRows = true;
      h.api.extraSubsystems.add({
        'id': 6,
        'name': 'another',
        'subnqn': 'nqn.2026-09.example:another',
        'allow_any_host': false,
      });
      final candidates = await h.coordinator.loadCandidates();
      expect(candidates.map((c) => c.target.id), [7, 8]);
      expect(candidates.first.source.id, 2);
      expect(candidates.first.destinations.map((s) => s.id), [4, 6]);
      expect(() => candidates.clear(), throwsUnsupportedError);
      expect(
        () => candidates.first.destinations.clear(),
        throwsUnsupportedError,
      );
      expect(h.writes, 0);
      expect(h.api.calls.map((r) => r.method.name), [
        'nvmet.subsys.query',
        'nvmet.port.query',
        'nvmet.namespace.query',
        'nvmet.port_subsys.query',
      ]);
    },
  );
  test(
    'discovery invalidates an earlier review and does not authorize dispatch',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(7, destinationId: 4);
      await h.coordinator.loadCandidates();
      expect(
        (await h.execute(review)).outcome,
        NvmeAttachedNamespaceMoveOutcome.rejected,
      );
      expect(h.writes, 0);
      h.api.namespace['enabled'] = true;
      await expectLater(
        h.coordinator.prepare(7, destinationId: 4),
        throwsStateError,
      );
    },
  );
  for (final reason in ['session', 'dispose', 'lock', 'malformed']) {
    test(
      'discovery $reason fails closed and releases its operation lock',
      () async {
        final h = _Harness();
        Object? owner;
        if (reason == 'session') h.current = false;
        if (reason == 'dispose') h.coordinator.dispose();
        if (reason == 'lock') owner = h.lock.acquire();
        if (reason == 'malformed') h.api.malformed = true;
        await expectLater(h.coordinator.loadCandidates(), throwsStateError);
        expect(h.writes, 0);
        if (owner != null) h.lock.release(owner);
        final fresh = h.lock.acquire();
        expect(fresh, isNotNull);
        h.lock.release(fresh!);
      },
    );
  }
  for (final reason in ['session', 'dispose']) {
    test('late discovery $reason response cannot be used', () async {
      final h = _Harness();
      h.api.gate = Completer<void>();
      final future = h.coordinator.loadCandidates();
      final rejected = expectLater(future, throwsStateError);
      await h.api.started.future;
      if (reason == 'session') h.current = false;
      if (reason == 'dispose') h.coordinator.dispose();
      h.api.gate!.complete();
      await rejected;
      expect(h.writes, 0);
    });
  }

  for (final field in ['nsid', 'subsys', 'device_type', 'locked', 'enabled']) {
    for (final phase in ['response', 'readback']) {
      test('$phase missing selected $field fences original session', () async {
        final h = _Harness();
        final r = await h.coordinator.prepare(7, destinationId: 4);
        h.api.failure = '$phase missing $field';
        expect(
          (await h.execute(r)).outcome,
          NvmeAttachedNamespaceMoveOutcome.unknown,
        );
        expect(h.writes, 1);
        expect(h.coordinator.locked, true);
      });
    }
  }
  for (final field in ['ana', 'pi_enable', 'qid_max', 'ieee_oui']) {
    for (final endpoint in ['source', 'destination']) {
      for (final mode in ['missing', 'added']) {
        test(
          '$endpoint $mode optional $field cannot change after dispatch',
          () async {
            final h = _Harness();
            final row = endpoint == 'source'
                ? h.api.subsystem
                : h.api.destination;
            if (mode == 'missing') row[field] = null;
            final r = await h.coordinator.prepare(7, destinationId: 4);
            h.api.failure = '$endpoint $mode $field';
            expect(
              (await h.execute(r)).outcome,
              NvmeAttachedNamespaceMoveOutcome.unknown,
            );
            expect(h.writes, 1);
            expect(h.coordinator.locked, true);
          },
        );
      }
    }
  }
  test('new review supersedes the old review', () async {
    final h = _Harness();
    final a = await h.coordinator.prepare(7, destinationId: 4);
    final b = await h.coordinator.prepare(7, destinationId: 4);
    expect(
      (await h.execute(a)).outcome,
      NvmeAttachedNamespaceMoveOutcome.rejected,
    );
    expect(
      (await h.execute(b)).outcome,
      NvmeAttachedNamespaceMoveOutcome.completed,
    );
    expect(h.writes, 1);
  });
  test(
    'bounded inventory overflow rejects review and fresh preflight',
    () async {
      void overflow(_Fake f) => f.ports.addAll([
        for (var id = 100; id < 200; id++)
          {'id': id, 'addr_trtype': 'TCP', 'enabled': false},
      ]);
      final a = _Harness();
      overflow(a.api);
      await expectLater(a.coordinator.loadCandidates(), throwsStateError);
      await expectLater(
        a.coordinator.prepare(7, destinationId: 4),
        throwsStateError,
      );
      final b = _Harness();
      final r = await b.coordinator.prepare(7, destinationId: 4);
      overflow(b.api);
      expect(
        (await b.execute(r)).outcome,
        NvmeAttachedNamespaceMoveOutcome.rejected,
      );
      expect(a.writes + b.writes, 0);
    },
  );
  for (final transport in ['TCP', 'RDMA']) {
    for (final onlyTarget in [true, false]) {
      for (final populated in [true, false]) {
        for (final nsid in [1, 16, 4294967294]) {
          test(
            '$transport onlyTarget=$onlyTarget populated=$populated NSID=$nsid preserves both subsystems',
            () async {
              final h = _Harness();
              h.api.ports.single['addr_trtype'] = transport;
              h.api.includeOther = !onlyTarget;
              h.api.namespace['nsid'] = nsid;
              if (populated) h.api.residents.add(_resident(12, 3));
              final beforeOther = Map.of(h.api.other),
                  beforeMapping = Map.of(h.api.mappings.single);
              final choices = await h.coordinator.loadCandidates();
              expect(
                choices.map((c) => c.target.id),
                onlyTarget ? [7] : [7, 8],
              );
              expect(choices.first.destinations.map((s) => s.id), [4]);
              expect(h.writes, 0);
              final r = await h.coordinator.prepare(7, destinationId: 4);
              expect(
                r.sourceNamespaces.map((n) => n.id),
                onlyTarget ? isEmpty : [8],
              );
              expect(() => r.sourceNamespaces.clear(), throwsUnsupportedError);
              expect(r.mapping.id, 11);
              expect(r.port.id, 3);
              expect(
                (await h.execute(r)).outcome,
                NvmeAttachedNamespaceMoveOutcome.completed,
              );
              expect(h.api.namespace['nsid'], nsid);
              expect(h.api.namespace['enabled'], false);
              expect(h.api.other, beforeOther);
              expect(h.api.mappings.single, beforeMapping);
              expect(
                h.api.calls
                    .singleWhere(
                      (r) => r.method.name == 'nvmet.namespace.update',
                    )
                    .arguments,
                [
                  7,
                  {'subsys_id': 4},
                ],
              );
              expect(h.writes, 1);
            },
          );
        }
      }
    }
  }
  for (final change in ['ID', 'destination', 'session', 'cancel']) {
    testWidgets('$change discards attached move review without writes', (
      tester,
    ) async {
      final h = _Harness();
      final c = await _mount(tester, h);
      await _tap(tester, 'review');
      expect(
        find.byKey(const Key('nvme-attached-namespace-move-submit')),
        findsOneWidget,
      );
      if (change == 'ID') {
        await tester.enterText(
          find.byKey(const Key('nvme-attached-namespace-move-id')),
          '8',
        );
      } else if (change == 'destination') {
        await tester.enterText(
          find.byKey(const Key('nvme-attached-namespace-move-new')),
          '2',
        );
      } else if (change == 'session') {
        c.read(_active.notifier).select(_Harness().session);
      } else {
        await _tap(tester, 'cancel');
      }
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nvme-attached-namespace-move-submit')),
        findsNothing,
      );
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('unmounted page cannot restore a late move review', (
    tester,
  ) async {
    final h = _Harness();
    await _mount(tester, h);
    h.api.gate = Completer<void>();
    final f = find.byKey(const Key('nvme-attached-namespace-move-review'));
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pump();
    await h.api.started.future;
    await tester.pumpWidget(const SizedBox());
    h.api.gate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('nvme-attached-namespace-move-submit')),
      findsNothing,
    );
    expect(h.writes, 0);
    expect(tester.takeException(), isNull);
  });

  test('populated destination preserves every resident and submits assignment only', () async {
    final h = _Harness();
    h.api.residents.addAll([_resident(13, 4294967294), _resident(12, 3)]);
    final before = h.api.residents.map(Map<String, Object?>.of).toList();
    final r = await h.coordinator.prepare(7, destinationId: 4);
    expect(r.destinationNamespaces.map((n) => n.id), [12, 13]);
    expect(r.destinationNamespaces.map((n) => n.nsid), [3, 4294967294]);
    expect(() => r.destinationNamespaces.clear(), throwsUnsupportedError);
    expect(
      (await h.execute(r)).outcome,
      NvmeAttachedNamespaceMoveOutcome.completed,
    );
    expect(h.api.residents, before);
    expect(h.api.namespace['nsid'], 1);
    expect(
      h.api.calls
          .singleWhere((r) => r.method.name == 'nvmet.namespace.update')
          .arguments,
      [
        7,
        {'subsys_id': 4},
      ],
    );
    expect(h.writes, 1);
  });
  final invalidResidents = <String, void Function(_Fake)>{
    'NSID collision': (a) => a.residents.first['nsid'] = 1,
    'unknown NSID': (a) => a.residents.first.remove('nsid'),
    'reserved NSID': (a) => a.residents.first['nsid'] = 4294967295,
    'zero NSID': (a) => a.residents.first['nsid'] = 0,
    'duplicate NSIDs': (a) => a.residents.add(_resident(13, 3)),
    'enabled': (a) => a.residents.first['enabled'] = true,
    'locked': (a) => a.residents.first['locked'] = true,
    'unknown lock': (a) => a.residents.first.remove('locked'),
    'FILE': (a) => a.residents.first['device_type'] = 'FILE',
    'added resident': (a) => a.residents.add(_resident(14, 9)),
  };
  for (final entry in invalidResidents.entries) {
    test(
      'destination ${entry.key} fails fresh preflight without dispatch',
      () async {
        final h = _Harness();
        h.api.residents.add(_resident(12, 3));
        final r = await h.coordinator.prepare(7, destinationId: 4);
        entry.value(h.api);
        expect(
          (await h.execute(r)).outcome,
          NvmeAttachedNamespaceMoveOutcome.rejected,
        );
        expect(h.writes, 0);
        if (entry.key != 'added resident') {
          await expectLater(
            h.coordinator.prepare(7, destinationId: 4),
            throwsStateError,
          );
        }
      },
    );
  }
  for (final failure in [
    'resident NSID',
    'resident enabled',
    'resident removed',
    'resident added',
    'resident collision',
  ]) {
    test('$failure after dispatch fences without retry or rollback', () async {
      final h = _Harness();
      h.api.residents.add(_resident(12, 3));
      final r = await h.coordinator.prepare(7, destinationId: 4);
      h.api.failure = failure;
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceMoveOutcome.unknown,
      );
      expect(h.coordinator.locked, true);
      expect(h.writes, 1);
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceMoveOutcome.rejected,
      );
      expect(h.writes, 1);
    });
  }
  for (final id in [-1, 0, 999]) {
    test('invalid namespace ID $id cannot write', () async {
      final h = _Harness();
      await expectLater(
        h.coordinator.prepare(id, destinationId: 4),
        throwsStateError,
      );
      expect(h.writes, 0);
    });
  }
  for (final destinationId in [-1, 0, 2, 999]) {
    test(
      'invalid absent or same destination $destinationId cannot write',
      () async {
        final h = _Harness();
        await expectLater(
          h.coordinator.prepare(7, destinationId: destinationId),
          throwsStateError,
        );
        expect(h.writes, 0);
      },
    );
  }
  test(
    'exact assignment-only payload preserves identity NSID and disabled state',
    () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7, destinationId: 4);
      expect(h.writes, 0);
      expect(r.source.id, 2);
      expect(r.destination.id, 4);
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceMoveOutcome.completed,
      );
      expect(
        h.api.calls
            .singleWhere((r) => r.method.name == 'nvmet.namespace.update')
            .arguments,
        [
          7,
          {'subsys_id': 4},
        ],
      );
      expect(h.api.namespace['nsid'], 1);
      expect(h.api.namespace['enabled'], false);
      expect(h.api.namespace['id'], 7);
      expect(h.api.calls.last.method.name, 'nvmet.port_subsys.query');
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceMoveOutcome.rejected,
      );
      expect(h.writes, 1);
    },
  );
  final unsafe = <String, void Function(_Fake)>{
    'missing association': (a) => a.mappings.clear(),
    'enabled port': (a) => a.ports.single['enabled'] = true,
    'FC port': (a) => a.ports.single['addr_trtype'] = 'FC',
    'unknown port enabled': (a) => a.ports.single.remove('enabled'),
    'shared subsystem': (a) {
      a.ports.add({'id': 6, 'addr_trtype': 'RDMA', 'enabled': false});
      a.mappings.add({
        'id': 12,
        'port': {'id': 6},
        'subsys': {'id': 2},
      });
    },
    'source resident FILE': (a) => a.other['device_type'] = 'FILE',
    'source resident enabled': (a) => a.other['enabled'] = true,
    'source resident locked': (a) => a.other['locked'] = true,
    'source resident unknown lock': (a) => a.other.remove('locked'),
    'FILE': (a) => a.namespace['device_type'] = 'FILE',
    'locked': (a) => a.namespace['locked'] = true,
    'unknown lock': (a) => a.namespace.remove('locked'),
    'unknown NSID': (a) => a.namespace.remove('nsid'),
    'any host': (a) => a.subsystem['allow_any_host'] = true,
    'port mapping': (a) => a.mappings.add({
      'id': 10,
      'port': {'id': 3},
      'subsys': {'id': 2},
    }),
    'host mapping': (a) => a.hostMappings.add({
      'id': 11,
      'host': {'id': 9},
      'subsys': {'id': 2},
    }),
    'malformed': (a) => a.malformed = true,
    'enabled': (a) => a.namespace['enabled'] = true,
    'FILE destination': (a) {
      a.other['subsys'] = {'id': 4};
      a.other['device_type'] = 'FILE';
    },
    'destination any host': (a) => a.destination['allow_any_host'] = true,
    'unknown source NQN': (a) => a.subsystem.remove('subnqn'),
    'unknown destination NQN': (a) => a.destination.remove('subnqn'),
    'same NQN': (a) => a.destination['subnqn'] = a.subsystem['subnqn'],
    'destination host mapping': (a) => a.hostMappings.add({
      'id': 11,
      'host': {'id': 9},
      'subsys': {'id': 4},
    }),
    'destination port mapping': (a) => a.mappings.add({
      'id': 12,
      'port': {'id': 3},
      'subsys': {'id': 4},
    }),
    'unknown other NSID': (a) => a.other.remove('nsid'),
    'out of range other NSID': (a) => a.other['nsid'] = 4294967295,
    'duplicate existing NSIDs': (a) => a.other['nsid'] = 1,
  };
  for (final entry in unsafe.entries) {
    test('discovery excludes ${entry.key} attached relocation pairs', () async {
      final h = _Harness();
      entry.value(h.api);
      if (const {'malformed', 'unknown port enabled'}.contains(entry.key)) {
        await expectLater(h.coordinator.loadCandidates(), throwsStateError);
      } else {
        expect(await h.coordinator.loadCandidates(), isEmpty);
      }
      expect(h.writes, 0);
    });
    test(
      '${entry.key} is rejected before review and at fresh preflight',
      () async {
        final a = _Harness();
        entry.value(a.api);
        await expectLater(
          a.coordinator.prepare(7, destinationId: 4),
          throwsStateError,
        );
        expect(a.writes, 0);
        final b = _Harness();
        final r = await b.coordinator.prepare(7, destinationId: 4);
        entry.value(b.api);
        expect(
          (await b.execute(r)).outcome,
          NvmeAttachedNamespaceMoveOutcome.rejected,
        );
        expect(b.writes, 0);
      },
    );
  }
  for (final reason in [
    'phrase',
    'reload',
    'limitations',
    'identity',
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
      final r = await h.coordinator.prepare(7, destinationId: 4);
      Object? owner;
      if (reason == 'expired') h.now = h.now.add(const Duration(minutes: 5));
      if (reason == 'backwards') {
        h.now = h.now.subtract(const Duration(seconds: 1));
      }
      if (reason == 'session') h.current = false;
      if (reason == 'dispose') h.coordinator.dispose();
      if (reason == 'cancel') h.coordinator.cancel(r);
      if (reason == 'lock') owner = h.lock.acquire();
      if (reason == 'drift') h.api.other['nsid'] = 3;
      expect(
        (await h.execute(
          r,
          phrase: reason == 'phrase' ? 'wrong' : null,
          reload: reason != 'reload',
          limitations: reason != 'limitations',
          identity: reason != 'identity',
        )).outcome,
        NvmeAttachedNamespaceMoveOutcome.rejected,
      );
      expect(h.writes, 0);
      if (owner != null) h.lock.release(owner);
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceMoveOutcome.rejected,
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
    'source resident enabled',
    'source resident FILE',
    'readback lock',
    'readback type',
    'throw',
    'denied',
    'unknown',
    'response ID',
    'response subsystem',
    'readback subsystem',
    'response enabled',
    'response type',
    'response missing',
    'destination drift',
    'source drift',
    'destination occupied',
    'destination association',
    'response NSID',
    'response lock',
    'readback enabled',
    'readback NSID',
    'other drift',
    'association',
    'malformed readback',
  ]) {
    test('$failure fences the original session without retry', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7, destinationId: 4);
      h.api.failure = failure;
      final result = await h.execute(r);
      expect(result.outcome, NvmeAttachedNamespaceMoveOutcome.unknown);
      expect(result.message, isNot(contains('private-server-error')));
      expect(h.coordinator.locked, true);
      expect(h.writes, 1);
      await expectLater(
        h.coordinator.prepare(7, destinationId: 4),
        throwsStateError,
      );
      expect(h.writes, 1);
    });
  }
  test('foreign review cannot be consumed or cancelled', () async {
    final a = _Harness(), b = _Harness();
    final r = await a.coordinator.prepare(7, destinationId: 4);
    b.coordinator.cancel(r);
    expect(
      (await b.execute(r)).outcome,
      NvmeAttachedNamespaceMoveOutcome.rejected,
    );
    expect(
      (await a.execute(r)).outcome,
      NvmeAttachedNamespaceMoveOutcome.completed,
    );
  });
  for (final reason in ['expire', 'session', 'dispose']) {
    test('$reason during slow preflight prevents dispatch', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7, destinationId: 4);
      h.api.gate = Completer<void>();
      final result = h.execute(r);
      await h.api.started.future;
      if (reason == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      if (reason == 'session') h.current = false;
      if (reason == 'dispose') h.coordinator.dispose();
      h.api.gate!.complete();
      expect((await result).outcome, NvmeAttachedNamespaceMoveOutcome.rejected);
      expect(h.writes, 0);
    });
  }
  for (final reason in ['session', 'dispose']) {
    test('$reason after dispatch fences the original session', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7, destinationId: 4);
      h.api.onDispatch = () {
        if (reason == 'session') h.current = false;
        if (reason == 'dispose') h.coordinator.dispose();
      };
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceMoveOutcome.unknown,
      );
      expect(h.writes, 1);
      expect(h.coordinator.locked, true);
    });
  }
  for (final capability in [
    'nvmet.subsys.query',
    'nvmet.port.query',
    'nvmet.namespace.query',
    'nvmet.port_subsys.query',
    'nvmet.host.query',
    'nvmet.host_subsys.query',
    'nvmet.namespace.update',
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
            'nvmet.namespace.update',
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
      await expectLater(h.coordinator.loadCandidates(), throwsStateError);
      await expectLater(
        h.coordinator.prepare(7, destinationId: 4),
        throwsStateError,
      );
      expect(h.api.calls, isEmpty);
    });
  }

  for (final populated in [false, true]) {
    for (final dark in [true, false]) {
      for (final width in [320.0, 430.0]) {
        testWidgets(
          'attached disabled ZVOL review $width dark=$dark populated=$populated at 200% with keyboard',
          (tester) async {
            final h = _Harness();
            if (populated) h.api.residents.add(_resident(12, 3));
            tester.view.physicalSize = Size(width, 960);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final container = ProviderContainer(
              overrides: [
                dashboardActiveSessionProvider.overrideWith(
                  (ref) => ref.watch(_active),
                ),
                nvmeAttachedNamespaceMoveCoordinatorProvider.overrideWithValue(
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
                        child: NvmeAttachedNamespaceMoveEditor(),
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

            final id = find.byKey(const Key('nvme-attached-namespace-move-id'));
            expect(h.api.calls, isEmpty);
            await tap('nvme-attached-namespace-move-discover');
            await tap('nvme-attached-namespace-move-source-choice');
            await tester.tap(find.text('#7 · NSID 1 · unused').last);
            await tester.pumpAndSettle();
            await tap('nvme-attached-namespace-move-destination-choice');
            await tester.tap(find.text('#4 · destination').last);
            await tester.pumpAndSettle();
            await tap('nvme-attached-namespace-move-review');
            expect(h.writes, 0);
            expect(
              tester
                  .widget<SelectableText>(
                    find.byKey(
                      const Key('nvme-attached-namespace-move-confirmation'),
                    ),
                  )
                  .data,
              'MOVE ATTACHED NVME NAMESPACE 7 FROM SUBSYSTEM 2 NQN nqn.2026-09.example:unused TO 4 NQN nqn.2026-09.example:destination KEEP NSID 1 KEEP ASSOCIATION 11 PORT 3',
            );
            expect(
              tester
                  .widget<FilledButton>(
                    find.byKey(
                      const Key('nvme-attached-namespace-move-submit'),
                    ),
                  )
                  .onPressed,
              isNull,
            );
            await tap('nvme-attached-namespace-move-reload');
            await tap('nvme-attached-namespace-move-limitations');
            final phrase = find.byKey(
              const Key('nvme-attached-namespace-move-phrase'),
            );
            await tester.ensureVisible(phrase);
            await tester.enterText(
              phrase,
              'MOVE ATTACHED NVME NAMESPACE 7 FROM SUBSYSTEM 2 NQN nqn.2026-09.example:unused TO 4 NQN nqn.2026-09.example:destination KEEP NSID 1 KEEP ASSOCIATION 11 PORT 3',
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<FilledButton>(
                    find.byKey(
                      const Key('nvme-attached-namespace-move-submit'),
                    ),
                  )
                  .onPressed,
              isNull,
            );
            await tap('nvme-attached-namespace-move-identity');
            await tap('nvme-attached-namespace-move-submit');
            expect(h.writes, 1);
            expect(h.api.namespace['subsys'], {'id': 4});
            expect(h.api.namespace['nsid'], 1);
            await tester.enterText(id, '8');
            await tester.enterText(
              find.byKey(const Key('nvme-attached-namespace-move-new')),
              '4',
            );
            await tester.pumpAndSettle();
            await tap('nvme-attached-namespace-move-review');
            for (final consent in ['reload', 'limitations', 'identity']) {
              expect(
                tester
                    .widget<Checkbox>(
                      find.byKey(Key('nvme-attached-namespace-move-$consent')),
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
