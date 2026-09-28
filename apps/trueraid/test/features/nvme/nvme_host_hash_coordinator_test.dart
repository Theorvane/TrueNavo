import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_host_hash_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_host_hash_editor.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _newHash = 'SHA-384';

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession,
        AuthenticatedNvmeHostHashSession,
        AuthenticatedNvmeHostChoicesSession {
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
        'nvmet.host.dhchap_hash_choices',
        'nvmet.host.dhchap_dhgroup_choices',
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
  List<String> choices = ['SHA-256', 'SHA-384', 'SHA-512'];
  bool choicesFail = false;
  int choiceReads = 0;
  int protectedReads = 0;
  @override
  Future<NvmeHostAuthenticationChoices>
  loadNvmeHostAuthenticationChoices() async {
    choiceReads++;
    if (choicesFail) throw StateError("private-error-never-shown");
    return NvmeHostAuthenticationChoices.project(choices, []);
  }

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
  Future<NvmeUncredentialedHost> changeUncredentialedNvmeHostHash({
    required int id,
    required String expectedNqn,
    required String expectedHash,
    required String newHash,
  }) async {
    writes++;
    expect(id, 9);
    expect(expectedNqn, 'nqn.2026-09.example:old');
    expect(expectedHash, 'SHA-256');
    expect(newHash, _newHash);
    if (failure == 'throw') throw const NvmeHostException();
    if (failure != 'unchanged') hash = newHash;
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
      failure == 'wrong NQN' ? 'nqn.2026-09.example:wrong' : expectedNqn,
      failure == 'returned hash' ? 'SHA-512' : newHash,
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
    coordinator = NvmeHostHashCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      createApi: api,
      choicesApi: api,
      lock: lock,
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final api = _Fake();
  final lock = ServerOperationLock();
  late final AuthenticatedSession session;
  late final NvmeHostHashCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  Future<NvmeHostHashResult> execute(
    NvmeHostHashReview r, {
    String? phrase,
    bool consent = true,
  }) => coordinator.execute(
    r,
    phrase ?? r.confirmation,
    acknowledgeHashChange: consent,
  );
}

void main() {
  test(
    'algorithm discovery errors never expose private text in a review failure',
    () async {
      final h = _Harness();
      h.api.choicesFail = true;
      await expectLater(
        h.coordinator.prepare(9, _newHash),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'safe error',
            isNot(contains('private-error-never-shown')),
          ),
        ),
      );
      expect(h.api.writes, 0);
    },
  );
  test('hash-only change preserves NQN and topology', () async {
    final h = _Harness();
    final r = await h.coordinator.prepare(9, _newHash);
    expect(r.confirmation, 'CHANGE NVME HOST 9 HASH FROM SHA-256 TO $_newHash');
    expect(h.api.writes, 0);
    expect((await h.execute(r)).outcome, NvmeHostHashOutcome.completed);
    expect(h.api.writes, 1);
    expect(h.api.protectedReads, 3);
    expect(h.api.requests.every((r) => r.method.name.endsWith('.query')), true);
    expect((await h.execute(r)).outcome, NvmeHostHashOutcome.rejected);
    expect(h.api.writes, 1);
  });
  for (final id in [-1, 0, 1, 2, 3, 999]) {
    test('reject non-host database ID $id', () async {
      final h = _Harness();
      await expectLater(h.coordinator.prepare(id, _newHash), throwsStateError);
      expect(h.api.writes, 0);
      expect(h.api.protectedReads, 0);
    });
  }
  for (final hash in ['', 'SHA-1', 'sha-384', 'SHA-384 ', 'SHA-384\n']) {
    test('invalid hash $hash fails before reads', () async {
      final h = _Harness();
      await expectLater(h.coordinator.prepare(9, hash), throwsStateError);
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
    'choice failure': (a) => a.choicesFail = true,
    'unadvertised choice': (a) => a.choices = ['SHA-256'],
  };
  for (final entry in unsafe.entries) {
    test('${entry.key} rejects review and fresh preflight', () async {
      final h = _Harness();
      entry.value(h.api);
      await expectLater(h.coordinator.prepare(9, _newHash), throwsStateError);
      expect(h.api.writes, 0);
      final changed = _Harness();
      final r = await changed.coordinator.prepare(9, _newHash);
      entry.value(changed.api);
      expect((await changed.execute(r)).outcome, NvmeHostHashOutcome.rejected);
      expect(changed.api.writes, 0);
    });
  }
  test('unchanged hash rejects without write', () async {
    final h = _Harness();
    await expectLater(h.coordinator.prepare(9, 'SHA-256'), throwsStateError);
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
      final r = await h.coordinator.prepare(9, _newHash);
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
        NvmeHostHashOutcome.rejected,
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
      final r = await h.coordinator.prepare(9, _newHash);
      h.api.failure = failure;
      expect((await h.execute(r)).outcome, NvmeHostHashOutcome.unknown);
      expect(h.api.writes, 1);
      expect(h.coordinator.locked, true);
      await expectLater(h.coordinator.prepare(9, _newHash), throwsStateError);
    });
  }
  for (final width in [320.0, 430.0]) {
    testWidgets('hash consent and ID invalidation at $width 200 percent', (
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
            nvmeHostHashCoordinatorProvider.overrideWith(
              (ref) => h.coordinator,
            ),
          ],
          child: MaterialApp(
            theme: TrueRAIDTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(child: NvmeHostHashEditor()),
            ),
          ),
        ),
      );
      Finder key(String suffix) => find.byKey(Key('nvme-host-hash-$suffix'));
      Future<void> tap(String suffix) async {
        await tester.ensureVisible(key(suffix));
        await tester.tap(key(suffix));
        await tester.pumpAndSettle();
      }

      await tester.enterText(key('id'), '9');
      await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_newHash).last);
      await tester.pumpAndSettle();
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
        'CHANGE NVME HOST 9 HASH FROM SHA-256 TO $_newHash',
      );
      await tap('submit');
      expect(h.api.writes, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
