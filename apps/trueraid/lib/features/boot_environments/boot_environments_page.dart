import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'boot_environment_review_dialog.dart';
import 'boot_environments_controller.dart';

class BootEnvironmentsPage extends ConsumerWidget {
  const BootEnvironmentsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final capabilities = ref
        .watch(bootEnvironmentsSessionProvider)
        ?.bootEnvironmentsCapabilities;
    return Scaffold(
      appBar: AppBar(title: const Text('Boot environments')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text('SYSTEM RECOVERY', style: TdTypography.micro),
                const SizedBox(height: 8),
                const Text('Boot environments', style: TdTypography.titleLarge),
                const SizedBox(height: 8),
                Text(session?.endpoint ?? 'No authenticated server'),
                const SizedBox(height: 12),
                const Text(
                  'Keep known working system versions and choose the '
                  'environment used on the next boot.',
                ),
                const SizedBox(height: 16),
                const BootEnvironmentsOperationBanner(),
                if (session?.endpoint == null ||
                    capabilities?.supported != true)
                  TdPanel(
                    title: 'Boot environments unavailable',
                    child: Text(
                      session?.endpoint == null
                          ? 'A live connection is required.'
                          : capabilities?.blockedReason ??
                                'Connect to a supported TrueNAS server.',
                    ),
                  )
                else
                  ref
                      .watch(bootEnvironmentsInventoryProvider)
                      .when(
                        skipLoadingOnRefresh: false,
                        skipLoadingOnReload: false,
                        loading: () => const LinearProgressIndicator(),
                        error: (error, _) => TdPanel(
                          title: 'Could not load boot environments',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                error is BootEnvironmentsException
                                    ? error.userMessage
                                    : 'Server details were withheld. Refresh '
                                          'to try again.',
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton(
                                key: const Key('boot-retry'),
                                onPressed: () => ref.invalidate(
                                  bootEnvironmentsInventoryProvider,
                                ),
                                child: const Text('Refresh environments'),
                              ),
                            ],
                          ),
                        ),
                        data: (inventory) => _BootInventory(
                          key: ObjectKey(session),
                          session: session!,
                          inventory: inventory,
                          capabilities: capabilities!,
                        ),
                      ),
                const SizedBox(height: 20),
                const Text(
                  'Boot environments contain the system installation. '
                  'Data pools are separate. Activating an environment schedules '
                  'it for the next boot; it does not reboot the server.',
                ),
                const SizedBox(height: 12),
                const Text('Renaming is unavailable on TrueNAS 25.10.'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BootInventory extends ConsumerStatefulWidget {
  const _BootInventory({
    required this.session,
    required this.inventory,
    required this.capabilities,
    super.key,
  });
  final AuthenticatedSession session;
  final BootEnvironmentInventory inventory;
  final BootEnvironmentsCapabilities capabilities;

  @override
  ConsumerState<_BootInventory> createState() => _BootInventoryState();
}

class _BootInventoryState extends ConsumerState<_BootInventory> {
  var _search = '';

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(bootEnvironmentsControllerProvider);
    final inventory = widget.inventory;
    final largestBytes = inventory.environments.fold<int>(
      0,
      (largest, item) => item.usedBytes > largest ? item.usedBytes : largest,
    );
    final visible = inventory.environments
        .where((item) => item.id.toLowerCase().contains(_search))
        .toList();
    final enabled = !state.locked && inventory.blockedReason == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (inventory.blockedReason != null) ...[
          TdPanel(
            title: 'Changes unavailable',
            child: Text(inventory.blockedReason!),
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          key: const Key('boot-search'),
          decoration: const InputDecoration(
            labelText: 'Search environments',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => _search = value.toLowerCase()),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('boot-refresh'),
            onPressed: state.busy
                ? null
                : () => ref.invalidate(bootEnvironmentsInventoryProvider),
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ),
        const SizedBox(height: 12),
        Text('${inventory.environments.length} boot environments'),
        const SizedBox(height: 8),
        const Text(
          'Bars compare reported sizes; shared blocks can appear in more '
          'than one environment.',
        ),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              inventory.environments.isEmpty
                  ? 'The server returned no boot environments.'
                  : 'No environments match your search.',
            ),
          ),
        for (final item in visible)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: TdPanel(
              key: Key('boot-environment-${item.id}'),
              title: item.id,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (item.active) const _Status('Current system'),
                      if (item.activated) const _Status('Next boot'),
                      if (item.keep) const _Status('Kept'),
                      if (!item.canActivate) const _Status('Cannot activate'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Created: ${item.created}'),
                  Text('Space used: ${_bytes(item.usedBytes)}'),
                  const SizedBox(height: 8),
                  Semantics(
                    key: Key('boot-space-label-${item.id}'),
                    label:
                        '${item.id}: ${_bytes(item.usedBytes)} reported space. '
                        'Bar relative to the largest reported environment.',
                    child: ExcludeSemantics(
                      child: LinearProgressIndicator(
                        key: Key('boot-space-${item.id}'),
                        value: largestBytes == 0
                            ? 0
                            : item.usedBytes / largestBytes,
                        minHeight: 6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('Dataset: ${item.dataset}'),
                  if (!item.canDelete) ...[
                    const SizedBox(height: 8),
                    Text(_deleteBlockedReason(item)),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final action in [
                        BootEnvironmentAction.clone,
                        BootEnvironmentAction.keep,
                        BootEnvironmentAction.activate,
                        BootEnvironmentAction.delete,
                      ])
                        OutlinedButton(
                          key: Key('boot-${action.name}-${item.id}'),
                          onPressed:
                              enabled &&
                                  widget.capabilities.supports(action) &&
                                  _allows(item, action)
                              ? () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => BootEnvironmentActionPage(
                                      session: widget.session,
                                      inventory: inventory,
                                      snapshot: item,
                                      action: action,
                                    ),
                                  ),
                                )
                              : null,
                          child: Text(_actionLabel(action, keep: !item.keep)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class BootEnvironmentsOperationBanner extends ConsumerWidget {
  const BootEnvironmentsOperationBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bootEnvironmentsControllerProvider);
    // Rebuild acknowledgement availability on reconnect as well.
    ref.watch(dashboardActiveSessionProvider);
    if (!state.busy && state.result == null) return const SizedBox.shrink();
    final controller = ref.read(bootEnvironmentsControllerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TdPanel(
        title: state.busy
            ? 'Applying boot environment change'
            : state.unknown
            ? 'Outcome needs verification'
            : state.result?.outcome == BootEnvironmentOutcome.verified
            ? 'Boot environment change verified'
            : 'Change not applied',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.server != null) Text('Original server: ${state.server}'),
            if (state.target != null) Text('Target: ${state.target}'),
            const SizedBox(height: 8),
            if (state.busy)
              const LinearProgressIndicator()
            else
              Text(state.result!.message),
            if (state.unknown && !state.connectionCurrent) ...[
              const SizedBox(height: 12),
              const Text(
                'Reconnect to the original server and inspect its boot '
                'environments before acknowledging this warning.',
              ),
              TextButton(
                key: const Key('boot-acknowledge-unknown'),
                onPressed: controller.canAcknowledge
                    ? controller.acknowledgeAfterReconnect
                    : null,
                child: const Text('I inspected the original server'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class BootEnvironmentActionPage extends ConsumerStatefulWidget {
  const BootEnvironmentActionPage({
    required this.session,
    required this.inventory,
    required this.snapshot,
    required this.action,
    super.key,
  });
  final AuthenticatedSession session;
  final BootEnvironmentInventory inventory;
  final BootEnvironmentSnapshot snapshot;
  final BootEnvironmentAction action;

  @override
  ConsumerState<BootEnvironmentActionPage> createState() =>
      _BootEnvironmentActionPageState();
}

class _BootEnvironmentActionPageState
    extends ConsumerState<BootEnvironmentActionPage> {
  final _name = TextEditingController();
  var _reviewing = false, _expired = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  BootEnvironmentRequest get _request => BootEnvironmentRequest(
    inventory: widget.inventory,
    snapshot: widget.snapshot,
    action: widget.action,
    targetName: widget.action == BootEnvironmentAction.clone
        ? _name.text
        : null,
    keep: widget.action == BootEnvironmentAction.keep
        ? !widget.snapshot.keep
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    if (!identical(session, widget.session)) {
      _expired = true;
      _name.clear();
    }
    final state = ref.watch(bootEnvironmentsControllerProvider);
    final title = _actionLabel(widget.action, keep: !widget.snapshot.keep);
    final capabilities = ref
        .watch(bootEnvironmentsSessionProvider)
        ?.bootEnvironmentsCapabilities;
    return Scaffold(
      appBar: AppBar(title: Text(_expired ? 'Connection changed' : title)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: _expired
                  ? [
                      const Text(
                        'This form has expired. Return to boot environments '
                        'and load the current server before starting again.',
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                    ]
                  : [
                      Text(title, style: TdTypography.titleLarge),
                      const SizedBox(height: 12),
                      Text('Server: ${widget.session.endpoint}'),
                      Text('Environment: ${widget.snapshot.id}'),
                      const SizedBox(height: 16),
                      const BootEnvironmentsOperationBanner(),
                      for (final line in _details(_request))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(line),
                        ),
                      if (widget.action == BootEnvironmentAction.clone) ...[
                        TextField(
                          key: const Key('boot-clone-name'),
                          controller: _name,
                          enabled: !_reviewing && !state.locked,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: 'New environment name',
                            helperText: 'Choose a unique name for the clone.',
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_error != null) ...[
                        Text(_error!, key: const Key('boot-action-error')),
                        const SizedBox(height: 12),
                      ],
                      if (_reviewing) const LinearProgressIndicator(),
                      FilledButton(
                        key: const Key('boot-action-review'),
                        onPressed:
                            !_reviewing &&
                                !state.locked &&
                                capabilities?.supports(widget.action) == true
                            ? _review
                            : null,
                        child: const Text('Review change'),
                      ),
                    ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _review() async {
    final request = _request;
    final error = request.validationError;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final api = ref.read(bootEnvironmentsSessionProvider);
    if (api == null || _expired) return;
    setState(() {
      _reviewing = true;
      _error = null;
    });
    BootEnvironmentReview review;
    try {
      review = await api.reviewBootEnvironment(request);
    } on BootEnvironmentsException catch (error) {
      if (mounted) setState(() => _error = error.userMessage);
      return;
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'The change could not be reviewed. '
              'Refresh boot environments and try again.',
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
    if (!mounted ||
        _expired ||
        !identical(widget.session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BootEnvironmentReviewDialog(
        session: widget.session,
        title: _actionLabel(request.action, keep: request.keep),
        target: request.targetName ?? request.snapshot.id,
        details: _details(request),
        confirmLabel: _actionLabel(request.action, keep: request.keep),
        acknowledgement: switch (request.action) {
          BootEnvironmentAction.activate => 'I understand this changes the environment selected for the next boot.',
          BootEnvironmentAction.delete =>
            'I understand this permanently removes this boot environment.',
          _ => null,
        },
      ),
    );
    if (!mounted || confirmed != true || _expired) return;
    await ref
        .read(bootEnvironmentsControllerProvider.notifier)
        .execute(expectedSession: widget.session, review: review);
    if (mounted &&
        !_expired &&
        ref.read(bootEnvironmentsControllerProvider).result?.outcome ==
            BootEnvironmentOutcome.verified) {
      Navigator.of(context).pop();
    }
  }
}

class _Status extends StatelessWidget {
  const _Status(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(label, style: TdTypography.label),
    ),
  );
}

bool _allows(BootEnvironmentSnapshot item, BootEnvironmentAction action) =>
    switch (action) {
      BootEnvironmentAction.clone => item.canClone,
      BootEnvironmentAction.keep => true,
      BootEnvironmentAction.activate => item.canActivateForNextBoot,
      BootEnvironmentAction.delete => item.canDelete,
      BootEnvironmentAction.rename => false,
    };

String _actionLabel(BootEnvironmentAction action, {bool? keep}) =>
    switch (action) {
      BootEnvironmentAction.clone => 'Clone environment',
      BootEnvironmentAction.keep => keep == false ? 'Remove keep' : 'Keep',
      BootEnvironmentAction.activate => 'Activate for next boot',
      BootEnvironmentAction.delete => 'Delete environment',
      BootEnvironmentAction.rename => 'Rename unavailable',
    };

List<String> _details(
  BootEnvironmentRequest request,
) => switch (request.action) {
  BootEnvironmentAction.clone => [
    'Create a separate boot environment from ${request.snapshot.id}.',
    'The clone will not become the current system or the next boot '
        'environment automatically.',
  ],
  BootEnvironmentAction.keep => [
    request.keep == true
        ? 'Keep this environment from automatic boot environment cleanup.'
        : 'Allow automatic cleanup to remove this environment when eligible.',
    'Current retention: ${request.snapshot.keep ? 'Kept' : 'Not kept'}. '
        'After change: ${request.keep == true ? 'Kept' : 'Not kept'}.',
  ],
  BootEnvironmentAction.activate => [
    'Select ${request.snapshot.id} as the environment used on the next boot.',
    'The current system continues running. This action does not reboot '
        'the server.',
    'A different system version may be incompatible with current system '
        'configuration. Check compatibility before booting it.',
  ],
  BootEnvironmentAction.delete => [
    'Permanently delete ${request.snapshot.id} and its boot environment '
        'dataset ${request.snapshot.dataset}.',
    'This removes this recovery option. It does not delete data pools.',
    'Current, next boot, kept, and incompatible environments are protected.',
  ],
  BootEnvironmentAction.rename => ['Renaming is unavailable on TrueNAS 25.10.'],
};

String _deleteBlockedReason(BootEnvironmentSnapshot item) => item.active
    ? 'The current system is protected from deletion.'
    : item.activated
    ? 'The environment selected for the next boot is protected from deletion.'
    : item.keep
    ? 'Remove keep before reviewing deletion.'
    : 'This environment is protected from deletion because it cannot activate.';

String _bytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble(), index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  return '${value.toStringAsFixed(index == 0 ? 0 : 1)} ${units[index]}';
}
