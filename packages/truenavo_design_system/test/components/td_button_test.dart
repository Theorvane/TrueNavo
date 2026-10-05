import 'dart:math' as math;
import 'dart:ui' show Color, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

void main() {
  Widget app(Widget child) => MaterialApp(
    theme: TrueNavoTheme.light(),
    home: Scaffold(body: child),
  );
  testWidgets(
    'loading button preserves its label and cannot invoke its callback',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        app(
          TdButton(label: 'Connect', isLoading: true, onPressed: () => calls++),
        ),
      );
      await tester.tap(find.text('Connect'));
      await tester.tap(find.text('Connect'));
      expect(calls, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );
  testWidgets('all variants retain a 44px target', (tester) async {
    for (final variant in TdButtonVariant.values) {
      await tester.pumpWidget(
        app(TdButton(label: variant.name, onPressed: () {}, variant: variant)),
      );
      expect(
        tester.getSize(find.byType(TextButton)).height,
        greaterThanOrEqualTo(44),
      );
      await tester.pumpWidget(
        app(
          TdButton(
            label: '${variant.name} loading',
            onPressed: () {},
            variant: variant,
            isLoading: true,
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(TextButton)).height,
        greaterThanOrEqualTo(44),
      );
    }
  });

  testWidgets('disabled primary uses distinct semantic colors and semantics', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      app(TdButton(label: 'Save', onPressed: () => calls++)),
    );
    final enabledStyle = tester
        .widget<TextButton>(find.byType(TextButton))
        .style!;
    final theme = TrueNavoTheme.light().extension<TrueNavoThemeExtension>()!;

    await tester.pumpWidget(app(TdButton(label: 'Save', onPressed: null)));
    final disabledStyle = tester
        .widget<TextButton>(find.byType(TextButton))
        .style!;
    const disabled = <WidgetState>{WidgetState.disabled};

    expect(
      disabledStyle.foregroundColor!.resolve(disabled),
      theme.onActionDisabled,
    );
    expect(
      disabledStyle.backgroundColor!.resolve(disabled),
      theme.actionDisabled,
    );
    expect(disabledStyle.side!.resolve(disabled)!.color, theme.borderDisabled);
    expect(
      disabledStyle.foregroundColor!.resolve(disabled),
      isNot(enabledStyle.foregroundColor!.resolve({})),
    );
    expect(
      disabledStyle.backgroundColor!.resolve(disabled),
      isNot(enabledStyle.backgroundColor!.resolve({})),
    );
    expect(
      disabledStyle.side!.resolve(disabled)!.color,
      isNot(enabledStyle.side!.resolve({})!.color),
    );
    await tester.tap(find.text('Save'));
    expect(calls, 0);
    final semantics = tester.getSemantics(find.byType(TdButton));
    expect(semantics.flagsCollection.isButton, isTrue);
    expect(semantics.flagsCollection.isEnabled, Tristate.isFalse);
    expect(semantics.label, 'Save');
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final variant in TdButtonVariant.values) {
      for (final surface in _buttonSurfaces(variant)) {
        testWidgets(
          '${brightness.name} ${variant.name} $surface interactions meet the composited feedback contract',
          (tester) async {
            final theme = brightness == Brightness.light
                ? TrueNavoTheme.light()
                : TrueNavoTheme.dark();
            final tdTheme = theme.extension<TrueNavoThemeExtension>()!;
            final background = switch (surface) {
              _ButtonSurface.canvas => tdTheme.canvas,
              _ButtonSurface.panel => tdTheme.surfaceBase,
            };
            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                home: Scaffold(
                  body: ColoredBox(
                    color: background,
                    child: TdButton(
                      label: 'Save',
                      variant: variant,
                      onPressed: () {},
                    ),
                  ),
                ),
              ),
            );
            final style = tester
                .widget<TextButton>(find.byType(TextButton))
                .style!;
            final base = style.backgroundColor!.resolve({})!;
            final renderedBase = _composite(base, background);
            final hover = _composite(
              style.overlayColor!.resolve({WidgetState.hovered})!,
              renderedBase,
            );
            final pressed = _composite(
              style.overlayColor!.resolve({WidgetState.pressed})!,
              renderedBase,
            );

            // Non-text feedback must remain perceptible after alpha compositing:
            // hover is at least 1.10:1 and DeltaE76 5; pressed is at least 1.20:1
            // and DeltaE76 10. Pressed must never be weaker than hover.
            _expectPerceptibleChange(
              base: renderedBase,
              state: hover,
              minimumContrast: 1.10,
              minimumDeltaE: 5,
            );
            _expectPerceptibleChange(
              base: renderedBase,
              state: pressed,
              minimumContrast: 1.20,
              minimumDeltaE: 10,
            );
            expect(
              _contrastRatio(renderedBase, pressed),
              greaterThanOrEqualTo(_contrastRatio(renderedBase, hover)),
            );
            expect(
              _deltaE76(renderedBase, pressed),
              greaterThanOrEqualTo(_deltaE76(renderedBase, hover)),
            );

            final focusSide = style.side!.resolve({WidgetState.focused})!;
            final unfocusedSide = style.side!.resolve({})!;
            final renderedFocusBorder = _composite(focusSide.color, background);
            final renderedUnfocusedBorder = unfocusedSide.color.a == 0
                ? background
                : _composite(unfocusedSide.color, background);
            expect(focusSide.width, greaterThanOrEqualTo(2));
            expect(
              _contrastRatio(renderedFocusBorder, renderedBase),
              greaterThanOrEqualTo(3),
            );
            expect(
              _contrastRatio(renderedFocusBorder, renderedUnfocusedBorder),
              greaterThanOrEqualTo(3),
            );
            final combined = style.overlayColor!.resolve({
              WidgetState.focused,
              WidgetState.hovered,
            })!;
            expect(
              combined,
              style.overlayColor!.resolve({WidgetState.hovered}),
            );
          },
        );
      }
    }
  }

  testWidgets('disabled and loading states take priority over interactions', (
    tester,
  ) async {
    await tester.pumpWidget(app(TdButton(label: 'Save', onPressed: null)));
    final disabled = tester.widget<TextButton>(find.byType(TextButton)).style!;
    expect(
      disabled.overlayColor!.resolve({
        WidgetState.disabled,
        WidgetState.pressed,
      }),
      Colors.transparent,
    );
    await tester.pumpWidget(
      app(TdButton(label: 'Save', isLoading: true, onPressed: () {})),
    );
    final loading = tester.widget<TextButton>(find.byType(TextButton)).style!;
    expect(
      loading.overlayColor!.resolve({
        WidgetState.disabled,
        WidgetState.focused,
      }),
      Colors.transparent,
    );
  });

  testWidgets('loading stays active-looking while remaining non-invokable', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(TdButton(label: 'Save', isLoading: true, onPressed: () {})),
    );
    final style = tester.widget<TextButton>(find.byType(TextButton)).style!;
    final theme = TrueNavoTheme.light().extension<TrueNavoThemeExtension>()!;

    expect(
      style.backgroundColor!.resolve({WidgetState.disabled}),
      theme.actionPrimary,
    );
    expect(
      style.foregroundColor!.resolve({WidgetState.disabled}),
      theme.onActionPrimary,
    );
    expect(
      tester.getSize(find.byType(TextButton)).height,
      greaterThanOrEqualTo(44),
    );
  });
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

enum _ButtonSurface { canvas, panel }

Iterable<_ButtonSurface> _buttonSurfaces(TdButtonVariant variant) =>
    variant == TdButtonVariant.ghost
    ? _ButtonSurface.values
    : const [_ButtonSurface.canvas];

void _expectPerceptibleChange({
  required Color base,
  required Color state,
  required double minimumContrast,
  required double minimumDeltaE,
}) {
  expect(_contrastRatio(base, state), greaterThanOrEqualTo(minimumContrast));
  expect(_deltaE76(base, state), greaterThanOrEqualTo(minimumDeltaE));
}

double _contrastRatio(Color first, Color second) {
  final lighter = math.max(
    _relativeLuminance(first),
    _relativeLuminance(second),
  );
  final darker = math.min(
    _relativeLuminance(first),
    _relativeLuminance(second),
  );
  return (lighter + .05) / (darker + .05);
}

double _relativeLuminance(Color color) {
  double linearize(double value) => value <= .04045
      ? value / 12.92
      : math.pow((value + .055) / 1.055, 2.4).toDouble();
  return .2126 * linearize(color.r) +
      .7152 * linearize(color.g) +
      .0722 * linearize(color.b);
}

double _deltaE76(Color first, Color second) {
  final firstLab = _lab(first);
  final secondLab = _lab(second);
  return math.sqrt(
    math.pow(firstLab.$1 - secondLab.$1, 2) +
        math.pow(firstLab.$2 - secondLab.$2, 2) +
        math.pow(firstLab.$3 - secondLab.$3, 2),
  );
}

(double, double, double) _lab(Color color) {
  final red = _linearRgb(color.r);
  final green = _linearRgb(color.g);
  final blue = _linearRgb(color.b);
  final x = (red * .4124 + green * .3576 + blue * .1805) / .95047;
  final y = red * .2126 + green * .7152 + blue * .0722;
  final z = (red * .0193 + green * .1192 + blue * .9505) / 1.08883;
  double transform(double value) => value > .008856
      ? math.pow(value, 1 / 3).toDouble()
      : 7.787 * value + 16 / 116;
  final fx = transform(x);
  final fy = transform(y);
  final fz = transform(z);
  return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
}

double _linearRgb(double value) => value <= .04045
    ? value / 12.92
    : math.pow((value + .055) / 1.055, 2.4).toDouble();
