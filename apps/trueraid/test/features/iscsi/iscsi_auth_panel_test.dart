import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_auth_panel.dart';
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
}
