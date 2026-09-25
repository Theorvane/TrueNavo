import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'api_keys_controller.dart';

Future<void> reviewApiKeyChange({
  required BuildContext context,
  required WidgetRef ref,
  required AuthenticatedSession session,
  required ApiKeyRequest request,
}) async {
  bool current() =>
      identical(session, ref.read(dashboardActiveSessionProvider)) &&
      !ref.read(apiKeysInventoryProvider).isLoading &&
      identical(
        request.inventory,
        ref.read(apiKeysInventoryProvider).asData?.value,
      );
  if (!current() ||
      request.validationError != null ||
      ref.read(apiKeysControllerProvider).locked) {
    return;
  }
  final api = ref.read(apiKeysSessionProvider);
  if (api == null) return;
  var expired = false;
  final connection = ref.listenManual(dashboardActiveSessionProvider, (
    previous,
    next,
  ) {
    if (!identical(previous, next)) expired = true;
  });
  final inventory = ref.listenManual(apiKeysInventoryProvider, (_, next) {
    if (next.isLoading || !identical(next.asData?.value, request.inventory)) {
      expired = true;
    }
  });
  try {
    final review = await api.reviewApiKey(request);
    if (!context.mounted || expired || !current()) return;
    if (review.target != request.target ||
        review.endpoint != session.endpoint ||
        review.action != request.action) {
      throw StateError('API-key review did not match.');
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ApiKeyReviewDialog(
        session: session,
        request: request,
        review: review,
      ),
    );
    if (!context.mounted || confirmed != true || expired || !current()) return;
    final delivery = _ApiKeyDeliveryGuard();
    if (delivery.expired) return;
    WidgetsBinding.instance.addObserver(delivery);
    try {
      final secret = await ref
          .read(apiKeysControllerProvider.notifier)
          .execute(
            expectedSession: session,
            review: review,
            confirmation: review.target,
          );
      delivery.secret = secret;
      if (secret == null) return;
      if (!context.mounted ||
          delivery.expired ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        secret.discard();
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ApiKeySecretDialog(session: session, secret: secret),
      );
    } finally {
      WidgetsBinding.instance.removeObserver(delivery);
      delivery.secret?.discard();
      if (context.mounted && delivery.secret != null) {
        ref
            .read(apiKeysControllerProvider.notifier)
            .noteSecretDiscarded(session);
      }
    }
  } finally {
    connection.close();
    inventory.close();
  }
}

/// Guards delivery even when Flutter suppresses dialog frames while paused.
class _ApiKeyDeliveryGuard with WidgetsBindingObserver {
  _ApiKeyDeliveryGuard() {
    final state = WidgetsBinding.instance.lifecycleState;
    expired = state != null && state != AppLifecycleState.resumed;
  }
  bool expired = false;
  ApiKeyOneTimeSecret? secret;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      expired = true;
      secret?.discard();
    }
  }
}

class ApiKeyReviewDialog extends ConsumerStatefulWidget {
  const ApiKeyReviewDialog({
    required this.session,
    required this.request,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final ApiKeyRequest request;
  final ApiKeyReview review;
  @override
  ConsumerState<ApiKeyReviewDialog> createState() => _ApiKeyReviewDialogState();
}

class _ApiKeyReviewDialogState extends ConsumerState<ApiKeyReviewDialog> {
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
        _acknowledged = false;
        _confirmation.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    ref.listen(apiKeysInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(next.asData?.value, widget.request.inventory)) {
        _expire();
      }
    });
    final inventory = ref.watch(apiKeysInventoryProvider);
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(inventory.asData?.value, widget.request.inventory);
    final locked = ref.watch(apiKeysControllerProvider).locked;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('api-key-review-scroll'),
          child: Padding(
            padding: const EdgeInsets.all(TdSpacing.component),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  current
                      ? 'Review API-key ${widget.review.action.name}'
                      : 'Review is no longer current',
                  style: TdTypography.titleSmall,
                ),
                const SizedBox(height: 16),
                if (!current)
                  const Text(
                    'Previous account and key details are hidden. Close and reload. Nothing was sent.',
                  )
                else ...[
                  Text(widget.review.endpoint),
                  const SizedBox(height: 8),
                  SelectableText(widget.review.target),
                  if (widget.request.key case final key?)
                    Text(
                      'Before: ${key.name} · expiry ${key.expiresAt?.toUtc().toIso8601String() ?? 'Never'}',
                    ),
                  if (widget.review.action != ApiKeyAction.delete)
                    Text(
                      'After: ${widget.request.name} · expiry ${widget.request.serverExpiry?.toIso8601String() ?? 'Never'}',
                    ),
                  const SizedBox(height: 16),
                  for (final warning in widget.review.warnings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(warning),
                    ),
                  CheckboxListTile(
                    key: const Key('api-key-review-ack'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'I understand the credential and client impact.',
                    ),
                    value: _acknowledged,
                    onChanged: locked
                        ? null
                        : (value) =>
                              setState(() => _acknowledged = value == true),
                  ),
                  TextField(
                    key: const Key('api-key-review-confirmation'),
                    controller: _confirmation,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Type the exact target',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      key: const Key('api-key-review-submit'),
                      onPressed:
                          current &&
                              !locked &&
                              _acknowledged &&
                              _confirmation.text == widget.review.target
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
      ),
    );
  }
}

/// Secret stays in this short-lived widget only, never in a provider/controller.
class ApiKeySecretDialog extends ConsumerStatefulWidget {
  const ApiKeySecretDialog({
    required this.session,
    required this.secret,
    super.key,
  });
  final AuthenticatedSession session;
  final ApiKeyOneTimeSecret secret;
  @override
  ConsumerState<ApiKeySecretDialog> createState() => _ApiKeySecretDialogState();
}

class _ApiKeySecretDialogState extends ConsumerState<ApiKeySecretDialog>
    with WidgetsBindingObserver {
  String? _revealed;
  bool _expired = false, _ack = false, _copied = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      widget.secret.discard();
      _expired = true;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _revealed = null;
    widget.secret.discard();
    super.dispose();
  }

  void _discard() {
    widget.secret.discard();
    if (mounted) {
      setState(() {
        _revealed = null;
        _expired = true;
        _ack = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _discard();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) _discard();
    });
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider));
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('api-key-secret-scroll'),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'New API key · one-time delivery',
                  style: TdTypography.titleSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  current
                      ? 'TrueRAID does not store this key. It is discarded on close, backgrounding or connection change. Screenshots and clipboard history may retain a revealed key.'
                      : 'The secret was discarded because the app or connection changed. It cannot be revealed again.',
                ),
                if (current && _revealed == null) ...[
                  CheckboxListTile(
                    key: const Key('api-key-secret-ack'),
                    contentPadding: EdgeInsets.zero,
                    value: _ack,
                    title: const Text(
                      'I am in a private place and ready to save this key securely.',
                    ),
                    onChanged: (value) => setState(() => _ack = value == true),
                  ),
                  FilledButton(
                    key: const Key('api-key-secret-reveal'),
                    onPressed: _ack
                        ? () => setState(() {
                            _revealed = widget.secret.take();
                            if (_revealed == null) _expired = true;
                          })
                        : null,
                    child: const Text('Reveal once'),
                  ),
                ],
                if (current && _revealed != null) ...[
                  const SizedBox(height: 16),
                  SelectableText(
                    _revealed!,
                    key: const Key('api-key-secret-value'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: const Key('api-key-secret-copy'),
                    onPressed: () async {
                      final value = _revealed;
                      if (value == null ||
                          _expired ||
                          !identical(
                            widget.session,
                            ref.read(dashboardActiveSessionProvider),
                          )) {
                        return;
                      }
                      try {
                        await Clipboard.setData(ClipboardData(text: value));
                        if (mounted && !_expired) {
                          setState(() => _copied = true);
                        }
                      } on Object {
                        /* Never include platform errors or secret material. */
                      }
                    },
                    child: Text(
                      _copied
                          ? 'Copied · clipboard history may retain it'
                          : 'Copy to system clipboard',
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                OutlinedButton(
                  key: const Key('api-key-secret-close'),
                  onPressed: () {
                    _discard();
                    Navigator.pop(context);
                  },
                  child: const Text('Close and discard'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
