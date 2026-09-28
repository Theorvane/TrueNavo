import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_namespace_nsid_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_namespace_nsid_editor.dart';

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession {
  @override
  final adminCatalog = AdminCatalog.fromMetadata(
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
    'device_type': 'FILE',
    'enabled': false,
    'locked': false,
  };
  final ports = <Map<String, Object?>>[
    {'id': 3, 'addr_trtype': 'TCP', 'enabled': false},
  ];
  final mappings = <Map<String, Object?>>[],
      hostMappings = <Map<String, Object?>>[];
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
    coordinator = NvmeNamespaceNsidCoordinator(
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
  late final NvmeNamespaceNsidCoordinator coordinator;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  int get writes =>
      api.calls.where((r) => r.method.name == 'nvmet.namespace.update').length;
  Future<NvmeNamespaceNsidResult> execute(
    NvmeNamespaceNsidReview r, {
    String? phrase,
    bool reload = true,
    bool limitations = true,
  }) => coordinator.execute(
    r,
    phrase ?? r.confirmation,
    acknowledgeReload: reload,
    acknowledgeLimitations: limitations,
  );
}

class _Active extends Notifier<AuthenticatedSession?> {
  @override
  AuthenticatedSession? build() => null;
  void select(AuthenticatedSession session) => state = session;
}

final _active = NotifierProvider<_Active, AuthenticatedSession?>(_Active.new);

void main() {
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
          NvmeNamespaceNsidOutcome.completed,
        );
        expect(h.writes, 1);
      },
    );
  }
  for (final nsid in [3, 4294967294]) {
    test('exact NSID-only payload $nsid with separate readback', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7, nsid: nsid);
      expect(h.writes, 0);
      expect((await h.execute(r)).outcome, NvmeNamespaceNsidOutcome.completed);
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
      expect((await h.execute(r)).outcome, NvmeNamespaceNsidOutcome.rejected);
      expect(h.writes, 1);
    });
  }
  final unsafe = <String, void Function(_Fake)>{
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
  for (final entry in unsafe.entries) {
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
        expect((await b.execute(r)).outcome, NvmeNamespaceNsidOutcome.rejected);
        expect(b.writes, 0);
      },
    );
  }
  for (final reason in [
    'phrase',
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
        )).outcome,
        NvmeNamespaceNsidOutcome.rejected,
      );
      expect(h.writes, 0);
      if (owner != null) h.lock.release(owner);
      expect((await h.execute(r)).outcome, NvmeNamespaceNsidOutcome.rejected);
    });
  }
  for (final failure in [
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
      expect(result.outcome, NvmeNamespaceNsidOutcome.unknown);
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
    expect((await b.execute(r)).outcome, NvmeNamespaceNsidOutcome.rejected);
    expect((await a.execute(r)).outcome, NvmeNamespaceNsidOutcome.completed);
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
      expect((await result).outcome, NvmeNamespaceNsidOutcome.rejected);
      expect(h.writes, 0);
    });
  }
  for (final dark in [true, false]) {
    for (final width in [320.0, 430.0]) {
      testWidgets(
        'isolated ZVOL review $width dark=$dark at 200% with keyboard',
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
                      child: NvmeNamespaceNsidEditor(),
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

          final id = find.byKey(const Key('nvme-namespace-nsid-id'));
          await tester.enterText(id, '7');
          await tester.enterText(
            find.byKey(const Key('nvme-namespace-nsid-new')),
            '3',
          );
          await tester.pumpAndSettle();
          await tap('nvme-namespace-nsid-review');
          expect(h.writes, 0);
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('nvme-namespace-nsid-submit')),
                )
                .onPressed,
            isNull,
          );
          await tap('nvme-namespace-nsid-reload');
          await tap('nvme-namespace-nsid-limitations');
          final phrase = find.byKey(const Key('nvme-namespace-nsid-phrase'));
          await tester.ensureVisible(phrase);
          await tester.enterText(
            phrase,
            'CHANGE NVME NAMESPACE 7 NSID 1 TO 3 SUBSYSTEM 2',
          );
          await tester.pumpAndSettle();
          await tap('nvme-namespace-nsid-submit');
          expect(h.writes, 1);
          expect(h.api.namespace['nsid'], 3);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
