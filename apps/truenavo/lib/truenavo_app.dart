import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import 'app_shell/adaptive_shell.dart';
import 'features/connection/connection_controller.dart';
import 'features/connection/connection_screen.dart';
import 'features/connection/connection_state.dart';
import 'features/server_profiles/server_profiles_controller.dart';
import 'features/search/global_search.dart';
import 'features/offline_demo/offline_demo_screen.dart';

class TrueNavoApp extends ConsumerStatefulWidget {
  const TrueNavoApp({super.key});

  @override
  ConsumerState<TrueNavoApp> createState() => _TrueNavoAppState();
}

class _TrueNavoAppState extends ConsumerState<TrueNavoApp> {
  bool _offlineDemo = false;

  @override
  Widget build(BuildContext context) {
    // Replace, rather than nest, the live MaterialApp. A nested navigator's
    // root dialogs could otherwise escape the isolated demo provider scope.
    if (_offlineDemo) {
      return OfflineDemoScreen(
        onExit: () => setState(() => _offlineDemo = false),
      );
    }
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
            : ConnectionScreen(
                onExploreDemo: () => setState(() => _offlineDemo = true),
              ),
      ),
    );
  }
}
