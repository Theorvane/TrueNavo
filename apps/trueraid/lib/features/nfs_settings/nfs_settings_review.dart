import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'nfs_settings_controller.dart';

String nfsThreads(int? value) =>
    value == null ? 'Automatic (server-computed)' : '$value manual threads';

class NfsSettingsDiff extends StatelessWidget {
  const NfsSettingsDiff({required this.request, super.key});
  final NfsSettingsRequest request;
  @override
  Widget build(BuildContext context) {
    final before = request.inventory.config.settings, after = request.settings;
    final fields = <String, (String, String)>{
      'Threads': (
        nfsThreads(before.serverThreads),
        nfsThreads(after.serverThreads),
      ),
      'Protocols': (before.protocols.join(', '), after.protocols.join(', ')),
      'Bindings': (
        before.bindAddresses.isEmpty
            ? 'All interfaces'
            : before.bindAddresses.join(', '),
        after.bindAddresses.isEmpty
            ? 'All interfaces'
            : after.bindAddresses.join(', '),
      ),
      'Mountd log': ('${before.mountdLog}', '${after.mountdLog}'),
      'Statd / lockd log': (
        '${before.statdLockdLog}',
        '${after.statdLockdLog}',
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in fields.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('${item.key}: ${item.value.$1} → ${item.value.$2}'),
          ),
        const Text(
          'Protected settings, ports, exports and service start-at-boot flag remain unchanged.',
        ),
      ],
    );
  }
}

class NfsSettingsReviewDialog extends ConsumerStatefulWidget {
  const NfsSettingsReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final NfsSettingsReview review;
  @override
  ConsumerState<NfsSettingsReviewDialog> createState() =>
      _NfsSettingsReviewDialogState();
}

class _NfsSettingsReviewDialogState
    extends ConsumerState<NfsSettingsReviewDialog> {
  final _target = TextEditingController();
  bool _impact = false,
      _specific = false,
      _bindings = false,
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
    ref.read(nfsSettingsControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _impact = false;
      _specific = false;
      _bindings = false;
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
      _impact = false;
      _specific = false;
      _bindings = false;
      ref.read(nfsSettingsControllerProvider.notifier).abandonRoute();
      scheduleMicrotask(() {
        if (mounted) _target.clear();
      });
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(nfsSettingsInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(widget.review.request.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(nfsSettingsInventoryProvider),
        state = ref.watch(nfsSettingsControllerProvider);
    final current =
        !_expired &&
        !_closing &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(inventory.asData?.value, widget.review.request.inventory) &&
        ref
            .read(nfsSettingsControllerProvider.notifier)
            .isReviewCurrent(widget.review);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('nfs-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review global NFS change'
                    : 'NFS settings review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details are hidden. Reload configuration and begin a new review.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                const SizedBox(height: 12),
                NfsSettingsDiff(request: widget.review.request),
                const SizedBox(height: 12),
                const Text(
                  'This writes NFS configuration while stopped. Keep the service stopped and coordinate client recovery independently. Checks are non-atomic: a concurrent start can cause restart, client interruption and export regeneration, including host/user resolution and generated export cleanup.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Changing mountd logging also reloads syslogd. Configuration writes regenerate rc settings and can precede a later failure; no rollback is promised. No service start, client test, automatic retry or polling is offered.',
                ),
                if (widget.review.warnings.isNotEmpty)
                  ExpansionTile(
                    key: const Key('nfs-review-details'),
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Additional server/adapter details'),
                    children: [
                      for (final warning in widget.review.warnings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(warning),
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                const Text(
                  'This single-use review expires after five minutes. Type the full target exactly.',
                ),
                SelectableText(widget.review.target),
                TextField(
                  key: const Key('nfs-confirm-target'),
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
                  key: const Key('nfs-confirm-impact'),
                  contentPadding: EdgeInsets.zero,
                  value: _impact,
                  onChanged: (value) =>
                      setState(() => _impact = value ?? false),
                  title: const Text(
                    'I authorize the displayed configuration write, rc generation and any logging-service reload.',
                  ),
                ),
                CheckboxListTile(
                  key: const Key('nfs-confirm-specific'),
                  contentPadding: EdgeInsets.zero,
                  value: _specific,
                  onChanged: (v) => setState(() => _specific = v ?? false),
                  title: const Text(
                    'I independently coordinated the stopped service, client interruption and recovery; verified configuration is not proof of client access.',
                  ),
                ),
                if (widget.review.request.changesBindings)
                  CheckboxListTile(
                    key: const Key('nfs-confirm-bindings'),
                    contentPadding: EdgeInsets.zero,
                    value: _bindings,
                    onChanged: (v) => setState(() => _bindings = v ?? false),
                    title: const Text(
                      'I reviewed interface exposure and firewall/client access; an empty binding permits all interfaces when started.',
                    ),
                  ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('nfs-review-cancel'),
                    onPressed: () => _finish(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('nfs-confirm-submit'),
                    onPressed:
                        current &&
                            !state.locked &&
                            _impact &&
                            _specific &&
                            (!widget.review.request.changesBindings ||
                                _bindings) &&
                            _target.text == widget.review.target
                        ? () => _finish(true)
                        : null,
                    child: const Text('Apply global NFS change'),
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
