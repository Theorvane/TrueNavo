import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'snapshot_schedules_controller.dart';
import 'snapshot_schedules_page.dart';

/// All review API calls are read-only. Only a current, explicitly confirmed
/// SDK-issued review can reach the controller's single setter dispatch.
Future<void> reviewSnapshotScheduleChange({
  required BuildContext context,
  required WidgetRef ref,
  required AuthenticatedSession session,
  required SnapshotScheduleInventory inventory,
  required SnapshotScheduleRequest request,
  VoidCallback? onReviewReady,
}) async {
  if (!identical(session, ref.read(dashboardActiveSessionProvider)) ||
      !identical(
        inventory,
        ref.read(snapshotSchedulesInventoryProvider).asData?.value,
      ) ||
      request.validationError != null) {
    return;
  }
  final api = ref.read(snapshotSchedulesSessionProvider);
  if (api == null) return;
  final review = await api.reviewSnapshotSchedule(request);
  if (!context.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      !identical(
        inventory,
        ref.read(snapshotSchedulesInventoryProvider).asData?.value,
      )) {
    return;
  }
  if (review.target != request.target || review.action != request.action) {
    throw StateError(
      'The returned review does not match the selected operation.',
    );
  }
  onReviewReady?.call();
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => SnapshotScheduleReviewDialog(
      session: session,
      request: request,
      review: review,
    ),
  );
  if (!context.mounted ||
      confirmed != true ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      !identical(
        inventory,
        ref.read(snapshotSchedulesInventoryProvider).asData?.value,
      )) {
    return;
  }
  await ref
      .read(snapshotSchedulesControllerProvider.notifier)
      .execute(
        expectedSession: session,
        review: review,
        confirmation: review.target,
      );
}

class SnapshotScheduleReviewDialog extends ConsumerStatefulWidget {
  const SnapshotScheduleReviewDialog({
    required this.session,
    required this.request,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final SnapshotScheduleRequest request;
  final SnapshotScheduleReview review;
  @override
  ConsumerState<SnapshotScheduleReviewDialog> createState() =>
      _SnapshotScheduleReviewDialogState();
}

class _SnapshotScheduleReviewDialogState
    extends ConsumerState<SnapshotScheduleReviewDialog> {
  final _confirmation = TextEditingController();
  bool _acknowledged = false;
  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(snapshotSchedulesInventoryProvider);
    final current =
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.request.inventory, inventory.asData?.value);
    final review = widget.review;
    final deletion = review.action == SnapshotScheduleAction.delete;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.all(TdSpacing.component),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review ${_action(review.action)}'
                    : 'Review is no longer current',
                style: TdTypography.titleSmall,
              ),
              const SizedBox(height: TdSpacing.component),
              Flexible(
                child: SingleChildScrollView(
                  child: !current
                      ? const Text(
                          'The previous server, target and schedule details are hidden. Close this review and reload the current connection. Nothing was sent.',
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Authenticated server',
                              style: TdTypography.label,
                            ),
                            SelectableText(
                              widget.session.endpoint ?? 'Unavailable',
                            ),
                            const SizedBox(height: TdSpacing.related),
                            const Text(
                              'Exact target',
                              style: TdTypography.label,
                            ),
                            SelectableText(review.target),
                            Text(
                              'Server timezone: ${widget.request.inventory.timezone}',
                            ),
                            const SizedBox(height: TdSpacing.component),
                            if (widget.request.task != null)
                              _SettingsSummary(
                                title: 'Before',
                                settings: widget.request.task!.settings,
                              ),
                            if (widget.request.settings != null) ...[
                              const SizedBox(height: TdSpacing.component),
                              _SettingsSummary(
                                title: 'After',
                                settings: widget.request.settings!,
                              ),
                            ],
                            const SizedBox(height: TdSpacing.component),
                            TdPanel(
                              title: 'Server-reviewed changes',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (final change in review.changes)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: TdSpacing.related,
                                      ),
                                      child: Text(change),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: TdSpacing.component),
                            for (final warning in review.warnings)
                              Padding(
                                padding: const EdgeInsets.only(
                                  bottom: TdSpacing.related,
                                ),
                                child: Text(warning),
                              ),
                            if (deletion)
                              const Text(
                                'This removes the periodic task, not a direct snapshot-delete request. Existing snapshots are not guaranteed to retain the same future expiry: without this task’s retention protection, later cleanup may remove eligible snapshots. No private retention-fixation job is launched.',
                              ),
                            if (review.action == SnapshotScheduleAction.update)
                              const Text(
                                'Retention, naming, scope and enabled-state changes can affect existing snapshots’ future expiry. This app does not fix their removal dates through a private background job.',
                              ),
                            if (review.action == SnapshotScheduleAction.run)
                              const Text(
                                'This is a separately reviewed run request. Acceptance means it was queued; it does not verify snapshot completion or application consistency.',
                              ),
                            const SizedBox(height: TdSpacing.component),
                            TdPanel(
                              title:
                                  'Potentially affected existing snapshots · ${review.affectedSnapshots.length}',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Text(
                                    'This is the bounded set identified by the server review, not a prediction of exact deletion times. Other retention rules can also apply.',
                                  ),
                                  if (review.affectedSnapshots.isEmpty)
                                    const Text(
                                      'The review returned no existing snapshot identifiers in this scope.',
                                    ),
                                  for (final snapshot
                                      in review.affectedSnapshots)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        top: TdSpacing.related,
                                      ),
                                      child: SelectableText(snapshot),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: TdSpacing.component),
                            TextField(
                              key: const Key('schedule-confirm-target'),
                              controller: _confirmation,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: const InputDecoration(
                                labelText: 'Type the exact target shown above',
                                helperText: 'Case-sensitive; include the task number when shown.',
                                helperMaxLines: 3,
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                            Material(
                              type: MaterialType.transparency,
                              child: CheckboxListTile(
                                key: const Key('schedule-confirm-impact'),
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: _acknowledged,
                                onChanged: (value) => setState(
                                  () => _acknowledged = value ?? false,
                                ),
                                title: Text(
                                  deletion
                                      ? 'I reviewed the affected snapshots and understand that deleting this task can change their later expiry.'
                                      : 'I reviewed the exact schedule, dataset scope and retention impact.',
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: TdSpacing.component),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: TdSpacing.related,
                runSpacing: TdSpacing.related,
                children: [
                  TextButton(
                    key: const Key('schedule-cancel-confirm'),
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(current ? 'Cancel' : 'Close'),
                  ),
                  if (current)
                    FilledButton(
                      key: const Key('schedule-submit-confirm'),
                      onPressed:
                          _acknowledged &&
                              widget.session.endpoint != null &&
                              _confirmation.text == review.target &&
                              !ref
                                  .watch(snapshotSchedulesControllerProvider)
                                  .locked
                          ? () => Navigator.pop(context, true)
                          : null,
                      child: const Text('Submit once'),
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

class _SettingsSummary extends StatelessWidget {
  const _SettingsSummary({required this.title, required this.settings});
  final String title;
  final SnapshotScheduleSettings settings;
  @override
  Widget build(BuildContext context) => TdPanel(
    title: title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Dataset: ${settings.dataset}'),
        Text('Recursive: ${settings.recursive}'),
        Text(
          'Exclusions: ${settings.exclude.isEmpty ? 'None' : settings.exclude.join(', ')}',
        ),
        Text('Retention: ${settings.lifetimeValue} ${settings.lifetimeUnit}'),
        Text('Naming: ${settings.namingSchema}'),
        Text(
          'Enabled: ${settings.enabled} · Allow empty: ${settings.allowEmpty}',
        ),
        Text(scheduleCalendar(settings.cron).summary),
        Text('Cron: ${scheduleCalendar(settings.cron).expression}'),
        if (settings.cron.dom != '*' && settings.cron.dow != '*')
          const Text('Day of month OR day of week matches; not both together.'),
        Text('Inclusive window: ${settings.cron.begin}–${settings.cron.end}'),
      ],
    ),
  );
}

String _action(SnapshotScheduleAction action) => switch (action) {
  SnapshotScheduleAction.create => 'schedule creation',
  SnapshotScheduleAction.update => 'schedule update',
  SnapshotScheduleAction.delete => 'schedule deletion',
  SnapshotScheduleAction.run => 'run now',
};
