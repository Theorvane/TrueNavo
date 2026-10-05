import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'system_power_controller.dart';
import 'system_power_identity.dart';

class SystemPowerReasonDialog extends ConsumerStatefulWidget {
  const SystemPowerReasonDialog({
    required this.session,
    required this.inventory,
    required this.action,
    super.key,
  });
  final AuthenticatedSession session;
  final SystemPowerInventory inventory;
  final SystemPowerAction action;
  @override
  ConsumerState<SystemPowerReasonDialog> createState() =>
      _SystemPowerReasonDialogState();
}

class _SystemPowerReasonDialogState
    extends ConsumerState<SystemPowerReasonDialog> {
  final _reason = TextEditingController();
  bool _expired = false;
  String? _error;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _expired = state != null && state != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _reason.clear();
      _error = null;
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(systemPowerInventoryProvider, (_, next) {
      if (next.isLoading || !identical(widget.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(systemPowerInventoryProvider);
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.inventory, inventory.asData?.value);
    final locked = ref.watch(systemPowerControllerProvider).locked;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('power-reason-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? systemPowerLabel(widget.action)
                    : 'Power draft expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details and the draft are hidden. Reload and review again.',
                )
              else ...[
                SelectableText(widget.inventory.endpoint),
                const SizedBox(height: 12),
                const Text(
                  'This interrupts all clients, shares, applications and virtual machines. Arrange a maintenance window and independent server access first.',
                ),
                if (widget.action == SystemPowerAction.shutdown)
                  const Text(
                    'Shutdown leaves the server offline. This app cannot turn it back on; arrange physical or independent management access.',
                  ),
                TextField(
                  key: const Key('power-reason'),
                  controller: _reason,
                  maxLength: 256,
                  minLines: 2,
                  maxLines: 4,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Audit reason',
                    helperText: 'Required. No credentials, surrounding spaces or line breaks.',
                  ),
                ),
                if (_error != null) Text(_error!),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('power-reason-review'),
                    onPressed: current && !locked
                        ? () {
                            final request = SystemPowerRequest(
                              inventory: widget.inventory,
                              action: widget.action,
                              reason: _reason.text,
                            );
                            if (request.validationError != null) {
                              setState(() => _error = request.validationError);
                              return;
                            }
                            Navigator.of(context).pop(request);
                          }
                        : null,
                    child: const Text('Review impact'),
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
