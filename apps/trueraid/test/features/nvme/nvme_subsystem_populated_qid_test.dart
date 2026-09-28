import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_subsystem_populated_qid_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_subsystem_populated_qid_editor.dart';

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
    'qid_max': 16,
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
  final mappings = <Map<String, Object?>>[],
      hostMappings = <Map<String, Object?>>[];
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
    if (failure == 'throw') throw StateError('private-server-error');
    if (failure == 'denied') {
      return AdminFailed(request, reason: AdminFailureReason.denied);
    }
    if (failure == 'unknown') return AdminOutcomeUnknown(request);
    subsystem['qid_max'] = (request.arguments[1] as Map)['qid_max'];
    final returned = Map.of(subsystem);
    if (failure == 'response ID') returned['id'] = 999;
    if (failure == 'response NQN') {
      returned['subnqn'] = 'nqn.2026-09.example:wrong';
    }
    if (failure == 'response name') returned['name'] = 'changed';
    if (failure == 'namespace enabled') namespace['enabled'] = true;
    if (failure == 'namespace NSID') namespace['nsid'] = 4;
    if (failure == 'response access') returned['allow_any_host'] = true;
    for (final field in ['qid_max', 'pi_enable', 'ana', 'ieee_oui']) {
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
            : true;
      }
    }
    if (failure == 'readback qid_max') subsystem['qid_max'] = 16;
    if (failure == 'response missing QID') returned.remove('qid_max');
    if (failure == 'response malformed QID') returned['qid_max'] = '1';
    if (failure == 'readback missing QID') subsystem.remove('qid_max');
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
    coordinator = NvmeSubsystemPopulatedQidCoordinator(
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
  late final NvmeSubsystemPopulatedQidCoordinator coordinator;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  int get writes =>
      api.calls.where((r) => r.method.name == 'nvmet.subsys.update').length;
  Future<NvmeSubsystemPopulatedQidResult> execute(
    NvmeSubsystemPopulatedQidReview r, {
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

const _choice = NvmePopulatedQidChoice(1);
const _choices = [
  NvmePopulatedQidChoice(null),
  NvmePopulatedQidChoice(1),
  NvmePopulatedQidChoice(2147483647),
];
void main() {
  testWidgets(
    'strict queue-ID input rejects malformed limits without reads and invalidates reviewed input',
    (tester) async {
      final h = _Harness();
      final container = ProviderContainer(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
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
                child: NvmeSubsystemPopulatedQidEditor(),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('nvme-subsystem-populated-qid-id')),
        '2',
      );
      final toggle = find.byKey(
        const Key('nvme-subsystem-populated-qid-default'),
      );
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final limit = find.byKey(const Key('nvme-subsystem-populated-qid-limit'));
      for (final invalid in [
        '',
        '0',
        '-1',
        '+1',
        ' 1',
        '1 ',
        '01',
        '1.5',
        '1e2',
        '2147483648',
        '9999999999',
      ]) {
        await tester.ensureVisible(limit);
        await tester.enterText(limit, invalid);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('nvme-subsystem-populated-qid-review')),
              )
              .onPressed,
          isNull,
          reason: invalid,
        );
        expect(h.api.calls, isEmpty);
      }
      await tester.enterText(limit, '1');
      await tester.pumpAndSettle();
      final reviewButton = find.byKey(
        const Key('nvme-subsystem-populated-qid-review'),
      );
      await tester.ensureVisible(reviewButton);
      await tester.tap(reviewButton);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nvme-subsystem-populated-qid-submit')),
        findsOneWidget,
      );
      await tester.ensureVisible(limit);
      await tester.enterText(limit, '2');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('nvme-subsystem-populated-qid-submit')),
        findsNothing,
      );
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final invalid in [-1, 0, 2147483648]) {
    test(
      'invalid requested queue-ID limit $invalid rejects before reads',
      () async {
        final h = _Harness();
        await expectLater(
          h.coordinator.prepare(2, choice: NvmePopulatedQidChoice(invalid)),
          throwsStateError,
        );
        expect(h.api.calls, isEmpty);
      },
    );
  }

  test(
    'multiple namespaces are reviewed immutably and remain unchanged',
    () async {
      final h = _Harness();
      h.api.other['subsys'] = {'id': 2};
      h.api.other['device_type'] = 'ZVOL';
      final before = Map.of(h.api.other);
      final review = await h.coordinator.prepare(2, choice: _choice);
      expect(review.namespaces.map((n) => n.id), [7, 8]);
      expect(() => review.namespaces.clear(), throwsUnsupportedError);
      expect(
        (await h.execute(review)).outcome,
        NvmeSubsystemPopulatedQidOutcome.completed,
      );
      expect(h.api.other, before);
      expect(h.writes, 1);
    },
  );
  for (final initial in [null, 1, 16, 2147483647]) {
    for (final choice in _choices) {
      test(
        'saved QID $initial to ${choice.label} only submits qid_max',
        () async {
          final h = _Harness();
          h.api.subsystem.addAll({
            'qid_max': initial,
            'pi_enable': false,
            'ana': false,
            'ieee_oui': '00:11:22',
          });
          if (initial == choice.wireValue) {
            await expectLater(
              h.coordinator.prepare(2, choice: choice),
              throwsStateError,
            );
            expect(h.writes, 0);
            return;
          }
          final before = Map.of(h.api.namespace);
          final review = await h.coordinator.prepare(2, choice: choice);
          expect(
            (await h.execute(review)).outcome,
            NvmeSubsystemPopulatedQidOutcome.completed,
          );
          expect(
            h.api.calls
                .singleWhere((r) => r.method.name == 'nvmet.subsys.update')
                .arguments,
            [
              2,
              {'qid_max': choice.wireValue},
            ],
          );
          expect(h.api.subsystem['name'], 'unused');
          expect(h.api.subsystem['subnqn'], 'nqn.2026-09.example:unused');
          expect(h.api.subsystem['ana'], false);
          expect(h.api.namespace, before);
          expect(
            (await h.execute(review)).outcome,
            NvmeSubsystemPopulatedQidOutcome.rejected,
          );
          expect(h.writes, 1);
        },
      );
    }
  }
  for (final id in [-1, 0, 999]) {
    test('invalid or missing subsystem ID $id cannot write', () async {
      final h = _Harness();
      await expectLater(
        h.coordinator.prepare(id, choice: _choice),
        throwsStateError,
      );
      expect(h.writes, 0);
    });
  }
  final unsafe = <String, void Function(_Fake)>{
    'any host': (a) => a.subsystem['allow_any_host'] = true,
    'unknown NQN': (a) => a.subsystem.remove('subnqn'),
    'no-op': (a) => a.subsystem['qid_max'] = 1,
    'missing QID': (a) => a.subsystem.remove('qid_max'),
    'zero NSID': (a) => a.namespace['nsid'] = 0,
    'empty': (a) => a.namespace['subsys'] = {'id': 4},
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
        a.coordinator.prepare(2, choice: _choice),
        throwsStateError,
      );
      expect(a.writes, 0);
      final b = _Harness();
      final review = await b.coordinator.prepare(2, choice: _choice);
      entry.value(b.api);
      expect(
        (await b.execute(review)).outcome,
        NvmeSubsystemPopulatedQidOutcome.rejected,
      );
      expect(b.writes, 0);
    });
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
      final review = await h.coordinator.prepare(2, choice: _choice);
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
        )).outcome,
        NvmeSubsystemPopulatedQidOutcome.rejected,
      );
      expect(h.writes, 0);
      if (owner != null) h.lock.release(owner);
      expect(
        (await h.execute(review)).outcome,
        NvmeSubsystemPopulatedQidOutcome.rejected,
      );
    });
  }
  for (final failure in [
    'throw',
    'denied',
    'unknown',
    'response missing QID',
    'response malformed QID',
    'readback missing QID',
    'response ID',
    'response NQN',
    'response name',
    'response access',
    'response qid_max',
    'response pi_enable',
    'response ana',
    'response ieee_oui',
    'readback NQN',
    'readback name',
    'readback qid_max',
    'readback pi_enable',
    'readback ana',
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
        final review = await h.coordinator.prepare(2, choice: _choice);
        h.api.failure = failure;
        final result = await h.execute(review);
        expect(result.outcome, NvmeSubsystemPopulatedQidOutcome.unknown);
        expect(result.message, isNot(contains('private-server-error')));
        expect(h.coordinator.locked, true);
        expect(h.writes, 1);
        await expectLater(
          h.coordinator.prepare(
            2,
            choice: const NvmePopulatedQidChoice(2147483647),
          ),
          throwsStateError,
        );
        expect(h.writes, 1);
      },
    );
  }
  test('foreign review cannot be cancelled or consumed', () async {
    final a = _Harness(), b = _Harness();
    final review = await a.coordinator.prepare(2, choice: _choice);
    b.coordinator.cancel(review);
    expect(
      (await b.execute(review)).outcome,
      NvmeSubsystemPopulatedQidOutcome.rejected,
    );
    expect(
      (await a.execute(review)).outcome,
      NvmeSubsystemPopulatedQidOutcome.completed,
    );
  });
  for (final reason in ['expire', 'session', 'dispose']) {
    test('$reason during slow preflight cannot dispatch', () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(2, choice: _choice);
      h.api.gate = Completer<void>();
      final result = h.execute(review);
      await h.api.started.future;
      if (reason == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      if (reason == 'session') h.current = false;
      if (reason == 'dispose') h.coordinator.dispose();
      h.api.gate!.complete();
      expect((await result).outcome, NvmeSubsystemPopulatedQidOutcome.rejected);
      expect(h.writes, 0);
    });
  }
  for (final selected in _choices) {
    for (final dark in [true, false]) {
      for (final width in [320.0, 430.0]) {
        testWidgets(
          'Populated QID editor ${selected.label} $width dark=$dark 200% with keyboard',
          (tester) async {
            final h = _Harness();
            h.api.subsystem['qid_max'] = 16;
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
                        child: NvmeSubsystemPopulatedQidEditor(),
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
            if (selected.wireValue != null) {
              await tap('nvme-subsystem-populated-qid-default');
              final limit = find.byKey(
                const Key('nvme-subsystem-populated-qid-limit'),
              );
              await tester.ensureVisible(limit);
              await tester.enterText(limit, selected.label);
              await tester.pumpAndSettle();
            }
            await tester.enterText(
              find.byKey(const Key('nvme-subsystem-populated-qid-id')),
              '2',
            );
            await tester.pumpAndSettle();
            await tap('nvme-subsystem-populated-qid-review');
            expect(h.writes, 0);
            expect(
              tester
                  .widget<FilledButton>(
                    find.byKey(
                      const Key('nvme-subsystem-populated-qid-submit'),
                    ),
                  )
                  .onPressed,
              isNull,
            );
            await tap('nvme-subsystem-populated-qid-reload');
            await tap('nvme-subsystem-populated-qid-limitations');
            final phrase = find.byKey(
              const Key('nvme-subsystem-populated-qid-phrase'),
            );
            await tester.ensureVisible(phrase);
            await tester.enterText(
              phrase,
              'SET POPULATED NVME QID 2 FROM 16 TO ${selected.label} KEEP NQN nqn.2026-09.example:unused',
            );
            await tester.pumpAndSettle();
            await tap('nvme-subsystem-populated-qid-submit');
            expect(h.writes, 1);
            expect(h.api.subsystem['qid_max'], selected.wireValue);
            expect(h.api.subsystem['subnqn'], 'nqn.2026-09.example:unused');
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
