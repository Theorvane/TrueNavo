import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'smb_shares_controller.dart';

/// A review is session-issued and single-use. No submitted operation is retried.
Future<void> reviewSmbShareChange({
  required BuildContext context,
  required WidgetRef ref,
  required AuthenticatedSession session,
  required SmbShareRequest request,
}) async {
  final inventory = request.inventory;
  bool current() =>
      identical(session, ref.read(dashboardActiveSessionProvider)) &&
      !ref.read(smbSharesInventoryProvider).isLoading &&
      identical(inventory, ref.read(smbSharesInventoryProvider).asData?.value);
  if (!current() ||
      request.validationError != null ||
      ref.read(smbSharesControllerProvider).locked) {
    return;
  }
  final api = ref.read(smbSharesSessionProvider);
  if (api == null) return;
  var expired = false;
  final connection = ref.listenManual(dashboardActiveSessionProvider, (
    previous,
    next,
  ) {
    if (!identical(previous, next)) expired = true;
  });
  final data = ref.listenManual(smbSharesInventoryProvider, (_, next) {
    if (next.isLoading || !identical(next.asData?.value, inventory)) {
      expired = true;
    }
  });
  try {
    final review = await api.reviewSmbShare(request);
    if (!context.mounted || expired || !current()) return;
    if (review.target != request.target || review.action != request.action) {
      throw StateError('Review does not match the requested share.');
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SmbShareReviewDialog(
        session: session,
        request: request,
        review: review,
      ),
    );
    if (!context.mounted || confirmed != true || expired || !current()) return;
    await ref
        .read(smbSharesControllerProvider.notifier)
        .execute(
          expectedSession: session,
          review: review,
          confirmation: review.target,
        );
  } finally {
    connection.close();
    data.close();
  }
}

class SmbShareReviewDialog extends ConsumerStatefulWidget {
  const SmbShareReviewDialog({
    required this.session,
    required this.request,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final SmbShareRequest request;
  final SmbShareReview review;
  @override
  ConsumerState<SmbShareReviewDialog> createState() =>
      _SmbShareReviewDialogState();
}

class _SmbShareReviewDialogState extends ConsumerState<SmbShareReviewDialog> {
  final _confirmation = TextEditingController();
  bool _acknowledged = false, _expired = false;
  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  void _expire() {
    if (!_expired) {
      setState(() {
        _expired = true;
        _confirmation.clear();
        _acknowledged = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(smbSharesInventoryProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final locked = ref.watch(smbSharesControllerProvider).locked;
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    ref.listen(smbSharesInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(next.asData?.value, widget.request.inventory)) {
        _expire();
      }
    });
    final current =
        !_expired &&
        identical(widget.session, session) &&
        !inventory.isLoading &&
        identical(widget.request.inventory, inventory.asData?.value);
    final review = widget.review;
    final deleting = review.action == SmbShareAction.delete;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 740),
        child: SingleChildScrollView(
          key: const Key('smb-review-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Padding(
            padding: const EdgeInsets.all(TdSpacing.component),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  current
                      ? 'Review ${deleting
                            ? 'share deletion'
                            : review.action == SmbShareAction.create
                            ? 'new share'
                            : 'share changes'}'
                      : 'Review is no longer current',
                  style: TdTypography.titleSmall,
                ),
                const SizedBox(height: TdSpacing.component),
                if (!current)
                  const Text(
                    'Previous connection, share and review details are hidden. Close this review and reload. Nothing was sent.',
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Authenticated endpoint',
                        style: TdTypography.label,
                      ),
                      SelectableText(widget.session.endpoint ?? 'Unavailable'),
                      const SizedBox(height: TdSpacing.related),
                      const Text('Exact target', style: TdTypography.label),
                      SelectableText(review.target),
                      SelectableText(review.identity),
                      const SizedBox(height: TdSpacing.component),
                      if (widget.request.share case final share?) ...[
                        const Text('Before', style: TdTypography.titleSmall),
                        Text('Name: ${share.name}'),
                        Text('Path: ${share.path}'),
                        Text(
                          'Comment: ${share.comment.isEmpty ? 'None' : share.comment}',
                        ),
                        Text(
                          'Read-only: ${share.readonly}; enabled: ${share.enabled}',
                        ),
                      ],
                      if (widget.request.settings case final settings?) ...[
                        const SizedBox(height: TdSpacing.related),
                        const Text('After', style: TdTypography.titleSmall),
                        Text('Name: ${settings.name}'),
                        Text(
                          'Path: ${widget.request.dataset?.mountpoint ?? widget.request.share!.path}',
                        ),
                        Text(
                          'Comment: ${settings.comment.isEmpty ? 'None' : settings.comment}',
                        ),
                        Text(
                          'Read-only: ${settings.readonly}; enabled: ${settings.enabled}',
                        ),
                      ],
                      const SizedBox(height: TdSpacing.component),
                      TdPanel(
                        title: 'Reviewed changes',
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
                      Text(
                        deleting
                            ? 'Deleting this share can disconnect clients and remove its protocol share ACL. The dataset and files are not deleted.'
                            : 'Saving can reload SMB configuration and affect clients. Read-only or enabled-state changes can reject access and pending I/O.',
                      ),
                      const Text(
                        'Quiesce clients and flush pending writes first. This workspace does not start services, edit filesystem permissions, or prove client connectivity.',
                      ),
                      const SizedBox(height: TdSpacing.component),
                      TextField(
                        key: const Key('smb-confirm-target'),
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
                          key: const Key('smb-confirm-impact'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _acknowledged,
                          onChanged: (v) =>
                              setState(() => _acknowledged = v ?? false),
                          title: const Text(
                            'I reviewed the exact share and understand the effect on existing clients.',
                          ),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: TdSpacing.component),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: TdSpacing.related,
                  runSpacing: TdSpacing.related,
                  children: [
                    TextButton(
                      key: const Key('smb-confirm-cancel'),
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(current ? 'Cancel' : 'Close'),
                    ),
                    FilledButton(
                      key: const Key('smb-confirm-submit'),
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
