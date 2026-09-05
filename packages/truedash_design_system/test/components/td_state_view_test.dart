import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

void main() {
  testWidgets('state view supports compact accessible error content', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueDashTheme.dark(),
        home: const Scaffold(
          body: TdStateView(
            kind: TdStateKind.error,
            title: 'Connection failed',
            description: 'Try again',
            compact: true,
          ),
        ),
      ),
    );
    expect(find.text('Connection failed'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
