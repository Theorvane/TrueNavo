import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/app_shell/adaptive_shell.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';
import 'package:truedash/features/server_profiles/server_profiles_controller.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

void main() {
  testWidgets('switches displayed context only and explains its limit', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      serverProfilesControllerProvider.notifier,
    );
    await controller.registerAndSelect(
      const ServerProfile(
        id: 'one',
        displayName: 'One',
        originalHostInput: 'one',
        normalizedEndpoint: 'wss://one',
        lastKnownVersion: '1',
      ),
    );
    await controller.registerAndSelect(
      const ServerProfile(
        id: 'two',
        displayName: 'Two',
        originalHostInput: 'two',
        normalizedEndpoint: 'wss://two',
        lastKnownVersion: '1',
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: TrueDashTheme.light(),
          home: const AdaptiveShell(),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Choose server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('One').last);
    await tester.pump();
    expect(find.text('One'), findsWidgets);
    expect(
      find.text(
        'Server selection changes what is shown in this app. It does not '
        'reconnect.',
      ),
      findsOneWidget,
    );
    expect(
      container.read(serverProfilesControllerProvider).profiles,
      hasLength(2),
    );
  });

  testWidgets('empty catalog describes the saved empty state', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: TrueDashTheme.light(),
          home: const AdaptiveShell(),
        ),
      ),
    );

    expect(find.text('No server selected'), findsWidgets);
    expect(find.bySemanticsLabel('Server catalog: empty'), findsOneWidget);
    expect(find.text('No saved server profile is selected.'), findsOneWidget);
    expect(find.text('Return to connection'), findsOneWidget);
    expect(find.textContaining('Add server'), findsNothing);
    handle.dispose();
  });
}
