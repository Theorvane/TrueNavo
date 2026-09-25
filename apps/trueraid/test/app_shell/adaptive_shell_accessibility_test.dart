import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/app_shell/adaptive_shell.dart';
import 'package:trueraid/app_shell/app_destination.dart';
import 'package:trueraid/features/server_profiles/server_profile.dart';
import 'package:trueraid/features/server_profiles/server_profiles_controller.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

void main() {
  testWidgets('route focus never draws a destination outline', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_shell());
    await tester.tap(find.byKey(const Key('open-management')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    FocusScope.of(tester.element(find.byType(AdaptiveShell))).requestFocus();
    await _pumpFocusRing(tester);
    for (final destination in AppDestination.values) {
      expect(
        find.byKey(ValueKey('navigation-focus-ring-${destination.name}')),
        findsNothing,
      );
    }
  });

  testWidgets(
    'empty shell exposes one truthful catalog trigger and return action',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.binding.setSurfaceSize(const Size(390, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_shell());

        expect(find.bySemanticsLabel('Server catalog: empty'), findsOneWidget);
        expect(
          tester.getSemantics(_serverTrigger).flagsCollection.isButton,
          equals(true),
        );
        _expectMinimumActionRect(tester, _serverTrigger);
        final returnAction = _returnAction();
        _expectMinimumActionRect(tester, returnAction);
      } finally {
        handle.dispose();
      }
    },
  );

  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final width in [320.0, 390.0, 768.0, 1024.0, 1440.0]) {
      testWidgets(
        '${brightness.name} reflows five destinations safely at $width with large text and reduced motion',
        (tester) async {
          final handle = tester.ensureSemantics();
          try {
            await tester.binding.setSurfaceSize(Size(width, 800));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final container = await _profilesWithLongName();
            addTearDown(container.dispose);
            await tester.pumpWidget(
              _shell(
                container: container,
                brightness: brightness,
                mediaQuery: const MediaQueryData(
                  disableAnimations: true,
                  textScaler: TextScaler.linear(2),
                ),
              ),
            );
            await tester.pump();

            expect(tester.takeException(), isNull);
            final navigation = width < 600
                ? find.byType(NavigationBar)
                : find.byType(NavigationRail);
            _expectWithinViewport(tester.getRect(navigation), width, 800);
            expect(AppDestination.values, hasLength(5));
            for (final destination in AppDestination.values) {
              _expectNativeDestinationSemantics(
                tester,
                _nativeDestinationAction(tester, destination),
                destination,
                selected: destination == AppDestination.home,
              );
            }
            expect(find.bySemanticsLabel('Choose server'), findsOneWidget);
            _expectWithinViewport(tester.getRect(_serverTrigger), width, 800);
          } finally {
            handle.dispose();
          }
        },
      );
    }
  }

  for (final width in [390.0, 768.0]) {
    testWidgets('native destination actions are at least 44px at $width', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_shell());

        for (final destination in AppDestination.values) {
          final action = _nativeDestinationAction(tester, destination);
          _expectNativeDestinationSemantics(
            tester,
            action,
            destination,
            selected: destination == AppDestination.home,
          );
          _expectMinimumActionRect(tester, action);
        }
      } finally {
        handle.dispose();
      }
    });

    testWidgets('Tab order activates each native destination at $width', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_shell());

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _pumpFocusRing(tester);
        _expectPrimaryFocusOverlaps(tester, _serverTrigger);
        _expectServerFocusRing(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _pumpFocusRing(tester);
        _expectPrimaryFocusOverlaps(
          tester,
          find.byKey(const Key('open-global-search')),
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _pumpFocusRing(tester);
        _expectPrimaryFocusOverlaps(
          tester,
          find.byKey(const Key('open-management')),
        );

        for (final destination in AppDestination.values) {
          final action = _nativeDestinationAction(tester, destination);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await _pumpFocusRing(tester);
          _expectPrimaryFocusOverlaps(tester, action);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await _pumpFocusRing(tester);
          expect(find.text(_scopeFor(destination)), findsOneWidget);
          _expectNativeDestinationSemantics(
            tester,
            action,
            destination,
            selected: true,
          );
          _expectPrimaryFocusOverlaps(tester, action);
        }

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _pumpFocusRing(tester);
        _expectPrimaryFocusOverlaps(tester, _returnAction());

        // Wrap through the ordered global action and then follow the catalog.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _pumpFocusRing(tester);
        _expectPrimaryFocusOverlaps(tester, _serverTrigger);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _pumpFocusRing(tester);
        _expectPrimaryFocusOverlaps(
          tester,
          find.byKey(const Key('open-global-search')),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _pumpFocusRing(tester);
        _expectPrimaryFocusOverlaps(
          tester,
          find.byKey(const Key('open-management')),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _pumpFocusRing(tester);
        _expectPrimaryFocusOverlaps(
          tester,
          _nativeDestinationAction(tester, AppDestination.home),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _pumpFocusRing(tester);
        final successor = AppDestination.values[AppDestination.home.index + 1];
        final successorAction = _nativeDestinationAction(tester, successor);
        _expectPrimaryFocusOverlaps(tester, successorAction);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await _pumpFocusRing(tester);
        expect(find.text(_scopeFor(successor)), findsOneWidget);
        _expectNativeDestinationSemantics(
          tester,
          successorAction,
          successor,
          selected: true,
        );
      } finally {
        handle.dispose();
      }
    });

    testWidgets(
      'native destination focus ring follows keyboard focus at $width',
      (tester) async {
        final handle = tester.ensureSemantics();
        try {
          await tester.binding.setSurfaceSize(Size(width, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(_shell());

          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await _pumpFocusRing(tester);
          _expectPrimaryFocusOverlaps(tester, _serverTrigger);
          _expectServerFocusRing(tester);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await _pumpFocusRing(tester);
          _expectPrimaryFocusOverlaps(
            tester,
            find.byKey(const Key('open-global-search')),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await _pumpFocusRing(tester);
          _expectPrimaryFocusOverlaps(
            tester,
            find.byKey(const Key('open-management')),
          );
          for (final destination in AppDestination.values) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await _pumpFocusRing(tester);
            final action = _nativeDestinationAction(tester, destination);
            _expectPrimaryFocusOverlaps(tester, action);
            final ring = find.byKey(
              ValueKey('navigation-focus-ring-${destination.name}'),
            );
            expect(ring, findsOneWidget);
            expect(
              tester.getRect(ring).overlaps(tester.getRect(action)),
              equals(true),
            );
            final border =
                (tester.widget<DecoratedBox>(ring).decoration as BoxDecoration)
                    .border;
            expect(border, isNotNull);
            expect(border!.top.width, greaterThanOrEqualTo(2));
            expect(
              border.top.color,
              equals(tester.element(ring).tdTheme.actionFocusOnSurface),
            );
            for (final other in AppDestination.values) {
              expect(
                find.byKey(ValueKey('navigation-focus-ring-${other.name}')),
                other == destination ? findsOneWidget : findsNothing,
              );
            }
          }
        } finally {
          handle.dispose();
        }
      },
    );
  }

  testWidgets(
    'server menu actions meet touch targets and restore trigger focus',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final container = await _profilesWithTwoProfiles();
        addTearDown(container.dispose);
        await tester.pumpWidget(_shell(container: container));
        expect(find.bySemanticsLabel('Choose server'), findsOneWidget);
        expect(
          tester.getSemantics(_serverTrigger).flagsCollection.isButton,
          equals(true),
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _pumpFocusRing(tester);
        _expectPrimaryFocusOverlaps(tester, _serverTrigger);
        _expectServerFocusRing(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        final items = find.byWidgetPredicate(
          (widget) => widget is PopupMenuItem,
        );
        expect(items, findsNWidgets(4));
        for (final item in items.evaluate()) {
          final box = item.renderObject! as RenderBox;
          expect(box.size.width, greaterThanOrEqualTo(44));
          expect(
            box.size.height,
            greaterThanOrEqualTo(TdSizing.minimumTouchTarget),
          );
        }
        await tester.tap(find.text('One'));
        await tester.pumpAndSettle();
        _expectPrimaryFocusOverlaps(tester, _serverTrigger);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        _expectPrimaryFocusOverlaps(tester, _serverTrigger);
      } finally {
        handle.dispose();
      }
    },
  );
}

Widget _shell({
  ProviderContainer? container,
  Brightness brightness = Brightness.light,
  MediaQueryData? mediaQuery,
}) {
  final app = MaterialApp(
    theme: TrueRAIDTheme.light(),
    darkTheme: TrueRAIDTheme.dark(),
    themeMode: brightness == Brightness.light
        ? ThemeMode.light
        : ThemeMode.dark,
    home: const AdaptiveShell(),
  );
  final scoped = container == null
      ? ProviderScope(child: app)
      : UncontrolledProviderScope(container: container, child: app);
  return mediaQuery == null
      ? scoped
      : MediaQuery(data: mediaQuery, child: scoped);
}

Future<ProviderContainer> _profilesWithLongName() async {
  final container = ProviderContainer();
  await container
      .read(serverProfilesControllerProvider.notifier)
      .registerAndSelect(
        const ServerProfile(
          id: 'long',
          displayName: 'A deliberately long server profile name that must remain accessible at two hundred percent text scale',
          originalHostInput: 'long.example.test',
          normalizedEndpoint: 'wss://long.example.test',
          lastKnownVersion: '25.10',
        ),
      );
  return container;
}

Future<ProviderContainer> _profilesWithTwoProfiles() async {
  final container = ProviderContainer();
  final controller = container.read(serverProfilesControllerProvider.notifier);
  for (final profile in const [
    ServerProfile(
      id: 'one',
      displayName: 'One',
      originalHostInput: 'one.example.test',
      normalizedEndpoint: 'wss://one.example.test',
      lastKnownVersion: '25.10',
    ),
    ServerProfile(
      id: 'two',
      displayName: 'Two',
      originalHostInput: 'two.example.test',
      normalizedEndpoint: 'wss://two.example.test',
      lastKnownVersion: '25.10',
    ),
  ]) {
    await controller.registerAndSelect(profile);
  }
  return container;
}

final _serverTrigger = find.byKey(const ValueKey('server-catalog-trigger'));

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

void _expectNativeDestinationSemantics(
  WidgetTester tester,
  Finder action,
  AppDestination destination, {
  required bool selected,
}) {
  final semantics = tester.getSemantics(action);
  expect(semantics.label, contains(destination.label));
  expect(
    semantics.label,
    contains('Tab ${destination.index + 1} of ${AppDestination.values.length}'),
  );
  expect(
    semantics.getSemanticsData().hasAction(SemanticsAction.tap),
    equals(true),
  );
  expect(
    semantics.flagsCollection.isSelected,
    equals(selected ? Tristate.isTrue : Tristate.isFalse),
  );
}

Finder _returnAction() => find.ancestor(
  of: find.descendant(
    of: find.byType(TdButton),
    matching: find.text('Return to connection'),
  ),
  matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
);

void _expectMinimumActionRect(WidgetTester tester, Finder action) {
  expect(action, findsOneWidget);
  final rect = tester.getRect(action);
  expect(rect.width, greaterThanOrEqualTo(44));
  expect(rect.height, greaterThanOrEqualTo(TdSizing.minimumTouchTarget));
}

void _expectWithinViewport(Rect rect, double width, double height) {
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(width));
  expect(rect.bottom, lessThanOrEqualTo(height));
}

void _expectPrimaryFocusOverlaps(WidgetTester tester, Finder target) {
  final box =
      FocusManager.instance.primaryFocus!.context!.findRenderObject()!
          as RenderBox;
  final focusRect = box.localToGlobal(Offset.zero) & box.size;
  expect(focusRect.overlaps(tester.getRect(target)), equals(true));
}

Future<void> _pumpFocusRing(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void _expectServerFocusRing(WidgetTester tester) {
  final ring = find.byKey(const ValueKey('server-catalog-focus-ring'));
  final decoration =
      tester.widget<DecoratedBox>(ring).decoration as BoxDecoration;
  final border = decoration.border;
  expect(border, isNotNull);
  expect(border!.top.width, greaterThanOrEqualTo(2));
  expect(
    border.top.color,
    equals(tester.element(ring).tdTheme.actionFocusOnSurface),
  );
}

String _scopeFor(AppDestination destination) => switch (destination) {
  AppDestination.home => 'Read-only server overview.',
  AppDestination.storage => 'Read-only pools and dataset inventory.',
  AppDestination.workloads => 'Read-only service inventory and status.',
  AppDestination.alerts => 'Read-only alerts from the connected server.',
  AppDestination.jobs => 'Read-only job history from the connected server.',
};
