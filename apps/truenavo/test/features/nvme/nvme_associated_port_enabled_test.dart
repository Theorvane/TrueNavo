import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_associated_port_enabled_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_associated_port_enabled_editor.dart';

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
    {'id': 3, 'addr_trtype': 'TCP', 'enabled': false},
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
    final enabled = (request.arguments[1] as Map)['enabled'];
    if (failure != 'wrong enabled') ports.first['enabled'] = enabled;
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
    coordinator = NvmeAssociatedPortEnabledCoordinator(
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
  late final NvmeAssociatedPortEnabledCoordinator coordinator;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  int get writes =>
      api.calls.where((r) => r.method.name == 'nvmet.port.update').length;
  Future<NvmeAssociatedPortEnabledResult> execute(
    NvmeAssociatedPortEnabledReview r, {
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
        h.coordinator.prepare(3, choice: NvmeAssociatedPortChoice.on),
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
        choice: NvmeAssociatedPortChoice.on,
      );
      expect(r.namespaces.map((n) => n.id), [8, 10]);
      expect(
        (await h.execute(r)).outcome,
        NvmeAssociatedPortEnabledOutcome.completed,
      );
    },
  );
  test('truncated inventory rejects', () async {
    final h = _Harness();
    for (var i = 0; i < 101; i++) {
      h.api.ports.add({'id': 100 + i, 'addr_trtype': 'TCP', 'enabled': false});
    }
    await expectLater(
      h.coordinator.prepare(3, choice: NvmeAssociatedPortChoice.on),
      throwsStateError,
    );
    expect(h.writes, 0);
  });
  for (final transport in ['TCP', 'RDMA']) {
    for (final choice in NvmeAssociatedPortChoice.values) {
      test('$transport saved ${choice.label} changes only enabled', () async {
        final h = _Harness();
        h.api.ports.first['addr_trtype'] = transport;
        h.api.ports.first['enabled'] = !choice.wireValue;
        h.api.ports.first.addAll({
          'pi_enable': null,
          'max_queue_size': 32,
          'inline_data_size': null,
        });
        final r = await h.coordinator.prepare(3, choice: choice);
        expect(r.namespaces.single.id, 7);
        expect(() => r.namespaces.clear(), throwsUnsupportedError);
        expect(
          (await h.execute(r)).outcome,
          NvmeAssociatedPortEnabledOutcome.completed,
        );
        expect(h.writes, 1);
        expect(
          h.api.calls
              .lastWhere((r) => r.method.name == 'nvmet.port.update')
              .arguments,
          [
            3,
            {'enabled': choice.wireValue},
          ],
        );
        expect(h.api.namespace['enabled'], false);
        expect(h.api.mappings.single['id'], 11);
        expect(
          (await h.execute(r)).outcome,
          NvmeAssociatedPortEnabledOutcome.rejected,
        );
        expect(h.writes, 1);
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
    'noop',
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
        case 'noop':
          h.api.ports.first['enabled'] = true;
      }
      await expectLater(
        h.coordinator.prepare(3, choice: NvmeAssociatedPortChoice.on),
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
        choice: NvmeAssociatedPortChoice.on,
      );
      expect(
        (await h.execute(
          r,
          phrase: consent == 'phrase' ? 'wrong' : null,
          reload: consent != 'reload',
          limitations: consent != 'limitations',
          exposure: consent != 'exposure',
        )).outcome,
        NvmeAssociatedPortEnabledOutcome.rejected,
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
    'wrong enabled',
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
        choice: NvmeAssociatedPortChoice.on,
      );
      h.api.failure = failure;
      expect(
        (await h.execute(r)).outcome,
        NvmeAssociatedPortEnabledOutcome.unknown,
      );
      expect(h.writes, 1);
      expect(h.coordinator.locked, true);
      expect(_Harness().coordinator.locked, false);
      expect(
        (await h.execute(r)).outcome,
        NvmeAssociatedPortEnabledOutcome.rejected,
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
        choice: NvmeAssociatedPortChoice.on,
      );
      if (change == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      if (change == 'session') h.current = false;
      if (change == 'dispose') h.coordinator.dispose();
      if (change == 'cancel') h.coordinator.cancel(r);
      if (change == 'drift') h.api.other['nsid'] = 4;
      final owner = change == 'lock' ? h.lock.acquire() : null;
      expect(
        (await h.execute(r)).outcome,
        NvmeAssociatedPortEnabledOutcome.rejected,
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
        choice: NvmeAssociatedPortChoice.on,
      );
      h.api.gate = Completer<void>();
      final pending = h.execute(r);
      await h.api.started.future;
      if (change == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      if (change == 'session') h.current = false;
      if (change == 'dispose') h.coordinator.dispose();
      h.api.gate!.complete();
      expect(
        (await pending).outcome,
        NvmeAssociatedPortEnabledOutcome.rejected,
      );
      expect(h.writes, 0);
    });
  }
  for (final change in ['session', 'dispose']) {
    test('$change after dispatch fences original session', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(
        3,
        choice: NvmeAssociatedPortChoice.on,
      );
      h.api.onDispatch = () {
        if (change == 'session') h.current = false;
        if (change == 'dispose') h.coordinator.dispose();
      };
      expect(
        (await h.execute(r)).outcome,
        NvmeAssociatedPortEnabledOutcome.unknown,
      );
      expect(h.writes, 1);
      expect(h.coordinator.locked, true);
    });
  }
  test('foreign and superseded reviews reject', () async {
    final h = _Harness(), other = _Harness();
    final r = await h.coordinator.prepare(
      3,
      choice: NvmeAssociatedPortChoice.on,
    );
    expect(
      (await other.execute(r)).outcome,
      NvmeAssociatedPortEnabledOutcome.rejected,
    );
    final replacement = await h.coordinator.prepare(
      3,
      choice: NvmeAssociatedPortChoice.on,
    );
    expect(
      (await h.execute(r)).outcome,
      NvmeAssociatedPortEnabledOutcome.rejected,
    );
    expect(
      (await h.execute(replacement)).outcome,
      NvmeAssociatedPortEnabledOutcome.completed,
    );
  });
  test('invalid ID is rejected without reads', () async {
    final h = _Harness();
    await expectLater(
      h.coordinator.prepare(0, choice: NvmeAssociatedPortChoice.on),
      throwsStateError,
    );
    expect(h.api.calls, isEmpty);
  });
  for (final dark in [true, false]) {
    for (final width in [320.0, 430.0]) {
      testWidgets('associated port $width dark=$dark 200% keyboard', (
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
            nvmeAssociatedPortEnabledCoordinatorProvider.overrideWithValue(
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
                    child: NvmeAssociatedPortEnabledEditor(),
                  ),
                ),
              ),
            ),
          ),
        );
        Future<void> tap(String key) async {
          final f = find.byKey(Key('nvme-associated-port-enabled-$key'));
          await tester.ensureVisible(f);
          await tester.tap(f);
          await tester.pumpAndSettle();
        }

        expect(h.api.calls, isEmpty);
        await tester.enterText(
          find.byKey(const Key('nvme-associated-port-enabled-id')),
          '3',
        );
        await tester.pumpAndSettle();
        await tap('review');
        await tap('reload');
        await tap('limitations');
        final phrase = find.byKey(
          const Key('nvme-associated-port-enabled-phrase'),
        );
        await tester.ensureVisible(phrase);
        await tester.enterText(
          phrase,
          'SET ASSOCIATED NVME PORT 3 FROM OFF TO ON KEEP SUBSYSTEM 2 NQN nqn.2026-09.example:unused',
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('nvme-associated-port-enabled-submit')),
              )
              .onPressed,
          isNull,
        );
        await tap('exposure');
        await tap('submit');
        expect(h.writes, 1);
        expect(h.api.ports.first['enabled'], true);
        expect(h.api.namespace['enabled'], false);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
