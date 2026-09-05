import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/connection/connection_screen.dart';
import '../features/server_profiles/server_profiles_controller.dart';
import '../features/server_profiles/server_switcher.dart';
import 'app_destination.dart';

class AdaptiveShell extends ConsumerStatefulWidget {
  const AdaptiveShell({super.key});

  @override
  ConsumerState<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends ConsumerState<AdaptiveShell> {
  AppDestination _destination = AppDestination.home;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final mobile = width < 600;
      final desktop = width >= 1000;
      final content = _Content(
        destination: _destination,
        pagePadding: mobile
            ? 16
            : desktop
            ? 32
            : 24,
        onReturnToConnection: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ConnectionScreen()),
        ),
      );
      return Scaffold(
        appBar: AppBar(title: const ServerSwitcher()),
        body: mobile
            ? content
            : Row(
                children: [
                  NavigationRail(
                    selectedIndex: _destination.index,
                    extended: desktop,
                    minWidth: 72,
                    minExtendedWidth: 224,
                    labelType: desktop ? null : NavigationRailLabelType.all,
                    onDestinationSelected: _select,
                    destinations: [
                      for (final destination in AppDestination.values)
                        NavigationRailDestination(
                          icon: Icon(destination.icon),
                          selectedIcon: Icon(destination.selectedIcon),
                          label: Text(destination.label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: content),
                ],
              ),
        bottomNavigationBar: mobile
            ? NavigationBar(
                selectedIndex: _destination.index,
                onDestinationSelected: _select,
                destinations: [
                  for (final destination in AppDestination.values)
                    NavigationDestination(
                      icon: Icon(destination.icon),
                      selectedIcon: Icon(destination.selectedIcon),
                      label: destination.label,
                    ),
                ],
              )
            : null,
      );
    },
  );

  void _select(int index) =>
      setState(() => _destination = AppDestination.values[index]);
}

class _Content extends ConsumerWidget {
  const _Content({
    required this.destination,
    required this.pagePadding,
    required this.onReturnToConnection,
  });
  final AppDestination destination;
  final double pagePadding;
  final VoidCallback onReturnToConnection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(serverProfilesControllerProvider).selectedProfile;
    return SingleChildScrollView(
      padding: EdgeInsets.all(pagePadding),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1440),
          child: profile == null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'No server selected',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text('This app session has no server profile.'),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: onReturnToConnection,
                      child: const Text('Return to connection'),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      destination.label,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    Semantics(
                      label: 'Current server: ${profile.displayName}',
                      child: Text(
                        profile.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('Data connection is provided in a later slice.'),
                    const SizedBox(height: 12),
                    const Text(
                      'Server selection changes only what is shown in this '
                      'app session. It does not reconnect.',
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
