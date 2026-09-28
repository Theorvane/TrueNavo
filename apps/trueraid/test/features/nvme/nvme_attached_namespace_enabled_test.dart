import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_attached_namespace_enabled_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_attached_namespace_enabled_editor.dart';

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
  bool malformed = false;
  bool extraSubsystem = false;
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
    if (request.method.name != 'nvmet.namespace.update') {
      throw StateError('Unexpected method');
    }
    onDispatch?.call();
    if (failure == 'throw') throw StateError('private-server-error');
    if (failure == 'denied') {
      return AdminFailed(request, reason: AdminFailureReason.denied);
    }
    if (failure == 'unknown') return AdminOutcomeUnknown(request);
    namespace['enabled'] = (request.arguments[1] as Map)['enabled'];
    final returned = Map.of(namespace);
    if (failure == 'response ID') returned['id'] = 999;
    if (failure == 'response enabled') returned['enabled'] = false;
    if (failure == 'response subsystem') returned['subsys'] = {'id': 4};
    if (failure == 'response FILE') returned['device_type'] = 'FILE';
    if (failure == 'response missing enabled') returned.remove('enabled');
    if (failure == 'readback lock') namespace['locked'] = true;
    if (failure == 'readback FILE') namespace['device_type'] = 'FILE';
    if (failure == 'readback missing enabled') namespace.remove('enabled');
    if (failure == 'response NSID') {
      returned['nsid'] = 999;
    }
    if (failure == 'response lock') returned['locked'] = true;
    if (failure == 'readback enabled') {
      namespace['enabled'] = false;
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
    coordinator = NvmeAttachedNamespaceEnabledCoordinator(
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
  late final NvmeAttachedNamespaceEnabledCoordinator coordinator;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  int get writes =>
      api.calls.where((r) => r.method.name == 'nvmet.namespace.update').length;
  Future<NvmeAttachedNamespaceEnabledResult> execute(
    NvmeAttachedNamespaceEnabledReview r, {
    String? phrase,
    bool reload = true,
    bool limitations = true,
    bool exposure = true,
  }) => coordinator.execute(
    r,
    phrase ?? r.confirmation,
    acknowledgeReload: reload,
    acknowledgeLimitations: limitations,
    acknowledgeExposureRisk: exposure,
  );
}

class _Active extends Notifier<AuthenticatedSession?> {
  @override
  AuthenticatedSession? build() => null;
  void select(AuthenticatedSession session) => state = session;
}

final _active = NotifierProvider<_Active, AuthenticatedSession?>(_Active.new);

Future<ProviderContainer> _mount(WidgetTester tester, _Harness h) async {
  final container = ProviderContainer(
    overrides: [
      dashboardActiveSessionProvider.overrideWith((ref) => ref.watch(_active)),
    ],
  );
  addTearDown(container.dispose);
  container.read(_active.notifier).select(h.session);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: TrueRAIDTheme.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: NvmeAttachedNamespaceEnabledEditor(),
          ),
        ),
      ),
    ),
  );
  await tester.enterText(
    find.byKey(const Key('nvme-attached-namespace-enabled-id')),
    '7',
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  test('new review supersedes an earlier review without dispatch', () async {
    final h = _Harness();
    final old = await h.coordinator.prepare(7, enabled: true);
    final current = await h.coordinator.prepare(7, enabled: true);
    expect(
      (await h.execute(old)).outcome,
      NvmeAttachedNamespaceEnabledOutcome.rejected,
    );
    expect(h.writes, 0);
    expect(
      (await h.execute(current)).outcome,
      NvmeAttachedNamespaceEnabledOutcome.completed,
    );
    expect(h.writes, 1);
  });
  test('oversized port inventory rejects review and fresh preflight', () async {
    void overflow(_Fake api) {
      api.ports.addAll([
        for (var id = 100; id < 200; id++)
          {'id': id, 'addr_trtype': 'TCP', 'enabled': false},
      ]);
    }

    final a = _Harness();
    overflow(a.api);
    await expectLater(
      a.coordinator.prepare(7, enabled: true),
      throwsStateError,
    );
    expect(a.writes, 0);
    final b = _Harness();
    final r = await b.coordinator.prepare(7, enabled: true);
    overflow(b.api);
    expect(
      (await b.execute(r)).outcome,
      NvmeAttachedNamespaceEnabledOutcome.rejected,
    );
    expect(b.writes, 0);
  });
  for (final id in [-1, 0, 999]) {
    test('invalid or absent namespace database ID $id cannot write', () async {
      final h = _Harness();
      await expectLater(
        h.coordinator.prepare(id, enabled: true),
        throwsStateError,
      );
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
        final review = await h.coordinator.prepare(7, enabled: true);
        expect(
          (await h.execute(review)).outcome,
          NvmeAttachedNamespaceEnabledOutcome.completed,
        );
        expect(h.writes, 1);
      },
    );
  }
  for (final transport in ['TCP', 'RDMA']) {
    for (final enabled in [true, false]) {
      test(
        '$transport exact enabled-only payload $enabled and preserved public rows',
        () async {
          final h = _Harness();
          h.api.ports.single['addr_trtype'] = transport;
          h.api.namespace['enabled'] = !enabled;
          final r = await h.coordinator.prepare(7, enabled: enabled);
          expect(r.mapping.id, 11);
          expect(r.port.id, 3);
          expect(r.port.transport, transport);
          expect(r.residents.single.id, 8);
          expect(() => r.residents.clear(), throwsUnsupportedError);
          expect(h.writes, 0);
          expect(
            (await h.execute(r)).outcome,
            NvmeAttachedNamespaceEnabledOutcome.completed,
          );
          expect(
            h.api.calls
                .singleWhere((r) => r.method.name == 'nvmet.namespace.update')
                .arguments,
            [
              7,
              {'enabled': enabled},
            ],
          );
          expect(h.api.namespace['nsid'], 1);
          expect(h.api.other['enabled'], false);
          expect(h.api.ports.single['enabled'], false);
          expect(h.api.mappings.single['id'], 11);
          expect(h.api.calls.last.method.name, 'nvmet.port_subsys.query');
          expect(
            (await h.execute(r)).outcome,
            NvmeAttachedNamespaceEnabledOutcome.rejected,
          );
          expect(h.writes, 1);
        },
      );
    }
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
    'unknown enabled': (a) => a.namespace.remove('enabled'),
    'no-op': (a) => a.namespace['enabled'] = true,
    'reserved target NSID': (a) => a.namespace['nsid'] = 4294967295,
    'unknown other NSID': (a) => a.other.remove('nsid'),
    'out of range other NSID': (a) => a.other['nsid'] = 4294967295,
    'duplicate existing NSIDs': (a) => a.other['nsid'] = 1,
  };
  for (final entry in unsafe.entries) {
    test(
      '${entry.key} is rejected before review and at fresh preflight',
      () async {
        final a = _Harness();
        entry.value(a.api);
        await expectLater(
          a.coordinator.prepare(7, enabled: true),
          throwsStateError,
        );
        expect(a.writes, 0);
        final b = _Harness();
        final r = await b.coordinator.prepare(7, enabled: true);
        entry.value(b.api);
        expect(
          (await b.execute(r)).outcome,
          NvmeAttachedNamespaceEnabledOutcome.rejected,
        );
        expect(b.writes, 0);
      },
    );
  }
  for (final reason in [
    'phrase',
    'exposure',
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
      final r = await h.coordinator.prepare(7, enabled: true);
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
          exposure: reason != 'exposure',
        )).outcome,
        NvmeAttachedNamespaceEnabledOutcome.rejected,
      );
      expect(h.writes, 0);
      if (owner != null) h.lock.release(owner);
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceEnabledOutcome.rejected,
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
    'response enabled',
    'response subsystem',
    'response FILE',
    'response missing enabled',
    'readback lock',
    'readback FILE',
    'readback missing enabled',
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
      final r = await h.coordinator.prepare(7, enabled: true);
      h.api.failure = failure;
      final result = await h.execute(r);
      expect(result.outcome, NvmeAttachedNamespaceEnabledOutcome.unknown);
      expect(result.message, isNot(contains('private-server-error')));
      expect(h.coordinator.locked, true);
      expect(h.writes, 1);
      await expectLater(
        h.coordinator.prepare(7, enabled: false),
        throwsStateError,
      );
      expect(h.writes, 1);
    });
  }
  test('foreign review cannot be consumed or cancelled', () async {
    final a = _Harness(), b = _Harness();
    final r = await a.coordinator.prepare(7, enabled: true);
    b.coordinator.cancel(r);
    expect(
      (await b.execute(r)).outcome,
      NvmeAttachedNamespaceEnabledOutcome.rejected,
    );
    expect(
      (await a.execute(r)).outcome,
      NvmeAttachedNamespaceEnabledOutcome.completed,
    );
  });
  for (final reason in ['expire', 'session', 'dispose']) {
    test('$reason during slow preflight prevents dispatch', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7, enabled: true);
      h.api.gate = Completer<void>();
      final result = h.execute(r);
      await h.api.started.future;
      if (reason == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      if (reason == 'session') h.current = false;
      if (reason == 'dispose') h.coordinator.dispose();
      h.api.gate!.complete();
      expect(
        (await result).outcome,
        NvmeAttachedNamespaceEnabledOutcome.rejected,
      );
      expect(h.writes, 0);
    });
  }
  for (final reason in ['session', 'dispose']) {
    test('$reason after dispatch fences the original session', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7, enabled: true);
      h.api.onDispatch = () {
        if (reason == 'session') h.current = false;
        if (reason == 'dispose') h.coordinator.dispose();
      };
      expect(
        (await h.execute(r)).outcome,
        NvmeAttachedNamespaceEnabledOutcome.unknown,
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
      await expectLater(
        h.coordinator.prepare(7, enabled: true),
        throwsStateError,
      );
      expect(h.api.calls, isEmpty);
    });
  }
  for (final dark in [true, false]) {
    for (final width in [320.0, 430.0]) {
      testWidgets(
        'attached ZVOL enabled review $width dark=$dark at 200% with keyboard',
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
                theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 960),
                    textScaler: const TextScaler.linear(2),
                    viewInsets: const EdgeInsets.only(bottom: 200),
                  ),
                  child: const Scaffold(
                    body: SingleChildScrollView(
                      child: NvmeAttachedNamespaceEnabledEditor(),
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

          final id = find.byKey(
            const Key('nvme-attached-namespace-enabled-id'),
          );
          await tester.enterText(id, '7');
          await tester.pumpAndSettle();
          await tap('nvme-attached-namespace-enabled-review');
          expect(h.writes, 0);
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(
                    const Key('nvme-attached-namespace-enabled-submit'),
                  ),
                )
                .onPressed,
            isNull,
          );
          await tap('nvme-attached-namespace-enabled-reload');
          await tap('nvme-attached-namespace-enabled-limitations');
          final phrase = find.byKey(
            const Key('nvme-attached-namespace-enabled-phrase'),
          );
          await tester.ensureVisible(phrase);
          await tester.enterText(
            phrase,
            'ENABLE ATTACHED NVME NAMESPACE 7 NSID 1 FROM false TO true KEEP ASSOCIATION 11 PORT 3 SUBSYSTEM 2 NQN nqn.2026-09.example:unused',
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(
                    const Key('nvme-attached-namespace-enabled-submit'),
                  ),
                )
                .onPressed,
            isNull,
          );
          await tap('nvme-attached-namespace-enabled-exposure');
          await tap('nvme-attached-namespace-enabled-submit');
          expect(h.writes, 1);
          expect(h.api.namespace['enabled'], true);
          await tap('nvme-attached-namespace-enabled-value');
          await tester.tap(find.text('Disabled').last);
          await tester.pumpAndSettle();
          await tap('nvme-attached-namespace-enabled-review');
          for (final consent in ['reload', 'limitations', 'exposure']) {
            expect(
              tester
                  .widget<Checkbox>(
                    find.byKey(Key('nvme-attached-namespace-enabled-$consent')),
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
  for (final change in ['ID', 'setting', 'session']) {
    testWidgets('$change invalidates native review with no write', (
      tester,
    ) async {
      final h = _Harness();
      final container = await _mount(tester, h);
      final button = find.byKey(
        const Key('nvme-attached-namespace-enabled-review'),
      );
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nvme-attached-namespace-enabled-phrase')),
        findsOneWidget,
      );
      if (change == 'ID') {
        await tester.enterText(
          find.byKey(const Key('nvme-attached-namespace-enabled-id')),
          '8',
        );
      } else if (change == 'setting') {
        final selector = find.byKey(
          const Key('nvme-attached-namespace-enabled-value'),
        );
        await tester.ensureVisible(selector);
        await tester.tap(selector);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Disabled').last);
      } else {
        container.read(_active.notifier).select(_Harness().session);
      }
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nvme-attached-namespace-enabled-phrase')),
        findsNothing,
      );
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('disposed page cannot restore a late native review', (
    tester,
  ) async {
    final h = _Harness();
    await _mount(tester, h);
    h.api.gate = Completer<void>();
    final button = find.byKey(
      const Key('nvme-attached-namespace-enabled-review'),
    );
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await h.api.started.future;
    await tester.pumpWidget(const SizedBox());
    h.api.gate!.complete();
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('nvme-attached-namespace-enabled-phrase')),
      findsNothing,
    );
  });
}
