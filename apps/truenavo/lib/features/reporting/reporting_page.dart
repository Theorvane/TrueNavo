import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../offline_demo/offline_demo_mode.dart';
import 'reporting_chart.dart';
import 'reporting_controller.dart';

class ReportingPage extends ConsumerWidget {
  const ReportingPage({this.autoLoad = true, this.initialGraphName, super.key});
  final bool autoLoad;
  final String? initialGraphName;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final demo = ref.watch(offlineDemoModeProvider);
    final capabilities = ref
        .watch(reportingSessionProvider)
        ?.reportingCapabilities;
    final td = context.tdTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Reporting')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1320),
            child: ListView(
              padding: const EdgeInsets.all(TdSpacing.pageMobile),
              children: [
                const Text(
                  'Performance history',
                  style: TdTypography.titleLarge,
                ),
                const SizedBox(height: TdSpacing.related),
                Text(
                  session?.endpoint ?? 'No authenticated server endpoint',
                  style: TdTypography.metadata,
                ),
                const SizedBox(height: TdSpacing.component),
                if (session?.endpoint == null ||
                    capabilities?.connected != true)
                  const TdPanel(
                    title: 'Connect to load reporting',
                    child: Text(
                      'A live connection is required. No sample values are fabricated for offline servers.',
                    ),
                  )
                else if (capabilities?.supported != true)
                  TdPanel(
                    title: 'Reporting is unavailable',
                    child: Text(
                      capabilities?.blockedReason ?? 'This server has not advertised the reporting methods.',
                    ),
                  )
                else
                  _ReportingContent(
                    session: session!,
                    autoLoad: autoLoad,
                    initialGraphName: initialGraphName,
                  ),
                const SizedBox(height: TdSpacing.component),
                Text(
                  demo
                      ? 'Offline demonstration: generated CPU, memory, disk and network histories. These values are not measurements from a server.'
                      : 'History is a snapshot. Refresh to load newer samples. '
                            'Available CPU, memory, disk, network, temperature, ARC and UPS '
                            'graphs are discovered from this server. Only measured values are shown.',
                  style: TdTypography.metadata.copyWith(
                    color: td.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReportingContent extends ConsumerStatefulWidget {
  const _ReportingContent({
    required this.session,
    required this.autoLoad,
    required this.initialGraphName,
  });
  final AuthenticatedSession session;
  final bool autoLoad;
  final String? initialGraphName;
  @override
  ConsumerState<_ReportingContent> createState() => _ReportingContentState();
}

class _ReportingContentState extends ConsumerState<_ReportingContent> {
  bool _autoLoaded = false;
  @override
  void initState() {
    super.initState();
    if (widget.initialGraphName != null) {
      _clearPreviousSelectionAfterFrame();
    }
  }

  @override
  void didUpdateWidget(covariant _ReportingContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session) ||
        oldWidget.initialGraphName != widget.initialGraphName) {
      _autoLoaded = false;
    }
    if (oldWidget.initialGraphName != widget.initialGraphName &&
        widget.initialGraphName != null) {
      _clearPreviousSelectionAfterFrame();
    }
  }

  void _clearPreviousSelectionAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.initialGraphName != null) {
        ref.read(reportingControllerProvider.notifier).clearSelection();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final graphs = ref.watch(reportingGraphsProvider);
    final state = ref.watch(reportingControllerProvider);
    final controller = ref.read(reportingControllerProvider.notifier);
    return graphs.when(
      loading: () => const TdPanel(
        title: 'Discovering reporting graphs',
        child: LinearProgressIndicator(),
      ),
      error: (_, _) => TdPanel(
        title: 'Graph discovery failed',
        description: 'Available metrics could not be verified.',
        child: OutlinedButton.icon(
          onPressed: () => ref.invalidate(reportingGraphsProvider),
          icon: const Icon(Icons.refresh),
          label: const Text('Retry discovery'),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return const TdPanel(
            title: 'No reporting graphs returned',
            child: Text(
              'This server has not supplied any discoverable graphs. No zero values are substituted.',
            ),
          );
        }
        final available = items
            .where(
              (graph) => graph.supported && graph.identifiers?.isEmpty != true,
            )
            .toList();
        if (widget.autoLoad &&
            !_autoLoaded &&
            state.phase == ReportingPhase.idle &&
            available.isNotEmpty) {
          _autoLoaded = true;
          final requested = widget.initialGraphName;
          final graph = requested == null
              ? available.where((item) => item.name == 'cpu').firstOrNull ??
                    available.first
              : available.where((item) => item.name == requested).firstOrNull;
          if (graph != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted ||
                  !identical(
                    ref.read(dashboardActiveSessionProvider),
                    session,
                  ) ||
                  ref.read(reportingControllerProvider).phase !=
                      ReportingPhase.idle) {
                return;
              }
              controller.load(
                expectedSession: session,
                graph: graph,
                identifier: graph.identifiers?.firstOrNull,
              );
            });
          }
        }
        final selected = items
            .where((item) => item.name == state.graph?.name)
            .firstOrNull;
        final unavailable = items
            .where(
              (graph) => !graph.supported || graph.identifiers?.isEmpty == true,
            )
            .toList();
        Future<void> select(
          ReportingGraph graph, {
          String? identifier,
          ReportingRange? range,
        }) => controller.load(
          expectedSession: session,
          graph: graph,
          identifier: identifier ?? graph.identifiers?.firstOrNull,
          range: range ?? state.range,
          window: range == null ? state.window : null,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.initialGraphName != null &&
                available.every((item) => item.name != widget.initialGraphName))
              const TdPanel(
                title: 'Requested metric unavailable',
                child: Text(
                  'This server did not offer the requested graph. Choose another metric explicitly.',
                ),
              ),
            TdPanel(
              title: 'Metric & range',
              description: '${items.length} server graphs',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      'reporting-metric-${state.graph?.name ?? 'none'}',
                    ),
                    initialValue: selected?.name,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Metric'),
                    items: [
                      for (final graph in items)
                        DropdownMenuItem(
                          value: graph.name,
                          enabled:
                              graph.supported &&
                              graph.identifiers?.isEmpty != true,
                          child: Text(
                            '${_title(graph)}${unavailable.contains(graph) ? ' · unavailable' : ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: state.busy
                        ? null
                        : (name) {
                            if (name != null) {
                              select(
                                items.singleWhere((item) => item.name == name),
                              );
                            }
                          },
                  ),
                  if (selected?.identifiers != null &&
                      selected!.identifiers!.isNotEmpty) ...[
                    const SizedBox(height: TdSpacing.component),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'reporting-instance-${selected.name}-${state.identifier}',
                      ),
                      initialValue:
                          selected.identifiers!.contains(state.identifier)
                          ? state.identifier
                          : selected.identifiers!.first,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Instance'),
                      items: [
                        for (final identifier in selected.identifiers!)
                          DropdownMenuItem(
                            value: identifier,
                            child: Text(
                              identifier,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: state.busy
                          ? null
                          : (identifier) {
                              if (identifier != null) {
                                select(selected, identifier: identifier);
                              }
                            },
                    ),
                    const SizedBox(height: TdSpacing.related),
                    SelectableText(
                      state.identifier ?? selected.identifiers!.first,
                    ),
                  ],
                  const SizedBox(height: TdSpacing.component),
                  Wrap(
                    spacing: TdSpacing.related,
                    runSpacing: TdSpacing.related,
                    children: [
                      for (final range in ReportingRange.values)
                        ChoiceChip(
                          key: ValueKey('reporting-range-${range.name}'),
                          tooltip: range.label,
                          label: Text(switch (range) {
                            ReportingRange.hour => '1h',
                            ReportingRange.day => '24h',
                            ReportingRange.week => '7d',
                            ReportingRange.month => '30d',
                            ReportingRange.year => '1y',
                          }),
                          selected:
                              state.window == null && range == state.range,
                          onSelected: selected == null || state.busy
                              ? null
                              : (_) => select(
                                  selected,
                                  identifier: state.identifier,
                                  range: range,
                                ),
                        ),
                      OutlinedButton.icon(
                        key: const Key('reporting-custom-range'),
                        onPressed: selected == null || state.busy
                            ? null
                            : () async {
                                final now = ref
                                    .read(reportingClockProvider)()
                                    .toUtc();
                                final today = DateTime(
                                  now.year,
                                  now.month,
                                  now.day,
                                );
                                final chosen = await showDateRangePicker(
                                  context: context,
                                  firstDate: DateTime(1970, 1, 2),
                                  lastDate: today,
                                  helpText:
                                      'Reporting dates (UTC, up to 365 days)',
                                  initialDateRange: DateTimeRange(
                                    start: today.subtract(
                                      const Duration(days: 6),
                                    ),
                                    end: today,
                                  ),
                                );
                                if (chosen == null ||
                                    !mounted ||
                                    !context.mounted ||
                                    !identical(
                                      ref.read(dashboardActiveSessionProvider),
                                      session,
                                    )) {
                                  return;
                                }
                                final start = DateTime.utc(
                                  chosen.start.year,
                                  chosen.start.month,
                                  chosen.start.day,
                                );
                                var end = DateTime.utc(
                                  chosen.end.year,
                                  chosen.end.month,
                                  chosen.end.day,
                                ).add(const Duration(days: 1));
                                if (end.isAfter(now)) end = now;
                                final window = ReportingWindow(
                                  start: start,
                                  end: end,
                                );
                                if (!window.valid) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Choose a UTC interval from one minute to 365 days.',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                await controller.load(
                                  expectedSession: session,
                                  graph: selected,
                                  identifier: state.identifier,
                                  range: state.range,
                                  window: window,
                                );
                              },
                        icon: const Icon(Icons.date_range_rounded),
                        label: const Text('Custom dates'),
                      ),
                    ],
                  ),
                  if (state.requestedWindow case final window?) ...[
                    const SizedBox(height: TdSpacing.related),
                    Text(
                      '${reportingTimestamp(window.start)} → ${reportingTimestamp(window.end)}',
                      key: const Key('reporting-requested-window'),
                      style: TdTypography.metadata,
                    ),
                    Wrap(
                      spacing: TdSpacing.related,
                      runSpacing: TdSpacing.related,
                      children: [
                        TextButton.icon(
                          key: const Key('reporting-previous-period'),
                          onPressed: state.busy
                              ? null
                              : () => controller.movePeriod(forward: false),
                          icon: const Icon(Icons.chevron_left_rounded),
                          label: const Text('Earlier'),
                        ),
                        TextButton.icon(
                          key: const Key('reporting-next-period'),
                          onPressed:
                              state.busy ||
                                  !window.end.isBefore(
                                    ref.read(reportingClockProvider)().toUtc(),
                                  )
                              ? null
                              : () => controller.movePeriod(forward: true),
                          icon: const Icon(Icons.chevron_right_rounded),
                          label: const Text('Later'),
                        ),
                        if (state.window != null)
                          TextButton(
                            key: const Key('reporting-latest-period'),
                            onPressed: state.busy
                                ? null
                                : controller.returnToLatest,
                            child: Text('Latest · ${state.range.label}'),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: TdSpacing.related),
                  Wrap(
                    spacing: TdSpacing.related,
                    runSpacing: TdSpacing.related,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('reporting-refresh'),
                        onPressed: state.graph == null || state.busy
                            ? null
                            : controller.refresh,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Refresh history'),
                      ),
                      if (state.loadedAt case final loaded?)
                        Text(
                          'Loaded ${reportingTimestamp(loaded)}',
                          style: TdTypography.metadata,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: TdSpacing.component),
            if (state.phase == ReportingPhase.idle)
              const TdPanel(
                title: 'Choose a metric to begin',
                child: Text('No history has been requested yet.'),
              )
            else if (state.busy)
              const TdPanel(
                title: 'Loading server measurements',
                child: LinearProgressIndicator(),
              )
            else if (state.phase == ReportingPhase.failed ||
                state.phase == ReportingPhase.empty)
              TdPanel(
                title: state.phase == ReportingPhase.failed
                    ? 'History could not be loaded'
                    : 'No usable samples',
                child: Text(
                  state.message ??
                      'No verified reporting history is available.',
                ),
              )
            else
              for (var index = 0; index < state.histories.length; index++) ...[
                ReportingChart(
                  key: ValueKey(
                    'reporting-history-$index-${state.graph?.name}-${state.identifier}',
                  ),
                  history: state.histories[index],
                  title: state.graph == null
                      ? state.histories[index].graphName
                      : _title(state.graph!, state.histories[index].identifier),
                ),
                const SizedBox(height: TdSpacing.component),
              ],
            if (unavailable.isNotEmpty)
              Material(
                type: MaterialType.transparency,
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('Unavailable graphs (${unavailable.length})'),
                  children: [
                    for (final graph in unavailable)
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: TdSpacing.related,
                        ),
                        child: Text(
                          '${_title(graph)} · ${graph.blockedReason ?? 'No instances were reported by this server.'}',
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

String _title(ReportingGraph graph, [String? identifier]) =>
    graph.title.replaceAll('{identifier}', identifier ?? 'instance').trim();
