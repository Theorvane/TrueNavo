import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/app_shell/adaptive_shell.dart';
import 'package:truedash/app_shell/app_destination.dart';
import 'package:truedash/features/connection/connection_controller.dart';
import 'package:truedash/features/connection/connection_screen.dart';
import 'package:truedash/features/tls_trust/tls_trust_providers.dart';
import 'package:truedash_design_system/truedash_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  for (final width in [320.0, 599.0, 600.0, 999.0, 1000.0]) {
    testWidgets('uses the approved navigation at ${width.toInt()}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: TrueDashTheme.light(),
            home: const AdaptiveShell(),
          ),
        ),
      );
      expect(
        find.byType(NavigationBar),
        width < 600 ? findsOneWidget : findsNothing,
      );
      final rails = find.byType(NavigationRail);
      expect(rails, width < 600 ? findsNothing : findsOneWidget);
      if (width >= 600) {
        expect(tester.widget<NavigationRail>(rails).extended, width >= 1000);
      }
    });
  }

  testWidgets('retains selected destination across layout modes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(599, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: TrueDashTheme.light(),
          home: const AdaptiveShell(),
        ),
      ),
    );
    await tester.tap(find.text(AppDestination.jobs.label));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    await tester.pump();
    expect(find.text('Jobs'), findsWidgets);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      AppDestination.jobs.index,
    );
  });

  testWidgets('each destination has its own honest no-server state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: TrueDashTheme.light(),
            home: const AdaptiveShell(),
          ),
        ),
      );
      for (final destination in AppDestination.values) {
        await tester.tap(_nativeDestinationAction(tester, destination));
        await tester.pump();
        expect(find.text(destination.label), findsWidgets);
        expect(
          find.text('${destination.label} needs a server connection'),
          findsOneWidget,
        );
        expect(find.text(_scopeFor(destination)), findsOneWidget);
      }
    } finally {
      handle.dispose();
    }
  });

  testWidgets(
    'return to connection dismisses its route after a successful connection',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tlsTrustRouteProvider.overrideWithValue(
              TlsTrustRoute.platformValidated,
            ),
            sessionRepositoryProvider.overrideWithValue(_SuccessRepository()),
          ],
          child: MaterialApp(
            theme: TrueDashTheme.light(),
            home: const AdaptiveShell(),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('server-catalog-trigger')),
          matching: find.text('No server selected'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Return to connection'));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionScreen), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('server-url-field')),
        'https://nas.example',
      );
      await tester.enterText(
        find.byKey(const Key('username-field')),
        'test-account',
      );
      await tester.enterText(
        find.byKey(const Key('api-key-field')),
        'test-api-key',
      );
      await tester.ensureVisible(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();

      expect(find.text('Home'), findsWidgets);
      expect(find.text('nas.example'), findsWidgets);
      expect(find.byType(ConnectionScreen), findsNothing);
    },
  );
}

Finder _nativeDestinationActions(WidgetTester tester) {
  final navigation = find.byType(NavigationBar).evaluate().isNotEmpty
      ? find.byType(NavigationBar)
      : find.byType(NavigationRail);
  final actions = find.descendant(
    of: navigation,
    matching: find.byWidgetPredicate((widget) => widget is InkResponse),
  );
  expect(actions, findsNWidgets(AppDestination.values.length));
  return actions;
}

Finder _nativeDestinationAction(
  WidgetTester tester,
  AppDestination destination,
) => _nativeDestinationActions(tester).at(destination.index);

String _scopeFor(AppDestination destination) => switch (destination) {
  AppDestination.home => 'Read-only server overview.',
  AppDestination.storage => 'Read-only pools and dataset inventory.',
  AppDestination.workloads => 'Read-only service inventory and status.',
  AppDestination.alerts => 'Read-only alerts from the connected server.',
  AppDestination.jobs => 'Read-only job history from the connected server.',
};

final class _SuccessRepository implements SessionRepository {
  @override
  Future<void> close() async {}

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async => ServerSummary(
    originalHostInput: serverInput,
    endpointUri: Uri.parse('wss://nas.example/api/current'),
    identity: 'admin',
    version: '25.10',
    availableMethodNames: const {'a', 'b'},
  );
}
