import 'package:flutter/material.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

import 'features/connection/connection_screen.dart';

class TrueDashApp extends StatelessWidget {
  const TrueDashApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TrueDash',
    debugShowCheckedModeBanner: false,
    theme: TrueDashTheme.light(),
    darkTheme: TrueDashTheme.dark(),
    themeMode: ThemeMode.system,
    builder: (context, child) => LayoutBuilder(
      builder: (context, constraints) {
        final density = TrueDashDensity.resolve(constraints.maxWidth);
        final highContrast = MediaQuery.highContrastOf(context);
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Theme(
          data: isDark
              ? TrueDashTheme.dark(density: density, highContrast: highContrast)
              : TrueDashTheme.light(
                  density: density,
                  highContrast: highContrast,
                ),
          child: child!,
        );
      },
    ),
    home: const ConnectionScreen(),
  );
}
