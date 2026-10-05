import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_host_create_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_host_create_editor.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _nqn = 'nqn.2026-09.example:new';

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession,
        AuthenticatedNvmeHostCreateSession {
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
        'nvmet.host.create',
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
  final hosts = <Map<String, Object?>>[
    {'id': 9, 'hostnqn': 'nqn.2026-09.example:old'},
  ];
  final mappings = <Map<String, Object?>>[];
  final subsystem = <String, Object?>{
    'id': 2,
    'name': 'unused',
    'subnqn': 'nqn.2026-09.example:unused',
    'allow_any_host': false,
  };
  int writes = 0, reads = 0;
  final requests = <AdminRequest>[];
  String? failure;
  bool incomplete = false;
  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    reads++;
    if (incomplete) throw const NvmeHostException();
    return NvmeHostPublicRows.project(
      [for (final h in hosts) Map.of(h)],
      [for (final m in mappings) Map.of(m)],
    );
  }

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    requests.add(request);
    return AdminCompleted(
      request,
      value: switch (request.method.name) {
        'nvmet.subsys.query' => [Map.of(subsystem)],
        'nvmet.port.query' ||
        'nvmet.namespace.query' ||
        'nvmet.port_subsys.query' => <Object?>[],
        _ => throw StateError('Generic write is forbidden'),
      },
    );
  }

  @override
  Future<NvmeHostCreated> createUnassociatedNvmeHost({
    required String hostNqn,
  }) async {
    writes++;
    expect(hostNqn, _nqn);
    if (failure == 'throw') throw const NvmeHostException();
    final id = failure == 'reused ID' ? 9 : 45;
    final nqn = failure == 'wrong NQN' ? 'nqn.2026-09.example:wrong' : hostNqn;
    if (failure != 'absent') hosts.add({'id': id, 'hostnqn': nqn});
    if (failure == 'host drift') {
      hosts.first['hostnqn'] = 'nqn.2026-09.example:drift';
    }
    if (failure == 'topology drift') subsystem['name'] = 'changed';
    if (failure == 'new mapping') {
      mappings.add({
        'id': 3,
        'host': {'id': id},
        'subsys': {'id': 2},
      });
    }
    if (failure == 'readback failure') incomplete = true;
    return NvmeHostCreated(id, nqn);
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
      endpoint: 'wss://fixture.example/api/current',
    );
    coordinator = NvmeHostCreateCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      createApi: api,
      lock: lock,
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final api = _Fake();
  final lock = ServerOperationLock();
  late final AuthenticatedSession session;
  late final NvmeHostCreateCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  Future<NvmeHostCreateResult> execute(
    NvmeHostCreateReview r, {
    String? phrase,
    bool consent = true,
  }) => coordinator.execute(
    r,
    phrase ?? r.confirmation,
    acknowledgeNoDhchap: consent,
  );
}

void main() {
  test(
    'registration uses typed create only and verifies unassociated identity',
    () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(_nqn);
      expect(
        r.confirmation,
        'REGISTER UNASSOCIATED NVME HOST $_nqn WITHOUT DHCHAP',
      );
      expect(h.api.writes, 0);
      expect((await h.execute(r)).outcome, NvmeHostCreateOutcome.completed);
      expect(h.api.writes, 1);
      expect(h.api.reads, 3);
      expect(
        h.api.requests.every((r) => r.method.name.endsWith('.query')),
        true,
      );
      expect((await h.execute(r)).outcome, NvmeHostCreateOutcome.rejected);
      expect(h.api.writes, 1);
    },
  );
  for (final nqn in [
    '',
    'nqn.short',
    ' $_nqn',
    '$_nqn ',
    '$_nqn\n',
    '$_nqn\u0000',
    'nqn.2026-09.example:한글',
    'nqn.${'x' * 220}',
    'uuid.2026-09.example:host',
  ]) {
    test('invalid NQN ${nqn.length} rejects before reads', () async {
      final h = _Harness();
      await expectLater(h.coordinator.prepare(nqn), throwsStateError);
      expect(h.api.requests, isEmpty);
      expect(h.api.reads, 0);
      expect(h.api.writes, 0);
    });
  }
  for (final condition in [
    'duplicate',
    'case duplicate',
    'bound',
    'incomplete',
    'unresolved',
  ]) {
    test('$condition rejects preflight without write', () async {
      final h = _Harness();
      switch (condition) {
        case 'duplicate':
          h.api.hosts.first['hostnqn'] = _nqn;
        case 'case duplicate':
          h.api.hosts.first['hostnqn'] = _nqn.toUpperCase();
        case 'bound':
          h.api.hosts.addAll(
            List.generate(
              98,
              (i) => {'id': i + 100, 'hostnqn': 'nqn.2026-09.example:old$i'},
            ),
          );
        case 'incomplete':
          h.api.incomplete = true;
        case 'unresolved':
          h.api.mappings.add({
            'id': 3,
            'host': {'id': 1000},
            'subsys': {'id': 2},
          });
      }
      await expectLater(h.coordinator.prepare(_nqn), throwsStateError);
      expect(h.api.writes, 0);
    });
  }
  for (final condition in [
    'consent',
    'phrase',
    'session',
    'expiry',
    'backward clock',
    'cancel',
    'lock',
    'drift',
    'new duplicate',
  ]) {
    test('$condition invalidates review', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(_nqn);
      Object? owner;
      switch (condition) {
        case 'session':
          h.current = false;
        case 'expiry':
          h.clock = h.clock.add(const Duration(minutes: 5));
        case 'backward clock':
          h.clock = h.clock.subtract(const Duration(seconds: 1));
        case 'cancel':
          h.coordinator.cancel(r);
        case 'lock':
          owner = h.lock.acquire();
        case 'drift':
          h.api.subsystem['name'] = 'changed';
        case 'new duplicate':
          h.api.hosts.add({'id': 42, 'hostnqn': _nqn});
      }
      expect(
        (await h.execute(
          r,
          consent: condition != 'consent',
          phrase: condition == 'phrase' ? 'wrong' : null,
        )).outcome,
        NvmeHostCreateOutcome.rejected,
      );
      expect(h.api.writes, 0);
      if (owner != null) h.lock.release(owner);
    });
  }
  for (final failure in [
    'throw',
    'absent',
    'reused ID',
    'wrong NQN',
    'host drift',
    'topology drift',
    'new mapping',
    'readback failure',
  ]) {
    test('$failure fences further edits', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(_nqn);
      h.api.failure = failure;
      expect((await h.execute(r)).outcome, NvmeHostCreateOutcome.unknown);
      expect(h.api.writes, 1);
      expect(h.coordinator.locked, true);
      await expectLater(h.coordinator.prepare(_nqn), throwsStateError);
    });
  }
  for (final width in [320.0, 430.0]) {
    testWidgets('host registration consent at $width 200 percent', (
      tester,
    ) async {
      final h = _Harness();
      tester.view.physicalSize = Size(width, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardActiveSessionProvider.overrideWith((ref) => h.session),
            nvmeHostCreateCoordinatorProvider.overrideWith(
              (ref) => h.coordinator,
            ),
          ],
          child: MaterialApp(
            theme: TrueNavoTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(child: NvmeHostCreateEditor()),
            ),
          ),
        ),
      );
      Finder key(String suffix) => find.byKey(Key('nvme-host-create-$suffix'));
      Future<void> tap(String suffix) async {
        await tester.ensureVisible(key(suffix));
        await tester.tap(key(suffix));
        await tester.pumpAndSettle();
      }

      await tester.enterText(key('name'), _nqn);
      await tap('review');
      expect(tester.widget<FilledButton>(key('submit')).onPressed, isNull);
      await tap('consent');
      await tester.ensureVisible(key('confirmation'));
      await tester.enterText(key('confirmation'), 'wrong');
      await tap('submit');
      expect(h.api.writes, 0);
      await tap('review');
      await tap('consent');
      await tester.ensureVisible(key('name'));
      await tester.enterText(key('name'), 'nqn.2026-09.example:changed');
      await tester.pumpAndSettle();
      expect(key('submit'), findsNothing);
      await tester.enterText(key('name'), _nqn);
      await tap('review');
      expect(tester.widget<FilledButton>(key('submit')).onPressed, isNull);
      await tap('consent');
      await tester.ensureVisible(key('confirmation'));
      await tester.enterText(
        key('confirmation'),
        'REGISTER UNASSOCIATED NVME HOST $_nqn WITHOUT DHCHAP',
      );
      await tap('submit');
      expect(h.api.writes, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
