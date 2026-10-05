import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_nqn_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_nqn_editor.dart';

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
  };
  final namespace = <String, Object?>{
    'id': 7,
    'nsid': 1,
    'subsys': {'id': 4},
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
    subsystem['subnqn'] = (request.arguments[1] as Map)['subnqn'];
    final returned = Map.of(subsystem);
    if (failure == 'namespace NSID') namespace['nsid'] = 5;
    if (failure == 'namespace enabled') namespace['enabled'] = true;
    if (failure == 'namespace lock') namespace['locked'] = true;
    if (failure == 'namespace detached') namespace['subsys'] = {'id': 4};
    if (failure == 'response ID') returned['id'] = 999;
    if (failure == 'response NQN') {
      returned['subnqn'] = 'nqn.2026-09.example:wrong';
    }
    if (failure == 'response name') returned['name'] = 'changed';
    if (failure == 'response access') returned['allow_any_host'] = true;
    for (final field in ['ana', 'pi_enable', 'qid_max', 'ieee_oui']) {
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
    if (failure == 'readback NQN') {
      subsystem['subnqn'] = 'nqn.2026-09.example:wrong';
    }
    if (failure == 'readback name') subsystem['name'] = 'changed';
    if (failure == 'other drift') other['nsid'] = 3;
    if (failure == 'namespace attached') namespace['subsys'] = {'id': 2};
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
    coordinator = NvmeSubsystemNqnCoordinator(
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
  late final NvmeSubsystemNqnCoordinator coordinator;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  int get writes =>
      api.calls.where((r) => r.method.name == 'nvmet.subsys.update').length;
  Future<NvmeSubsystemNqnResult> execute(
    NvmeSubsystemNqnReview r, {
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

const _newNqn = 'nqn.2026-09.com.example:new';
void main() {
  test('populated NQN-only patch preserves all resident metadata and reviews immutable IDs', () async {
    final h = _Harness();
    h.api.namespace['subsys'] = {'id': 2};
    h.api.other['subsys'] = {'id': 2};
    h.api.other['device_type'] = 'ZVOL';
    final before = [Map.of(h.api.namespace), Map.of(h.api.other)];
    final review = await h.coordinator.prepare(2, nqn: _newNqn);
    expect(review.namespaces.map((n) => n.id), [7, 8]);
    expect(review.namespaces.map((n) => n.nsid), [1, 2]);
    expect(() => review.namespaces.clear(), throwsUnsupportedError);
    expect(
      (await h.execute(review)).outcome,
      NvmeSubsystemNqnOutcome.completed,
    );
    expect([h.api.namespace, h.api.other], before);
    expect(
      h.api.calls
          .singleWhere((r) => r.method.name == 'nvmet.subsys.update')
          .arguments,
      [
        2,
        {'subnqn': _newNqn},
      ],
    );
    expect(h.writes, 1);
  });
  final invalidResidents = <String, void Function(_Fake)>{
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
  };
  for (final entry in invalidResidents.entries) {
    test('resident $entry rejects initial and fresh NQN review', () async {
      final a = _Harness();
      a.api.namespace['subsys'] = {'id': 2};
      entry.value(a.api);
      await expectLater(
        a.coordinator.prepare(2, nqn: _newNqn),
        throwsStateError,
      );
      final b = _Harness();
      b.api.namespace['subsys'] = {'id': 2};
      final review = await b.coordinator.prepare(2, nqn: _newNqn);
      entry.value(b.api);
      expect(
        (await b.execute(review)).outcome,
        NvmeSubsystemNqnOutcome.rejected,
      );
      expect(a.writes, 0);
      expect(b.writes, 0);
    });
  }
  for (final failure in [
    'namespace NSID',
    'namespace enabled',
    'namespace lock',
    'namespace detached',
  ]) {
    test(
      '$failure after populated NQN dispatch fences original session',
      () async {
        final h = _Harness();
        h.api.namespace['subsys'] = {'id': 2};
        final review = await h.coordinator.prepare(2, nqn: _newNqn);
        h.api.failure = failure;
        expect(
          (await h.execute(review)).outcome,
          NvmeSubsystemNqnOutcome.unknown,
        );
        expect(h.coordinator.locked, true);
        expect(h.writes, 1);
        expect(
          (await h.execute(review)).outcome,
          NvmeSubsystemNqnOutcome.rejected,
        );
        expect(h.writes, 1);
      },
    );
  }
  for (final invalid in [
    '',
    ' nqn.2026-09.com.example:new',
    'nqn.2026-09.com.example:new ',
    'nqn.2026-09.com.example:new\n',
    'nqn.2026-00.example:new',
    'nqn.2026-13.example:new',
    'nqn.2026-09.com.example:new 이름',
    'nqn.2026-09.-example.org:new',
    'nqn.2026-09.example..org:new',
    'uuid:unverified',
    'nqn.2026-09.example:${'x' * 224}',
  ]) {
    test(
      'invalid unsupported NQN rejects before any request: $invalid',
      () async {
        final h = _Harness();
        await expectLater(
          h.coordinator.prepare(2, nqn: invalid),
          throwsStateError,
        );
        expect(h.api.calls, isEmpty);
      },
    );
  }
  for (final nqn in [
    _newNqn,
    'nqn.2026-01.com.example:node_01',
    'nqn.2026-12.example.org:${'x' * (223 - 'nqn.2026-12.example.org:'.length)}',
  ]) {
    test(
      'NQN-only update preserves target settings and other topology: $nqn',
      () async {
        final h = _Harness();
        h.api.subsystem.addAll({
          'ana': null,
          'pi_enable': false,
          'qid_max': 16,
          'ieee_oui': '00:11:22',
        });
        final review = await h.coordinator.prepare(2, nqn: nqn);
        expect(h.writes, 0);
        expect(
          (await h.execute(review)).outcome,
          NvmeSubsystemNqnOutcome.completed,
        );
        expect(
          h.api.calls
              .singleWhere((r) => r.method.name == 'nvmet.subsys.update')
              .arguments,
          [
            2,
            {'subnqn': nqn},
          ],
        );
        expect(h.api.subsystem['name'], 'unused');
        expect(h.api.subsystem['ana'], null);
        expect(h.api.subsystem['qid_max'], 16);
        expect(
          (await h.execute(review)).outcome,
          NvmeSubsystemNqnOutcome.rejected,
        );
        expect(h.writes, 1);
      },
    );
  }
  for (final id in [-1, 0, 999]) {
    test('invalid or missing subsystem ID $id cannot write', () async {
      final h = _Harness();
      await expectLater(
        h.coordinator.prepare(id, nqn: _newNqn),
        throwsStateError,
      );
      expect(h.writes, 0);
    });
  }
  final unsafe = <String, void Function(_Fake)>{
    'any host': (a) => a.subsystem['allow_any_host'] = true,
    'unknown NQN': (a) => a.subsystem.remove('subnqn'),
    'duplicate existing NQN': (a) =>
        a.subsystem['subnqn'] = 'nqn.2026-09.example:other',
    'requested NQN occupied': (a) => a.subsystem['subnqn'] = _newNqn,
    'FILE namespace': (a) {
      a.namespace['subsys'] = {'id': 2};
      a.namespace['device_type'] = 'FILE';
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
        a.coordinator.prepare(2, nqn: _newNqn),
        throwsStateError,
      );
      expect(a.writes, 0);
      final b = _Harness();
      final review = await b.coordinator.prepare(2, nqn: _newNqn);
      entry.value(b.api);
      expect(
        (await b.execute(review)).outcome,
        NvmeSubsystemNqnOutcome.rejected,
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
      final review = await h.coordinator.prepare(2, nqn: _newNqn);
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
        NvmeSubsystemNqnOutcome.rejected,
      );
      expect(h.writes, 0);
      if (owner != null) h.lock.release(owner);
      expect(
        (await h.execute(review)).outcome,
        NvmeSubsystemNqnOutcome.rejected,
      );
    });
  }
  for (final failure in [
    'throw',
    'denied',
    'unknown',
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
    'association',
    'malformed readback',
  ]) {
    test(
      '$failure fences original session without retry or rollback',
      () async {
        final h = _Harness();
        final review = await h.coordinator.prepare(2, nqn: _newNqn);
        h.api.failure = failure;
        final result = await h.execute(review);
        expect(result.outcome, NvmeSubsystemNqnOutcome.unknown);
        expect(result.message, isNot(contains('private-server-error')));
        expect(h.coordinator.locked, true);
        expect(h.writes, 1);
        await expectLater(
          h.coordinator.prepare(2, nqn: 'nqn.2026-09.example:next'),
          throwsStateError,
        );
        expect(h.writes, 1);
      },
    );
  }
  test('foreign review cannot be cancelled or consumed', () async {
    final a = _Harness(), b = _Harness();
    final review = await a.coordinator.prepare(2, nqn: _newNqn);
    b.coordinator.cancel(review);
    expect((await b.execute(review)).outcome, NvmeSubsystemNqnOutcome.rejected);
    expect(
      (await a.execute(review)).outcome,
      NvmeSubsystemNqnOutcome.completed,
    );
  });
  for (final reason in ['expire', 'session', 'dispose']) {
    test('$reason during slow preflight cannot dispatch', () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(2, nqn: _newNqn);
      h.api.gate = Completer<void>();
      final result = h.execute(review);
      await h.api.started.future;
      if (reason == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      if (reason == 'session') h.current = false;
      if (reason == 'dispose') h.coordinator.dispose();
      h.api.gate!.complete();
      expect((await result).outcome, NvmeSubsystemNqnOutcome.rejected);
      expect(h.writes, 0);
    });
  }
  for (final dark in [true, false]) {
    for (final width in [320.0, 430.0]) {
      for (final populated in [false, true]) {
        testWidgets(
          'NQN editor $width dark=$dark populated=$populated 200% with keyboard',
          (tester) async {
            final h = _Harness();
            if (populated) h.api.namespace['subsys'] = {'id': 2};
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
                        child: NvmeSubsystemNqnEditor(),
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
              find.byKey(const Key('nvme-subsystem-nqn-id')),
              '2',
            );
            await tester.enterText(
              find.byKey(const Key('nvme-subsystem-nqn-new')),
              _newNqn,
            );
            await tester.pumpAndSettle();
            await tap('nvme-subsystem-nqn-review');
            expect(h.writes, 0);
            expect(
              find.text(
                'Namespace #7, NSID 1: disabled unlocked ZVOL; unchanged',
              ),
              populated ? findsOneWidget : findsNothing,
            );
            expect(
              tester
                  .widget<FilledButton>(
                    find.byKey(const Key('nvme-subsystem-nqn-submit')),
                  )
                  .onPressed,
              isNull,
            );
            await tap('nvme-subsystem-nqn-reload');
            await tap('nvme-subsystem-nqn-limitations');
            final phrase = find.byKey(const Key('nvme-subsystem-nqn-phrase'));
            await tester.ensureVisible(phrase);
            await tester.enterText(
              phrase,
              'CHANGE NVME SUBSYSTEM 2 NQN nqn.2026-09.example:unused TO $_newNqn',
            );
            await tester.pumpAndSettle();
            await tap('nvme-subsystem-nqn-submit');
            expect(h.writes, 1);
            expect(h.api.subsystem['subnqn'], _newNqn);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
