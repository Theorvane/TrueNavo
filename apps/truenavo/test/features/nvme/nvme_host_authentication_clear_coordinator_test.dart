import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_host_authentication_clear_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_host_authentication_clear_editor.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession,
        AuthenticatedNvmeHostAuthenticationClearSession {
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
  bool credentialed = true;
  bool controller = true;
  String? group = '4096-BIT';
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
  Future<NvmeHostAuthentication> loadNvmeHostAuthenticationTarget(
    int id,
  ) async {
    protectedReads++;
    if (incomplete) throw StateError('private-error-never-shown');
    final row = hosts.where((h) => h['id'] == id).single;
    return NvmeHostAuthenticationInventory.project([
      {
        'id': id,
        'hostnqn': protectedNqn ?? row['hostnqn'],
        'dhchap_hash': hash,
        'dhchap_dhgroup': group,
        'dhchap_key': credentialed ? 'private-error-never-shown' : null,
        'dhchap_ctrl_key': controller ? 'private-error-never-shown' : null,
      },
    ]).hosts.single;
  }

  @override
  Future<NvmeHostAuthentication> clearNvmeHostAuthentication({
    required NvmeHostAuthentication expected,
  }) async {
    writes++;
    expect(expected.id, 9);
    expect(expected.nqn, 'nqn.2026-09.example:old');
    expect(expected.hash, 'SHA-256');
    if (failure == 'throw') throw StateError('private-error-never-shown');
    if (failure != 'unchanged') {
      credentialed = false;
      controller = false;
      group = null;
    }
    if (failure == 'topology drift') subsystem['name'] = 'changed';
    if (failure == 'new mapping') {
      mappings.add({
        'id': 3,
        'host': {'id': 9},
        'subsys': {'id': 2},
      });
    }
    if (failure == 'hash drift') hash = 'SHA-512';
    if (failure == 'auth drift') credentialed = true;
    if (failure == 'group drift') group = '2048-BIT';
    if (failure == 'readback failure') incomplete = true;
    return NvmeHostAuthentication(
      id: failure == 'wrong ID' ? 99 : 9,
      nqn: failure == 'wrong NQN' ? 'nqn.2026-09.example:wrong' : expected.nqn,
      hash: failure == 'returned hash' ? 'SHA-512' : expected.hash,
      group: failure == 'returned group' ? '4096-BIT' : null,
      hostKeyReturned: failure == 'returned key',
      controllerKeyReturned: failure == 'returned controller',
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
    coordinator = NvmeHostAuthenticationClearCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      clearApi: api,
      lock: lock,
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final api = _Fake();
  final lock = ServerOperationLock();
  late final AuthenticatedSession session;
  late final NvmeHostAuthenticationClearCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  Future<NvmeHostAuthenticationClearResult> execute(
    NvmeHostAuthenticationClearReview r, {
    String? phrase,
    bool consent = true,
  }) => coordinator.execute(
    r,
    phrase ?? r.confirmation,
    acknowledgeCredentialLoss: consent,
  );
}

void main() {
  test(
    'clears only authentication settings and preserves all public topology',
    () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(9);
      expect(r.confirmation, 'CLEAR NVME HOST 9 AUTHENTICATION');
      expect(r.target.hasReturnedAuthentication, true);
      expect(h.api.writes, 0);
      expect(
        (await h.execute(r)).outcome,
        NvmeHostAuthenticationClearOutcome.completed,
      );
      expect(h.api.writes, 1);
      expect(h.api.protectedReads, 3);
      expect(
        h.api.requests.every((r) => r.method.name.endsWith('.query')),
        true,
      );
      expect(
        (await h.execute(r)).outcome,
        NvmeHostAuthenticationClearOutcome.rejected,
      );
      expect(h.api.writes, 1);
    },
  );
  for (final id in [-1, 0, 1, 2, 3, 999]) {
    test('rejects non-host database ID $id', () async {
      final h = _Harness();
      await expectLater(h.coordinator.prepare(id), throwsStateError);
      expect(h.api.writes, 0);
      expect(h.api.protectedReads, 0);
    });
  }
  final unsafe = <String, void Function(_Fake)>{
    'associated': (a) => a.mappings.add({
      'id': 3,
      'host': {'id': 9},
      'subsys': {'id': 2},
    }),
    'incomplete': (a) => a.incomplete = true,
    'identity mismatch': (a) => a.protectedNqn = 'nqn.2026-09.example:wrong',
    'already unset': (a) {
      a.credentialed = false;
      a.controller = false;
      a.group = null;
    },
  };
  for (final entry in unsafe.entries) {
    test('${entry.key} rejects review and fresh preflight', () async {
      final h = _Harness();
      entry.value(h.api);
      await expectLater(h.coordinator.prepare(9), throwsStateError);
      expect(h.api.writes, 0);
      final changed = _Harness();
      final r = await changed.coordinator.prepare(9);
      entry.value(changed.api);
      expect(
        (await changed.execute(r)).outcome,
        NvmeHostAuthenticationClearOutcome.rejected,
      );
      expect(changed.api.writes, 0);
    });
  }
  for (final shape in ['host only', 'controller only', 'group only']) {
    test(
      'clears $shape including inconsistent returned combinations',
      () async {
        final h = _Harness();
        h.api.credentialed = shape == 'host only';
        h.api.controller = shape == 'controller only';
        h.api.group = shape == 'group only' ? '4096-BIT' : null;
        final r = await h.coordinator.prepare(9);
        expect(
          (await h.execute(r)).outcome,
          NvmeHostAuthenticationClearOutcome.completed,
        );
        expect(h.api.writes, 1);
      },
    );
  }
  for (final condition in [
    'consent',
    'phrase',
    'expiry',
    'backwards clock',
    'session',
    'cancel',
    'hash drift',
    'group drift',
    'key flag drift',
    'lock',
    'topology drift',
  ]) {
    test('$condition invalidates review', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(9);
      Object? owner;
      switch (condition) {
        case 'expiry':
          h.clock = h.clock.add(const Duration(minutes: 5));
        case 'backwards clock':
          h.clock = h.clock.subtract(const Duration(seconds: 1));
        case 'session':
          h.current = false;
        case 'cancel':
          h.coordinator.cancel(r);
        case 'hash drift':
          h.api.hash = 'SHA-512';
        case 'group drift':
          h.api.group = '8192-BIT';
        case 'key flag drift':
          h.api.controller = false;
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
        NvmeHostAuthenticationClearOutcome.rejected,
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
    'returned group',
    'returned key',
    'returned controller',
    'topology drift',
    'new mapping',
    'hash drift',
    'auth drift',
    'group drift',
    'readback failure',
  ]) {
    test('$failure fences further edits after one write', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(9);
      h.api.failure = failure;
      final result = await h.execute(r);
      expect(result.outcome, NvmeHostAuthenticationClearOutcome.unknown);
      expect(result.message, isNot(contains('private-error-never-shown')));
      expect(h.api.writes, 1);
      expect(h.coordinator.locked, true);
      await expectLater(h.coordinator.prepare(9), throwsStateError);
    });
  }
  for (final width in [320.0, 430.0]) {
    for (final dark in [true, false]) {
      testWidgets(
        'credential-loss consent and ID invalidation $width dark=$dark 200 percent',
        (tester) async {
          final h = _Harness();
          tester.view.physicalSize = Size(width, 1600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                dashboardActiveSessionProvider.overrideWith((ref) => h.session),
                nvmeHostAuthenticationClearCoordinatorProvider.overrideWith(
                  (ref) => h.coordinator,
                ),
              ],
              child: MaterialApp(
                theme: dark ? TrueNavoTheme.dark() : TrueNavoTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: const Scaffold(
                  body: SingleChildScrollView(
                    child: NvmeHostAuthenticationClearEditor(),
                  ),
                ),
              ),
            ),
          );
          Finder key(String suffix) =>
              find.byKey(Key('nvme-host-auth-clear-$suffix'));
          Future<void> tap(String suffix) async {
            await tester.ensureVisible(key(suffix));
            await tester.tap(key(suffix));
            await tester.pumpAndSettle();
          }

          await tester.enterText(key('id'), '9');
          await tap('review');
          expect(tester.widget<FilledButton>(key('submit')).onPressed, isNull);
          expect(
            find.textContaining('private-error-never-shown'),
            findsNothing,
          );
          expect(
            find.textContaining('cannot detect key rotations'),
            findsOneWidget,
          );
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
            'CLEAR NVME HOST 9 AUTHENTICATION',
          );
          await tap('submit');
          expect(h.api.writes, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
