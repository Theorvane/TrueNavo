import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_sessions.dart';
import 'package:trueraid/features/iscsi/iscsi_sessions_panel.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

class _UnusedRepository implements SessionRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('loads identities only on request, and hides on server switch', (
    tester,
  ) async {
    final original = AuthenticatedSession(
      profileId: 'original',
      repository: _UnusedRepository(),
      availableMethodNames: const {},
      endpoint: 'wss://first.example/api/current',
    );
    final other = AuthenticatedSession(
      profileId: 'other',
      repository: _UnusedRepository(),
      availableMethodNames: const {},
      endpoint: 'wss://second.example/api/current',
    );
    AuthenticatedSession? selectedSession = original;
    final selected = Provider<AuthenticatedSession?>((ref) => selectedSession);
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith(
          (ref) => ref.watch(selected),
        ),
        iscsiSessionsProvider.overrideWith((ref) async {
          reads++;
          return IscsiSessionsSnapshot.parse([
            {
              'initiator': 'iqn.test:client',
              'initiator_addr': '192.0.2.15',
              'target': 'iqn.test:target',
              'iser': false,
              'offload': false,
            },
          ], DateTime.utc(2026));
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(body: IscsiSessionsPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(find.textContaining('iqn.test:client'), findsNothing);

    await tester.tap(find.byKey(const Key('iscsi-load-sessions')));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.textContaining('iqn.test:client'), findsOneWidget);
    expect(find.textContaining('192.0.2.15'), findsOneWidget);

    selectedSession = other;
    container.invalidate(selected);
    container.read(selected);
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.textContaining('iqn.test:client'), findsNothing);
    expect(find.text('Load sessions'), findsOneWidget);
  });
}
