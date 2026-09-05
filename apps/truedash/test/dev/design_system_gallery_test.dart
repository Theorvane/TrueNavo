import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/dev/design_system_gallery.dart';

void main() {
  testWidgets('gallery exposes component states and theme control', (
    tester,
  ) async {
    await tester.pumpWidget(const DesignSystemGallery());
    expect(find.text('Primary'), findsOneWidget);
    expect(find.text('Success'), findsOneWidget);
    expect(find.text('Pool capacity'), findsOneWidget);
    expect(find.byTooltip('Toggle theme'), findsOneWidget);
    expect(find.text('Comfortable density'), findsOneWidget);
    expect(find.text('Field states'), findsOneWidget);
    expect(find.text('Loading state'), findsOneWidget);
    expect(find.text('Empty state'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Compact density'), findsOneWidget);
  });
}
