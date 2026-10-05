import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_namespace_delete_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_namespace_delete_editor.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

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
        'nvmet.namespace.delete',
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
    'device_type': 'FILE',
    'enabled': false,
    'locked': false,
  };
  final other = <String, Object?>{
    'id': 8,
    'nsid': 2,
    'subsys': {'id': 2},
    'device_type': 'ZVOL',
    'enabled': false,
    'locked': false,
  };
  final mappings = <Map<String, Object?>>[];
  final hostMappings = <Map<String, Object?>>[];
  bool removed = false, ambiguous = false, keep = false, drift = false;
  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async =>
      NvmeHostPublicRows.project([
        {'id': 9, 'hostnqn': 'nqn.2026-09.example:host'},
      ], hostMappings);
  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'nvmet.subsys.query':
        return AdminCompleted(request, value: [Map.of(subsystem)]);
      case 'nvmet.port.query':
        return AdminCompleted(
          request,
          value: [
            {'id': 3, 'addr_trtype': 'TCP', 'enabled': false},
          ],
        );
      case 'nvmet.namespace.query':
        return AdminCompleted(
          request,
          value: [if (!removed) Map.of(namespace), Map.of(other)],
        );
      case 'nvmet.port_subsys.query':
        return AdminCompleted(
          request,
          value: [for (final row in mappings) Map.of(row)],
        );
      case 'nvmet.namespace.delete':
        expect(request.arguments, [
          7,
          {'remove': false},
        ]);
        if (ambiguous) return AdminOutcomeUnknown(request);
        removed = !keep;
        if (drift) other['nsid'] = 3;
        return AdminCompleted(request, value: true);
      default:
        throw StateError('Unexpected method');
    }
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
    coordinator = NvmeNamespaceDeleteCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final api = _Fake();
  late final AuthenticatedSession session;
  late final NvmeNamespaceDeleteCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes =>
      api.calls.where((c) => c.method.name == 'nvmet.namespace.delete').length;
  Future<NvmeNamespaceDeleteResult> execute(
    NvmeNamespaceDeleteReview r, {
    String? phrase,
    bool consent = true,
  }) => coordinator.execute(
    r,
    phrase ?? r.confirmation,
    acknowledgeConfigurationLoss: consent,
  );
}

void main() {
  for (final type in ['FILE', 'ZVOL']) {
    test(
      '$type configuration removal always preserves backing request',
      () async {
        final h = _Harness();
        h.api.namespace['device_type'] = type;
        final r = await h.coordinator.prepare(7);
        expect(
          r.confirmation,
          'DELETE NVME NAMESPACE 7 SUBSYSTEM 2 NSID 1 KEEP BACKING',
        );
        expect(h.writes, 0);
        expect(
          (await h.execute(r)).outcome,
          NvmeNamespaceDeleteOutcome.completed,
        );
        expect(h.writes, 1);
        expect(h.api.other['nsid'], 2);
        expect(
          (await h.execute(r)).outcome,
          NvmeNamespaceDeleteOutcome.rejected,
        );
        expect(h.writes, 1);
      },
    );
  }
  for (final id in [-1, 0, 1, 2, 3, 999]) {
    test('reject non-namespace database ID $id', () async {
      final h = _Harness();
      await expectLater(h.coordinator.prepare(id), throwsStateError);
      expect(h.writes, 0);
      if (id <= 0) expect(h.api.calls, isEmpty);
    });
  }
  final unsafe = <String, void Function(_Fake)>{
    'enabled': (a) => a.namespace['enabled'] = true,
    'locked': (a) => a.namespace['locked'] = true,
    'unknown lock': (a) => a.namespace.remove('locked'),
    'unknown NSID': (a) => a.namespace.remove('nsid'),
    'any host': (a) => a.subsystem['allow_any_host'] = true,
    'port mapping': (a) => a.mappings.add({
      'id': 20,
      'port': {'id': 3},
      'subsys': {'id': 2},
    }),
    'host mapping': (a) => a.hostMappings.add({
      'id': 21,
      'host': {'id': 9},
      'subsys': {'id': 2},
    }),
  };
  for (final entry in unsafe.entries) {
    test('reject ${entry.key} at review and fresh preflight', () async {
      final h = _Harness();
      entry.value(h.api);
      await expectLater(h.coordinator.prepare(7), throwsStateError);
      expect(h.writes, 0);
      final changed = _Harness();
      final r = await changed.coordinator.prepare(7);
      entry.value(changed.api);
      expect(
        (await changed.execute(r)).outcome,
        NvmeNamespaceDeleteOutcome.rejected,
      );
      expect(changed.writes, 0);
    });
  }
  for (final failure in [
    'consent',
    'phrase',
    'expiry',
    'session',
    'cancel',
    'nsid drift',
    'type drift',
  ]) {
    test('$failure invalidates review without write', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7);
      switch (failure) {
        case 'expiry':
          h.clock = h.clock.add(const Duration(minutes: 5));
        case 'session':
          h.current = false;
        case 'cancel':
          h.coordinator.cancel(r);
        case 'nsid drift':
          h.api.namespace['nsid'] = 5;
        case 'type drift':
          h.api.namespace['device_type'] = 'ZVOL';
      }
      expect(
        (await h.execute(
          r,
          consent: failure != 'consent',
          phrase: failure == 'phrase' ? 'wrong' : null,
        )).outcome,
        NvmeNamespaceDeleteOutcome.rejected,
      );
      expect(h.writes, 0);
    });
  }
  for (final failure in ['ambiguous', 'present', 'other drift']) {
    test('$failure fences retries after write', () async {
      final h = _Harness();
      final r = await h.coordinator.prepare(7);
      h.api.ambiguous = failure == 'ambiguous';
      h.api.keep = failure == 'present';
      h.api.drift = failure == 'other drift';
      expect((await h.execute(r)).outcome, NvmeNamespaceDeleteOutcome.unknown);
      expect(h.writes, 1);
      expect(h.coordinator.locked, true);
      await expectLater(h.coordinator.prepare(7), throwsStateError);
    });
  }
  for (final width in [320.0, 430.0]) {
    testWidgets('editor consent and ID invalidation fit $width at large text', (
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
            nvmeNamespaceDeleteCoordinatorProvider.overrideWith(
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
              body: SingleChildScrollView(child: NvmeNamespaceDeleteEditor()),
            ),
          ),
        ),
      );
      Finder key(String suffix) =>
          find.byKey(Key('nvme-namespace-delete-$suffix'));
      await tester.enterText(key('id'), '7');
      await tester.ensureVisible(key('review'));
      await tester.tap(key('review'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(key('submit')).onPressed, isNull);
      await tester.ensureVisible(key('consent'));
      await tester.tap(key('consent'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(key('submit')).onPressed, isNotNull);
      await tester.ensureVisible(key('confirmation'));
      await tester.enterText(key('confirmation'), 'wrong');
      await tester.ensureVisible(key('submit'));
      await tester.tap(key('submit'));
      await tester.pumpAndSettle();
      expect(h.writes, 0);
      await tester.ensureVisible(key('review'));
      await tester.tap(key('review'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('id'));
      await tester.enterText(key('id'), '8');
      await tester.pumpAndSettle();
      expect(key('submit'), findsNothing);
      expect(h.writes, 0);
      await tester.enterText(key('id'), '7');
      await tester.ensureVisible(key('review'));
      await tester.tap(key('review'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(key('submit')).onPressed, isNull);
      await tester.ensureVisible(key('consent'));
      await tester.tap(key('consent'));
      await tester.ensureVisible(key('confirmation'));
      await tester.enterText(
        key('confirmation'),
        'DELETE NVME NAMESPACE 7 SUBSYSTEM 2 NSID 1 KEEP BACKING',
      );
      await tester.ensureVisible(key('submit'));
      await tester.tap(key('submit'));
      await tester.pumpAndSettle();
      expect(h.writes, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
