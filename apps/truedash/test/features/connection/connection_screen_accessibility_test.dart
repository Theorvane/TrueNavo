import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truedash/truedash_app.dart';

void main() {
  testWidgets('mobile uses one form pane and desktop presents two panes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(child: TrueDashApp()));
    expect(find.byKey(const Key('connection-form-pane')), findsOneWidget);
    expect(find.byKey(const Key('connection-intro-pane')), findsNothing);
    expect(find.text('TrueDash'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('connection-form-pane')), findsOneWidget);
    expect(find.byKey(const Key('connection-intro-pane')), findsOneWidget);
    expect(find.text('TrueDash'), findsOneWidget);
  });

  testWidgets('text scaling retains the connect action without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(2)),
        child: ProviderScope(child: TrueDashApp()),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('connect-button')),
      200,
      scrollable: find.ancestor(
        of: find.byKey(const Key('connect-button')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('Connect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '320px at 200% text scale keeps Connect reachable without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: ProviderScope(child: TrueDashApp()),
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('connect-button')),
        200,
        scrollable: find.ancestor(
          of: find.byKey(const Key('connect-button')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('Connect'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
