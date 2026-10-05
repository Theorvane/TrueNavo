import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_screen.dart';
import 'package:truenavo/truenavo_app.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

void main() {
  testWidgets('installs system light and dark semantic themes', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: TrueNavoApp()));
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.theme, isNotNull);
    expect(material.darkTheme, isNotNull);
    expect(material.themeMode, ThemeMode.system);
    expect(
      Theme.of(tester.element(find.byType(ConnectionScreen)))
          .extension<TrueNavoThemeExtension>(),
      isNotNull,
    );
  });

  testWidgets('resolves approved density breakpoints from explicit widths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(child: TrueNavoApp()));
    final element = tester.element(find.byType(ConnectionScreen));
    expect(
      Theme.of(element).extension<TrueNavoThemeExtension>()!.density,
      TrueNavoDensity.comfortable,
    );
    await tester.binding.setSurfaceSize(const Size(600, 844));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(ConnectionScreen)))
          .extension<TrueNavoThemeExtension>()!
          .density,
      TrueNavoDensity.standard,
    );
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(ConnectionScreen)))
          .extension<TrueNavoThemeExtension>()!
          .density,
      TrueNavoDensity.compact,
    );
  });
}
