import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'time_settings_charts.dart';
import 'time_settings_controller.dart';

String timeSettingsActionLabel(TimeSettingsAction action) => switch (action) {
  TimeSettingsAction.timezone => 'Change timezone',
  TimeSettingsAction.createNtp => 'Add NTP source',
  TimeSettingsAction.updateNtp => 'Edit NTP source',
  TimeSettingsAction.deleteNtp => 'Delete NTP source',
};
String timeSettingsImpact(TimeSettingsAction action) => switch (action) {
  TimeSettingsAction.timezone => 'Only the timezone field is changed. Local-time schedules, cron and replication interpretation can change. TrueNAS updates the replication timezone, reloads time services, restarts cron and unconditionally starts SSL after writing configuration. A later error can follow an earlier write. Resolve pending GUI rollback independently; that rollback concerns GUI fields, not a timezone undo feature.',
  TimeSettingsAction.createNtp || TimeSettingsAction.updateNtp => 'Saving always asks the server to probe the configured NTP address, including options-only edits, using IPv4/DNS and UDP port 123. This can send network traffic before validation completes. Force is fixed off; there is no skip-probe or dry-run option. A successful configuration change restarts ntpd; failures can happen after the database write. Use burst only with personally controlled servers, not public NTP servers. A preference flag is not measured accuracy.',
  TimeSettingsAction.deleteNtp => 'Deletion removes this configured row and restarts ntpd. At least one configured row must remain, but that does not establish a healthy or reachable source. Other effective sources can come from DHCP or configuration files. Failure can occur after the row was removed.',
};

class TimeSettingsDiff extends StatelessWidget {
  const TimeSettingsDiff({required this.request, super.key});
  final TimeSettingsRequest request;
  @override
  Widget build(BuildContext context) {
    if (request.action == TimeSettingsAction.timezone) {
      return Text(
        'Timezone: ${request.inventory.timezone} → ${request.timezone}',
      );
    }
    final before = request.server?.settings, after = request.settings;
    final values = <String, (String, String)>{
      'Address': (
        before?.address ?? 'Not configured',
        after?.address ?? 'Removed',
      ),
      'Burst': ('${before?.burst ?? '—'}', '${after?.burst ?? '—'}'),
      'Initial burst': ('${before?.iburst ?? '—'}', '${after?.iburst ?? '—'}'),
      'Prefer': ('${before?.prefer ?? '—'}', '${after?.prefer ?? '—'}'),
      'Minimum poll': (
        before == null
            ? '—'
            : '${before.minPoll} (${pollSeconds(before.minPoll)})',
        after == null
            ? '—'
            : '${after.minPoll} (${pollSeconds(after.minPoll)})',
      ),
      'Maximum poll': (
        before == null
            ? '—'
            : '${before.maxPoll} (${pollSeconds(before.maxPoll)})',
        after == null
            ? '—'
            : '${after.maxPoll} (${pollSeconds(after.maxPoll)})',
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (request.server != null)
          Text('Configured source ID: ${request.server!.id}'),
        for (final entry in values.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('${entry.key}: ${entry.value.$1} → ${entry.value.$2}'),
          ),
        if (request.action == TimeSettingsAction.deleteNtp)
          Text(
            'Configured rows remaining: ${request.inventory.servers.length - 1} — not a health guarantee',
          ),
      ],
    );
  }
}

class TimeSettingsReviewDialog extends ConsumerStatefulWidget {
  const TimeSettingsReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final TimeSettingsReview review;
  @override
  ConsumerState<TimeSettingsReviewDialog> createState() =>
      _TimeSettingsReviewDialogState();
}

class _TimeSettingsReviewDialogState
    extends ConsumerState<TimeSettingsReviewDialog> {
  final _target = TextEditingController();
  bool _impact = false,
      _specific = false,
      _burst = false,
      _expired = false,
      _closing = false;
  late final AppLifecycleListener _lifecycle;
  late final Timer _expiry;
  @override
  void initState() {
    super.initState();
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) _expire();
      },
    );
    _expiry = Timer(const Duration(minutes: 5), _expire);
  }

  void _expire() {
    if (_expired || _closing || !mounted) return;
    ref.read(timeSettingsControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _impact = false;
      _specific = false;
      _burst = false;
      _target.clear();
    });
  }

  void _finish(bool value) {
    _closing = true;
    Navigator.of(context).pop(value);
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
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      ref.read(timeSettingsControllerProvider.notifier).abandonRoute();
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(timeSettingsInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(widget.review.request.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(timeSettingsInventoryProvider),
        state = ref.watch(timeSettingsControllerProvider);
    final current =
        !_expired &&
        !_closing &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(inventory.asData?.value, widget.review.request.inventory) &&
        ref
            .read(timeSettingsControllerProvider.notifier)
            .isReviewCurrent(widget.review);
    final action = widget.review.action;
    final burst =
        (action == TimeSettingsAction.createNtp ||
            action == TimeSettingsAction.updateNtp) &&
        widget.review.request.settings?.burst == true;
    final specific = switch (action) {
      TimeSettingsAction.timezone =>
        'I checked local-time schedules and replication impact.',
      TimeSettingsAction.createNtp || TimeSettingsAction.updateNtp =>
        'I authorize the server-side NTP network probe on save.',
      TimeSettingsAction.deleteNtp =>
        'I checked the remaining configured sources independently.',
    };
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('time-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review ${timeSettingsActionLabel(action).toLowerCase()}'
                    : 'Time-settings review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details are hidden. Reload configuration and begin a new review.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                const SizedBox(height: 12),
                TimeSettingsDiff(request: widget.review.request),
                const SizedBox(height: 12),
                Text(timeSettingsImpact(action)),
                for (final warning in widget.review.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(warning),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Verifying configured values does not establish live synchronization, reachability or time accuracy. This single-use review expires after five minutes. Type the full target exactly.',
                ),
                SelectableText(widget.review.target),
                TextField(
                  key: const Key('time-confirm-target'),
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
                  key: const Key('time-confirm-impact'),
                  contentPadding: EdgeInsets.zero,
                  value: _impact,
                  onChanged: (value) =>
                      setState(() => _impact = value ?? false),
                  title: const Text(
                    'I accept the configuration and service side effects.',
                  ),
                ),
                CheckboxListTile(
                  key: const Key('time-confirm-specific'),
                  contentPadding: EdgeInsets.zero,
                  value: _specific,
                  onChanged: (value) =>
                      setState(() => _specific = value ?? false),
                  title: Text(specific),
                ),
                if (burst)
                  CheckboxListTile(
                    key: const Key('time-confirm-burst'),
                    contentPadding: EdgeInsets.zero,
                    value: _burst,
                    onChanged: (value) =>
                        setState(() => _burst = value ?? false),
                    title: const Text(
                      'I directly control this server; it is not a public NTP server.',
                    ),
                  ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('time-review-cancel'),
                    onPressed: () => _finish(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('time-confirm-submit'),
                    style: action == TimeSettingsAction.deleteNtp
                        ? FilledButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .error,
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onError,
                          )
                        : null,
                    onPressed:
                        current &&
                            !state.locked &&
                            _impact &&
                            _specific &&
                            (!burst || _burst) &&
                            _target.text == widget.review.target
                        ? () => _finish(true)
                        : null,
                    child: const Text('Apply reviewed change once'),
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
