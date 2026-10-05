import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../email_settings/email_settings_page.dart';
import '../alert_settings/alert_settings_page.dart';
import 'alerts_controller.dart';
import 'alerts_dialog.dart';

class AlertsPage extends ConsumerStatefulWidget {
  const AlertsPage({super.key});
  @override
  ConsumerState<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends ConsumerState<AlertsPage> {
  bool _reviewing = false;
  String? _error;
  String _search = '', _severity = 'ALL', _status = 'ALL', _source = 'ALL';
  final _searchController = TextEditingController();
  @override
  void dispose() {
    _searchController.clear();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _open(
    AuthenticatedSession session,
    AlertInventory inventory,
    AlertSnapshot alert, {
    AlertAction? action,
  }) async {
    if (_reviewing) return;
    setState(() {
      _reviewing = true;
      _error = null;
    });
    final initial = WidgetsBinding.instance.lifecycleState;
    var expired = initial != null && initial != AppLifecycleState.resumed;
    final lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) expired = true;
      },
    );
    final watch = ref.listenManual(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) expired = true;
    });
    final inventoryWatch = ref.listenManual(alertsInventoryProvider, (_, b) {
      if (b.isLoading || !identical(inventory, b.asData?.value)) expired = true;
    });
    bool current() =>
        mounted &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(alertsInventoryProvider).isLoading &&
        identical(inventory, ref.read(alertsInventoryProvider).asData?.value);
    try {
      if (!current()) return;
      AlertReview? review;
      if (action != null) {
        final request = AlertRequest(
          inventory: inventory,
          action: action,
          alert: alert,
        );
        if (request.validationError != null) {
          setState(() => _error = request.validationError);
          return;
        }
        final api = ref.read(alertsSessionProvider);
        if (api == null) return;
        review = await api.reviewAlert(request);
        if (!identical(review.request, request) ||
            review.endpoint != session.endpoint) {
          throw StateError('Mismatching review');
        }
      }
      if (!mounted || !current()) return;
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertsDialog(
          session: session,
          inventory: inventory,
          alert: alert,
          review: review,
        ),
      );
      if (review == null || confirmed != true || !current()) return;
      await ref
          .read(alertsControllerProvider.notifier)
          .execute(
            expectedSession: session,
            review: review,
            confirmation: review.target,
          );
    } on Object {
      if (current()) {
        setState(
          () => _error = 'This alert could not be reviewed safely. No change was submitted. Reload current alerts.',
        );
      }
    } finally {
      lifecycle.dispose();
      watch.close();
      inventoryWatch.close();
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider),
        api = ref.watch(alertsSessionProvider),
        state = ref.watch(alertsControllerProvider),
        controller = ref.read(alertsControllerProvider.notifier),
        caps = api?.alertsCapabilities;
    final available = session?.endpoint != null && caps?.supported == true;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) {
        setState(() {
          _error = null;
          _search = '';
          _severity = 'ALL';
          _status = 'ALL';
          _source = 'ALL';
          _searchController.clear();
        });
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alerts'),
        actions: [
          IconButton(
            key: const Key('alerts-notification-services'),
            tooltip: 'Notification services',
            onPressed: !_reviewing
                ? () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => const AlertSettingsPage(),
                    ),
                  )
                : null,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            key: const Key('alerts-email-settings'),
            tooltip: 'Email delivery settings',
            onPressed: !_reviewing
                ? () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => const EmailSettingsPage(),
                    ),
                  )
                : null,
            icon: const Icon(Icons.alternate_email_rounded),
          ),
          IconButton(
            key: const Key('alerts-refresh'),
            tooltip: 'Reload visible alerts',
            onPressed: available && !state.locked && !_reviewing
                ? () => ref.invalidate(alertsInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: const Key('alerts-workspace-scroll'),
        padding: const EdgeInsets.all(20),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('SYSTEM · ALERTS', style: TdTypography.micro),
                const SizedBox(height: 8),
                const Text('Alert center', style: TdTypography.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'Inspect visible alert metadata and explicitly dismiss or restore supported plain alerts. Dismissed does not mean resolved.',
                ),
                const SizedBox(height: 20),
                if (state.result case final result?)
                  TdPanel(
                    title: 'Operation · ${result.outcome.name}',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(result.message),
                        if (controller.canAcknowledge)
                          TextButton(
                            onPressed: controller.acknowledgeAfterReconnect,
                            child: const Text(
                              'I inspected the original server; reload',
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_error != null) Text(_error!),
                if (!available)
                  TdPanel(
                    title: 'Alerts unavailable',
                    child: Text(
                      caps?.blockedReason ??
                          'Connect to inspect visible alerts.',
                    ),
                  )
                else
                  ref
                      .watch(alertsInventoryProvider)
                      .when(
                        skipLoadingOnRefresh: false,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => const TdPanel(
                          title: 'Alert inventory unavailable',
                          child: Text(
                            'Visible alert safety information could not be validated. Remote details were withheld. No alert operation was attempted.',
                          ),
                        ),
                        data: (inventory) {
                          final sources =
                              inventory.alerts
                                  .map((a) => a.sourceLabel)
                                  .toSet()
                                  .toList()
                                ..sort();
                          final effectiveSource = sources.contains(_source)
                              ? _source
                              : 'ALL';
                          final rows = inventory.alerts
                              .where(
                                (a) =>
                                    (_severity == 'ALL' ||
                                        a.level == _severity) &&
                                    (_status == 'ALL' ||
                                        a.dismissed ==
                                            (_status == 'DISMISSED')) &&
                                    (effectiveSource == 'ALL' ||
                                        a.sourceLabel == effectiveSource) &&
                                    '${a.title} ${a.sourceLabel} ${a.id} ${a.category}'
                                        .toLowerCase()
                                        .contains(_search.toLowerCase()),
                              )
                              .toList();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _AlertsOverview(inventory: inventory),
                              const SizedBox(height: 16),
                              if (inventory.failoverLicensed)
                                const TdPanel(
                                  title: 'HA display-only',
                                  child: Text(
                                    'Coordinate controller alert changes in TrueNAS. Native actions are disabled for licensed HA systems.',
                                  ),
                                ),
                              TextField(
                                key: const Key('alerts-search'),
                                controller: _searchController,
                                autocorrect: false,
                                enableSuggestions: false,
                                decoration: const InputDecoration(
                                  labelText:
                                      'Search safe title, source or UUID',
                                  prefixIcon: Icon(Icons.search_rounded),
                                ),
                                onChanged: (v) => setState(() => _search = v),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  _filter(
                                    'severity',
                                    'Severity',
                                    _severity,
                                    const [
                                      'ALL',
                                      'INFO',
                                      'NOTICE',
                                      'WARNING',
                                      'ERROR',
                                      'CRITICAL',
                                      'ALERT',
                                      'EMERGENCY',
                                    ],
                                    (v) => _severity = v,
                                  ),
                                  _filter(
                                    'status',
                                    'Visibility',
                                    _status,
                                    const ['ALL', 'ACTIVE', 'DISMISSED'],
                                    (v) => _status = v,
                                  ),
                                  _filter('source', 'Source', effectiveSource, [
                                    'ALL',
                                    ...sources,
                                  ], (v) => _source = v),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                '${rows.length} matching / ${inventory.alerts.length} visible alerts',
                              ),
                              const SizedBox(height: 12),
                              if (rows.isEmpty)
                                const TdPanel(
                                  title: 'No matching visible alerts',
                                  child: Text(
                                    'This is not proof that the system is healthy. Product and NEVER-policy filters can omit alerts.',
                                  ),
                                ),
                              for (final alert in rows)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: TdPanel(
                                    title: alert.title,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(
                                          '${alert.level} · ${alert.dismissed ? 'Dismissed' : 'Active'} · ${alert.category}',
                                        ),
                                        Text(
                                          '${alert.sourceLabel} · ${alert.node}',
                                        ),
                                        Text(
                                          'Last occurrence: ${alert.lastSeen.toUtc().toIso8601String()}',
                                        ),
                                        if (alert.blockedReason
                                            case final reason?)
                                          Text(reason),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            TextButton(
                                              key: Key(
                                                'alerts-details-${alert.id}',
                                              ),
                                              onPressed: !_reviewing
                                                  ? () => _open(
                                                      session!,
                                                      inventory,
                                                      alert,
                                                    )
                                                  : null,
                                              child: const Text('Details'),
                                            ),
                                            TextButton(
                                              key: Key(
                                                'alerts-change-${alert.id}',
                                              ),
                                              onPressed:
                                                  !state.locked &&
                                                      !_reviewing &&
                                                      !inventory
                                                          .failoverLicensed &&
                                                      alert.supported &&
                                                      caps!.allows(
                                                        alert.dismissed
                                                            ? AlertAction
                                                                  .restore
                                                            : AlertAction
                                                                  .dismiss,
                                                      )
                                                  ? () => _open(
                                                      session!,
                                                      inventory,
                                                      alert,
                                                      action: alert.dismissed
                                                          ? AlertAction.restore
                                                          : AlertAction.dismiss,
                                                    )
                                                  : null,
                                              child: Text(
                                                alert.dismissed
                                                    ? 'Restore'
                                                    : 'Dismiss',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              const TdPanel(
                                title: 'Native scope',
                                child: Text(
                                  'Audited plain alert classes on standalone systems only. One-shot, custom dismissal, bulk operations, alert policy/service configuration and live event subscriptions remain in TrueNAS. Raw descriptions and arbitrary HTML are never rendered.',
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _filter(
    String key,
    String label,
    String value,
    List<String> items,
    void Function(String) update,
  ) => SizedBox(
    width: 220,
    child: DropdownButtonFormField<String>(
      key: Key('alerts-filter-$key-$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: items
          .map((v) => DropdownMenuItem(value: v, child: Text(v)))
          .toList(),
      onChanged: (v) {
        if (v != null) setState(() => update(v));
      },
    ),
  );
}

class _AlertsOverview extends StatelessWidget {
  const _AlertsOverview({required this.inventory});
  final AlertInventory inventory;
  @override
  Widget build(BuildContext context) {
    final total = inventory.alerts.length,
        dismissed = inventory.alerts.where((a) => a.dismissed).length,
        colors = Theme.of(context).colorScheme;
    final sources = <String, int>{};
    for (final a in inventory.alerts) {
      sources.update(a.sourceLabel, (n) => n + 1, ifAbsent: () => 1);
    }
    final ranked = sources.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return TdPanel(
      title: 'Visible alert distribution',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Counts describe the current server-filtered list, not all underlying problems.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 28,
            runSpacing: 20,
            children: [
              SizedBox(
                width: 220,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      label:
                          '$total visible alerts, ${total - dismissed} active, $dismissed dismissed',
                      child: SizedBox(
                        width: 112,
                        height: 112,
                        child: CustomPaint(
                          key: const Key('alerts-status-chart'),
                          painter: _AlertsDonut(
                            total == 0 ? 0 : dismissed / total,
                            colors.primary,
                            colors.surfaceContainerHighest,
                          ),
                          child: Center(
                            child: Text(
                              '$total',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _statusLegend(
                      'active',
                      'Active · ${total - dismissed}',
                      colors.surfaceContainerHighest,
                    ),
                    const SizedBox(height: 4),
                    _statusLegend(
                      'dismissed',
                      'Dismissed · $dismissed',
                      colors.primary,
                    ),
                    const SizedBox(height: 4),
                    const Text('Dismissed ≠ resolved'),
                  ],
                ),
              ),
              SizedBox(
                width: 220,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Severity · all visible'),
                    for (final level in const [
                      'EMERGENCY',
                      'ALERT',
                      'CRITICAL',
                      'ERROR',
                      'WARNING',
                      'NOTICE',
                      'INFO',
                    ])
                      _bar(
                        context,
                        level,
                        inventory.alerts.where((a) => a.level == level).length,
                        total,
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: 220,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Sources · all visible'),
                    if (ranked.isEmpty) const Text('No visible sources'),
                    for (final e in ranked.take(6))
                      _bar(context, e.key, e.value, total),
                    if (ranked.length > 6)
                      Text(
                        '${ranked.length - 6} additional sources available in filters',
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusLegend(String status, String label, Color color) => Row(
    children: [
      SizedBox(
        width: 12,
        height: 12,
        child: DecoratedBox(
          key: Key('alerts-status-legend-$status'),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(label)),
    ],
  );

  Widget _bar(BuildContext context, String label, int count, int total) =>
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Semantics(
          label: '$label: $count visible alerts',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('$label · $count'),
              const SizedBox(height: 3),
              LinearProgressIndicator(value: total == 0 ? 0 : count / total),
            ],
          ),
        ),
      );
}

class _AlertsDonut extends CustomPainter {
  const _AlertsDonut(this.value, this.foreground, this.background);
  final double value;
  final Color foreground, background;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(6, 6, size.width - 12, size.height - 12),
        paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2,
      false,
      paint..color = background,
    );
    if (value > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * value,
        false,
        paint..color = foreground,
      );
    }
  }

  @override
  bool shouldRepaint(_AlertsDonut old) =>
      old.value != value ||
      old.foreground != foreground ||
      old.background != background;
}
