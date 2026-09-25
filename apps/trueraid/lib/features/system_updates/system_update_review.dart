import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'system_updates_controller.dart';

List<String> systemUpdateImpact(SystemUpdateAction action) => switch (action) {
  SystemUpdateAction.check => const [
    'Checking contacts the upstream update source and may initialize the server update profile. Opening this page and reloading local information do not contact the update source.',
  ],
  SystemUpdateAction.download => const [
    'Download writes the update image into server staging storage. TrueNAS can retry internally; this app submits only once.',
    'Download completion is not independent checksum verification and does not prove the image can be installed.',
  ],
  SystemUpdateAction.install => const [
    'Installation changes the operating system and boot selection. Every inactive boot environment must already have Keep enabled because the installer can prune unprotected environments.',
    'Reported raw boot-pool free space is not proof of sufficient installation capacity. Keep a verified configuration backup and recovery access.',
    'This workflow never uploads an image, resumes an installation, or requests an automatic reboot. After success, independently verify the installed environment and next-boot selection in TrueNAS.',
  ],
};

Future<void> reviewSystemUpdateChange({
  required BuildContext context,
  required WidgetRef ref,
  required AuthenticatedSession session,
  required SystemUpdateRequest request,
}) async {
  bool current() =>
      identical(session, ref.read(dashboardActiveSessionProvider)) &&
      !ref.read(systemUpdatesInventoryProvider).isLoading &&
      identical(
        request.inventory,
        ref.read(systemUpdatesInventoryProvider).asData?.value,
      );
  if (!current() ||
      request.validationError != null ||
      ref.read(systemUpdatesControllerProvider).locked) {
    return;
  }
  final api = ref.read(systemUpdatesSessionProvider);
  if (api == null) return;
  var expired = false;
  final connection = ref.listenManual(dashboardActiveSessionProvider, (
    previous,
    next,
  ) {
    if (!identical(previous, next)) expired = true;
  });
  final inventory = ref.listenManual(systemUpdatesInventoryProvider, (_, next) {
    if (next.isLoading || !identical(next.asData?.value, request.inventory)) {
      expired = true;
    }
  });
  try {
    final review = await api.reviewSystemUpdate(request);
    if (!context.mounted || expired || !current()) return;
    if (review.endpoint != session.endpoint ||
        !identical(review.request, request)) {
      throw StateError('The review does not match the exact request.');
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          SystemUpdateReviewDialog(session: session, review: review),
    );
    if (!context.mounted || confirmed != true || expired || !current()) return;
    await ref
        .read(systemUpdatesControllerProvider.notifier)
        .execute(
          expectedSession: session,
          review: review,
          confirmation: review.target,
        );
  } finally {
    connection.close();
    inventory.close();
  }
}

class SystemUpdateReviewDialog extends ConsumerStatefulWidget {
  const SystemUpdateReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final SystemUpdateReview review;
  @override
  ConsumerState<SystemUpdateReviewDialog> createState() =>
      _SystemUpdateReviewDialogState();
}

class _SystemUpdateReviewDialogState
    extends ConsumerState<SystemUpdateReviewDialog> {
  final _confirmation = TextEditingController();
  bool _acknowledged = false, _expired = false;
  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _confirmation.clear();
      _acknowledged = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(systemUpdatesInventoryProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final locked = ref.watch(systemUpdatesControllerProvider).locked;
    final review = widget.review;
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    ref.listen(systemUpdatesInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(next.asData?.value, review.request.inventory)) {
        _expire();
      }
    });
    final current =
        !_expired &&
        identical(widget.session, session) &&
        !inventory.isLoading &&
        identical(review.request.inventory, inventory.asData?.value);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 740),
        child: SingleChildScrollView(
          key: const Key('updates-review-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Padding(
            padding: const EdgeInsets.all(TdSpacing.component),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  current
                      ? 'Review ${review.action.name}'
                      : 'Review is no longer current',
                  style: TdTypography.titleSmall,
                ),
                const SizedBox(height: TdSpacing.component),
                if (!current)
                  const Text(
                    'Previous server and release details are hidden. Close this review and reload. Nothing was sent.',
                  )
                else ...[
                  const Text(
                    'Authenticated endpoint',
                    style: TdTypography.label,
                  ),
                  SelectableText(review.endpoint),
                  const SizedBox(height: TdSpacing.related),
                  const Text('Exact target', style: TdTypography.label),
                  SelectableText(review.target),
                  Text(
                    'Current version: ${review.request.inventory.currentVersion}',
                  ),
                  if (review.request.version case final version?) ...[
                    Text('Train: ${version.train}'),
                    Text('Release: ${version.version}'),
                    Text('Profile: ${version.profile}'),
                    Text('Image: ${version.filename}'),
                    SelectableText(
                      'Source-reported checksum (not independently verified): ${version.checksum}',
                    ),
                  ],
                  const SizedBox(height: TdSpacing.component),
                  for (final warning in [
                    ...systemUpdateImpact(review.action),
                    ...review.warnings,
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: TdSpacing.related),
                      child: Text(warning),
                    ),
                  TextField(
                    key: const Key('updates-confirm-target'),
                    controller: _confirmation,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Type the exact target shown above',
                      helperText:
                          'Case-sensitive. No trimming or approximation.',
                      helperMaxLines: 3,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  Material(
                    type: MaterialType.transparency,
                    child: CheckboxListTile(
                      key: const Key('updates-confirm-impact'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _acknowledged,
                      onChanged: (value) =>
                          setState(() => _acknowledged = value ?? false),
                      title: const Text(
                        'I reviewed the exact server and target and understand these effects.',
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: TdSpacing.component),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: TdSpacing.related,
                  runSpacing: TdSpacing.related,
                  children: [
                    TextButton(
                      key: const Key('updates-confirm-cancel'),
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(current ? 'Cancel' : 'Close'),
                    ),
                    FilledButton(
                      key: const Key('updates-confirm-submit'),
                      onPressed:
                          current &&
                              !locked &&
                              _acknowledged &&
                              _confirmation.text == review.target
                          ? () => Navigator.of(context).pop(true)
                          : null,
                      child: const Text('Submit once'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
