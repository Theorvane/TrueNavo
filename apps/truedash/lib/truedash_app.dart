import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

import 'app_shell/adaptive_shell.dart';
import 'features/connection/connection_controller.dart';
import 'features/connection/connection_screen.dart';
import 'features/connection/connection_state.dart';
import 'features/server_profiles/server_profiles_controller.dart';

class TrueDashApp extends ConsumerWidget {
  const TrueDashApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionControllerProvider);
    final selectedProfile = ref.watch(
      serverProfilesControllerProvider.select((state) => state.selectedProfile),
    );
    return MaterialApp(
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
                ? TrueDashTheme.dark(
                    density: density,
                    highContrast: highContrast,
                  )
                : TrueDashTheme.light(
                    density: density,
                    highContrast: highContrast,
                  ),
            child: child!,
          );
        },
      ),
      home: connection is ConnectionSucceeded && selectedProfile != null
          ? const AdaptiveShell()
          : const ConnectionScreen(),
    );
  }
}
