import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/app_shell/adaptive_shell.dart';
import 'package:truedash/app_shell/app_destination.dart';

void main() {
  for (final width in [599.0, 600.0, 999.0, 1000.0]) {
    testWidgets('uses the approved navigation at ${width.toInt()}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: AdaptiveShell())),
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
      const ProviderScope(child: MaterialApp(home: AdaptiveShell())),
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
}
