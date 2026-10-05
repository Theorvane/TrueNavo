import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import 'app_shell/adaptive_shell.dart';
import 'features/connection/connection_controller.dart';
import 'features/connection/connection_screen.dart';
import 'features/connection/connection_state.dart';
import 'features/server_profiles/server_profiles_controller.dart';
import 'features/search/global_search.dart';

class TrueNavoApp extends ConsumerWidget {
  const TrueNavoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionControllerProvider);
    final selectedProfile = ref.watch(
      serverProfilesControllerProvider.select((state) => state.selectedProfile),
    );
    return GlobalSearchHost(
      shortcutsEnabled:
          connection is ConnectionSucceeded && selectedProfile != null,
      builder: (navigatorKey, observer) => MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [observer],
        title: 'TrueNavo',
        debugShowCheckedModeBanner: false,
        theme: TrueNavoTheme.light(),
        darkTheme: TrueNavoTheme.dark(),
        themeMode: ThemeMode.system,
        builder: (context, child) => LayoutBuilder(
          builder: (context, constraints) {
            final density = TrueNavoDensity.resolve(constraints.maxWidth);
            final highContrast = MediaQuery.highContrastOf(context);
            final isDark = Theme.of(context).brightness == Brightness.dark;
            return Theme(
              data: isDark
                  ? TrueNavoTheme.dark(
                      density: density,
                      highContrast: highContrast,
                    )
                  : TrueNavoTheme.light(
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
      ),
    );
  }
}
