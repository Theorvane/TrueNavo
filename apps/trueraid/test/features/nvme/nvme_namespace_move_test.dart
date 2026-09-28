import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_namespace_move_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_namespace_move_editor.dart';

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
  final residents = <Map<String, Object?>>[];
  final ports = <Map<String, Object?>>[
    {'id': 3, 'addr_trtype': 'TCP', 'enabled': false},
  ];
  final mappings = <Map<String, Object?>>[],
      hostMappings = <Map<String, Object?>>[];
  String? failure;
  bool malformed = false;
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
      'nvmet.subsys.query' => [Map.of(subsystem), Map.of(destination)],
      'nvmet.port.query' => [for (final p in ports) Map.of(p)],
      'nvmet.namespace.query' => [
        malformed ? {'id': 7} : Map.of(namespace),
        Map.of(other),
        for (final resident in residents) Map.of(resident),
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
    namespace['subsys'] = {'id': (request.arguments[1] as Map)['subsys_id']};
    final returned = Map.of(namespace);
    if (failure == 'resident NSID') residents.first['nsid'] = 5;
    if (failure == 'resident enabled') residents.first['enabled'] = true;
    if (failure == 'resident removed') residents.clear();
    if (failure == 'resident added') residents.add(_resident(14, 9));
    if (failure == 'resident collision') residents.first['nsid'] = 1;
    if (failure == 'response type') returned['device_type'] = 'FILE';
    if (failure == 'response missing') returned.remove('enabled');
    if (failure == 'destination drift') destination['name'] = 'changed';
    if (failure == 'source drift') subsystem['name'] = 'changed';
    if (failure == 'destination occupied') other['subsys'] = {'id': 4};
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
    coordinator = NvmeNamespaceMoveCoordinator(
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
  late final NvmeNamespaceMoveCoordinator coordinator;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  int get writes =>
      api.calls.where((r) => r.method.name == 'nvmet.namespace.update').length;
  Future<NvmeNamespaceMoveResult> execute(
    NvmeNamespaceMoveReview r, {
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

Map<String, Object?> _resident(int id, int nsid) => {
  'id': id,
  'nsid': nsid,
  'subsys': {'id': 4},
  'device_type': 'ZVOL',
  'enabled': false,
  'locked': false,
};

void main() {
  test('populated destination preserves every resident and submits assignment only', () async {
    final h = _Harness();
    h.api.residents.addAll([_resident(13, 4294967294), _resident(12, 3)]);
    final before = h.api.residents.map(Map<String, Object?>.of).toList();
    final r = await h.coordinator.prepare(7, destinationId: 4);
    expect(r.destinationNamespaces.map((n) => n.id), [12, 13]);
    expect(r.destinationNamespaces.map((n) => n.nsid), [3, 4294967294]);
    expect(() => r.destinationNamespaces.clear(), throwsUnsupportedError);
    expect((await h.execute(r)).outcome, NvmeNamespaceMoveOutcome.completed);
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
        expect((await h.execute(r)).outcome, NvmeNamespaceMoveOutcome.rejected);
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
      expect((await h.execute(r)).outcome, NvmeNamespaceMoveOutcome.unknown);
      expect(h.coordinator.locked, true);
      expect(h.writes, 1);
      expect((await h.execute(r)).outcome, NvmeNamespaceMoveOutcome.rejected);
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
      expect((await h.execute(r)).outcome, NvmeNamespaceMoveOutcome.completed);
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
      expect((await h.execute(r)).outcome, NvmeNamespaceMoveOutcome.rejected);
      expect(h.writes, 1);
    },
  );
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
    'FILE destination': (a) => a.other['subsys'] = {'id': 4},
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
      'id': 11,
      'port': {'id': 3},
      'subsys': {'id': 4},
    }),
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
          a.coordinator.prepare(7, destinationId: 4),
          throwsStateError,
        );
        expect(a.writes, 0);
        final b = _Harness();
        final r = await b.coordinator.prepare(7, destinationId: 4);
        entry.value(b.api);
        expect((await b.execute(r)).outcome, NvmeNamespaceMoveOutcome.rejected);
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
        )).outcome,
        NvmeNamespaceMoveOutcome.rejected,
      );
      expect(h.writes, 0);
      if (owner != null) h.lock.release(owner);
      expect((await h.execute(r)).outcome, NvmeNamespaceMoveOutcome.rejected);
    });
  }
  for (final failure in [
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
      expect(result.outcome, NvmeNamespaceMoveOutcome.unknown);
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
    expect((await b.execute(r)).outcome, NvmeNamespaceMoveOutcome.rejected);
    expect((await a.execute(r)).outcome, NvmeNamespaceMoveOutcome.completed);
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
      expect((await result).outcome, NvmeNamespaceMoveOutcome.rejected);
      expect(h.writes, 0);
    });
  }
  for (final dark in [true, false]) {
    for (final width in [320.0, 430.0]) {
      for (final populated in [false, true]) {
        testWidgets(
          'isolated ZVOL review $width dark=$dark populated=$populated at 200% with keyboard',
          (tester) async {
            final h = _Harness();
            if (populated) {
              h.api.residents.addAll([
                _resident(12, 3),
                _resident(13, 4294967294),
              ]);
            }
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
                        child: NvmeNamespaceMoveEditor(),
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

            final id = find.byKey(const Key('nvme-namespace-move-id'));
            await tester.enterText(id, '7');
            await tester.enterText(
              find.byKey(const Key('nvme-namespace-move-new')),
              '4',
            );
            await tester.pumpAndSettle();
            await tap('nvme-namespace-move-review');
            expect(h.writes, 0);
            expect(
              find.text(
                'Existing namespace #12, NSID 3: disabled unlocked ZVOL',
              ),
              populated ? findsOneWidget : findsNothing,
            );
            expect(
              find.text(
                'Existing namespace #13, NSID 4294967294: disabled unlocked ZVOL',
              ),
              populated ? findsOneWidget : findsNothing,
            );
            expect(
              tester
                  .widget<FilledButton>(
                    find.byKey(const Key('nvme-namespace-move-submit')),
                  )
                  .onPressed,
              isNull,
            );
            await tap('nvme-namespace-move-reload');
            await tap('nvme-namespace-move-limitations');
            final phrase = find.byKey(const Key('nvme-namespace-move-phrase'));
            await tester.ensureVisible(phrase);
            await tester.enterText(
              phrase,
              'MOVE NVME NAMESPACE 7 FROM SUBSYSTEM 2 TO 4 KEEP NSID 1',
            );
            await tester.pumpAndSettle();
            await tap('nvme-namespace-move-submit');
            expect(h.writes, 1);
            expect(h.api.namespace['nsid'], 1);
            expect(h.api.namespace['subsys'], {'id': 4});
            expect(h.api.namespace['enabled'], false);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
