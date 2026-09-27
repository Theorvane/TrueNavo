import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_auth_panel.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

class _Fake implements SessionRepository, AuthenticatedIscsiAuthSession {
  int reads = 0;
  @override
  Future<IscsiAuthInventory> loadIscsiAuthReferences() async {
    reads++;
    return IscsiAuthInventory([
      const IscsiAuthReference(
        id: 3,
        tag: 9,
        user: 'client-user',
        peerUser: '',
        discoveryAuth: 'CHAP',
      ),
      const IscsiAuthReference(
        id: 4,
        tag: 10,
        user: 'unused-user',
        peerUser: '',
        discoveryAuth: 'NONE',
      ),
    ], DateTime.utc(2026));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('CHAP identities load only on request and hide after switch', (
    tester,
  ) async {
    final api = _Fake();
    AuthenticatedSession? selected = AuthenticatedSession(
      profileId: 'first',
      repository: api,
      availableMethodNames: const {'iscsi.auth.query'},
      endpoint: 'wss://first.example/api/current',
    );
    final provider = Provider<AuthenticatedSession?>((ref) => selected);
    final container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith(
          (ref) => ref.watch(provider),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(body: IscsiAuthPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.reads, 0);
    expect(find.textContaining('client-user'), findsNothing);

    await tester.tap(find.byKey(const Key('iscsi-load-auth')));
    await tester.pumpAndSettle();
    expect(api.reads, 1);
    expect(find.textContaining('client-user'), findsOneWidget);
    expect(find.textContaining('Tag 9'), findsOneWidget);

    selected = AuthenticatedSession(
      profileId: 'second',
      repository: _Fake(),
      availableMethodNames: const {'iscsi.auth.query'},
      endpoint: 'wss://second.example/api/current',
    );
    container.invalidate(provider);
    container.read(provider);
    await tester.pumpAndSettle();
    expect(api.reads, 1);
    expect(find.textContaining('client-user'), findsNothing);
    expect(find.text('Load references'), findsOneWidget);
  });

  testWidgets('on-demand CHAP references show saved topology and donut', (
    tester,
  ) async {
    final api = _Fake();
    final session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {'iscsi.auth.query'},
      endpoint: 'wss://fixture.example/api/current',
    );
    final overview = IscsiOverview.parse(
      portals: [],
      initiators: [],
      targets: [
        {
          'id': 7,
          'name': 'target-a',
          'mode': 'ISCSI',
          'groups': [
            {'portal': 2, 'initiator': 5, 'authmethod': 'CHAP', 'auth': 3},
            {'portal': 2, 'initiator': 5, 'authmethod': 'CHAP', 'auth': 99},
          ],
        },
      ],
      extents: [],
      mappings: [],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => session),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: IscsiAuthPanel(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.reads, 0);
    expect(find.byKey(const Key('iscsi-auth-usage-donut')), findsNothing);
    await tester.tap(find.byKey(const Key('iscsi-load-auth')));
    await tester.pumpAndSettle();
    expect(api.reads, 1);
    expect(find.byKey(const Key('iscsi-auth-usage-donut')), findsOneWidget);
    expect(find.text('Target/discovery referenced · 1'), findsOneWidget);
    expect(find.text('No returned reference · 1'), findsOneWidget);
    expect(find.textContaining('1 missing credential IDs'), findsOneWidget);
    expect(find.textContaining('1 target(s)'), findsOneWidget);
  });
}
