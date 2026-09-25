import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../audit_export/audit_export_page.dart';
import 'activity_controller.dart';

class ActivityPage extends ConsumerWidget {
  const ActivityPage({this.initialAudit = false, super.key});
  final bool initialAudit;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(dashboardActiveSessionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Activity & audit')),
      body: SafeArea(
        child: session == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: TdPanel(
                  title: 'Connect a server',
                  child: Text('Activity is available after authentication.'),
                ),
              )
            : _ActivityBody(
                key: ObjectKey(session),
                session: session,
                initialAudit: initialAudit,
              ),
      ),
    );
  }
}

class _ActivityBody extends ConsumerStatefulWidget {
  const _ActivityBody({
    required this.session,
    required this.initialAudit,
    super.key,
  });
  final AuthenticatedSession session;
  final bool initialAudit;
  @override
  ConsumerState<_ActivityBody> createState() => _ActivityBodyState();
}

class _ActivityBodyState extends ConsumerState<_ActivityBody> {
  late bool _audit = widget.initialAudit;
  JobQuery _jobs = const JobQuery();
  ActivityJobState? _state;
  String _method = '', _username = '';
  AuditService _service = AuditService.middleware;
  bool? _success;
  int _hours = 24;
  late AuditQuery _events = _auditQuery();
  AuditQuery _auditQuery() {
    final until = DateTime.now().toUtc();
    return AuditQuery(
      from: until.subtract(Duration(hours: _hours)),
      until: until,
      service: _service,
      username: _username.trim(),
      success: _success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = ref
        .watch(activitySessionProvider)
        ?.activityCapabilities;
    final operation = ref.watch(activityControllerProvider);
    final controller = ref.read(activityControllerProvider.notifier);
    final jobs = !_audit && capabilities?.canReadJobs == true
        ? ref.watch(activityJobsProvider(_jobs))
        : null;
    final audit = _audit && capabilities?.canReadAudit == true
        ? ref.watch(activityAuditProvider(_events))
        : null;
    final loading = jobs?.isLoading == true || audit?.isLoading == true;
    final disabled =
        operation.busy || operation.pending || operation.unresolved || loading;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: ListView(
          padding: const EdgeInsets.all(TdSpacing.pageMobile),
          children: [
            Text(
              'SERVER ACTIVITY',
              style: TdTypography.micro.copyWith(
                color: context.tdTheme.actionPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _audit
                  ? 'Who changed what, and when'
                  : 'Every operation, in view',
              style: TdTypography.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              widget.session.endpoint ?? 'Authenticated server',
              style: TdTypography.metadata,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Jobs'),
                  selected: !_audit,
                  onSelected: (_) => setState(() => _audit = false),
                ),
                ChoiceChip(
                  label: const Text('Audit trail'),
                  selected: _audit,
                  onSelected: (_) => setState(() => _audit = true),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (operation.result != null || operation.busy) ...[
              TdPanel(
                title: operation.busy ? 'Checking job' : 'Cancellation status',
                description: operation.server,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (operation.busy) const LinearProgressIndicator(),
                    if (operation.result != null)
                      Text(operation.result!.message),
                    if (operation.pending)
                      OutlinedButton(
                        onPressed: operation.busy ? null : controller.check,
                        child: const Text('Check cancellation status'),
                      ),
                    if (operation.unresolved)
                      OutlinedButton(
                        onPressed: controller.canAcknowledgeUnknown
                            ? controller.acknowledgeUnknown
                            : null,
                        child: const Text(
                          'I inspected the original server and reconnected',
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (capabilities?.supported != true)
              const TdPanel(
                title: 'Version not supported',
                child: Text(
                  'This workspace requires a stable TrueNAS 25.10 server. No requests will be sent.',
                ),
              )
            else if (_audit
                ? capabilities?.canReadAudit != true
                : capabilities?.canReadJobs != true)
              const TdPanel(
                title: 'Unavailable to this account',
                child: Text(
                  'This server did not advertise the required read method.',
                ),
              )
            else ...[
              _audit ? _auditFilters(loading) : _jobFilters(loading),
              const SizedBox(height: 16),
              if (loading)
                const LinearProgressIndicator()
              else if ((_audit ? audit?.hasError : jobs?.hasError) == true)
                TdPanel(
                  title: 'Activity unavailable',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'The response could not be verified or access was denied. No remote error details are displayed.',
                      ),
                      OutlinedButton(
                        onPressed: _refresh,
                        child: const Text('Retry read'),
                      ),
                    ],
                  ),
                )
              else if (_audit && audit?.asData != null) ...[
                _AuditSummary(events: audit!.requireValue.entries),
                const SizedBox(height: 16),
                if (audit.requireValue.entries.isEmpty)
                  const TdPanel(
                    child: Text(
                      'No audit events match this interval and filters.',
                    ),
                  ),
                for (final event in audit.requireValue.entries) ...[
                  TdPanel(
                    title: event.method ?? event.event,
                    description:
                        '${event.service.name.toUpperCase()} · ${_time(event.timestamp)}',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TdStatusBadge(
                          status: event.success
                              ? TdStatus.success
                              : TdStatus.critical,
                          label: event.success ? 'Success' : 'Failed',
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${event.username.isEmpty ? 'No username' : event.username} · ${event.address.isEmpty ? 'No client address' : event.address}',
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          'Event ID: ${event.id}',
                          style: TdTypography.metadata,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _pagination(
                  _events.page,
                  audit.requireValue.hasMore,
                  (page) => setState(
                    () => _events = AuditQuery(
                      from: _events.from,
                      until: _events.until,
                      service: _events.service,
                      username: _events.username,
                      success: _events.success,
                      page: page,
                    ),
                  ),
                ),
                const Text(
                  'Only safe event metadata is displayed. Request arguments, event payloads and service data are excluded. Times are UTC. Retention can remove older events.',
                ),
              ] else if (!_audit && jobs?.asData != null) ...[
                _JobSummary(jobs: jobs!.requireValue.entries),
                const SizedBox(height: 16),
                if (jobs.requireValue.entries.isEmpty)
                  const TdPanel(child: Text('No jobs match these filters.')),
                for (final job in jobs.requireValue.entries) ...[
                  TdPanel(
                    title: job.method,
                    description:
                        'Job #${job.id} · ${job.startedAt == null ? 'Start time unavailable' : _time(job.startedAt!)}',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TdStatusBadge(
                          status: _status(job.state),
                          label: job.state.name.toUpperCase(),
                        ),
                        if (job.progressPercent != null) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            value: job.progressPercent! / 100,
                            semanticsLabel: 'Job ${job.id} progress',
                          ),
                          const SizedBox(height: 8),
                          Text('${job.progressPercent!.toStringAsFixed(0)}%'),
                        ],
                        if (job.finishedAt != null)
                          Text('Finished ${_time(job.finishedAt!)}'),
                        if (job.active)
                          OutlinedButton.icon(
                            key: ValueKey('cancel-job-${job.id}'),
                            onPressed:
                                disabled ||
                                    capabilities?.canCancelJobs != true ||
                                    !job.canCancel
                                ? null
                                : () => _cancel(job),
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('Review cancellation'),
                          ),
                        if (job.active && !job.canCancel)
                          const Text(
                            'This job cannot be cancelled safely from this inventory.',
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _pagination(
                  _jobs.page,
                  jobs.requireValue.hasMore,
                  (page) => setState(
                    () => _jobs = JobQuery(
                      state: _jobs.state,
                      method: _jobs.method,
                      page: page,
                    ),
                  ),
                ),
                const Text(
                  'Only jobs visible to your account are shown. Jobs may finish or disappear between pages. Arguments, results, credentials and raw logs are excluded.',
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _jobFilters(bool loading) => TdPanel(
    title: 'Find jobs',
    child: Column(
      children: [
        DropdownButtonFormField<ActivityJobState?>(
          initialValue: _state,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'State'),
          items: [
            const DropdownMenuItem(value: null, child: Text('All states')),
            for (final state in ActivityJobState.values)
              DropdownMenuItem(
                value: state,
                child: Text(state.name.toUpperCase()),
              ),
          ],
          onChanged: loading ? null : (value) => setState(() => _state = value),
        ),
        const SizedBox(height: 12),
        TextField(
          enabled: !loading,
          decoration: const InputDecoration(
            labelText: 'Exact method (optional)',
            hintText: 'pool.scrub',
          ),
          onChanged: (value) => _method = value,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: loading
                ? null
                : () => setState(() {
                    _jobs = JobQuery(state: _state, method: _method.trim());
                    ref.invalidate(activityJobsProvider(_jobs));
                  }),
            icon: const Icon(Icons.refresh),
            label: const Text('Apply / refresh'),
          ),
        ),
      ],
    ),
  );
  Widget _auditFilters(bool loading) => TdPanel(
    title: 'Filter audit trail',
    child: Column(
      children: [
        DropdownButtonFormField<AuditService>(
          initialValue: _service,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Service'),
          items: [
            for (final service in AuditService.values)
              DropdownMenuItem(
                value: service,
                child: Text(service.name.toUpperCase()),
              ),
          ],
          onChanged: loading
              ? null
              : (value) => setState(() => _service = value!),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: _hours,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Interval'),
          items: const [
            DropdownMenuItem(value: 1, child: Text('Last hour')),
            DropdownMenuItem(value: 24, child: Text('Last 24 hours')),
            DropdownMenuItem(value: 168, child: Text('Last 7 days')),
            DropdownMenuItem(value: 720, child: Text('Last 30 days')),
          ],
          onChanged: loading
              ? null
              : (value) => setState(() => _hours = value!),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<bool?>(
          initialValue: _success,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Result'),
          items: const [
            DropdownMenuItem(value: null, child: Text('All results')),
            DropdownMenuItem(value: true, child: Text('Success')),
            DropdownMenuItem(value: false, child: Text('Failed')),
          ],
          onChanged: loading
              ? null
              : (value) => setState(() => _success = value),
        ),
        const SizedBox(height: 12),
        TextField(
          enabled: !loading,
          maxLength: 64,
          decoration: const InputDecoration(
            labelText: 'Exact username (optional)',
          ),
          onChanged: (value) => _username = value,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: loading
                ? null
                : () => setState(() => _events = _auditQuery()),
            icon: const Icon(Icons.search),
            label: const Text('Apply / refresh'),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('activity-audit-export'),
            onPressed: loading
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AuditExportPage(),
                    ),
                  ),
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('Export a sensitive report'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${_time(_events.from)} to ${_time(_events.until)}',
          style: TdTypography.metadata,
        ),
      ],
    ),
  );
  Widget _pagination(int page, bool more, ValueChanged<int> change) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton(
          onPressed: page == 0 ? null : () => change(page - 1),
          child: const Text('Previous'),
        ),
        Text('Page ${page + 1}'),
        OutlinedButton(
          onPressed: !more || page >= 39 ? null : () => change(page + 1),
          child: const Text('Next'),
        ),
        if (more && page >= 39)
          const Text('Narrow the filters to find older entries.'),
      ],
    ),
  );
  void _refresh() {
    if (_audit) {
      ref.invalidate(activityAuditProvider(_events));
    } else {
      ref.invalidate(activityJobsProvider(_jobs));
    }
  }

  Future<void> _cancel(ActivityJob job) async {
    var confirmation = '';
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (context, ref, _) {
          final same = identical(
            ref.watch(dashboardActiveSessionProvider),
            widget.session,
          );
          return StatefulBuilder(
            builder: (context, update) => AlertDialog(
              title: const Text('Cancel this job?'),
              content: SingleChildScrollView(
                child: !same
                    ? const Text(
                        'The server changed. Close this review and reload.',
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.session.endpoint ?? ''),
                          const SizedBox(height: 12),
                          Text('${job.method} · ${job.confirmation}'),
                          const SizedBox(height: 12),
                          const Text(
                            'Cancellation may interrupt an operation partway through. Completed work is not rolled back. The server decides whether this account can cancel the job.',
                          ),
                          const SizedBox(height: 12),
                          Text('Type ${job.confirmation} exactly.'),
                          TextField(
                            key: const Key('job-cancel-confirmation'),
                            autocorrect: false,
                            enableSuggestions: false,
                            onChanged: (value) =>
                                update(() => confirmation = value),
                          ),
                        ],
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Keep running'),
                ),
                FilledButton(
                  onPressed: !same || confirmation != job.confirmation
                      ? null
                      : () => Navigator.pop(dialogContext, true),
                  child: const Text('Request cancellation'),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (!mounted || approved != true) return;
    await ref
        .read(activityControllerProvider.notifier)
        .cancel(widget.session, job, confirmation);
  }
}

String _time(DateTime date) =>
    '${date.toUtc().toIso8601String().substring(0, 19).replaceFirst('T', ' ')} UTC';
TdStatus _status(ActivityJobState state) => switch (state) {
  ActivityJobState.running => TdStatus.info,
  ActivityJobState.waiting => TdStatus.warning,
  ActivityJobState.success => TdStatus.success,
  ActivityJobState.failed => TdStatus.critical,
  ActivityJobState.aborted => TdStatus.neutral,
};

class _JobSummary extends StatelessWidget {
  const _JobSummary({required this.jobs});
  final List<ActivityJob> jobs;
  @override
  Widget build(BuildContext context) => TdPanel(
    title: '${jobs.length} jobs on this page',
    child: Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final state in ActivityJobState.values)
          TdStatusBadge(
            status: _status(state),
            label:
                '${jobs.where((job) => job.state == state).length} ${state.name}',
          ),
      ],
    ),
  );
}

class _AuditSummary extends StatelessWidget {
  const _AuditSummary({required this.events});
  final List<AuditEvent> events;
  @override
  Widget build(BuildContext context) {
    final success = events.where((event) => event.success).length;
    return TdPanel(
      title: '${events.length} events on this page',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (events.isNotEmpty)
            LinearProgressIndicator(
              value: success / events.length,
              color: context.tdTheme.statusSuccess,
              backgroundColor: context.tdTheme.statusCritical,
              semanticsLabel:
                  '$success successful and ${events.length - success} failed events on this page',
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              TdStatusBadge(
                status: TdStatus.success,
                label: '$success success',
              ),
              TdStatusBadge(
                status: TdStatus.critical,
                label: '${events.length - success} failed',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
