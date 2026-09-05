import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/app_shell/adaptive_shell.dart';
import 'package:truedash/app_shell/app_destination.dart';
import 'package:truedash/features/connection/connection_controller.dart';
import 'package:truedash/features/connection/connection_screen.dart';
import 'package:truedash_design_system/truedash_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  for (final width in [599.0, 600.0, 999.0, 1000.0]) {
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
      3,
    );
  });

  testWidgets('each destination has its own honest scope and common status', (
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
          find.text('Data connection is provided in a later slice.'),
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
            sessionRepositoryProvider.overrideWithValue(_SuccessRepository()),
          ],
          child: MaterialApp(
            theme: TrueDashTheme.light(),
            home: const AdaptiveShell(),
          ),
        ),
      );

      expect(find.text('No server selected'), findsWidgets);
      await tester.tap(find.text('Return to connection'));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionScreen), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('server-url-field')),
        'https://nas.example',
      );
      await tester.enterText(
        find.byKey(const Key('api-key-field')),
        'test-api-key',
      );
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
  AppDestination.home => 'Dashboard content is not available in this slice.',
  AppDestination.alerts => 'Alert data is not available in this slice.',
  AppDestination.manage =>
    'Management commands are not available in this slice.',
  AppDestination.jobs => 'Job feed content is not available in this slice.',
};

final class _SuccessRepository implements SessionRepository {
  @override
  Future<void> close() async {}

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String apiKey,
  }) async => ServerSummary(
    originalHostInput: serverInput,
    endpointUri: Uri.parse('wss://nas.example/api/current'),
    identity: 'admin',
    version: '25.10',
    availableMethodNames: const {'a', 'b'},
  );
}
