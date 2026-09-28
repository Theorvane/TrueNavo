import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../dashboard/dashboard_controller.dart';
import '../server_profiles/server_profiles_controller.dart';
import 'admin_controller.dart';
import 'admin_schema_form.dart';
import 'admin_workspace.dart' show adminUnavailableReason;

class AdminOperationPage extends ConsumerStatefulWidget {
  const AdminOperationPage({required this.operation, super.key});
  final AdminOperationDefinition operation;
  @override
  ConsumerState<AdminOperationPage> createState() => _AdminOperationPageState();
}

class _AdminOperationPageState extends ConsumerState<AdminOperationPage> {
  var _formKey = GlobalKey<AdminSchemaFormState>();
  AdminMethodSpec? _formMethod;
  final _scroll = ScrollController();
  bool _reviewing = false;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(adminSessionProvider)?.adminCatalog;
    final method = catalog?.method(widget.operation.method);
    // Inputs and secrets are never carried into a different server's schema.
    if (!identical(method, _formMethod)) {
      _formMethod = method;
      _formKey = GlobalKey<AdminSchemaFormState>();
    }
    final state = ref.watch(adminControllerProvider);
    final sameConnection = identical(
      ref.read(adminControllerProvider.notifier).operationSession,
      ref.watch(dashboardActiveSessionProvider),
    );
    final profile = ref.watch(serverProfilesControllerProvider).selectedProfile;
    final unavailable = switch (widget.operation.method) {
      'nvmet.subsys.create' => 'Use the dedicated NVMe-oF workflow.',
      'nvmet.subsys.delete' => 'Use the dedicated NVMe-oF workflow.',
      'nvmet.subsys.update' => 'Use the dedicated NVMe-oF workflow.',
      'nvmet.host_subsys.delete' => 'Use the dedicated NVMe-oF workflow.',
      'nvmet.host_subsys.create' => 'Use the dedicated NVMe-oF workflow.',
      'nvmet.host.delete' => 'Use the dedicated NVMe-oF workflow.',
      'nvmet.host.create' =>
        'Use the dedicated secret-stripping NVMe-oF workflow.',
      'nvmet.port_subsys.delete' => 'Use the dedicated NVMe-oF workflow.',
      'nvmet.port_subsys.create' => 'Use the dedicated NVMe-oF workflow.',
      'nvmet.port.delete' => 'Use the dedicated NVMe-oF workflow.',
      'nvmet.namespace.delete' => 'Use the dedicated NVMe-oF workflow.',
      'iscsi.global.update' ||
      'iscsi.portal.listen_ip_choices' ||
      'iscsi.portal.update' ||
      'iscsi.portal.create' ||
      'iscsi.portal.delete' ||
      'iscsi.extent.get_instance' ||
      'iscsi.extent.update' ||
      'iscsi.target.validate_name' ||
      'iscsi.target.create' ||
      'iscsi.target.delete' ||
      'iscsi.target.update' ||
      'iscsi.target.get_instance' ||
      'iscsi.initiator.update' ||
      'iscsi.targetextent.create' ||
      'iscsi.targetextent.delete' ||
      'iscsi.targetextent.update' => 'Use the dedicated iSCSI workflow.',
      'iscsi.initiator.create' => 'Use the dedicated iSCSI workflow.',
      'iscsi.initiator.delete' => 'Use the dedicated iSCSI workflow.',
      _ => adminUnavailableReason(widget.operation, catalog),
    };
    final td = context.tdTheme;
    final ownResult =
        state.operation?.id == widget.operation.id &&
        state.serverLabel == profile?.normalizedEndpoint;
    return Scaffold(
      appBar: AppBar(title: Text(widget.operation.title)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(TdSpacing.pageMobile),
              children: [
                Text(
                  widget.operation.domain.label.toUpperCase(),
                  style: TdTypography.micro.copyWith(
                    color: td.actionPrimary,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: TdSpacing.inline),
                Text(widget.operation.title, style: TdTypography.titleLarge),
                const SizedBox(height: TdSpacing.related),
                Text(
                  widget.operation.description,
                  style: TdTypography.body.copyWith(color: td.textSecondary),
                ),
                const SizedBox(height: TdSpacing.related),
                Text(
                  profile?.normalizedEndpoint ?? 'No live server selected',
                  style: TdTypography.metadata,
                ),
                const SizedBox(height: TdSpacing.group),
                if (ownResult && state.phase != AdminPhase.idle) ...[
                  _AdminResultPanel(state: state, showValue: sameConnection),
                  const SizedBox(height: TdSpacing.component),
                ],
                if (unavailable != null || method == null)
                  TdPanel(
                    title: 'This action is unavailable',
                    child: Text(unavailable ?? 'No verified method schema.'),
                  )
                else ...[
                  if (widget.operation.warning case final warning?) ...[
                    TdPanel(title: 'Before you continue', child: Text(warning)),
                    const SizedBox(height: TdSpacing.component),
                  ],
                  TdPanel(
                    title: widget.operation.risk == AdminRisk.read
                        ? 'View options'
                        : 'Configuration',
                    description:
                        'Only fields supported by this server are editable. '
                        'Optional values are left unchanged unless explicitly included.',
                    child: AdminSchemaForm(
                      key: _formKey,
                      parameters: method.parameters,
                      enabled: !state.busy && !_reviewing,
                    ),
                  ),
                  const SizedBox(height: TdSpacing.component),
                  Wrap(
                    spacing: TdSpacing.related,
                    runSpacing: TdSpacing.inline,
                    children: [
                      FilledButton.icon(
                        key: const Key('admin-review-submit'),
                        onPressed: state.busy || _reviewing
                            ? null
                            : () => _submit(method),
                        icon: Icon(
                          widget.operation.risk == AdminRisk.read
                              ? Icons.refresh_rounded
                              : Icons.fact_check_outlined,
                        ),
                        label: Text(
                          widget.operation.risk == AdminRisk.read
                              ? 'Load current data'
                              : 'Review changes',
                        ),
                      ),
                      TextButton(
                        onPressed: state.busy || _reviewing
                            ? null
                            : () => _formKey.currentState?.reset(),
                        child: const Text('Reset form'),
                      ),
                    ],
                  ),
                  if (state.busy && !ownResult)
                    const Padding(
                      padding: EdgeInsets.only(top: TdSpacing.related),
                      child: Text(
                        'Another administration request is still running.',
                      ),
                    ),
                  const SizedBox(height: TdSpacing.group),
                  Text(
                    'This is a schema-driven native workflow. Server-side validation '
                    'and permissions remain authoritative. Changes are never sent '
                    'by opening this page.',
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

  Future<void> _submit(AdminMethodSpec method) async {
    final session = ref.read(dashboardActiveSessionProvider);
    final profile = ref.read(serverProfilesControllerProvider).selectedProfile;
    if (session == null || profile == null || _reviewing) return;
    final arguments = _formKey.currentState?.validateAndBuild();
    if (arguments == null) return;
    final AdminRequest request;
    try {
      request = AdminRequest(method: method, arguments: arguments);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The request is too large or cannot be represented safely. Nothing was sent.',
          ),
        ),
      );
      return;
    }
    if (widget.operation.risk != AdminRisk.read) {
      setState(() => _reviewing = true);
      final approved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AdminReviewDialog(
          operation: widget.operation,
          serverLabel: profile.normalizedEndpoint,
          request: request,
        ),
      );
      if (!mounted) return;
      setState(() => _reviewing = false);
      if (approved != true) {
        _formKey.currentState?.clearSensitiveValues();
        return;
      }
    }
    // AdminRequest froze the validated arguments. Clearing fields cannot alter
    // the approved request, and plaintext secrets need not remain in the form.
    _formKey.currentState?.clearSensitiveValues();
    final submission = ref
        .read(adminControllerProvider.notifier)
        .execute(
          expectedSession: session,
          operation: widget.operation,
          request: request,
          serverLabel: profile.normalizedEndpoint,
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

class AdminReviewDialog extends StatefulWidget {
  const AdminReviewDialog({
    required this.operation,
    required this.serverLabel,
    required this.request,
    super.key,
  });
  final AdminOperationDefinition operation;
  final String serverLabel;
  final AdminRequest request;
  @override
  State<AdminReviewDialog> createState() => _AdminReviewDialogState();
}

class _AdminReviewDialogState extends State<AdminReviewDialog> {
  bool _acknowledged = false;
  String _typedTarget = '';
  @override
  Widget build(BuildContext context) {
    final sensitive =
        widget.operation.risk == AdminRisk.destructive ||
        widget.operation.risk == AdminRisk.disruptive;
    final arguments = widget.request.redactedArguments;
    final target = adminConfirmationTarget(
      widget.operation,
      arguments,
      widget.serverLabel,
    );
    final completeReview = adminReviewFits(widget.request.arguments);
    return AlertDialog(
      scrollable: true,
      title: Text('Review ${widget.operation.title.toLowerCase()}'),
      content: SizedBox(
        width: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SERVER', style: TdTypography.micro),
            SelectableText(widget.serverLabel),
            const SizedBox(height: TdSpacing.component),
            const Text('TARGET', style: TdTypography.micro),
            SelectableText(target, style: TdTypography.titleSmall),
            const SizedBox(height: TdSpacing.component),
            Text(
              widget.operation.warning ??
                  'This action changes server configuration. '
                      'Review every included field before continuing.',
            ),
            const SizedBox(height: TdSpacing.related),
            if (!completeReview)
              const Text(
                'This request is too large or deeply nested for a '
                'complete native review. Nothing can be submitted from this '
                'form; use a dedicated workflow.',
              ),
            for (
              var index = 0;
              index < arguments.length && completeReview;
              index++
            )
              _ValueTree(
                label: index < widget.request.method.parameters.length
                    ? widget.request.method.parameters[index].name
                    : 'Parameter ${index + 1}',
                value: arguments[index],
                depth: 0,
                review: true,
              ),
            const SizedBox(height: TdSpacing.related),
            CheckboxListTile(
              key: const Key('admin-impact-acknowledge'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('I have reviewed the target and the impact.'),
              value: _acknowledged,
              onChanged: (value) =>
                  setState(() => _acknowledged = value ?? false),
            ),
            if (sensitive)
              TextField(
                key: const Key('admin-confirm-target'),
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Type the exact target to confirm',
                ),
                onChanged: (value) => setState(() => _typedTarget = value),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin-confirm-send'),
          style: sensitive
              ? FilledButton.styleFrom(
                  backgroundColor: context.tdTheme.statusCritical,
                )
              : null,
          onPressed:
              completeReview &&
                  _acknowledged &&
                  (!sensitive || _typedTarget == target)
              ? () => Navigator.pop(context, true)
              : null,
          child: const Text('Confirm changes'),
        ),
      ],
    );
  }
}

String adminConfirmationTarget(
  AdminOperationDefinition operation,
  List<Object?> arguments,
  String serverLabel,
) {
  // Only these reviewed operations use their first argument as a resource
  // identifier. Never infer identity from an arbitrary string or a config
  // object's `name`: system.shutdown's first argument, for example, is a
  // user-entered reason. Server-wide and unreviewed shapes confirm the server.
  const resourceIdentifierMethods = {
    'sharing.smb.update',
    'sharing.smb.delete',
    'sharing.nfs.update',
    'sharing.nfs.delete',
    'iscsi.portal.update',
    'iscsi.portal.delete',
    'iscsi.initiator.update',
    'iscsi.initiator.delete',
    'iscsi.target.update',
    'iscsi.target.delete',
    'iscsi.targetextent.update',
    'iscsi.targetextent.delete',
    'nvmet.subsys.update',
    'nvmet.subsys.delete',
    'nvmet.port.update',
    'nvmet.port.delete',
    'nvmet.namespace.delete',
    'nvmet.host_subsys.delete',
    'nvmet.port_subsys.delete',
    'pool.scrub.update',
    'pool.scrub.delete',
    'pool.scrub.run',
    'pool.scrub.scrub',
    'pool.dataset.set_quota',
    'pool.snapshot.hold',
    'pool.snapshot.release',
    'pool.snapshottask.run',
    'replication.delete',
    'replication.run',
    'cloudsync.delete',
    'cloudsync.sync',
    'cloudsync.abort',
    'cloud_backup.delete',
    'cloud_backup.sync',
    'rsynctask.delete',
    'rsynctask.run',
    'kerberos.realm.update',
    'kerberos.realm.delete',
    'app.start',
    'app.stop',
    'app.redeploy',
    'app.image.delete',
    'vm.start',
    'vm.stop',
    'vm.restart',
    'vm.poweroff',
    'system.ntpserver.update',
    'system.ntpserver.delete',
    'service.update',
    'boot.environment.clone',
    'boot.environment.keep',
    'cronjob.delete',
    'alert.dismiss',
    'alert.restore',
    'core.job_abort',
  };
  if (!resourceIdentifierMethods.contains(operation.method) ||
      arguments.isEmpty) {
    return serverLabel;
  }
  return switch (arguments.first) {
    final String value when value.isNotEmpty && value != '[redacted]' => value,
    final num value => value.toString(),
    _ => serverLabel,
  };
}

bool adminReviewFits(Object? value, [int depth = 0]) {
  if (depth >= 6) return false;
  if (value is String) return value.length <= 2048;
  if (value is List) {
    return value.length <= 20 &&
        value.every((item) => adminReviewFits(item, depth + 1));
  }
  if (value is Map) {
    return value.length <= 40 &&
        value.entries.every(
          (entry) =>
              entry.key is String &&
              (entry.key as String).length <= 160 &&
              adminReviewFits(entry.value, depth + 1),
        );
  }
  return value == null || value is num || value is bool;
}

class _AdminResultPanel extends StatelessWidget {
  const _AdminResultPanel({required this.state, required this.showValue});
  final AdminOperationState state;
  final bool showValue;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: TdPanel(
      title: switch (state.phase) {
        AdminPhase.running => 'Request in progress',
        AdminPhase.completed => 'Server response received',
        AdminPhase.failed => 'Request not completed',
        _ => 'Result needs verification',
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: TdSpacing.related),
          ],
          Text(state.serverLabel ?? ''),
          if (state.jobId case final id?)
            Text('Job #$id', key: const Key('admin-job-id')),
          const SizedBox(height: TdSpacing.related),
          Text(state.message ?? ''),
          if (state.result case AdminCompleted(:final value)
              when showValue) ...[
            const SizedBox(height: TdSpacing.component),
            AdminResultView(value: value),
          ],
          if (!showValue && state.result is AdminCompleted)
            const Text(
              'Result details from a previous connection are hidden. Load fresh data.',
            ),
        ],
      ),
    ),
  );
}

/// Bounded native data presentation, not a raw JSON console. The API gateway
/// sanitizes secret fields before any value reaches this widget.
class AdminResultView extends StatelessWidget {
  const AdminResultView({required this.value, super.key});
  final Object? value;
  @override
  Widget build(BuildContext context) =>
      Material(type: MaterialType.transparency, child: _data(context));

  Widget _data(BuildContext context) {
    final data = value;
    if (data is List) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            data.isEmpty
                ? 'No items were returned.'
                : '${data.length} records shown',
            style: TdTypography.titleSmall,
          ),
          if (data.length > 100) const Text('Showing the first 100 records.'),
          if (data.isNotEmpty)
            const Text('Large responses may be shortened for display.'),
          for (var index = 0; index < data.length && index < 100; index++)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(_recordTitle(data[index], index)),
              children: [
                _ValueTree(label: 'Details', value: data[index], depth: 0),
              ],
            ),
        ],
      );
    }
    return _ValueTree(label: 'Result', value: value, depth: 0);
  }
}

String _recordTitle(Object? value, int index) {
  if (value is Map) {
    for (final key in [
      'name',
      'username',
      'service',
      'id',
      'hostname',
      'path',
    ]) {
      final candidate = value[key];
      if (candidate is String && candidate.isNotEmpty) {
        return candidate.length > 160
            ? '${candidate.substring(0, 160)}…'
            : candidate;
      }
      if (candidate is num) return 'Record $candidate';
    }
  }
  return 'Record ${index + 1}';
}

class _ValueTree extends StatelessWidget {
  const _ValueTree({
    required this.label,
    required this.value,
    required this.depth,
    this.review = false,
  });
  final String label;
  final Object? value;
  final int depth;
  final bool review;
  @override
  Widget build(BuildContext context) {
    final title = label.replaceAll('_', ' ');
    if (depth >= 6) return Text('$title: additional nested data omitted.');
    final data = value;
    if (data is Map) {
      final entries = data.entries.take(40);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (review) Text(title, style: TdTypography.titleSmall),
          if (data.isEmpty) Text('$title: no fields returned.'),
          for (final entry in entries)
            _ValueTree(
              label: entry.key.toString(),
              value: entry.value,
              depth: depth + 1,
              review: review,
            ),
          if (data.length > 40) const Text('Additional fields omitted.'),
        ],
      );
    }
    if (data is List) {
      if (data.isEmpty) return Text('$title: none');
      if (review) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$title (${data.length})', style: TdTypography.titleSmall),
            for (var index = 0; index < data.length && index < 20; index++)
              _ValueTree(
                label: '${index + 1}',
                value: data[index],
                depth: depth + 1,
                review: true,
              ),
          ],
        );
      }
      return ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text('$title (${data.length})'),
        children: [
          for (var index = 0; index < data.length && index < 20; index++)
            _ValueTree(
              label: '${index + 1}',
              value: data[index],
              depth: depth + 1,
            ),
          if (data.length > 20) const Text('Additional entries omitted.'),
        ],
      );
    }
    final text = switch (data) {
      null => 'Not set',
      true => 'Yes',
      false => 'No',
      _ => data.toString(),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: TdSpacing.inline),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TdTypography.metadata.copyWith(
              color: context.tdTheme.textSecondary,
            ),
          ),
          SelectableText(
            text.length > 2048 ? '${text.substring(0, 2048)}…' : text,
          ),
        ],
      ),
    );
  }
}
