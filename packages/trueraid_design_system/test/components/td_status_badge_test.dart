import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

void main() {
  testWidgets('status badge always has text and an icon', (tester) async {
    for (final status in TdStatus.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: Scaffold(
            body: TdStatusBadge(status: status, label: status.name),
          ),
        ),
      );
      expect(find.text(status.name), findsOneWidget);
      expect(find.byType(Icon), findsOneWidget);
      final decoration =
          tester.widget<Container>(find.byType(Container)).decoration
              as BoxDecoration;
      expect(
        (decoration.borderRadius! as BorderRadius).topLeft.x,
        TdRadius.pill,
      );
    }
  });

  for (final theme in [TrueRAIDTheme.light(), TrueRAIDTheme.dark()]) {
    testWidgets(
      '${theme.brightness.name} status badges have AA composited contrast',
      (tester) async {
        final td = theme.extension<TrueRAIDThemeExtension>()!;
        for (final status in TdStatus.values) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: TdStatusBadge(status: status, label: status.name),
              ),
            ),
          );
          final badge = tester.widget<Container>(find.byType(Container));
          final background = (badge.decoration! as BoxDecoration).color!;
          final foreground = tester
              .widget<Text>(find.text(status.name))
              .style!
              .color!;
          expect(
            _contrast(foreground, _composite(background, td.surfaceBase)),
            greaterThanOrEqualTo(4.5),
            reason: status.name,
          );
        }
      },
    );
  }
}

Color _composite(Color foreground, Color background) {
  final alpha = foreground.a;
  return Color.from(
    alpha: 1,
    red: foreground.r * alpha + background.r * (1 - alpha),
    green: foreground.g * alpha + background.g * (1 - alpha),
    blue: foreground.b * alpha + background.b * (1 - alpha),
  );
}

double _contrast(Color first, Color second) {
  double luminance(Color color) {
    double channel(double value) => value <= .04045
        ? value / 12.92
        : math.pow((value + .055) / 1.055, 2.4).toDouble();
    return .2126 * channel(color.r) +
        .7152 * channel(color.g) +
        .0722 * channel(color.b);
  }

  final one = luminance(first);
  final two = luminance(second);
  return (math.max(one, two) + .05) / (math.min(one, two) + .05);
}
