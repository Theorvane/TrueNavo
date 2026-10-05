import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../features/connection/connection_screen.dart';
import '../features/dashboard/dashboard_page.dart';
import '../features/admin/admin_workspace.dart';
import '../features/search/global_search.dart';
import '../features/server_profiles/server_profiles_controller.dart';
import '../features/server_profiles/server_switcher.dart';
import 'app_destination.dart';

const _mobileBreakpoint = 600.0;
const _extendedRailBreakpoint = 1000.0;
const _compactRailWidth = 72.0;
const _extendedRailWidth = 224.0;
const _contentMaxWidth = 1440.0;
const _focusRingThickness = 2.0;

class AdaptiveShell extends ConsumerStatefulWidget {
  const AdaptiveShell({super.key});

  @override
  ConsumerState<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends ConsumerState<AdaptiveShell> {
  AppDestination _destination = AppDestination.home;
  final _destinationAnchors = {
    for (final destination in AppDestination.values)
      destination: [
        GlobalKey(debugLabel: 'navigation-${destination.name}-unselected'),
        GlobalKey(debugLabel: 'navigation-${destination.name}-selected'),
      ],
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final mobile = width < _mobileBreakpoint;
      final desktop = width >= _extendedRailBreakpoint;
      final content = _Content(
        destination: _destination,
        pagePadding: mobile
            ? TdSpacing.pageMobile
            : desktop
            ? TdSpacing.pageDesktop
            : TdSpacing.pageTablet,
        onReturnToConnection: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ConnectionScreen(
              onConnectionSucceeded: () {
                if (mounted) Navigator.of(context).pop();
              },
            ),
          ),
        ),
      );
      return FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: mobile ? 64 : 72,
            titleSpacing: mobile ? TdSpacing.pageMobile : TdSpacing.pageTablet,
            surfaceTintColor: Colors.transparent,
            title: const FocusTraversalOrder(
              order: NumericFocusOrder(1),
              child: ServerSwitcher(),
            ),
            actions: [
              const FocusTraversalOrder(
                order: NumericFocusOrder(1.25),
                child: GlobalSearchButton(),
              ),
              FocusTraversalOrder(
                order: const NumericFocusOrder(1.5),
                child: IconButton(
                  key: const Key('open-management'),
                  tooltip: 'Manage server',
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AdminWorkspace(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: TdSpacing.inline),
            ],
          ),
          body: mobile
              ? FocusTraversalOrder(
                  order: const NumericFocusOrder(3),
                  child: content,
                )
              : Row(
                  children: [
                    FocusTraversalOrder(
                      order: const NumericFocusOrder(2),
                      child: SizedBox(
                        width: desktop ? _extendedRailWidth : _compactRailWidth,
                        child: _NativeNavigationFocusOverlay(
                          anchors: _destinationAnchors,
                          child: NavigationRail(
                            selectedIndex: _destination.index,
                            extended: desktop,
                            minWidth: _compactRailWidth,
                            minExtendedWidth: _extendedRailWidth,
                            labelType: desktop
                                ? null
                                : NavigationRailLabelType.none,
                            onDestinationSelected: _select,
                            destinations: [
                              for (final destination in AppDestination.values)
                                NavigationRailDestination(
                                  icon: Icon(
                                    destination.icon,
                                    key: _destinationAnchors[destination]![0],
                                  ),
                                  selectedIcon: Icon(
                                    destination.selectedIcon,
                                    key: _destinationAnchors[destination]![1],
                                  ),
                                  label: Text(
                                    destination.label,
                                    key: ValueKey(
                                      'navigation-label-${destination.name}',
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: FocusTraversalOrder(
                        order: const NumericFocusOrder(3),
                        child: content,
                      ),
                    ),
                  ],
                ),
          bottomNavigationBar: mobile
              ? FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: _NativeNavigationFocusOverlay(
                    anchors: _destinationAnchors,
                    child: NavigationBar(
                      selectedIndex: _destination.index,
                      onDestinationSelected: _select,
                      destinations: [
                        for (final destination in AppDestination.values)
                          NavigationDestination(
                            icon: Icon(
                              destination.icon,
                              key: _destinationAnchors[destination]![0],
                            ),
                            selectedIcon: Icon(
                              destination.selectedIcon,
                              key: _destinationAnchors[destination]![1],
                            ),
                            label: destination.label,
                          ),
                      ],
                    ),
                  ),
                )
              : null,
        ),
      );
    },
  );

  void _select(int index) =>
      setState(() => _destination = AppDestination.values[index]);
}

class _NativeNavigationFocusOverlay extends StatefulWidget {
  const _NativeNavigationFocusOverlay({
    required this.anchors,
    required this.child,
  });

  final Map<AppDestination, List<GlobalKey>> anchors;
  final Widget child;

  @override
  State<_NativeNavigationFocusOverlay> createState() =>
      _NativeNavigationFocusOverlayState();
}

class _NativeNavigationFocusOverlayState
    extends State<_NativeNavigationFocusOverlay> {
  final _overlayKey = GlobalKey();
  Rect? _focusedRect;
  AppDestination? _focusedDestination;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_updateFocusRing);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_updateFocusRing);
    super.dispose();
  }

  void _updateFocusRing() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resolveFocusedDestination();
    });
  }

  void _resolveFocusedDestination() {
    final overlay = _overlayKey.currentContext?.findRenderObject();
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final focused = focusContext?.findRenderObject();
    var focusInsideNavigation = false;
    focusContext?.visitAncestorElements((element) {
      if (identical(element, _overlayKey.currentContext)) {
        focusInsideNavigation = true;
        return false;
      }
      return true;
    });
    // Route and scroll scopes can span the whole screen. Their intersection
    // with the navigation is not evidence that a destination has focus.
    if (!focusInsideNavigation) {
      _setFocused(null, null);
      return;
    }
    if (overlay is! RenderBox || focused is! RenderBox || !focused.attached) {
      _setFocused(null, null);
      return;
    }
    final focusedOrigin = focused.localToGlobal(Offset.zero);
    final focusedRect = focusedOrigin & focused.size;
    AppDestination? closest;
    var nearestDistance = double.infinity;
    for (final entry in widget.anchors.entries) {
      for (final anchorKey in entry.value) {
        final anchor = anchorKey.currentContext?.findRenderObject();
        if (anchor is! RenderBox || !anchor.attached) continue;
        final center = anchor.localToGlobal(anchor.size.center(Offset.zero));
        final distance = (focusedRect.center - center).distance;
        if (distance < nearestDistance) {
          nearestDistance = distance;
          closest = entry.key;
        }
      }
    }
    final overlayRect = overlay.localToGlobal(Offset.zero) & overlay.size;
    if (closest == null || !overlayRect.overlaps(focusedRect)) {
      _setFocused(null, null);
      return;
    }
    _setFocused(
      closest,
      focusedRect.shift(-overlay.localToGlobal(Offset.zero)),
    );
  }

  void _setFocused(AppDestination? destination, Rect? rect) {
    if (_focusedDestination == destination && _focusedRect == rect) return;
    setState(() {
      _focusedDestination = destination;
      _focusedRect = rect;
    });
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (_) => _updateFocusRing(),
    child: Stack(
      key: _overlayKey,
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (_focusedDestination case final destination?)
          if (_focusedRect case final rect?)
            Positioned.fromRect(
              rect: rect,
              child: IgnorePointer(
                child: DecoratedBox(
                  key: ValueKey('navigation-focus-ring-${destination.name}'),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: context.tdTheme.actionFocusOnSurface,
                      width: _focusRingThickness,
                    ),
                  ),
                ),
              ),
            ),
      ],
    ),
  );
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
          constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
          child: profile == null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      destination.label,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: TdSpacing.related),
                    Text(_scopeFor(destination)),
                    const SizedBox(height: TdSpacing.related),
                    Text(
                      '${destination.label} needs a server connection',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: TdSpacing.related),
                    const Text('No saved server profile is selected.'),
                    const SizedBox(height: TdSpacing.related),
                    const Text(
                      'Connect to a server to view live, read-only data.',
                    ),
                    const SizedBox(height: TdSpacing.related),
                    TdButton(
                      label: 'Return to connection',
                      onPressed: onReturnToConnection,
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [DashboardPage(destination: destination)],
                ),
        ),
      ),
    );
  }
}

String _scopeFor(AppDestination destination) => switch (destination) {
  AppDestination.home => 'Read-only server overview.',
  AppDestination.storage => 'Read-only pools and dataset inventory.',
  AppDestination.workloads => 'Read-only service inventory and status.',
  AppDestination.alerts => 'Read-only alerts from the connected server.',
  AppDestination.jobs => 'Read-only job history from the connected server.',
};
