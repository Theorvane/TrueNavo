import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../dashboard/dashboard_repository.dart';
import '../datasets/dataset_properties_page.dart';
import '../server_profiles/server_profiles_controller.dart';
import 'management_controller.dart';

class ManagementPage extends ConsumerStatefulWidget {
  const ManagementPage({this.initialStorage = false, super.key});
  final bool initialStorage;

  @override
  ConsumerState<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends ConsumerState<ManagementPage> {
  late bool _storage = widget.initialStorage;
  String _filter = '';
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final repository = session?.repository;
    final manager = switch (repository) {
      final AuthenticatedSessionManagement manager => manager,
      _ => null,
    };
    final state = ref.watch(managementControllerProvider);
    final profile = ref.watch(serverProfilesControllerProvider).selectedProfile;
    final td = context.tdTheme;
    final capabilities = manager?.managementCapabilities;
    final serverLabel =
        profile?.normalizedEndpoint ?? session?.profileId ?? '—';
    return Scaffold(
      appBar: AppBar(title: const Text('Manage server')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(TdSpacing.pageMobile),
              children: [
                Text(
                  'CONTROL CENTER',
                  style: TdTypography.micro.copyWith(
                    color: td.actionPrimary,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: TdSpacing.inline),
                Text('Services & storage', style: TdTypography.titleLarge),
                const SizedBox(height: TdSpacing.related),
                Text(
                  profile?.displayName ?? 'No server selected',
                  style: TdTypography.titleSmall,
                ),
                Text(
                  serverLabel,
                  style: TdTypography.metadata.copyWith(
                    color: td.textSecondary,
                  ),
                ),
                const SizedBox(height: TdSpacing.group),
                if (state.phase != ManagementPhase.idle) ...[
                  _OperationStatus(state: state),
                  const SizedBox(height: TdSpacing.component),
                ],
                if (session == null ||
                    manager == null ||
                    capabilities?.connected != true)
                  const TdPanel(
                    title: 'A live connection is required',
                    description:
                        'Connect to the selected server before making changes. '
                        'Switching a saved profile does not reconnect it.',
                    child: Text(
                      'No management command can be sent from this screen.',
                    ),
                  )
                else if (capabilities?.versionSupported != true)
                  const TdPanel(
                    title: 'Management is not verified for this version',
                    description:
                        'Monitoring remains available. Write actions stay '
                        'disabled until this server version is explicitly supported.',
                    child: Text('No changes have been made.'),
                  )
                else ...[
                  Container(
                    padding: const EdgeInsets.all(TdSpacing.component),
                    decoration: BoxDecoration(
                      color: td.actionPrimary.withValues(alpha: .07),
                      borderRadius: BorderRadius.circular(TdRadius.card),
                      border: Border.all(
                        color: td.actionPrimary.withValues(alpha: .2),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.verified_user_outlined,
                          color: td.actionPrimary,
                        ),
                        const SizedBox(width: TdSpacing.related),
                        const Expanded(
                          child: Text(
                            'Every change requires confirmation. Your TrueNAS account '
                            'permissions still apply; availability does not grant access.',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: TdSpacing.group),
                  Wrap(
                    spacing: TdSpacing.related,
                    runSpacing: TdSpacing.inline,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ChoiceChip(
                        showCheckmark: false,
                        avatar: const Icon(Icons.dns_outlined, size: 18),
                        label: const Text('Services'),
                        selected: !_storage,
                        onSelected: (_) => setState(() {
                          _storage = false;
                          _filter = '';
                        }),
                      ),
                      ChoiceChip(
                        showCheckmark: false,
                        avatar: const Icon(Icons.storage_outlined, size: 18),
                        label: const Text('Storage'),
                        selected: _storage,
                        onSelected: (_) => setState(() {
                          _storage = true;
                          _filter = '';
                        }),
                      ),
                      IconButton(
                        tooltip: 'Refresh inventory',
                        onPressed: state.busy
                            ? null
                            : () => ref.invalidate(
                                dashboardLoadProvider(
                                  _storage ? 'storage' : 'workloads',
                                ),
                              ),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                      if (_storage)
                        OutlinedButton.icon(
                          key: const Key('management-dataset-properties'),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const DatasetPropertiesPage(),
                            ),
                          ),
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Edit properties'),
                        ),
                    ],
                  ),
                  const SizedBox(height: TdSpacing.component),
                  TextField(
                    key: ValueKey('management-search-$_storage'),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      labelText: _storage ? 'Find a dataset' : 'Find a service',
                    ),
                    onChanged: (value) =>
                        setState(() => _filter = value.toLowerCase()),
                  ),
                  const SizedBox(height: TdSpacing.component),
                  _inventory(session, capabilities!, state.busy, serverLabel),
                  const SizedBox(height: TdSpacing.group),
                  Text(
                    'Scope: service lifecycle, child datasets and single snapshots. '
                    'Pool destruction, recursive deletion, disks, networking and '
                    'system updates are not exposed.',
                    style: TdTypography.metadata.copyWith(color: td.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _inventory(
    AuthenticatedSession session,
    ManagementCapabilities capabilities,
    bool busy,
    String serverLabel,
  ) {
    final load = ref.watch(
      dashboardLoadProvider(_storage ? 'storage' : 'workloads'),
    );
    return load.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(TdSpacing.group),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => const TdPanel(
        title: 'Inventory could not be verified',
        child: Text('Refresh to load exact targets before making changes.'),
      ),
      data: (result) {
        if (result case DashboardData(value: DashboardWorkloads workloads)) {
          if (!workloads.servicesAvailable) return _unavailable();
          final services = workloads.services
              .where((item) => item.name.toLowerCase().contains(_filter))
              .toList();
          return TdPanel(
            title: 'Service lifecycle',
            description:
                'Start, stop or restart individual system services. '
                'Stopping a service can disconnect its clients.',
            child: services.isEmpty
                ? const Text('No services match this view.')
                : Column(
                    children: [
                      for (final service in services) ...[
                        _service(
                          service,
                          session,
                          capabilities,
                          busy,
                          serverLabel,
                        ),
                        if (service != services.last)
                          const Divider(height: TdSpacing.group),
                      ],
                    ],
                  ),
          );
        }
        if (result case DashboardData(value: DashboardStorage storage)) {
          if (!storage.datasetsAvailable) return _unavailable();
          final datasets = storage.datasets
              .where((item) => item.name.toLowerCase().contains(_filter))
              .toList();
          return TdPanel(
            title: 'Datasets & snapshots',
            description:
                'Choose an existing dataset as the exact target or '
                'parent. Inventory shows up to 50 entries.',
            child: datasets.isEmpty
                ? const Text(
                    'No datasets match this view. Create a pool in the '
                    'TrueNAS web interface if this server has no datasets yet.',
                  )
                : Column(
                    children: [
                      for (final dataset in datasets) ...[
                        _dataset(
                          dataset,
                          session,
                          capabilities,
                          busy,
                          serverLabel,
                        ),
                        if (dataset != datasets.last)
                          const Divider(height: TdSpacing.group),
                      ],
                    ],
                  ),
          );
        }
        return _unavailable();
      },
    );
  }

  Widget _unavailable() => const TdPanel(
    title: 'No verified inventory',
    child: Text(
      'This server did not provide usable targets. Refresh the '
      'connection or check your account permissions.',
    ),
  );

  Widget _service(
    DashboardService service,
    AuthenticatedSession session,
    ManagementCapabilities capabilities,
    bool busy,
    String serverLabel,
  ) {
    final id = service.managementId;
    final running = service.status.toUpperCase() == 'RUNNING';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: TdSpacing.related,
          runSpacing: TdSpacing.inline,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(service.name, style: TdTypography.titleSmall),
            TdStatusBadge(
              status: running ? TdStatus.success : TdStatus.neutral,
              label: service.status,
            ),
          ],
        ),
        const SizedBox(height: TdSpacing.related),
        Wrap(
          spacing: TdSpacing.related,
          runSpacing: TdSpacing.inline,
          children: [
            for (final action in ServiceControlAction.values)
              OutlinedButton.icon(
                key: ValueKey('service-${service.name}-${action.name}'),
                onPressed:
                    busy ||
                        id == null ||
                        !capabilities.supports(switch (action) {
                          ServiceControlAction.start =>
                            ManagementAction.serviceStart,
                          ServiceControlAction.stop =>
                            ManagementAction.serviceStop,
                          ServiceControlAction.restart =>
                            ManagementAction.serviceRestart,
                        })
                    ? null
                    : () => _confirm(
                        session,
                        serverLabel,
                        ServiceControlCommand(service: id, action: action),
                      ),
                icon: Icon(switch (action) {
                  ServiceControlAction.start => Icons.play_arrow_rounded,
                  ServiceControlAction.stop => Icons.stop_rounded,
                  ServiceControlAction.restart => Icons.restart_alt_rounded,
                }, size: 18),
                label: Text(switch (action) {
                  ServiceControlAction.start => 'Start',
                  ServiceControlAction.stop => 'Stop',
                  ServiceControlAction.restart => 'Restart',
                }),
              ),
          ],
        ),
        if (id == null)
          const Text('Exact service identity could not be verified.'),
        if (!capabilities.supports(ManagementAction.serviceStart) &&
            !capabilities.supports(ManagementAction.serviceStop) &&
            !capabilities.supports(ManagementAction.serviceRestart))
          const Text('Service control is not advertised by this server.'),
      ],
    );
  }

  Widget _dataset(
    DashboardDataset dataset,
    AuthenticatedSession session,
    ManagementCapabilities capabilities,
    bool busy,
    String serverLabel,
  ) {
    final id = dataset.managementId;
    final root = id?.contains('/') != true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              root ? Icons.storage_outlined : Icons.folder_outlined,
              size: 22,
              color: context.tdTheme.actionPrimary,
            ),
            const SizedBox(width: TdSpacing.related),
            Expanded(child: Text(dataset.name, style: TdTypography.titleSmall)),
          ],
        ),
        const SizedBox(height: TdSpacing.related),
        Wrap(
          spacing: TdSpacing.related,
          runSpacing: TdSpacing.inline,
          children: [
            OutlinedButton.icon(
              key: ValueKey('dataset-create-${dataset.name}'),
              onPressed:
                  busy ||
                      id == null ||
                      !capabilities.supports(ManagementAction.datasetCreate)
                  ? null
                  : () => _name(session, serverLabel, id, snapshot: false),
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('Child dataset'),
            ),
            OutlinedButton.icon(
              key: ValueKey('snapshot-create-${dataset.name}'),
              onPressed:
                  busy ||
                      id == null ||
                      !capabilities.supports(ManagementAction.snapshotCreate)
                  ? null
                  : () => _name(session, serverLabel, id, snapshot: true),
              icon: const Icon(Icons.camera_alt_outlined, size: 18),
              label: const Text('Snapshot'),
            ),
            TextButton.icon(
              key: ValueKey('dataset-delete-${dataset.name}'),
              style: TextButton.styleFrom(
                foregroundColor: context.tdTheme.statusCritical,
              ),
              onPressed:
                  busy ||
                      id == null ||
                      root ||
                      !capabilities.supports(ManagementAction.datasetDelete)
                  ? null
                  : () => _confirm(
                      session,
                      serverLabel,
                      DeleteDatasetCommand(dataset: id),
                    ),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Delete'),
            ),
          ],
        ),
        if (root && id != null)
          const Text('Pool roots cannot be deleted here.'),
        if (id == null)
          const Text('Exact dataset identity could not be verified.'),
        if (!capabilities.supports(ManagementAction.datasetDelete) && !root)
          const Text('Safe deletion checks are unavailable on this server.'),
      ],
    );
  }

  Future<void> _name(
    AuthenticatedSession session,
    String serverLabel,
    String dataset, {
    required bool snapshot,
  }) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(dataset: dataset, snapshot: snapshot),
    );
    if (!mounted || name == null) return;
    await _confirm(
      session,
      serverLabel,
      snapshot
          ? CreateSnapshotCommand(dataset: dataset, name: name)
          : CreateDatasetCommand(parent: dataset, name: name),
    );
  }

  Future<void> _confirm(
    AuthenticatedSession session,
    String serverLabel,
    ManagementCommand command,
  ) async {
    if (ref.read(managementControllerProvider).busy) return;
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ManagementConfirmationDialog(
        command: command,
        serverLabel: serverLabel,
      ),
    );
    if (!mounted || approved != true) return;
    final submission = ref
        .read(managementControllerProvider.notifier)
        .execute(
          expectedSession: session,
          serverLabel: serverLabel,
          command: command,
        );
    if (_scroll.hasClients) {
      await _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
    await submission;
  }
}

String managementActionLabel(ManagementAction action) => switch (action) {
  ManagementAction.serviceStart => 'Start service',
  ManagementAction.serviceStop => 'Stop service',
  ManagementAction.serviceRestart => 'Restart service',
  ManagementAction.datasetCreate => 'Create dataset',
  ManagementAction.datasetDelete => 'Delete dataset',
  ManagementAction.snapshotCreate => 'Create snapshot',
};

class ManagementConfirmationDialog extends StatefulWidget {
  const ManagementConfirmationDialog({
    required this.command,
    required this.serverLabel,
    super.key,
  });
  final ManagementCommand command;
  final String serverLabel;

  @override
  State<ManagementConfirmationDialog> createState() =>
      _ManagementConfirmationDialogState();
}

class _ManagementConfirmationDialogState
    extends State<ManagementConfirmationDialog> {
  String _typedTarget = '';

  @override
  Widget build(BuildContext context) {
    final command = widget.command;
    final deleting = command.managementAction == ManagementAction.datasetDelete;
    return AlertDialog(
      scrollable: true,
      title: Text('${managementActionLabel(command.managementAction)}?'),
      content: SizedBox(
        width: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SERVER', style: TdTypography.micro),
            SelectableText(widget.serverLabel),
            const SizedBox(height: TdSpacing.component),
            const Text('EXACT TARGET', style: TdTypography.micro),
            SelectableText(command.target, style: TdTypography.titleSmall),
            const SizedBox(height: TdSpacing.component),
            Text(switch (command.managementAction) {
              ManagementAction.serviceStart => 'This enables the service now. It does not change its boot setting.',
              ManagementAction.serviceStop => 'Active clients may lose access immediately. Stopping SSH can disconnect remote administration.',
              ManagementAction.serviceRestart => 'Active clients may be disconnected while this service restarts.',
              ManagementAction.datasetCreate => 'Creates one filesystem dataset with inherited defaults. No share or permissions are added.',
              ManagementAction.snapshotCreate => 'Creates one non-recursive snapshot. A snapshot is not an independent backup.',
              ManagementAction.datasetDelete =>
                'Permanently deletes this dataset and its files. This cannot be undone. '
                    'Pool roots and system datasets are blocked. Recursive and forced '
                    'deletion are disabled; attached resources must be removed separately. '
                    'Do not add shares or tasks during deletion: dependency checks are '
                    'not atomic and newly attached resources could be removed by TrueNAS.',
            }),
            if (deleting) ...[
              const SizedBox(height: TdSpacing.component),
              TextField(
                key: const Key('delete-confirm-target'),
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Type the exact target to confirm',
                ),
                onChanged: (value) => setState(() => _typedTarget = value),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('management-confirm'),
          style: deleting
              ? FilledButton.styleFrom(
                  backgroundColor: context.tdTheme.statusCritical,
                )
              : null,
          onPressed: deleting && _typedTarget != command.target
              ? null
              : () => Navigator.pop(context, true),
          child: Text(managementActionLabel(command.managementAction)),
        ),
      ],
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.dataset, required this.snapshot});
  final String dataset;
  final bool snapshot;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.snapshot ? 'New snapshot' : 'New child dataset'),
    content: SizedBox(
      width: 460,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.snapshot ? 'Dataset' : 'Parent'}: ${widget.dataset}',
            ),
            const SizedBox(height: TdSpacing.component),
            TextFormField(
              key: const Key('management-name'),
              controller: _name,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 64,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'Letters, numbers, dot, dash or underscore.',
              ),
              validator: (value) =>
                  value != null &&
                      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$')
                          .hasMatch(value)
                  ? null
                  : 'Enter a name starting with a letter or number.',
            ),
            const SizedBox(height: TdSpacing.inline),
            const Text(
              'You will review the full target before anything is sent.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, _name.text);
          }
        },
        child: const Text('Review'),
      ),
    ],
  );
}

class _OperationStatus extends StatelessWidget {
  const _OperationStatus({required this.state});
  final ManagementState state;

  int? get _jobId => switch (state.result) {
    ManagementJobSubmitted(:final jobId) => jobId,
    ManagementOutcomeUnknown(:final jobId) => jobId,
    _ => null,
  };

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: TdPanel(
      title: switch (state.phase) {
        ManagementPhase.running => 'Operation in progress',
        ManagementPhase.completed => 'Change completed',
        ManagementPhase.failed => 'Change not completed',
        _ => 'Result needs verification',
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: TdSpacing.related),
          ],
          Text('${state.serverLabel}'),
          if (_jobId case final jobId?)
            Text('Job #$jobId', key: const Key('management-job-id')),
          if (state.command case final command?)
            Text(
              '${managementActionLabel(command.managementAction)} · ${command.target}',
              style: TdTypography.titleSmall,
            ),
          const SizedBox(height: TdSpacing.related),
          Text(state.message ?? ''),
        ],
      ),
    ),
  );
}
