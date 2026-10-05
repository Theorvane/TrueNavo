import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_host_rename_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_host_rename_editor.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _nqn = 'nqn.2026-09.example:new';

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession,
        AuthenticatedNvmeHostRenameSession {
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
        'nvmet.host.update',
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
  bool credentialed = false;
  String hash = "SHA-256";
  String? protectedNqn;
  int protectedReads = 0;
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
  Future<NvmeUncredentialedHost> loadUncredentialedNvmeHost(int id) async {
    protectedReads++;
    if (credentialed || incomplete) throw const NvmeHostException();
    final row = hosts.where((h) => h['id'] == id).single;
    return NvmeUncredentialedHost(
      id,
      protectedNqn ?? row['hostnqn'] as String,
      hash,
    );
  }

  @override
  Future<NvmeUncredentialedHost> renameUncredentialedNvmeHost({
    required int id,
    required String expectedNqn,
    required String expectedHash,
    required String newNqn,
  }) async {
    writes++;
    expect(id, 9);
    expect(expectedNqn, 'nqn.2026-09.example:old');
    expect(expectedHash, 'SHA-256');
    expect(newNqn, _nqn);
    if (failure == 'throw') throw const NvmeHostException();
    if (failure != 'unchanged') hosts.first['hostnqn'] = newNqn;
    if (failure == 'topology drift') subsystem['name'] = 'changed';
    if (failure == 'new mapping') {
      mappings.add({
        'id': 3,
        'host': {'id': id},
        'subsys': {'id': 2},
      });
    }
    if (failure == 'hash drift') hash = 'SHA-512';
    if (failure == 'auth drift') credentialed = true;
    if (failure == 'readback failure') incomplete = true;
    return NvmeUncredentialedHost(
      failure == 'wrong ID' ? 99 : id,
      failure == 'wrong NQN' ? 'nqn.2026-09.example:wrong' : newNqn,
      failure == 'returned hash' ? 'SHA-512' : expectedHash,
    );
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
    coordinator = NvmeHostRenameCoordinator(
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
  late final NvmeHostRenameCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  Future<NvmeHostRenameResult> execute(
    NvmeHostRenameReview r, {
    String? phrase,
    bool consent = true,
  }) => coordinator.execute(
    r,
    phrase ?? r.confirmation,
    acknowledgeIdentityChange: consent,
  );
}

void main() {
  test('NQN-only rename preserves topology and hash', () async {
    final h = _Harness();
    final r = await h.coordinator.prepare(9, _nqn);
    expect(
      r.confirmation,
      'RENAME NVME HOST 9 FROM nqn.2026-09.example:old TO $_nqn',
    );
    expect(h.api.writes, 0);
    expect((await h.execute(r)).outcome, NvmeHostRenameOutcome.completed);
    expect(h.api.writes, 1);
    expect(h.api.protectedReads, 3);
    expect(h.api.requests.every((r) => r.method.name.endsWith('.query')), true);
    expect((await h.execute(r)).outcome, NvmeHostRenameOutcome.rejected);
    expect(h.api.writes, 1);
  });
  for (final id in [-1, 0, 1, 2, 3, 999]) {
    test('reject non-host database ID $id', () async {
      final h = _Harness();
      await expectLater(h.coordinator.prepare(id, _nqn), throwsStateError);
      expect(h.api.writes, 0);
      expect(h.api.protectedReads, 0);
    });
  }
  for (final nqn in ['', 'nqn.short', ' $_nqn', '$_nqn ', '$_nqn\n']) {
    test('invalid NQN ${nqn.length} fails before reads', () async {
      final h = _Harness();
      await expectLater(h.coordinator.prepare(9, nqn), throwsStateError);
      expect(h.api.requests, isEmpty);
      expect(h.api.reads, 0);
    });
  }
  final unsafe = <String, void Function(_Fake)>{
    'association': (a) => a.mappings.add({
      'id': 3,
      'host': {'id': 9},
      'subsys': {'id': 2},
    }),
    'credentials': (a) => a.credentialed = true,
    'incomplete': (a) => a.incomplete = true,
    'identity mismatch': (a) => a.protectedNqn = 'nqn.2026-09.example:wrong',
    'duplicate': (a) => a.hosts.add({'id': 10, 'hostnqn': _nqn}),
    'case duplicate': (a) =>
        a.hosts.add({'id': 10, 'hostnqn': _nqn.toUpperCase()}),
  };
  for (final entry in unsafe.entries) {
    test('${entry.key} rejects review and fresh preflight', () async {
      final h = _Harness();
      entry.value(h.api);
      await expectLater(h.coordinator.prepare(9, _nqn), throwsStateError);
      expect(h.api.writes, 0);
      final changed = _Harness();
      final r = await changed.coordinator.prepare(9, _nqn);
      entry.value(changed.api);
      expect(
        (await changed.execute(r)).outcome,
        NvmeHostRenameOutcome.rejected,
      );
      expect(changed.api.writes, 0);
    });
  }
  test('unchanged NQN rejects without write', () async {
    final h = _Harness();
    await expectLater(
      h.coordinator.prepare(9, 'nqn.2026-09.example:old'),
      throwsStateError,
    );
    expect(h.api.writes, 0);
  });
  for (final condition in [
    'consent',
    'phrase',
    'expiry',
    'session',
    'cancel',
    'hash drift',
    'lock',
    'topology drift',
  ]) {
    test('$condition invalidates review', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(9, _nqn);
      Object? owner;
      switch (condition) {
        case 'expiry':
          h.clock = h.clock.add(const Duration(minutes: 5));
        case 'session':
          h.current = false;
        case 'cancel':
          h.coordinator.cancel(r);
        case 'hash drift':
          h.api.hash = 'SHA-512';
        case 'lock':
          owner = h.lock.acquire();
        case 'topology drift':
          h.api.subsystem['name'] = 'changed';
      }
      expect(
        (await h.execute(
          r,
          consent: condition != 'consent',
          phrase: condition == 'phrase' ? 'wrong' : null,
        )).outcome,
        NvmeHostRenameOutcome.rejected,
      );
      expect(h.api.writes, 0);
      if (owner != null) h.lock.release(owner);
    });
  }
  for (final failure in [
    'throw',
    'unchanged',
    'wrong ID',
    'wrong NQN',
    'returned hash',
    'topology drift',
    'new mapping',
    'hash drift',
    'auth drift',
    'readback failure',
  ]) {
    test('$failure fences further edits after one write', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(9, _nqn);
      h.api.failure = failure;
      expect((await h.execute(r)).outcome, NvmeHostRenameOutcome.unknown);
      expect(h.api.writes, 1);
      expect(h.coordinator.locked, true);
      await expectLater(h.coordinator.prepare(9, _nqn), throwsStateError);
    });
  }
  for (final width in [320.0, 430.0]) {
    testWidgets('rename consent and ID invalidation at $width 200 percent', (
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
            nvmeHostRenameCoordinatorProvider.overrideWith(
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
              body: SingleChildScrollView(child: NvmeHostRenameEditor()),
            ),
          ),
        ),
      );
      Finder key(String suffix) => find.byKey(Key('nvme-host-rename-$suffix'));
      Future<void> tap(String suffix) async {
        await tester.ensureVisible(key(suffix));
        await tester.tap(key(suffix));
        await tester.pumpAndSettle();
      }

      await tester.enterText(key('id'), '9');
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
      await tester.ensureVisible(key('id'));
      await tester.enterText(key('id'), '3');
      await tester.pumpAndSettle();
      expect(key('submit'), findsNothing);
      await tester.enterText(key('id'), '9');
      await tap('review');
      expect(tester.widget<FilledButton>(key('submit')).onPressed, isNull);
      await tap('consent');
      await tester.ensureVisible(key('confirmation'));
      await tester.enterText(
        key('confirmation'),
        'RENAME NVME HOST 9 FROM nqn.2026-09.example:old TO $_nqn',
      );
      await tap('submit');
      expect(h.api.writes, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
