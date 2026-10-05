import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_attached_namespace_nsid_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_attached_namespace_nsid_editor.dart';

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
  String? queryFailure;
  bool reverseRows = false;
  int hostLoads = 0;
  final extraNamespaces = <Map<String, Object?>>[];
  bool malformed = false;
  bool extraSubsystem = false;
  Completer<void>? gate;
  final started = Completer<void>();
  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    hostLoads++;
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
        ...extraNamespaces,
      ],
      'nvmet.port_subsys.query' => [for (final m in mappings) Map.of(m)],
      _ => null,
    };
    if (rows != null) {
      if (queryFailure == request.method.name) {
        throw StateError('private-server-error');
      }
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
    namespace['nsid'] = (request.arguments[1] as Map)['nsid'];
    final returned = Map.of(namespace);
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
    if (failure == 'port enabled') ports.first['enabled'] = true;
    if (failure == 'port transport') ports.first['addr_trtype'] = 'FC';
    if (failure == 'port settings') ports.first['pi_enable'] = null;
    if (failure == 'mapping removed') mappings.clear();
    if (failure == 'mapping ID') mappings.first['id'] = 12;
    if (failure == 'neighbor enabled') other['enabled'] = true;
    if (failure == 'neighbor lock') other['locked'] = true;
    if (failure == 'neighbor FILE') other['device_type'] = 'FILE';
    if (failure == 'subsystem NQN') {
      subsystem['subnqn'] = 'nqn.2026-09.example:changed';
    }
    if (failure == 'subsystem name') subsystem['name'] = 'changed';
    if (failure == 'subsystem settings') subsystem['ana'] = true;
    if (failure == 'subsystem any host') subsystem['allow_any_host'] = true;
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
    coordinator = NvmeAttachedNamespaceNsidCoordinator(
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
  late final NvmeAttachedNamespaceNsidCoordinator coordinator;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  int get writes =>
      api.calls.where((r) => r.method.name == 'nvmet.namespace.update').length;
  Future<NvmeAttachedNamespaceNsidResult> execute(
    NvmeAttachedNamespaceNsidReview r, {
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

class _CoordinatorChoice
    extends Notifier<NvmeAttachedNamespaceNsidCoordinator?> {
  @override
  NvmeAttachedNamespaceNsidCoordinator? build() => null;
  void select(NvmeAttachedNamespaceNsidCoordinator coordinator) =>
      state = coordinator;
}

final _choice =
    NotifierProvider<_CoordinatorChoice, NvmeAttachedNamespaceNsidCoordinator?>(
      _CoordinatorChoice.new,
    );

Future<ProviderContainer> _mountDiscovery(
  WidgetTester tester,
  _Harness h, {
  double width = 430,
  bool dark = true,
}) async {
  tester.view.physicalSize = Size(width, 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      dashboardActiveSessionProvider.overrideWith((ref) => ref.watch(_active)),
      nvmeAttachedNamespaceNsidCoordinatorProvider.overrideWith((ref) {
        final session = ref.watch(dashboardActiveSessionProvider);
        final coordinator = ref.watch(_choice);
        return identical(session, h.session) ? coordinator : null;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(_active.notifier).select(h.session);
  container.read(_choice.notifier).select(h.coordinator);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: dark ? TrueNavoTheme.dark() : TrueNavoTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQueryData(
            size: Size(width, 960),
            textScaler: const TextScaler.linear(2),
            viewInsets: const EdgeInsets.only(bottom: 200),
          ),
          child: child!,
        ),
        home: const Scaffold(
          body: SingleChildScrollView(child: NvmeAttachedNamespaceNsidEditor()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _tap(WidgetTester tester, String suffix) async {
  final finder = find.byKey(Key('nvme-attached-namespace-nsid-$suffix'));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester, int id, int nsid) async {
  await _tap(tester, 'choice');
  await tester.tap(find.text('#$id · NSID $nsid · unused').last);
  await tester.pumpAndSettle();
}

void main() {
  for (final dark in [true, false]) {
    for (final width in [320.0, 430.0]) {
      for (final nsid in [1, 4294967294]) {
        testWidgets(
          'NSID selector and explicit suggestion $width dark=$dark current=$nsid at 200% with keyboard',
          (tester) async {
            final h = _Harness();
            h.api.namespace['nsid'] = nsid;
            final desired = nsid == 1 ? 3 : 1;
            await _mountDiscovery(tester, h, width: width, dark: dark);
            await _tap(tester, 'discover');
            await _select(tester, 7, nsid);
            expect(h.writes, 0);
            await _tap(tester, 'suggestion');
            expect(
              tester
                  .widget<TextField>(
                    find.byKey(const Key('nvme-attached-namespace-nsid-new')),
                  )
                  .controller!
                  .text,
              '$desired',
            );
            await _tap(tester, 'review');
            for (final consent in ['reload', 'limitations', 'identity']) {
              await _tap(tester, consent);
            }
            final phrase = find.byKey(
              const Key('nvme-attached-namespace-nsid-phrase'),
            );
            await tester.ensureVisible(phrase);
            await tester.enterText(
              phrase,
              'CHANGE ATTACHED NVME NAMESPACE 7 NSID $nsid TO $desired KEEP ASSOCIATION 11 PORT 3 SUBSYSTEM 2 NQN nqn.2026-09.example:unused',
            );
            await tester.pumpAndSettle();
            await _tap(tester, 'submit');
            expect(h.writes, 1);
            expect(h.api.namespace['nsid'], desired);
            expect(
              find.byKey(const Key('nvme-attached-namespace-nsid-choice')),
              findsNothing,
            );
            await _tap(tester, 'discover');
            await _select(tester, 7, desired);
            expect(
              find.text('Use suggested free NSID ${nsid == 1 ? 1 : 3}'),
              findsOneWidget,
            );
            expect(h.writes, 1);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
  testWidgets('refresh clears both IDs phrase review and three consents', (
    tester,
  ) async {
    final h = _Harness();
    await _mountDiscovery(tester, h);
    await _tap(tester, 'discover');
    await _select(tester, 7, 1);
    await _tap(tester, 'suggestion');
    await _tap(tester, 'review');
    for (final consent in ['reload', 'limitations', 'identity']) {
      await _tap(tester, consent);
    }
    await _tap(tester, 'discover');
    expect(
      find.byKey(const Key('nvme-attached-namespace-nsid-phrase')),
      findsNothing,
    );
    for (final field in ['id', 'new']) {
      expect(
        tester
            .widget<TextField>(
              find.byKey(Key('nvme-attached-namespace-nsid-$field')),
            )
            .controller!
            .text,
        isEmpty,
      );
    }
    await _select(tester, 8, 2);
    await _tap(tester, 'suggestion');
    await _tap(tester, 'review');
    for (final consent in ['reload', 'limitations', 'identity']) {
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(Key('nvme-attached-namespace-nsid-$consent')),
            )
            .value,
        false,
      );
    }
    expect(h.writes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'suggestion and manual namespace changes discard prior consent and desired NSID',
    (tester) async {
      final h = _Harness();
      await _mountDiscovery(tester, h);
      await _tap(tester, 'discover');
      await _select(tester, 7, 1);
      await _tap(tester, 'suggestion');
      await _tap(tester, 'review');
      await _tap(tester, 'reload');
      await _tap(tester, 'suggestion');
      expect(
        find.byKey(const Key('nvme-attached-namespace-nsid-phrase')),
        findsNothing,
      );
      await _tap(tester, 'review');
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const Key('nvme-attached-namespace-nsid-reload')),
            )
            .value,
        false,
      );
      await tester.enterText(
        find.byKey(const Key('nvme-attached-namespace-nsid-id')),
        '8',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('nvme-attached-namespace-nsid-new')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(
        find.byKey(const Key('nvme-attached-namespace-nsid-phrase')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const Key('nvme-attached-namespace-nsid-new')),
        '4',
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'review');
      expect(
        find.byKey(const Key('nvme-attached-namespace-nsid-phrase')),
        findsOneWidget,
      );
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final reason in ['session', 'coordinator']) {
    testWidgets('$reason clears existing NSID discovery selections', (
      tester,
    ) async {
      final h = _Harness();
      final container = await _mountDiscovery(tester, h);
      await _tap(tester, 'discover');
      await _select(tester, 7, 1);
      await _tap(tester, 'suggestion');
      if (reason == 'session') {
        container.read(_active.notifier).select(_Harness().session);
      } else {
        container.read(_choice.notifier).select(_Harness().coordinator);
        expect(
          container.read(nvmeAttachedNamespaceNsidCoordinatorProvider),
          isNot(same(h.coordinator)),
        );
      }
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nvme-attached-namespace-nsid-choice')),
        findsNothing,
      );
      for (final field in ['id', 'new']) {
        expect(
          tester
              .widget<TextField>(
                find.byKey(Key('nvme-attached-namespace-nsid-$field')),
              )
              .controller!
              .text,
          isEmpty,
        );
      }
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final reason in ['session', 'coordinator', 'dispose']) {
    testWidgets('$reason rejects late NSID discovery restoration', (
      tester,
    ) async {
      final h = _Harness();
      final container = await _mountDiscovery(tester, h);
      h.api.gate = Completer<void>();
      final button = find.byKey(
        const Key('nvme-attached-namespace-nsid-discover'),
      );
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      await h.api.started.future;
      if (reason == 'session') {
        container.read(_active.notifier).select(_Harness().session);
      }
      if (reason == 'coordinator') {
        container.read(_choice.notifier).select(_Harness().coordinator);
        expect(
          container.read(nvmeAttachedNamespaceNsidCoordinatorProvider),
          isNot(same(h.coordinator)),
        );
      }
      if (reason == 'dispose') {
        await tester.pumpWidget(const SizedBox());
      } else {
        await tester.pump();
      }
      h.api.gate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nvme-attached-namespace-nsid-choice')),
        findsNothing,
      );
      expect(
        find.text(
          'NSID target discovery failed. No configuration request was sent.',
        ),
        findsNothing,
      );
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final failure in [false, true]) {
    testWidgets('NSID discovery distinguishes empty and failure=$failure', (
      tester,
    ) async {
      final h = _Harness();
      if (failure) {
        h.api.queryFailure = 'nvmet.port.query';
      } else {
        h.api.ports.single['enabled'] = true;
      }
      await _mountDiscovery(tester, h);
      await _tap(tester, 'discover');
      expect(
        find.text('No eligible namespace NSID targets were found.'),
        failure ? findsNothing : findsOneWidget,
      );
      expect(
        find.text(
          'NSID target discovery failed. No configuration request was sent.',
        ),
        failure ? findsOneWidget : findsNothing,
      );
      h.api.queryFailure = null;
      h.api.ports.single['enabled'] = false;
      await _tap(tester, 'discover');
      await _select(tester, 7, 1);
      expect(
        find.byKey(const Key('nvme-attached-namespace-nsid-suggestion')),
        findsOneWidget,
      );
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final kind in ['oversized', 'unresolved']) {
    test('$kind discovery inventory fails closed', () async {
      final h = _Harness();
      if (kind == 'oversized') {
        h.api.ports.addAll([
          for (var id = 100; id < 200; id++)
            {'id': id, 'addr_trtype': 'TCP', 'enabled': false},
        ]);
      } else {
        h.api.other['subsys'] = {'id': 999};
      }
      await expectLater(h.coordinator.loadCandidates(), throwsStateError);
      expect(h.writes, 0);
    });
  }
  for (final transport in ['TCP', 'RDMA']) {
    for (final current in [1, 4, 4294967294]) {
      test(
        '$transport explicit suggestion for current NSID $current is read-only and independently reviewed',
        () async {
          final h = _Harness();
          h.api.namespace['nsid'] = current;
          h.api.ports.single['addr_trtype'] = transport;
          h.api.reverseRows = true;
          final candidates = await h.coordinator.loadCandidates();
          expect(candidates.map((c) => c.target.id), [7, 8]);
          final candidate = candidates.first;
          expect(candidate.suggestedNsid, current == 1 ? 3 : 1);
          expect(candidate.usedNsids, current == 1 ? [1, 2] : [2, current]);
          expect(candidate.mapping.id, 11);
          expect(candidate.port.transport, transport);
          expect(candidate.subsystem.subnqn, h.api.subsystem['subnqn']);
          expect(() => candidates.clear(), throwsUnsupportedError);
          expect(() => candidate.usedNsids.clear(), throwsUnsupportedError);
          expect(h.writes, 0);
          expect(h.api.hostLoads, 1);
          final review = await h.coordinator.prepare(
            candidate.target.id,
            nsid: candidate.suggestedNsid,
          );
          expect(h.api.hostLoads, 2);
          expect(
            (await h.execute(review)).outcome,
            NvmeAttachedNamespaceNsidOutcome.completed,
          );
          expect(
            h.api.calls
                .singleWhere((r) => r.method.name == 'nvmet.namespace.update')
                .arguments,
            [
              7,
              {'nsid': candidate.suggestedNsid},
            ],
          );
          expect(h.api.hostLoads, 4);
        },
      );
    }
  }
  test('sorted contiguous inventory yields smallest free explicit NSID without including unrelated subsystem', () async {
    final h = _Harness();
    h.api.reverseRows = true;
    h.api.extraNamespaces.addAll([
      for (var i = 3; i <= 20; i++)
        {
          'id': i + 10,
          'nsid': i,
          'subsys': {'id': 2},
          'device_type': 'ZVOL',
          'enabled': false,
          'locked': false,
        },
    ]);
    h.api.extraSubsystem = true;
    h.api.extraNamespaces.add({
      'id': 99,
      'nsid': 21,
      'subsys': {'id': 4},
      'device_type': 'ZVOL',
      'enabled': false,
      'locked': false,
    });
    final candidates = await h.coordinator.loadCandidates();
    expect(candidates.map((c) => c.target.id), [
      7,
      8,
      for (var i = 3; i <= 20; i++) i + 10,
    ]);
    expect(candidates.every((c) => c.suggestedNsid == 21), true);
    expect(candidates.first.usedNsids, [for (var i = 1; i <= 20; i++) i]);
    expect(h.writes, 0);
  });
  test('discovery invalidates old authorization and stale suggestions cannot bypass new collisions', () async {
    final h = _Harness();
    final old = await h.coordinator.prepare(7, nsid: 3);
    final candidates = await h.coordinator.loadCandidates();
    expect(
      (await h.execute(old)).outcome,
      NvmeAttachedNamespaceNsidOutcome.rejected,
    );
    h.api.other['nsid'] = candidates.first.suggestedNsid;
    await expectLater(
      h.coordinator.prepare(7, nsid: candidates.first.suggestedNsid),
      throwsStateError,
    );
    h.api.other['nsid'] = 2;
    final review = await h.coordinator.prepare(
      7,
      nsid: candidates.first.suggestedNsid,
    );
    h.api.other['nsid'] = 3;
    expect(
      (await h.execute(review)).outcome,
      NvmeAttachedNamespaceNsidOutcome.rejected,
    );
    expect(h.writes, 0);
  });
  for (final query in [
    'nvmet.subsys.query',
    'nvmet.port.query',
    'nvmet.namespace.query',
    'nvmet.port_subsys.query',
  ]) {
    test('$query discovery failure is sanitized and lock released', () async {
      final h = _Harness();
      h.api.queryFailure = query;
      await expectLater(
        h.coordinator.loadCandidates(),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'sanitized',
            isNot(contains('private-server-error')),
          ),
        ),
      );
      final owner = h.lock.acquire();
      expect(owner, isNotNull);
      h.lock.release(owner!);
      h.api.queryFailure = null;
      expect(await h.coordinator.loadCandidates(), hasLength(2));
      expect(h.writes, 0);
    });
  }
  for (final reason in ['session', 'dispose', 'lock', 'uncertain']) {
    test('$reason blocks discovery without queries', () async {
      final h = _Harness();
      if (reason == 'session') h.current = false;
      if (reason == 'dispose') h.coordinator.dispose();
      if (reason == 'uncertain') {
        final review = await h.coordinator.prepare(7, nsid: 3);
        h.api.failure = 'unknown';
        await h.execute(review);
        h.api.calls.clear();
      }
      final owner = reason == 'lock' ? h.lock.acquire() : null;
      await expectLater(h.coordinator.loadCandidates(), throwsStateError);
      expect(h.api.calls, isEmpty);
      if (owner != null) h.lock.release(owner);
    });
  }
  for (final reason in ['session', 'dispose', 'concurrent']) {
    test(
      '$reason during discovery rejects stale work and releases lock',
      () async {
        final h = _Harness();
        h.api.gate = Completer<void>();
        final pending = h.coordinator.loadCandidates();
        final checked = reason == 'concurrent'
            ? null
            : expectLater(pending, throwsStateError);
        await h.api.started.future;
        if (reason == 'session') h.current = false;
        if (reason == 'dispose') h.coordinator.dispose();
        if (reason == 'concurrent') {
          await expectLater(h.coordinator.loadCandidates(), throwsStateError);
          await expectLater(
            h.coordinator.prepare(7, nsid: 3),
            throwsStateError,
          );
        }
        h.api.gate!.complete();
        if (checked != null) {
          await checked;
        } else {
          expect(await pending, hasLength(2));
        }
        final owner = h.lock.acquire();
        expect(owner, isNotNull);
        h.lock.release(owner!);
        expect(h.writes, 0);
      },
    );
  }
  for (final nsid in [-1, 0, 4294967295, 4294967296]) {
    test(
      'invalid or reserved requested NSID $nsid sends no reads or writes',
      () async {
        final h = _Harness();
        await expectLater(
          h.coordinator.prepare(7, nsid: nsid),
          throwsStateError,
        );
        expect(h.api.calls, isEmpty);
      },
    );
  }
  for (final id in [-1, 0, 999]) {
    test('invalid or absent namespace database ID $id cannot write', () async {
      final h = _Harness();
      await expectLater(h.coordinator.prepare(id, nsid: 3), throwsStateError);
      expect(h.writes, 0);
    });
  }
  for (final otherNsid in [null, 3]) {
    test(
      'other subsystem NSID $otherNsid does not cause a false collision',
      () async {
        final h = _Harness();
        h.api.extraSubsystem = true;
        h.api.other['subsys'] = {'id': 4};
        h.api.other['nsid'] = otherNsid;
        final review = await h.coordinator.prepare(7, nsid: 3);
        expect(
          (await h.execute(review)).outcome,
          NvmeAttachedNamespaceNsidOutcome.completed,
        );
        expect(h.writes, 1);
      },
    );
  }
  for (final nsid in [3, 4294967294]) {
    test('exact NSID-only payload $nsid with separate readback', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7, nsid: nsid);
      expect(r.mapping.id, 11);
      expect(r.port.id, 3);
      expect(r.residents.single.id, 8);
      expect(() => r.residents.clear(), throwsUnsupportedError);
      expect(h.writes, 0);
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceNsidOutcome.completed,
      );
      expect(
        h.api.calls
            .singleWhere((r) => r.method.name == 'nvmet.namespace.update')
            .arguments,
        [
          7,
          {'nsid': nsid},
        ],
      );
      expect(h.api.calls.last.method.name, 'nvmet.port_subsys.query');
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceNsidOutcome.rejected,
      );
      expect(h.writes, 1);
    });
  }
  final unsafe = <String, void Function(_Fake)>{
    'missing association': (a) => a.mappings.clear(),
    'enabled port': (a) => a.ports.first['enabled'] = true,
    'FC port': (a) => a.ports.first['addr_trtype'] = 'FC',
    'unknown port enabled': (a) => a.ports.first.remove('enabled'),
    'shared port': (a) {
      a.extraSubsystem = true;
      a.mappings.add({
        'id': 12,
        'port': {'id': 3},
        'subsys': {'id': 4},
      });
    },
    'shared subsystem': (a) {
      a.ports.add({'id': 6, 'addr_trtype': 'TCP', 'enabled': false});
      a.mappings.add({
        'id': 12,
        'port': {'id': 6},
        'subsys': {'id': 2},
      });
    },
    'neighbor FILE': (a) => a.other['device_type'] = 'FILE',
    'neighbor enabled': (a) => a.other['enabled'] = true,
    'neighbor locked': (a) => a.other['locked'] = true,
    'neighbor unknown lock': (a) => a.other.remove('locked'),
    'unknown NQN': (a) => a.subsystem.remove('subnqn'),
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
    'no-op': (a) => a.namespace['nsid'] = 3,
    'collision': (a) => a.other['nsid'] = 3,
    'unknown other NSID': (a) => a.other.remove('nsid'),
    'out of range other NSID': (a) => a.other['nsid'] = 4294967295,
    'duplicate existing NSIDs': (a) => a.other['nsid'] = 1,
  };
  test(
    'disabled RDMA association preserves neighbors at minimum NSID',
    () async {
      final h = _Harness();
      h.api.ports.single['addr_trtype'] = 'RDMA';
      h.api.namespace['nsid'] = 4;
      final review = await h.coordinator.prepare(7, nsid: 1);
      expect(review.port.transport, 'RDMA');
      expect(
        (await h.execute(review)).outcome,
        NvmeAttachedNamespaceNsidOutcome.completed,
      );
      expect(h.api.other['nsid'], 2);
      expect(h.api.ports.single['enabled'], false);
      expect(h.api.mappings.single['id'], 11);
      expect(h.writes, 1);
    },
  );
  for (final entry in unsafe.entries) {
    test(
      '${entry.key} discovery filters unsafe targets or avoids occupied/no-op suggestions',
      () async {
        final h = _Harness();
        entry.value(h.api);
        try {
          final candidates = await h.coordinator.loadCandidates();
          if (const {'no-op', 'collision'}.contains(entry.key)) {
            final candidate = candidates.singleWhere((c) => c.target.id == 7);
            expect(
              candidate.usedNsids.contains(candidate.suggestedNsid),
              false,
            );
            expect(candidate.suggestedNsid, isNot(candidate.target.nsid));
          } else {
            expect(candidates.any((c) => c.target.id == 7), false);
          }
        } on StateError catch (error) {
          expect(error.toString(), contains('NSID target discovery failed'));
        }
        expect(h.writes, 0);
      },
    );
    test(
      '${entry.key} is rejected before review and at fresh preflight',
      () async {
        final a = _Harness();
        entry.value(a.api);
        await expectLater(a.coordinator.prepare(7, nsid: 3), throwsStateError);
        expect(a.writes, 0);
        final b = _Harness();
        final r = await b.coordinator.prepare(7, nsid: 3);
        entry.value(b.api);
        expect(
          (await b.execute(r)).outcome,
          NvmeAttachedNamespaceNsidOutcome.rejected,
        );
        expect(b.writes, 0);
      },
    );
  }
  for (final reason in [
    'phrase',
    'identity',
    'reload',
    'limitations',
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
      final r = await h.coordinator.prepare(7, nsid: 3);
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
        NvmeAttachedNamespaceNsidOutcome.rejected,
      );
      expect(h.writes, 0);
      if (owner != null) h.lock.release(owner);
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceNsidOutcome.rejected,
      );
    });
  }
  for (final failure in [
    'port enabled',
    'port transport',
    'port settings',
    'mapping removed',
    'mapping ID',
    'neighbor enabled',
    'neighbor lock',
    'neighbor FILE',
    'subsystem NQN',
    'subsystem name',
    'subsystem settings',
    'subsystem any host',
    'throw',
    'denied',
    'unknown',
    'response ID',
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
      final r = await h.coordinator.prepare(7, nsid: 3);
      h.api.failure = failure;
      final result = await h.execute(r);
      expect(result.outcome, NvmeAttachedNamespaceNsidOutcome.unknown);
      expect(result.message, isNot(contains('private-server-error')));
      expect(h.coordinator.locked, true);
      expect(h.writes, 1);
      await expectLater(h.coordinator.prepare(7, nsid: 4), throwsStateError);
      expect(h.writes, 1);
    });
  }
  test('foreign review cannot be consumed or cancelled', () async {
    final a = _Harness(), b = _Harness();
    final r = await a.coordinator.prepare(7, nsid: 3);
    b.coordinator.cancel(r);
    expect(
      (await b.execute(r)).outcome,
      NvmeAttachedNamespaceNsidOutcome.rejected,
    );
    expect(
      (await a.execute(r)).outcome,
      NvmeAttachedNamespaceNsidOutcome.completed,
    );
  });
  for (final reason in ['expire', 'session', 'dispose']) {
    test('$reason during slow preflight prevents dispatch', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7, nsid: 3);
      h.api.gate = Completer<void>();
      final result = h.execute(r);
      await h.api.started.future;
      if (reason == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      if (reason == 'session') h.current = false;
      if (reason == 'dispose') h.coordinator.dispose();
      h.api.gate!.complete();
      expect((await result).outcome, NvmeAttachedNamespaceNsidOutcome.rejected);
      expect(h.writes, 0);
    });
  }
  for (final reason in ['session', 'dispose']) {
    test('$reason after dispatch fences the original session', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7, nsid: 3);
      h.api.onDispatch = () {
        if (reason == 'session') h.current = false;
        if (reason == 'dispose') h.coordinator.dispose();
      };
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceNsidOutcome.unknown,
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
      await expectLater(h.coordinator.prepare(7, nsid: 3), throwsStateError);
      expect(h.api.calls, isEmpty);
    });
  }
  for (final dark in [true, false]) {
    for (final width in [320.0, 430.0]) {
      testWidgets(
        'attached disabled ZVOL review $width dark=$dark at 200% with keyboard',
        (tester) async {
          final h = _Harness();
          tester.view.physicalSize = Size(width, 960);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final container = ProviderContainer(
            overrides: [
              dashboardActiveSessionProvider.overrideWith(
                (ref) => ref.watch(_active),
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
                      child: NvmeAttachedNamespaceNsidEditor(),
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

          final id = find.byKey(const Key('nvme-attached-namespace-nsid-id'));
          await tester.enterText(id, '7');
          await tester.enterText(
            find.byKey(const Key('nvme-attached-namespace-nsid-new')),
            '3',
          );
          await tester.pumpAndSettle();
          await tap('nvme-attached-namespace-nsid-review');
          expect(h.writes, 0);
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('nvme-attached-namespace-nsid-submit')),
                )
                .onPressed,
            isNull,
          );
          await tap('nvme-attached-namespace-nsid-reload');
          await tap('nvme-attached-namespace-nsid-limitations');
          final phrase = find.byKey(
            const Key('nvme-attached-namespace-nsid-phrase'),
          );
          await tester.ensureVisible(phrase);
          await tester.enterText(
            phrase,
            'CHANGE ATTACHED NVME NAMESPACE 7 NSID 1 TO 3 KEEP ASSOCIATION 11 PORT 3 SUBSYSTEM 2 NQN nqn.2026-09.example:unused',
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('nvme-attached-namespace-nsid-submit')),
                )
                .onPressed,
            isNull,
          );
          await tap('nvme-attached-namespace-nsid-identity');
          await tap('nvme-attached-namespace-nsid-submit');
          expect(h.writes, 1);
          expect(h.api.namespace['nsid'], 3);
          await tester.enterText(
            find.byKey(const Key('nvme-attached-namespace-nsid-new')),
            '4',
          );
          await tester.pumpAndSettle();
          await tap('nvme-attached-namespace-nsid-review');
          for (final consent in ['reload', 'limitations', 'identity']) {
            expect(
              tester
                  .widget<Checkbox>(
                    find.byKey(Key('nvme-attached-namespace-nsid-$consent')),
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
