import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_associated_port_tuning_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_associated_port_tuning_editor.dart';

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
        'nvmet.port.update',
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
    {
      'id': 3,
      'addr_trtype': 'TCP',
      'enabled': false,
      'pi_enable': false,
      'max_queue_size': 32,
      'inline_data_size': 128,
    },
    {'id': 6, 'addr_trtype': 'TCP', 'enabled': false},
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
    if (request.method.name != 'nvmet.port.update') {
      throw StateError('Unexpected generic method');
    }
    onDispatch?.call();
    if (failure == 'throw') throw StateError('private-server-error');
    if (failure == 'denied') {
      return AdminFailed(request, reason: AdminFailureReason.denied);
    }
    final patch = request.arguments[1] as Map;
    final field = patch.keys.single as String;
    if (failure != 'wrong value') ports.first[field] = patch[field];
    if (failure == 'selected missing') ports.first.remove(field);
    if (failure == 'selected type') ports.first[field] = 'invalid';
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
        'subsys': {'id': 2},
      });
    }
    if (failure == 'malformed readback') malformed = true;

    final response = Map<String, Object?>.of(ports.first);
    if (failure == 'response missing') response.remove(field);
    if (failure == 'response value') {
      response[field] = patch[field] == null ? 1 : null;
    }
    if (failure == 'response ID') response['id'] = 99;
    if (failure == 'response enabled') {
      response['enabled'] = !(ports.first['enabled'] as bool);
    }
    if (failure == 'response null') return AdminCompleted(request, value: null);
    return AdminCompleted(request, value: response);
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
    coordinator = NvmeAssociatedPortTuningCoordinator(
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
  late final NvmeAssociatedPortTuningCoordinator coordinator;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  int get writes =>
      api.calls.where((r) => r.method.name == 'nvmet.port.update').length;
  Future<NvmeAssociatedPortTuningResult> execute(
    NvmeAssociatedPortTuningReview r, {
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
    'version',
    'nvmet.subsys.query',
    'nvmet.port.query',
    'nvmet.namespace.query',
    'nvmet.port_subsys.query',
    'nvmet.host.query',
    'nvmet.host_subsys.query',
    'nvmet.port.update',
  ]) {
    test('$missing unavailable before reads', () async {
      final h = _Harness();
      h.api.adminCatalog = AdminCatalog.fromMetadata(
        version: missing == 'version' ? '24.10.2' : '25.10.1',
        metadata: {
          for (final name in [
            'nvmet.subsys.query',
            'nvmet.port.query',
            'nvmet.namespace.query',
            'nvmet.port_subsys.query',
            'nvmet.host.query',
            'nvmet.host_subsys.query',
            'nvmet.port.update',
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
      await expectLater(
        h.coordinator.prepare(
          3,
          choice: const NvmeAssociatedPortChoice(
            NvmeAssociatedPortField.pi,
            true,
          ),
        ),
        throwsStateError,
      );
      expect(h.api.calls, isEmpty);
    });
  }
  test(
    'multiple disabled ZVOL residents have immutable sorted review',
    () async {
      final h = _Harness();
      h.api.namespace['id'] = 10;
      h.api.other.addAll({
        'subsys': {'id': 2},
        'device_type': 'ZVOL',
      });
      final r = await h.coordinator.prepare(
        3,
        choice: const NvmeAssociatedPortChoice(
          NvmeAssociatedPortField.pi,
          true,
        ),
      );
      expect(r.namespaces.map((n) => n.id), [8, 10]);
      expect(
        (await h.execute(r)).outcome,
        NvmeAssociatedPortTuningOutcome.completed,
      );
    },
  );
  test('truncated inventory rejects', () async {
    final h = _Harness();
    for (var i = 0; i < 101; i++) {
      h.api.ports.add({'id': 100 + i, 'addr_trtype': 'TCP', 'enabled': false});
    }
    await expectLater(
      h.coordinator.prepare(
        3,
        choice: const NvmeAssociatedPortChoice(
          NvmeAssociatedPortField.pi,
          true,
        ),
      ),
      throwsStateError,
    );
    expect(h.writes, 0);
  });
  for (final transport in ['TCP', 'RDMA']) {
    for (final field in NvmeAssociatedPortField.values) {
      final values = field == NvmeAssociatedPortField.pi
          ? <Object?>[null, true, false]
          : <Object?>[
              null,
              field == NvmeAssociatedPortField.inline ? 0 : 1,
              2147483647,
            ];
      for (final value in values) {
        test(
          '$transport ${field.wireName}=$value submits exactly one field',
          () async {
            final h = _Harness();
            h.api.ports.first['addr_trtype'] = transport;
            if (field == NvmeAssociatedPortField.pi) {
              h.api.ports.first['pi_enable'] = value == false ? true : false;
            }
            final choice = NvmeAssociatedPortChoice(field, value);
            final r = await h.coordinator.prepare(3, choice: choice);
            expect(r.namespaces.single.id, 7);
            expect(() => r.namespaces.clear(), throwsUnsupportedError);
            expect(
              (await h.execute(r)).outcome,
              NvmeAssociatedPortTuningOutcome.completed,
            );
            expect(h.writes, 1);
            expect(
              h.api.calls
                  .lastWhere((r) => r.method.name == 'nvmet.port.update')
                  .arguments,
              [
                3,
                {field.wireName: value},
              ],
            );
            expect(h.api.namespace['enabled'], false);
            expect(h.api.ports.first['enabled'], false);
            expect(h.api.mappings.single['id'], 11);
            expect(
              (await h.execute(r)).outcome,
              NvmeAssociatedPortTuningOutcome.rejected,
            );
            expect(h.writes, 1);
          },
        );
      }
    }
  }
  testWidgets(
    'field, value, default, PI and connection edits invalidate review',
    (tester) async {
      final h = _Harness();
      final container = ProviderContainer(
        overrides: [
          dashboardActiveSessionProvider.overrideWith(
            (ref) => ref.watch(_active),
          ),
          // Keep review time deterministic, as in coordinator unit tests.
          nvmeAssociatedPortTuningCoordinatorProvider.overrideWithValue(
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
            theme: TrueRAIDTheme.dark(),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: NvmeAssociatedPortTuningEditor(),
              ),
            ),
          ),
        ),
      );
      Future<void> tap(String key) async {
        final finder = find.byKey(Key('nvme-associated-port-tuning-$key'));
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> select(String key, String label) async {
        await tap(key);
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      final submit = find.byKey(
        const Key('nvme-associated-port-tuning-submit'),
      );
      final id = find.byKey(const Key('nvme-associated-port-tuning-id'));
      await tester.enterText(id, '3');
      await tester.pumpAndSettle();
      await tap('review');
      expect(submit, findsOneWidget);
      await select('field', 'Maximum queue size');
      expect(submit, findsNothing);
      await tap('default');
      final value = find.byKey(const Key('nvme-associated-port-tuning-value'));
      await tester.ensureVisible(value);
      await tester.enterText(value, '0');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('nvme-associated-port-tuning-review')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(value, '16');
      await tester.pumpAndSettle();
      await tap('review');
      expect(submit, findsOneWidget);
      await tester.enterText(value, '17');
      await tester.pumpAndSettle();
      expect(submit, findsNothing);
      await tap('review');
      await tap('default');
      expect(submit, findsNothing);
      await tap('review');
      expect(submit, findsOneWidget);
      await select('field', 'PI setting');
      expect(submit, findsNothing);
      await tap('review');
      await select('pi', 'DEFAULT');
      expect(submit, findsNothing);
      await tap('review');
      expect(submit, findsOneWidget);
      container.read(_active.notifier).select(_Harness().session);
      await tester.pumpAndSettle();
      expect(submit, findsNothing);
      expect(tester.widget<TextField>(id).controller!.text, isEmpty);
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
  for (final field in NvmeAssociatedPortField.values) {
    test('${field.wireName} missing is not DEFAULT', () async {
      final h = _Harness();
      h.api.ports.first.remove(field.wireName);
      await expectLater(
        h.coordinator.prepare(3, choice: NvmeAssociatedPortChoice(field, null)),
        throwsStateError,
      );
      expect(h.writes, 0);
    });
    test('${field.wireName} no-op rejects', () async {
      final h = _Harness();
      await expectLater(
        h.coordinator.prepare(
          3,
          choice: NvmeAssociatedPortChoice(
            field,
            h.api.ports.first[field.wireName],
          ),
        ),
        throwsStateError,
      );
      expect(h.writes, 0);
    });
    for (final bad
        in (field == NvmeAssociatedPortField.pi
            ? <Object?>[0, 1, 'ON', 'false']
            : <Object?>[
                -1,
                2147483648,
                true,
                '32',
                1.5,
                if (field == NvmeAssociatedPortField.queue) 0,
              ])) {
      test('${field.wireName} invalid $bad rejects before reads', () async {
        final h = _Harness();
        await expectLater(
          h.coordinator.prepare(
            3,
            choice: NvmeAssociatedPortChoice(field, bad),
          ),
          throwsStateError,
        );
        expect(h.api.calls, isEmpty);
      });
    }
    for (final failure in [
      'selected missing',
      'selected type',
      'response missing',
      'response value',
    ]) {
      test('${field.wireName} $failure fences after dispatch', () async {
        final h = _Harness();
        final r = await h.coordinator.prepare(
          3,
          choice: NvmeAssociatedPortChoice(
            field,
            field == NvmeAssociatedPortField.pi ? true : 16,
          ),
        );
        h.api.failure = failure;
        expect(
          (await h.execute(r)).outcome,
          NvmeAssociatedPortTuningOutcome.unknown,
        );
        expect(h.writes, 1);
        expect(h.coordinator.locked, true);
      });
    }
  }
  for (final unsafe in [
    'FC',
    'no mapping',
    'shared port',
    'shared subsystem',
    'any host',
    'host grant',
    'FILE',
    'enabled resident',
    'locked',
    'unknown lock',
    'missing NSID',
    'reserved NSID',
    'duplicate NSID',
    'empty',
    'malformed',
    'enabled port',
  ]) {
    test('$unsafe rejects without dispatch', () async {
      final h = _Harness();
      switch (unsafe) {
        case 'FC':
          h.api.ports.first['addr_trtype'] = 'FC';
        case 'no mapping':
          h.api.mappings.clear();
        case 'shared port':
          h.api.mappings.add({
            'id': 12,
            'port': {'id': 3},
            'subsys': {'id': 4},
          });
        case 'shared subsystem':
          h.api.mappings.add({
            'id': 12,
            'port': {'id': 6},
            'subsys': {'id': 2},
          });
        case 'any host':
          h.api.subsystem['allow_any_host'] = true;
        case 'host grant':
          h.api.hostMappings.add({
            'id': 10,
            'host': {'id': 9},
            'subsys': {'id': 2},
          });
        case 'FILE':
          h.api.namespace['device_type'] = 'FILE';
        case 'enabled resident':
          h.api.namespace['enabled'] = true;
        case 'locked':
          h.api.namespace['locked'] = true;
        case 'unknown lock':
          h.api.namespace.remove('locked');
        case 'missing NSID':
          h.api.namespace.remove('nsid');
        case 'reserved NSID':
          h.api.namespace['nsid'] = 4294967295;
        case 'duplicate NSID':
          h.api.other.addAll({
            'subsys': {'id': 2},
            'device_type': 'ZVOL',
            'nsid': 1,
          });
        case 'empty':
          h.api.namespace['subsys'] = {'id': 4};
        case 'malformed':
          h.api.malformed = true;
        case 'enabled port':
          h.api.ports.first['enabled'] = true;
      }
      await expectLater(
        h.coordinator.prepare(
          3,
          choice: const NvmeAssociatedPortChoice(
            NvmeAssociatedPortField.pi,
            true,
          ),
        ),
        throwsStateError,
      );
      expect(h.writes, 0);
    });
  }
  for (final consent in ['phrase', 'reload', 'limitations', 'exposure']) {
    test('$consent is independent and mandatory', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(
        3,
        choice: const NvmeAssociatedPortChoice(
          NvmeAssociatedPortField.pi,
          true,
        ),
      );
      expect(
        (await h.execute(
          r,
          phrase: consent == 'phrase' ? 'wrong' : null,
          reload: consent != 'reload',
          limitations: consent != 'limitations',
          exposure: consent != 'exposure',
        )).outcome,
        NvmeAssociatedPortTuningOutcome.rejected,
      );
      expect(h.writes, 0);
    });
  }
  for (final failure in [
    'throw',
    'denied',
    'response ID',
    'response enabled',
    'response null',
    'wrong value',
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
    test('$failure after dispatch fences original session', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(
        3,
        choice: const NvmeAssociatedPortChoice(
          NvmeAssociatedPortField.pi,
          true,
        ),
      );
      h.api.failure = failure;
      expect(
        (await h.execute(r)).outcome,
        NvmeAssociatedPortTuningOutcome.unknown,
      );
      expect(h.writes, 1);
      expect(h.coordinator.locked, true);
      expect(_Harness().coordinator.locked, false);
      expect(
        (await h.execute(r)).outcome,
        NvmeAssociatedPortTuningOutcome.rejected,
      );
      expect(h.writes, 1);
    });
  }
  for (final change in [
    'expire',
    'session',
    'dispose',
    'cancel',
    'drift',
    'lock',
  ]) {
    test('$change invalidates review before dispatch', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(
        3,
        choice: const NvmeAssociatedPortChoice(
          NvmeAssociatedPortField.pi,
          true,
        ),
      );
      if (change == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      if (change == 'session') h.current = false;
      if (change == 'dispose') h.coordinator.dispose();
      if (change == 'cancel') h.coordinator.cancel(r);
      if (change == 'drift') h.api.other['nsid'] = 4;
      final owner = change == 'lock' ? h.lock.acquire() : null;
      expect(
        (await h.execute(r)).outcome,
        NvmeAssociatedPortTuningOutcome.rejected,
      );
      expect(h.writes, 0);
      if (owner != null) h.lock.release(owner);
    });
  }
  for (final change in ['expire', 'session', 'dispose']) {
    test('$change during slow preflight rejects', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(
        3,
        choice: const NvmeAssociatedPortChoice(
          NvmeAssociatedPortField.pi,
          true,
        ),
      );
      h.api.gate = Completer<void>();
      final pending = h.execute(r);
      await h.api.started.future;
      if (change == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      if (change == 'session') h.current = false;
      if (change == 'dispose') h.coordinator.dispose();
      h.api.gate!.complete();
      expect((await pending).outcome, NvmeAssociatedPortTuningOutcome.rejected);
      expect(h.writes, 0);
    });
  }
  for (final change in ['session', 'dispose']) {
    test('$change after dispatch fences original session', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(
        3,
        choice: const NvmeAssociatedPortChoice(
          NvmeAssociatedPortField.pi,
          true,
        ),
      );
      h.api.onDispatch = () {
        if (change == 'session') h.current = false;
        if (change == 'dispose') h.coordinator.dispose();
      };
      expect(
        (await h.execute(r)).outcome,
        NvmeAssociatedPortTuningOutcome.unknown,
      );
      expect(h.writes, 1);
      expect(h.coordinator.locked, true);
    });
  }
  test('foreign and superseded reviews reject', () async {
    final h = _Harness(), other = _Harness();
    final r = await h.coordinator.prepare(
      3,
      choice: const NvmeAssociatedPortChoice(NvmeAssociatedPortField.pi, true),
    );
    expect(
      (await other.execute(r)).outcome,
      NvmeAssociatedPortTuningOutcome.rejected,
    );
    final replacement = await h.coordinator.prepare(
      3,
      choice: const NvmeAssociatedPortChoice(NvmeAssociatedPortField.pi, true),
    );
    expect(
      (await h.execute(r)).outcome,
      NvmeAssociatedPortTuningOutcome.rejected,
    );
    expect(
      (await h.execute(replacement)).outcome,
      NvmeAssociatedPortTuningOutcome.completed,
    );
  });
  test('invalid ID is rejected without reads', () async {
    final h = _Harness();
    await expectLater(
      h.coordinator.prepare(
        0,
        choice: const NvmeAssociatedPortChoice(
          NvmeAssociatedPortField.pi,
          true,
        ),
      ),
      throwsStateError,
    );
    expect(h.api.calls, isEmpty);
  });
  for (final field in NvmeAssociatedPortField.values) {
    for (final dark in [true, false]) {
      for (final width in [320.0, 430.0]) {
        testWidgets('associated port $field $width dark=$dark 200% keyboard', (
          tester,
        ) async {
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
              // Keep review time deterministic, as in coordinator unit tests.
              nvmeAssociatedPortTuningCoordinatorProvider.overrideWithValue(
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
                      child: NvmeAssociatedPortTuningEditor(),
                    ),
                  ),
                ),
              ),
            ),
          );
          Future<void> tap(String key) async {
            final f = find.byKey(Key('nvme-associated-port-tuning-$key'));
            await tester.ensureVisible(f);
            await tester.tap(f);
            await tester.pumpAndSettle();
          }

          expect(h.api.calls, isEmpty);
          if (field != NvmeAssociatedPortField.pi) {
            await tap('field');
            await tester.tap(find.text(field.label).last);
            await tester.pumpAndSettle();
            await tap('default');
            final value = find.byKey(
              const Key('nvme-associated-port-tuning-value'),
            );
            await tester.ensureVisible(value);
            await tester.enterText(value, '16');
            await tester.pumpAndSettle();
          }
          await tester.enterText(
            find.byKey(const Key('nvme-associated-port-tuning-id')),
            '3',
          );
          await tester.pumpAndSettle();
          await tap('review');
          await tap('reload');
          await tap('limitations');
          final phrase = find.byKey(
            const Key('nvme-associated-port-tuning-phrase'),
          );
          await tester.ensureVisible(phrase);
          await tester.enterText(
            phrase,
            'SET ASSOCIATED NVME ${field.wireName.toUpperCase()} PORT 3 FROM ${field == NvmeAssociatedPortField.pi
                ? 'OFF'
                : field == NvmeAssociatedPortField.queue
                ? '32'
                : '128'} TO ${field == NvmeAssociatedPortField.pi ? 'ON' : '16'} KEEP SUBSYSTEM 2 NQN nqn.2026-09.example:unused',
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('nvme-associated-port-tuning-submit')),
                )
                .onPressed,
            isNull,
          );
          await tap('exposure');
          await tap('submit');
          expect(h.writes, 1);
          expect(h.api.ports.first['enabled'], false);
          expect(
            h.api.ports.first[field.wireName],
            field == NvmeAssociatedPortField.pi ? true : 16,
          );
          expect(h.api.namespace['enabled'], false);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
