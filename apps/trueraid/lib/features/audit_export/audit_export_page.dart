import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../configuration_backup/configuration_backup_file.dart';
import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'audit_export_controller.dart';

class AuditExportPage extends ConsumerStatefulWidget {
  const AuditExportPage({super.key});

  @override
  ConsumerState<AuditExportPage> createState() => _AuditExportPageState();
}

class _AuditExportPageState extends ConsumerState<AuditExportPage> {
  AuditService _service = AuditService.middleware;
  AuditExportFormat _format = AuditExportFormat.csv;
  int _hours = 24;
  bool? _success;
  String _username = '';
  bool _sensitive = false,
      _artifact = false,
      _limit = false,
      _reviewing = false;
  String? _error;

  bool get _routeCurrent =>
      mounted && ModalRoute.of(context)?.isCurrent == true;

  AuditExportRequest _request() {
    final until = DateTime.now().toUtc();
    return AuditExportRequest(
      query: AuditQuery(
        from: until.subtract(Duration(hours: _hours)),
        until: until,
        service: _service,
        username: _username.trim(),
        success: _success,
      ),
      format: _format,
      sensitiveDataAccepted: _sensitive,
      serverArtifactAccepted: _artifact,
      rowLimitAccepted: _limit,
    );
  }

  Future<void> _review() async {
    final session = ref.read(dashboardActiveSessionProvider);
    final api = ref.read(auditExportSessionProvider);
    final request = _request();
    if (_reviewing ||
        session?.endpoint == null ||
        api == null ||
        !api.auditExportCapabilities.canExport ||
        request.validationError != null ||
        !_routeCurrent) {
      return;
    }
    setState(() {
      _reviewing = true;
      _error = null;
    });
    final expectedSession = session!;
    try {
      final review = await api.reviewAuditExport(request);
      if (!_routeCurrent ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          ) ||
          !identical(review.request, request) ||
          review.endpoint != expectedSession.endpoint) {
        return;
      }
      if (!mounted) return;
      final confirmation = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _AuditExportReviewDialog(review: review, session: expectedSession),
      );
      if (confirmation != review.target || !_routeCurrent) return;
      await ref
          .read(auditExportControllerProvider.notifier)
          .execute(
            expectedSession: expectedSession,
            review: review,
            confirmation: confirmation!,
            routeCurrent: () => _routeCurrent,
          );
    } on Object {
      if (_routeCurrent) {
        setState(() {
          _error = 'The report could not be reviewed safely. Remote details were withheld; create a fresh review.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _reviewing = false;
          _sensitive = false;
          _artifact = false;
          _limit = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final api = ref.watch(auditExportSessionProvider);
    final caps = api?.auditExportCapabilities;
    final state = ref.watch(auditExportControllerProvider);
    final controller = ref.read(auditExportControllerProvider.notifier);
    final saver = ref.watch(configurationBackupFileSaverProvider);
    final enabled =
        session?.endpoint != null &&
        caps?.canExport == true &&
        saver.supported &&
        !state.locked &&
        !_reviewing;
    return Scaffold(
      appBar: AppBar(title: const Text('Audit report export')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              key: const Key('audit-export-scroll'),
              padding: const EdgeInsets.all(TdSpacing.pageMobile),
              children: [
                const Text('SYSTEM · AUDIT EXPORT', style: TdTypography.micro),
                const SizedBox(height: 8),
                const Text(
                  'Export a bounded audit report',
                  style: TdTypography.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(session?.endpoint ?? 'No authenticated connection'),
                const SizedBox(height: 8),
                const Text(
                  'Nothing runs automatically. One reviewed report job is followed by one owned output-pipe download job. The app accepts only a same-server relative URL, at most 16 MiB of gzip data, and a verified bounded TrueNAS tar/report structure.',
                ),
                const SizedBox(height: 16),
                if (state.busy || _reviewing) const LinearProgressIndicator(),
                if (state.message != null) ...[
                  TdPanel(
                    title: state.unknown
                        ? 'Inspect before continuing'
                        : state.pending
                        ? 'Report job submitted'
                        : 'Export status',
                    description: state.server,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(state.message!),
                        if (state.operation != null)
                          Text('Owned report job: ${state.operation!.id}'),
                        if (state.pending)
                          FilledButton.icon(
                            key: const Key('audit-export-check'),
                            onPressed: state.busy
                                ? null
                                : () => controller.poll(
                                    routeCurrent: () => _routeCurrent,
                                  ),
                            icon: const Icon(Icons.download),
                            label: const Text('Check report and download'),
                          ),
                        if (state.unknown) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Reconnect to the same endpoint only after independently checking audit.export, audit.download_report and any selected destination.',
                          ),
                          OutlinedButton(
                            key: const Key('audit-export-acknowledge'),
                            onPressed: controller.canAcknowledge
                                ? controller.acknowledgeAfterReconnect
                                : null,
                            child: const Text(
                              'I inspected both jobs and reconnected',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (caps?.connected != true || caps?.versionSupported != true)
                  const TdPanel(
                    title: 'Audit export unavailable',
                    child: Text(
                      'Connect to a stable TrueNAS 25.10 server. No export requests are sent from this screen while disconnected.',
                    ),
                  )
                else if (caps?.available != true ||
                    caps?.transferSupported != true ||
                    !saver.supported)
                  const TdPanel(
                    title: 'Protected export unavailable',
                    child: Text(
                      'The server must advertise both audit jobs and the app must provide certificate-pinned bounded download plus an Android document destination.',
                    ),
                  )
                else ...[
                  TdPanel(
                    title: 'Report filters',
                    child: Column(
                      children: [
                        DropdownButtonFormField<AuditService>(
                          key: const Key('audit-export-service'),
                          initialValue: _service,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Service',
                          ),
                          items: [
                            for (final service in AuditService.values)
                              DropdownMenuItem(
                                value: service,
                                child: Text(service.name.toUpperCase()),
                              ),
                          ],
                          onChanged: enabled
                              ? (value) => setState(() => _service = value!)
                              : null,
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<AuditExportFormat>(
                          key: const Key('audit-export-format'),
                          initialValue: _format,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Archive payload format',
                          ),
                          items: [
                            for (final format in AuditExportFormat.values)
                              DropdownMenuItem(
                                value: format,
                                child: Text(format.name.toUpperCase()),
                              ),
                          ],
                          onChanged: enabled
                              ? (value) => setState(() => _format = value!)
                              : null,
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int>(
                          key: const Key('audit-export-interval'),
                          initialValue: _hours,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'UTC interval',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 1,
                              child: Text('Last hour'),
                            ),
                            DropdownMenuItem(
                              value: 24,
                              child: Text('Last 24 hours'),
                            ),
                            DropdownMenuItem(
                              value: 168,
                              child: Text('Last 7 days'),
                            ),
                            DropdownMenuItem(
                              value: 720,
                              child: Text('Last 30 days'),
                            ),
                          ],
                          onChanged: enabled
                              ? (value) => setState(() => _hours = value!)
                              : null,
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<bool?>(
                          key: const Key('audit-export-result'),
                          initialValue: _success,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Result',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: null,
                              child: Text('All results'),
                            ),
                            DropdownMenuItem(
                              value: true,
                              child: Text('Success'),
                            ),
                            DropdownMenuItem(
                              value: false,
                              child: Text('Failed'),
                            ),
                          ],
                          onChanged: enabled
                              ? (value) => setState(() => _success = value)
                              : null,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('audit-export-username'),
                          enabled: enabled,
                          maxLength: 64,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: 'Exact username (optional)',
                          ),
                          onChanged: (value) => _username = value,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TdPanel(
                    title: 'Required disclosures',
                    child: Material(
                      type: MaterialType.transparency,
                      child: Column(
                        children: [
                          CheckboxListTile(
                            key: const Key('audit-export-sensitive'),
                            value: _sensitive,
                            onChanged: enabled
                                ? (value) =>
                                      setState(() => _sensitive = value == true)
                                : null,
                            title: const Text(
                              'The full audit payload can contain sensitive data omitted from the on-screen viewer.',
                            ),
                          ),
                          CheckboxListTile(
                            key: const Key('audit-export-artifact'),
                            value: _artifact,
                            onChanged: enabled
                                ? (value) =>
                                      setState(() => _artifact = value == true)
                                : null,
                            title: const Text(
                              'TrueNAS creates a temporary server-side report that local cancellation does not delete.',
                            ),
                          ),
                          CheckboxListTile(
                            key: const Key('audit-export-limit'),
                            value: _limit,
                            onChanged: enabled
                                ? (value) =>
                                      setState(() => _limit = value == true)
                                : null,
                            title: const Text(
                              'The ordered export is capped at 10,000 rows and is not proof of complete capture.',
                            ),
                          ),
                          FilledButton.icon(
                            key: const Key('audit-export-review'),
                            onPressed:
                                enabled && _sensitive && _artifact && _limit
                                ? _review
                                : null,
                            icon: const Icon(Icons.fact_check_outlined),
                            label: const Text('Review export'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuditExportReviewDialog extends StatefulWidget {
  const _AuditExportReviewDialog({required this.review, required this.session});
  final AuditExportReview review;
  final AuthenticatedSession session;

  @override
  State<_AuditExportReviewDialog> createState() =>
      _AuditExportReviewDialogState();
}

class _AuditExportReviewDialogState extends State<_AuditExportReviewDialog> {
  String _confirmation = '';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Create this sensitive report?'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.session.endpoint ?? ''),
          const SizedBox(height: 12),
          for (final warning in widget.review.warnings) ...[
            Text('• $warning'),
            const SizedBox(height: 8),
          ],
          SelectableText(widget.review.target, style: TdTypography.metadata),
          const SizedBox(height: 12),
          TextField(
            key: const Key('audit-export-confirmation'),
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Type the exact target',
            ),
            onChanged: (value) => setState(() => _confirmation = value),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _confirmation == widget.review.target
            ? () => Navigator.pop(context, _confirmation)
            : null,
        child: const Text('Create report'),
      ),
    ],
  );
}
