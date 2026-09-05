import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

void main() {
  testWidgets('field keeps an external label and accessible secret toggle', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueDashTheme.light(),
        home: Scaffold(
          body: TdTextField(
            label: 'API key',
            controller: controller,
            secret: true,
            obscureText: true,
            onToggleSecret: () {},
          ),
        ),
      ),
    );
    expect(find.text('API key'), findsOneWidget);
    expect(find.byTooltip('Show API key'), findsOneWidget);
    expect(
      tester.getSize(find.byTooltip('Show API key')).height,
      greaterThanOrEqualTo(44),
    );
  });
}
