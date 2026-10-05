import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

double _contrast(Color first, Color second) {
  double channel(int value) {
    final normalized = value / 255;
    return normalized <= .04045
        ? normalized / 12.92
        : mathPow((normalized + .055) / 1.055, 2.4);
  }

  double luminance(Color color) =>
      .2126 * channel((color.r * 255).round()) +
      .7152 * channel((color.g * 255).round()) +
      .0722 * channel((color.b * 255).round());
  final one = luminance(first);
  final two = luminance(second);
  return (one > two ? one + .05 : two + .05) /
      (one > two ? two + .05 : one + .05);
}

double mathPow(double base, double exponent) =>
    math.pow(base, exponent).toDouble();

void main() {
  test(
    'light and dark themes expose semantic roles with accessible contrast',
    () {
      final dark = TrueNavoTheme.dark().extension<TrueNavoThemeExtension>()!;
      final light = TrueNavoTheme.light().extension<TrueNavoThemeExtension>()!;
      expect(
        _contrast(dark.textPrimary, dark.canvas),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(light.textMuted, light.canvas),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(dark.borderControl, dark.surfaceBase),
        greaterThanOrEqualTo(3),
      );
      expect(
        _contrast(light.borderControl, light.surfaceBase),
        greaterThanOrEqualTo(3),
      );
      for (final theme in [light, dark]) {
        expect(theme.actionDisabled, isNot(theme.actionPrimary));
        expect(theme.onActionDisabled, isNot(theme.onActionPrimary));
        expect(theme.borderDisabled, isNot(theme.actionPrimary));
        expect(
          _contrast(theme.onActionDisabled, theme.actionDisabled),
          greaterThanOrEqualTo(4.5),
        );
      }
      expect(TrueNavoTheme.dark().brightness, Brightness.dark);
      expect(TrueNavoTheme.light().brightness, Brightness.light);
      final highContrast = TrueNavoTheme.light(highContrast: true)
          .extension<TrueNavoThemeExtension>()!;
      expect(highContrast.highContrast, isTrue);
      expect(highContrast.copyWith().highContrast, isTrue);
      expect(highContrast.lerp(highContrast, .5).density, highContrast.density);
      expect(
        light
            .copyWith(statusStaleForeground: dark.statusStaleForeground)
            .statusStaleForeground,
        dark.statusStaleForeground,
      );
      expect(
        light.lerp(dark, .5).statusStaleSurface,
        Color.lerp(light.statusStaleSurface, dark.statusStaleSurface, .5),
      );
    },
  );
}
