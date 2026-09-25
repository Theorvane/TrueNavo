import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'ssh_credentials_controller.dart';

class SshCredentialsReviewDialog extends ConsumerStatefulWidget {
  const SshCredentialsReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final SshCredentialReview review;
  @override
  ConsumerState<SshCredentialsReviewDialog> createState() =>
      _SshCredentialsReviewDialogState();
}

class _SshCredentialsReviewDialogState
    extends ConsumerState<SshCredentialsReviewDialog> {
  final _confirmation = TextEditingController();
  bool _ack = false, _expired = false;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) _expire();
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _ack = false;
      _confirmation.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(sshCredentialsInventoryProvider, (_, b) {
      if (b.isLoading ||
          !identical(widget.review.request.inventory, b.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(sshCredentialsInventoryProvider);
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.review.request.inventory, inventory.asData?.value);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('ssh-credential-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review ${widget.review.action.name}'
                    : 'Review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'The previous server details are hidden. Reload and review again.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                SelectableText(widget.review.target),
                if (widget.review.action != SshCredentialAction.delete)
                  Text('New name: ${widget.review.request.name}'),
                if (widget.review.request.credential case final credential?)
                  Text(
                    'Existing ${credential.type} · ID ${credential.id} · ${credential.usageCount} dependencies',
                  ),
                if (widget.review.request.connection
                    case final connection?) ...[
                  Text(
                    'Destination: ${connection.username}@${connection.host}:${connection.port}',
                  ),
                  Text('Keypair ID: ${connection.keyPairId}'),
                  Text(
                    'Connection timeout: ${connection.connectTimeout} seconds',
                  ),
                ],
                for (final warning in widget.review.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(warning),
                  ),
                TextField(
                  key: const Key('ssh-credential-confirm-target'),
                  controller: _confirmation,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Type the exact target',
                    helperText: 'Case-sensitive; no trimming.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                CheckboxListTile(
                  key: const Key('ssh-credential-confirm-impact'),
                  contentPadding: EdgeInsets.zero,
                  value: _ack,
                  onChanged: (v) => setState(() => _ack = v ?? false),
                  title: const Text(
                    'I understand this change and its effect on every referencing task.',
                  ),
                ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('ssh-credential-confirm-submit'),
                    onPressed:
                        current &&
                            !ref
                                .watch(sshCredentialsControllerProvider)
                                .locked &&
                            _ack &&
                            _confirmation.text == widget.review.target
                        ? () => Navigator.of(context).pop(true)
                        : null,
                    child: const Text('Confirm once'),
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
