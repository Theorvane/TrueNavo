import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

void main() {
  testWidgets('metric card presents label value unit and freshness', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueNavoTheme.dark(),
        home: const Scaffold(
          body: TdMetricCard(
            label: 'Capacity',
            value: '12.4',
            unit: 'TB',
            freshness: 'Updated now',
          ),
        ),
      ),
    );
    expect(find.text('Capacity'), findsOneWidget);
    expect(find.text('12.4'), findsOneWidget);
    expect(find.text('TB'), findsOneWidget);
    expect(find.text('Updated now'), findsOneWidget);
  });
}
