import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_screen.dart';
import 'package:trueraid/trueraid_app.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

void main() {
  testWidgets('installs system light and dark semantic themes', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: TrueRAIDApp()));
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.theme, isNotNull);
    expect(material.darkTheme, isNotNull);
    expect(material.themeMode, ThemeMode.system);
    expect(
      Theme.of(tester.element(find.byType(ConnectionScreen)))
          .extension<TrueRAIDThemeExtension>(),
      isNotNull,
    );
  });

  testWidgets('resolves approved density breakpoints from explicit widths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(child: TrueRAIDApp()));
    final element = tester.element(find.byType(ConnectionScreen));
    expect(
      Theme.of(element).extension<TrueRAIDThemeExtension>()!.density,
      TrueRAIDDensity.comfortable,
    );
    await tester.binding.setSurfaceSize(const Size(600, 844));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(ConnectionScreen)))
          .extension<TrueRAIDThemeExtension>()!
          .density,
      TrueRAIDDensity.standard,
    );
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(ConnectionScreen)))
          .extension<TrueRAIDThemeExtension>()!
          .density,
      TrueRAIDDensity.compact,
    );
  });
}
