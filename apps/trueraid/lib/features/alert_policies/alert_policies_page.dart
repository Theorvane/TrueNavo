import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'alert_policies_controller.dart';

const _visibilityWarning =
    'NEVER hides this class from normal alert lists and related events, as well as configured notification services. It is not a global mute: independent system mail and proactive support may still report it.';
const _supportWarning =
    'Proactive support can send automatic external tickets containing formatted alert details, appliance serial, software version, licensed customer/company and configured primary/secondary contact details. Resetting an explicit off override can restore reporting by default. No support contact, ticket or private identity is read here.';

class AlertPoliciesPage extends ConsumerStatefulWidget {
  const AlertPoliciesPage({super.key});
  @override
  ConsumerState<AlertPoliciesPage> createState() => _AlertPoliciesPageState();
}

class _AlertPoliciesPageState extends ConsumerState<AlertPoliciesPage> {
  bool _working = false, _ownModal = false, _abandoned = false;
  String _filter = '';
  int _limit = 50;
  late final AlertPoliciesController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(alertPoliciesControllerProvider.notifier);
  }

  @override
  void dispose() {
    _controller.abandonRoute();
    super.dispose();
  }

  bool get _routeCurrent =>
      mounted && ModalRoute.of(context)?.isCurrent == true;
  Future<T?> _modal<T>(WidgetBuilder builder) async {
    setState(() => _ownModal = true);
    final route = DialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: false,
    );
    try {
      final result = await Navigator.of(context).push(route);
      await route.completed;
      return result;
    } finally {
      if (mounted) setState(() => _ownModal = false);
    }
  }

  Future<void> _change(
    AuthenticatedSession session,
    AlertPoliciesInventory inventory,
    AlertClassPolicySnapshot selected,
    AlertPoliciesAction action,
  ) async {
    if (_working) return;
    setState(() => _working = true);
    var expired = false;
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expired = true;
      },
    );
    final sessions = ref.listenManual(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) expired = true;
    });
    final inventories = ref.listenManual(alertPoliciesInventoryProvider, (
      _,
      next,
    ) {
      if (next.isLoading || !identical(inventory, next.asData?.value)) {
        expired = true;
      }
    });
    bool current() =>
        _routeCurrent &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(alertPoliciesInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(alertPoliciesInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      final request = await _modal<AlertPoliciesRequest>(
        (_) => _PolicyEditor(
          session: session,
          inventory: inventory,
          selected: selected,
          action: action,
        ),
      );
      if (request == null || !current()) {
        _controller.expireContext();
        return;
      }
      final review = await _controller.review(
        expectedSession: session,
        request: request,
        isRouteCurrent: () => _routeCurrent,
      );
      if (!current()) {
        _controller.expireContext();
        return;
      }
      if (review == null) return;
      final confirmed = await _modal<bool>(
        (_) => _PolicyReview(session: session, review: review),
      );
      if (confirmed != true || !current()) {
        _controller.expireContext();
        return;
      }
      await _controller.execute(
        expectedSession: session,
        review: review,
        confirmation: review.target,
        configurationImpactAccepted: true,
        visibilityImpactAccepted: true,
        supportDisclosureAccepted: true,
        isRouteCurrent: () => _routeCurrent,
      );
    } finally {
      lifecycle.dispose();
      sessions.close();
      inventories.close();
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false && !_ownModal && !_abandoned) {
      _abandoned = true;
      _controller.abandonRoute();
    } else if (ModalRoute.isCurrentOf(context) == true) {
      _abandoned = false;
    }
    final session = ref.watch(dashboardActiveSessionProvider),
        api = ref.watch(alertPoliciesSessionProvider),
        state = ref.watch(alertPoliciesControllerProvider);
    final inventory = ref.watch(alertPoliciesInventoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Alert policies')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Severity, notification batching and class overrides',
              style: TdTypography.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Configuration only. These counts are not generated alerts, delivery timing, queue health or support outcomes. No test notification or support request is sent by this page.',
            ),
            const SizedBox(height: 16),
            if (state.message != null)
              TdPanel(
                title: state.unresolved
                    ? 'Inspect the original server'
                    : state.status == AlertPoliciesStatus.completed
                    ? 'Configuration verified'
                    : 'Policy status',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(state.message!),
                    if (state.server != null)
                      Text('Original server: ${state.server}'),
                    if (state.unresolved) ...[
                      const Text(
                        'Writes stay locked across navigation and reconnect. Reconnect manually to the original address, verify the same host, then independently inspect the full policies and any external reports. No automatic retry or replay.',
                      ),
                      OutlinedButton(
                        key: const Key('policy-verify'),
                        onPressed: _controller.canVerifyReconnectedServer
                            ? _controller.verifyReconnectedServer
                            : null,
                        child: const Text(
                          'Verify reconnected original host once',
                        ),
                      ),
                      if (state.verificationMessage != null)
                        Text(state.verificationMessage!),
                      OutlinedButton(
                        key: const Key('policy-acknowledge'),
                        onPressed: _controller.canAcknowledge
                            ? _controller.acknowledgeAfterReconnect
                            : null,
                        child: const Text(
                          'I inspected the original policies and reports; release app lock',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            if (!state.locked) ...[
              if (api == null || !api.alertPoliciesCapabilities.supported)
                Text(
                  api?.alertPoliciesCapabilities.blockedReason ??
                      'Connect to inspect alert policies.',
                ),
              inventory.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => const TdPanel(
                  title: 'Policy configuration unavailable',
                  child: Text(
                    'Configuration and class metadata could not be safely verified. Remote details were withheld. Use an explicit reload; there is no automatic retry.',
                  ),
                ),
                data: (value) {
                  final classes = value.classes
                      .where(
                        (c) => '${c.id} ${c.title} ${c.categoryTitle}'
                            .toLowerCase()
                            .contains(_filter.toLowerCase()),
                      )
                      .toList();
                  final canEdit =
                      session != null &&
                      api?.alertPoliciesCapabilities.canConfigure == true &&
                      value.blockedReason == null &&
                      !state.busy &&
                      !_working;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 16),
                      _PolicyCharts(classes: value.classes),
                      const SizedBox(height: 16),
                      TdPanel(
                        title: 'Current configuration',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Version: ${value.currentVersion} · ${value.readiness.state}',
                            ),
                            Text('Host: ${value.hostId}'),
                            Text(
                              'Support eligibility: ${value.supportAvailable ?? 'unknown'} · globally enabled: ${value.supportEnabled ?? 'unknown'}',
                            ),
                            Text(
                              '${value.unlistedOverrideCount} unlisted/hidden override rows are preserved without editing.',
                            ),
                            if (value.blockedReason != null)
                              Text(value.blockedReason!),
                            if (api?.alertPoliciesCapabilities.canConfigure !=
                                true)
                              const Text(
                                'Policy updates are unavailable for this connection; this view is read-only.',
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('policy-filter'),
                        decoration: const InputDecoration(
                          labelText: 'Filter class or category',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (v) => setState(() {
                          _filter = v;
                          _limit = 50;
                        }),
                      ),
                      const SizedBox(height: 12),
                      if (value.classes.isEmpty)
                        const TdPanel(
                          title: 'No editable alert classes',
                          child: Text(
                            'The server returned no listed alert classes. No policy defaults, alert count or delivery state is inferred.',
                          ),
                        ),
                      if (value.classes.isNotEmpty && classes.isEmpty)
                        const Text('No classes match this filter.'),
                      for (final c in classes.take(_limit))
                        Card(
                          child: ExpansionTile(
                            key: Key('policy-class-${c.id}'),
                            title: Text(c.title),
                            subtitle: Text(
                              '${c.categoryTitle} · ${c.effectiveLevel.name.toUpperCase()} · ${c.effectivePolicy.name.toUpperCase()}${c.hasOverride ? ' · overridden' : ''}',
                            ),
                            childrenPadding: const EdgeInsets.fromLTRB(
                              16,
                              0,
                              16,
                              16,
                            ),
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text('Class: ${c.id}'),
                                  Text(
                                    'Source severity: ${c.defaultLevel.name.toUpperCase()} · source policy: IMMEDIATELY',
                                  ),
                                  Text(
                                    'Level field: ${c.overrides.level?.name.toUpperCase() ?? 'absent (source default)'}',
                                  ),
                                  Text(
                                    'Policy field: ${c.overrides.policy?.name.toUpperCase() ?? 'absent (source default)'}',
                                  ),
                                  Text(
                                    'Proactive support: ${c.supportsProactiveSupport ? '${c.effectiveProactiveSupport} (class setting; global eligibility still required)' : 'unsupported by this class'}',
                                  ),
                                  if (c.effectivePolicy ==
                                      AlertPolicyFrequency.never)
                                    const Text(_visibilityWarning),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      FilledButton.tonal(
                                        key: Key('policy-edit-${c.id}'),
                                        onPressed: canEdit
                                            ? () => _change(
                                                session,
                                                value,
                                                c,
                                                AlertPoliciesAction.configure,
                                              )
                                            : null,
                                        child: const Text('Edit overrides'),
                                      ),
                                      OutlinedButton(
                                        key: Key('policy-reset-${c.id}'),
                                        onPressed: canEdit && c.hasOverride
                                            ? () => _change(
                                                session,
                                                value,
                                                c,
                                                AlertPoliciesAction.resetClass,
                                              )
                                            : null,
                                        child: const Text(
                                          'Reset this class only',
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      if (classes.length > _limit)
                        TextButton(
                          onPressed: () => setState(() => _limit += 50),
                          child: Text(
                            'Show more (${math.min(_limit, classes.length)} of ${classes.length})',
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const Key('policy-refresh'),
                onPressed: state.busy || _working
                    ? null
                    : _controller.refreshConfiguration,
                icon: const Icon(Icons.refresh),
                label: const Text('Read fresh configuration'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PolicyCharts extends StatelessWidget {
  const _PolicyCharts({required this.classes});
  final List<AlertClassPolicySnapshot> classes;
  @override
  Widget build(BuildContext context) {
    final overrides = classes.where((c) => c.hasOverride).length,
        colors = Theme.of(context).colorScheme;
    final groups = <String, int>{
      for (final p in AlertPolicyFrequency.values)
        'Policy ${p.name.toUpperCase()}': classes
            .where((c) => c.effectivePolicy == p)
            .length,
      for (final l in AlertDeliveryLevel.values)
        'Severity ${l.name.toUpperCase()}': classes
            .where((c) => c.effectiveLevel == l)
            .length,
    };
    return TdPanel(
      title: 'Configured class policies',
      description: 'Resolved defaults plus overrides — not live alerts or successful delivery.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 20,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                label:
                    '$overrides of ${classes.length} listed classes have stored overrides',
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: 100,
                    height: 100,
                    child: CustomPaint(
                      key: const Key('policy-override-ring'),
                      painter: _PolicyRing(
                        overrides,
                        classes.length,
                        colors.primary,
                        colors.outlineVariant,
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: FittedBox(
                            child: Text(
                              '${classes.length}',
                              style: TdTypography.metricMedium,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Text(
                '$overrides overridden\n${classes.length - overrides} using source defaults',
              ),
            ],
          ),
          if (classes.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'No listed classes; no percentages or delivery status inferred.',
              ),
            ),
          for (final e in groups.entries.where((e) => e.value > 0))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('${e.key}: ${e.value}'),
                  const SizedBox(height: 4),
                  ExcludeSemantics(
                    child: LinearProgressIndicator(
                      value: e.value / classes.length,
                      minHeight: 8,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PolicyRing extends CustomPainter {
  const _PolicyRing(this.overrides, this.total, this.color, this.track);
  final int overrides, total;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero),
        radius = math.min(size.width, size.height) / 2 - 7;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..color = track;
    canvas.drawCircle(center, radius, paint);
    if (total > 0 && overrides > 0) {
      paint.color = color;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        math.pi * 2 * overrides / total,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PolicyRing old) =>
      old.overrides != overrides ||
      old.total != total ||
      old.color != color ||
      old.track != track;
}

class _PolicyEditor extends ConsumerStatefulWidget {
  const _PolicyEditor({
    required this.session,
    required this.inventory,
    required this.selected,
    required this.action,
  });
  final AuthenticatedSession session;
  final AlertPoliciesInventory inventory;
  final AlertClassPolicySnapshot selected;
  final AlertPoliciesAction action;
  @override
  ConsumerState<_PolicyEditor> createState() => _PolicyEditorState();
}

class _PolicyEditorState extends ConsumerState<_PolicyEditor> {
  AlertDeliveryLevel? _level;
  AlertPolicyFrequency? _policy;
  bool? _support;
  bool _supportConsent = false, _expired = false, _closing = false;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _level = widget.selected.overrides.level;
    _policy = widget.selected.overrides.policy;
    _support = widget.selected.overrides.proactiveSupport;
    final state = WidgetsBinding.instance.lifecycleState;
    _expired = state != null && state != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _expire() {
    if (!mounted || _closing || _expired) return;
    setState(() {
      _expired = true;
      _supportConsent = false;
    });
    ref.read(alertPoliciesControllerProvider.notifier).expireContext();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(alertPoliciesInventoryProvider, (_, next) {
      if (next.isLoading || !identical(widget.inventory, next.asData?.value)) {
        _expire();
      }
    });
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      _supportConsent = false;
      ref.read(alertPoliciesControllerProvider.notifier).abandonRoute();
    }
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        identical(
          widget.inventory,
          ref.watch(alertPoliciesInventoryProvider).asData?.value,
        );
    final reset = widget.action == AlertPoliciesAction.resetClass;
    final request = AlertPoliciesRequest(
      inventory: widget.inventory,
      classPolicy: widget.selected,
      action: widget.action,
      overrides: reset
          ? null
          : AlertClassOverrides(
              level: _level,
              policy: _policy,
              proactiveSupport: _support,
            ),
      proactiveSupportDisclosureAccepted: _supportConsent,
    );
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('policy-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? reset
                          ? 'Reset selected class override'
                          : 'Edit class overrides'
                    : 'Policy draft expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'The connection, route or foreground context changed. Close this draft and reload.',
                )
              else ...[
                Text(widget.selected.title),
                Text('Class: ${widget.selected.id}'),
                if (reset)
                  const Text(
                    'Only this class override row is removed. Unrelated and unlisted overrides remain unchanged; source defaults replace all selected overrides.',
                  )
                else ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Severity override (Default preserves field absence)',
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ChoiceChip(
                        key: const Key('policy-level-default'),
                        label: Text(
                          'Default: ${widget.selected.defaultLevel.name.toUpperCase()}',
                        ),
                        selected: _level == null,
                        onSelected: (_) => setState(() => _level = null),
                      ),
                      for (final value in AlertDeliveryLevel.values)
                        ChoiceChip(
                          key: Key('policy-level-${value.name}'),
                          label: Text(value.name.toUpperCase()),
                          selected: _level == value,
                          onSelected: (_) => setState(() => _level = value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Notification policy override'),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ChoiceChip(
                        key: const Key('policy-frequency-default'),
                        label: const Text('Default: IMMEDIATELY'),
                        selected: _policy == null,
                        onSelected: (_) => setState(() => _policy = null),
                      ),
                      for (final value in AlertPolicyFrequency.values)
                        ChoiceChip(
                          key: Key('policy-frequency-${value.name}'),
                          label: Text(value.name.toUpperCase()),
                          selected: _policy == value,
                          onSelected: (_) => setState(() => _policy = value),
                        ),
                    ],
                  ),
                  if (widget.selected.supportsProactiveSupport) ...[
                    const SizedBox(height: 16),
                    const Text('Proactive support class override'),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final value in <bool?>[null, false, true])
                          ChoiceChip(
                            key: Key('policy-support-$value'),
                            label: Text(
                              value == null
                                  ? 'Default: enabled'
                                  : value
                                  ? 'Enabled'
                                  : 'Disabled',
                            ),
                            selected: _support == value,
                            onSelected: (_) => setState(() {
                              _support = value;
                              _supportConsent = false;
                            }),
                          ),
                      ],
                    ),
                  ],
                ],
                if ((request.afterOverrides.policy ??
                        AlertPolicyFrequency.immediately) ==
                    AlertPolicyFrequency.never)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text(_visibilityWarning),
                  ),
                if (request.changesProactiveSupport) ...[
                  const SizedBox(height: 16),
                  const Text(_supportWarning),
                  Text(
                    'Public support eligibility: ${widget.inventory.supportAvailable ?? 'unknown'} · globally enabled: ${widget.inventory.supportEnabled ?? 'unknown'}',
                  ),
                  CheckboxListTile(
                    key: const Key('policy-editor-support-consent'),
                    contentPadding: EdgeInsets.zero,
                    value: _supportConsent,
                    onChanged: (v) =>
                        setState(() => _supportConsent = v ?? false),
                    title: const Text(
                      'I acknowledge this proactive-support change and its external disclosure or loss-of-reporting effects.',
                    ),
                  ),
                ],
                if (request.validationError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(request.validationError!),
                  ),
              ],
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('policy-editor-cancel'),
                    onPressed: () {
                      _closing = true;
                      Navigator.pop(context);
                    },
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('policy-editor-review'),
                    onPressed: current && request.validationError == null
                        ? () {
                            _closing = true;
                            Navigator.pop(context, request);
                          }
                        : null,
                    child: const Text('Review change'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PolicyReview extends ConsumerStatefulWidget {
  const _PolicyReview({required this.session, required this.review});
  final AuthenticatedSession session;
  final AlertPoliciesReview review;
  @override
  ConsumerState<_PolicyReview> createState() => _PolicyReviewState();
}

class _PolicyReviewState extends ConsumerState<_PolicyReview> {
  final _target = TextEditingController();
  bool _impact = false,
      _visibility = false,
      _support = false,
      _expired = false,
      _closing = false;
  late final Timer _expiry;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _expired = state != null && state != AppLifecycleState.resumed;
    _expiry = Timer(const Duration(minutes: 5), _expire);
    _lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _expire() {
    if (!mounted || _closing || _expired) return;
    ref.read(alertPoliciesControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _impact = false;
      _visibility = false;
      _support = false;
      _target.clear();
    });
  }

  @override
  void dispose() {
    _expiry.cancel();
    _lifecycle.dispose();
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(alertPoliciesInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(widget.review.request.inventory, next.asData?.value)) {
        _expire();
      }
    });
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      _impact = false;
      _visibility = false;
      _support = false;
      ref.read(alertPoliciesControllerProvider.notifier).abandonRoute();
    }
    final state = ref.watch(alertPoliciesControllerProvider),
        request = widget.review.request,
        before = request.classPolicy,
        after = request.afterOverrides;
    final current =
        !_expired &&
        !_closing &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        identical(
          request.inventory,
          ref.watch(alertPoliciesInventoryProvider).asData?.value,
        ) &&
        ref
            .read(alertPoliciesControllerProvider.notifier)
            .isReviewCurrent(widget.review);
    final never =
        (after.policy ?? AlertPolicyFrequency.immediately) ==
        AlertPolicyFrequency.never;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('policy-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current ? 'Review alert policy' : 'Policy review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details are hidden. Close and begin a new review.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                Text('${before.title} · ${before.id}'),
                Text(
                  'Stored row: ${before.hasOverride ? 'present' : 'absent'} → ${request.action == AlertPoliciesAction.resetClass ? 'removed' : 'present'}',
                ),
                Text(
                  'Severity: ${before.overrides.level?.name.toUpperCase() ?? 'default'} → ${after.level?.name.toUpperCase() ?? 'default (${before.defaultLevel.name.toUpperCase()})'}',
                ),
                Text(
                  'Policy: ${before.overrides.policy?.name.toUpperCase() ?? 'default'} → ${after.policy?.name.toUpperCase() ?? 'default (IMMEDIATELY)'}',
                ),
                if (before.supportsProactiveSupport)
                  Text(
                    'Proactive support: ${before.overrides.proactiveSupport ?? 'default (enabled)'} → ${after.proactiveSupport ?? 'default (enabled)'}',
                  ),
                const SizedBox(height: 12),
                const Text(
                  'The complete override map is sent with unrelated rows and absent fields preserved. A write can precede an error. Configuration readback is not proof of notification delivery, a support ticket or recipient receipt.',
                ),
                if (never) ...[
                  const SizedBox(height: 12),
                  const Text(_visibilityWarning),
                ],
                if (request.changesProactiveSupport) ...[
                  const SizedBox(height: 12),
                  const Text(_supportWarning),
                ],
                ExpansionTile(
                  key: const Key('policy-review-details'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Source and safety details'),
                  children: [
                    for (final warning in widget.review.warnings)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(warning),
                      ),
                  ],
                ),
                const Text(
                  'This review is single-use and expires within five minutes. Type the exact full target.',
                ),
                SelectableText(widget.review.target),
                TextField(
                  key: const Key('policy-confirm-target'),
                  controller: _target,
                  minLines: 1,
                  maxLines: 8,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Exact confirmation target',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                CheckboxListTile(
                  key: const Key('policy-confirm-impact'),
                  contentPadding: EdgeInsets.zero,
                  value: _impact,
                  onChanged: (v) => setState(() => _impact = v ?? false),
                  title: const Text(
                    'I accept this class-policy change and its notification effects.',
                  ),
                ),
                if (never)
                  CheckboxListTile(
                    key: const Key('policy-confirm-visibility'),
                    contentPadding: EdgeInsets.zero,
                    value: _visibility,
                    onChanged: (v) => setState(() => _visibility = v ?? false),
                    title: const Text(
                      'I accept hiding this class from normal alert lists; NEVER is not a global mute.',
                    ),
                  ),
                if (request.changesProactiveSupport)
                  CheckboxListTile(
                    key: const Key('policy-confirm-support'),
                    contentPadding: EdgeInsets.zero,
                    value: _support,
                    onChanged: (v) => setState(() => _support = v ?? false),
                    title: const Text(
                      'I explicitly approve the proactive-support disclosure or loss-of-reporting effects.',
                    ),
                  ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('policy-review-cancel'),
                    onPressed: () {
                      _closing = true;
                      Navigator.pop(context, false);
                    },
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('policy-confirm-submit'),
                    onPressed:
                        current &&
                            !state.busy &&
                            !state.locked &&
                            _impact &&
                            (!never || _visibility) &&
                            (!request.changesProactiveSupport || _support) &&
                            _target.text == widget.review.target
                        ? () {
                            _closing = true;
                            Navigator.pop(context, true);
                          }
                        : null,
                    child: const Text('Apply reviewed policy'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
