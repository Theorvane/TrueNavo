import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truedash/features/connection/connection_screen.dart';
import 'package:truedash/truedash_app.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

void main() {
  testWidgets('installs system light and dark semantic themes', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: TrueDashApp()));
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.theme, isNotNull);
    expect(material.darkTheme, isNotNull);
    expect(material.themeMode, ThemeMode.system);
    expect(
      Theme.of(tester.element(find.byType(ConnectionScreen)))
          .extension<TrueDashThemeExtension>(),
      isNotNull,
    );
  });

  testWidgets('resolves approved density breakpoints from explicit widths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(child: TrueDashApp()));
    final element = tester.element(find.byType(ConnectionScreen));
    expect(
      Theme.of(element).extension<TrueDashThemeExtension>()!.density,
      TrueDashDensity.comfortable,
    );
    await tester.binding.setSurfaceSize(const Size(600, 844));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(ConnectionScreen)))
          .extension<TrueDashThemeExtension>()!
          .density,
      TrueDashDensity.standard,
    );
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(ConnectionScreen)))
          .extension<TrueDashThemeExtension>()!
          .density,
      TrueDashDensity.compact,
    );
  });
}
