import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../admin/admin_controller.dart';
import '../admin/admin_operation_page.dart';
import '../admin/admin_workspace.dart';
import '../notification_providers/notification_providers_page.dart';
import '../apps/apps_page.dart';
import '../data_protection/data_protection_page.dart';
import '../datasets/dataset_properties_page.dart';
import '../management/management_page.dart';
import '../network/network_page.dart';
import '../reporting/reporting_page.dart';
import '../shares/shares_page.dart';
import '../zvols/zvols_page.dart';
import 'search_index.dart';

class _OpenSearchIntent extends Intent {
  const _OpenSearchIntent();
}

/// Above the app Navigator so shortcuts work on pushed pages, not just Home.
class GlobalSearchHost extends StatefulWidget {
  const GlobalSearchHost({
    required this.builder,
    this.shortcutsEnabled = true,
    super.key,
  });
  final Widget Function(GlobalKey<NavigatorState>, NavigatorObserver) builder;
  final bool shortcutsEnabled;

  @override
  State<GlobalSearchHost> createState() => _GlobalSearchHostState();
}

class _GlobalSearchHostState extends State<GlobalSearchHost> {
  final _navigator = GlobalKey<NavigatorState>();
  final _observer = _SearchRouteObserver();

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.keyK, control: true):
          _OpenSearchIntent(),
      SingleActivator(LogicalKeyboardKey.keyK, meta: true): _OpenSearchIntent(),
    },
    child: Actions(
      actions: {
        _OpenSearchIntent: CallbackAction<_OpenSearchIntent>(
          onInvoke: (_) {
            // Do not cover authentication, an impact review or another popup.
            final lifecycle = WidgetsBinding.instance.lifecycleState;
            final focus = FocusManager.instance.primaryFocus?.context;
            final editor = focus?.findAncestorWidgetOfExactType<EditableText>();
            if (widget.shortcutsEnabled &&
                (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
                editor?.obscureText != true &&
                _observer.top is PageRoute) {
              final navigator = _navigator.currentState;
              if (navigator != null) showGlobalSearch(navigator.context);
            }
            return null;
          },
        ),
      },
      child: widget.builder(_navigator, _observer),
    ),
  );
}

class _SearchRouteObserver extends NavigatorObserver {
  final _routes = <Route<dynamic>>[];
  Route<dynamic>? get top => _routes.isEmpty ? null : _routes.last;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.add(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index < 0) return;
    if (newRoute == null) {
      _routes.removeAt(index);
    } else {
      _routes[index] = newRoute;
    }
  }
}

final _openNavigators = Expando<bool>();

/// Selection only opens an existing guarded workspace. Never invokes an RPC.
Future<void> showGlobalSearch(BuildContext context) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  if (_openNavigators[navigator] == true) return;
  _openNavigators[navigator] = true;
  NavigationSearchEntry? entry;
  try {
    entry = await showDialog<NavigationSearchEntry>(
      context: context,
      builder: (_) => const GlobalSearchDialog(),
    );
  } finally {
    _openNavigators[navigator] = false;
  }
  if (!navigator.mounted ||
      entry == null ||
      !navigationSearchIndex.any((candidate) => identical(candidate, entry))) {
    return;
  }
  final page = navigationSearchPage(entry);
  await navigator.push(MaterialPageRoute<void>(builder: (_) => page));
}

Widget navigationSearchPage(NavigationSearchEntry entry) {
  if (entry.workspace case final workspace?) {
    if (workspace.method case final method?) {
      return AdminOperationTile.nativePageForMethod(method)!;
    }
    return switch (workspace) {
      SearchWorkspace.notificationProviders =>
        const NotificationProvidersPage(),
      SearchWorkspace.administration => const AdminWorkspace(),
      SearchWorkspace.management => const ManagementPage(),
      SearchWorkspace.shares => const SharesPage(),
      SearchWorkspace.protection => const DataProtectionPage(),
      SearchWorkspace.reporting => const ReportingPage(),
      SearchWorkspace.network => const NetworkPage(),
      SearchWorkspace.apps => const AppsPage(),
      SearchWorkspace.datasets => const DatasetPropertiesPage(),
      SearchWorkspace.zvols => const ZvolsPage(),
      _ => const AdminWorkspace(),
    };
  }
  if (entry.domain case final domain?) return AdminDomainPage(domain: domain);
  final operation = entry.operation!;
  return AdminOperationTile.nativePageForMethod(operation.method) ??
      AdminOperationPage(operation: operation);
}

class GlobalSearchButton extends StatelessWidget {
  const GlobalSearchButton({super.key});
  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('open-global-search'),
    tooltip: 'Search features (Ctrl/⌘ K)',
    onPressed: () => showGlobalSearch(context),
    icon: const Icon(Icons.search_rounded),
  );
}

class GlobalSearchDialog extends ConsumerStatefulWidget {
  const GlobalSearchDialog({super.key});
  @override
  ConsumerState<GlobalSearchDialog> createState() => _GlobalSearchDialogState();
}

class _GlobalSearchDialogState extends ConsumerState<GlobalSearchDialog>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _rowKeys = <String, GlobalKey>{};
  var _matches = searchNavigation('');
  var _selected = 0;
  var _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _text.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !_closing && mounted) {
      _closing = true;
      _text.clear();
      final route = ModalRoute.of(context);
      if (route != null) Navigator.of(context).removeRoute(route);
    }
  }

  void _move(int delta) {
    if (_matches.isEmpty) return;
    setState(() => _selected = (_selected + delta) % _matches.length);
    final row = _rowKeys[_matches[_selected].id]?.currentContext;
    if (row != null) Scrollable.ensureVisible(row, alignment: .5);
  }

  void _open([NavigationSearchEntry? entry]) {
    if (_closing || _matches.isEmpty) return;
    _closing = true;
    Navigator.of(context).pop(entry ?? _matches[_selected]);
  }

  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    // Metadata only: this getter does not query or index an appliance.
    final catalog = ref.watch(adminSessionProvider)?.adminCatalog;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 720),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (!_closing) {
                _closing = true;
                Navigator.of(context).pop();
              }
            },
          },
          child: CustomScrollView(
            shrinkWrap: true,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Find a feature',
                              style: TdTypography.titleSmall,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close search',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('global-search-input'),
                        controller: _text,
                        autofocus: true,
                        maxLength: 120,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.search,
                        decoration: const InputDecoration(
                          labelText: 'Feature, setting or API method',
                          prefixIcon: Icon(Icons.search),
                          counterText: '',
                        ),
                        onChanged: (value) => setState(() {
                          _matches = searchNavigation(value);
                          _selected = 0;
                        }),
                        onSubmitted: (_) => _open(),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Local navigation only. Opening a result does not submit an action. No server content is searched or saved.',
                        style: TdTypography.metadata.copyWith(
                          color: td.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _matches.isEmpty
                            ? 'No matching features.'
                            : '${_matches.length}${_matches.length == 50 ? '+' : ''} results · ↑ ↓ select · Enter open · Esc close',
                        style: TdTypography.metadata,
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Column(
                  children: List.generate(_matches.length, (index) {
                    final entry = _matches[index];
                    final operation = entry.operation;
                    final native =
                        entry.workspace != null ||
                        (operation != null &&
                            AdminOperationTile.nativePageForMethod(
                                  operation.method,
                                ) !=
                                null);
                    final unavailable = operation == null
                        ? null
                        : adminUnavailableReason(operation, catalog);
                    final label = native
                        ? 'Native workspace · availability checked on open'
                        : entry.domain != null
                        ? 'Administration area'
                        : unavailable != null
                        ? 'Unavailable · open explanation'
                        : 'Configuration page · review required';
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      child: Material(
                        color: index == _selected
                            ? td.actionPrimary.withValues(alpha: .12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          key: _rowKeys.putIfAbsent(
                            entry.id,
                            () => GlobalKey(debugLabel: entry.id),
                          ),
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => _open(entry),
                          child: Semantics(
                            key: ValueKey('search-result-${entry.id}'),
                            button: true,
                            selected: index == _selected,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.arrow_outward_rounded,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          entry.title,
                                          style: TdTypography.body.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        Text(
                                          label,
                                          style: TdTypography.metadata.copyWith(
                                            color: td.textSecondary,
                                          ),
                                        ),
                                        if (operation != null)
                                          Text(
                                            operation.method,
                                            style: TdTypography.metadata
                                                .copyWith(color: td.textMuted),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
