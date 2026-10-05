import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

void main() {
  for (final secret in [false, true]) {
    testWidgets(
      'personalized IME learning follows secret policy even without obscuring: $secret',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: TrueNavoTheme.light(),
            home: Scaffold(
              body: TdTextField(
                label: 'Input',
                controller: controller,
                secret: secret,
              ),
            ),
          ),
        );
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.enableIMEPersonalizedLearning, !secret);
        expect(field.enableSuggestions, !secret);
        expect(field.autocorrect, !secret);
      },
    );
  }
  testWidgets('field keeps an external label and accessible secret toggle', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueNavoTheme.light(),
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
