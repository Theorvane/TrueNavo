import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'disks_controller.dart';

class DisksEditor extends ConsumerStatefulWidget {
  const DisksEditor({
    required this.session,
    required this.inventory,
    required this.disk,
    super.key,
  });
  final AuthenticatedSession session;
  final DiskInventory inventory;
  final DiskSnapshot disk;
  @override
  ConsumerState<DisksEditor> createState() => _DisksEditorState();
}

class _DisksEditorState extends ConsumerState<DisksEditor> {
  late final TextEditingController _description;
  late String _standby, _apm;
  late final AppLifecycleListener _lifecycle;
  bool _expired = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _description = TextEditingController(text: widget.disk.description);
    _standby = widget.disk.hddStandby;
    _apm = widget.disk.advancedPowerManagement;
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
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
      _description.clear();
      _error = null;
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(disksInventoryProvider, (_, b) {
      if (b.isLoading || !identical(widget.inventory, b.asData?.value)) {
        _expire();
      }
    });
    final data = ref.watch(disksInventoryProvider);
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !data.isLoading &&
        identical(widget.inventory, data.asData?.value);
    final powerAllowed = widget.disk.powerManagementBlockedReason == null;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: SingleChildScrollView(
          key: const Key('disks-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current ? 'Edit disk settings' : 'Editor expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (!current)
                const Text(
                  'Previous server details are hidden. Reload and review again.',
                )
              else ...[
                SelectableText(widget.session.endpoint!),
                SelectableText(
                  '${widget.disk.name} · ${widget.disk.identifier}',
                ),
                Text('Serial: ${widget.disk.serial}'),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('disk-description'),
                  controller: _description,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'Description'),
                  autocorrect: false,
                  enableSuggestions: false,
                ),
                const SizedBox(height: 12),
                _choice(
                  'disk-standby',
                  'HDD standby',
                  _standby,
                  DiskSettings.standbyChoices,
                  powerAllowed,
                  (v) => _standby = v,
                ),
                const SizedBox(height: 12),
                _choice(
                  'disk-apm',
                  'Advanced power management',
                  _apm,
                  DiskSettings.apmChoices,
                  powerAllowed,
                  (v) => _apm = v,
                ),
                const SizedBox(height: 12),
                Text(
                  widget.disk.powerManagementBlockedReason ?? 'Power policies can increase access latency and spin-down cycles. The server saves the policy; independent readback cannot prove that the hardware applied it.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'No wipe, formatting, partition, encryption password or SMART test is part of this edit.',
                ),
                if (_error != null)
                  Text(_error!, key: const Key('disk-editor-error')),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('disk-editor-review'),
                    onPressed: !current
                        ? null
                        : () {
                            final settings = DiskSettings(
                              description: _description.text,
                              hddStandby: _standby,
                              advancedPowerManagement: _apm,
                            );
                            final request = DiskRequest(
                              inventory: widget.inventory,
                              disk: widget.disk,
                              settings: settings,
                            );
                            if (request.validationError case final error?) {
                              setState(() => _error = error);
                              return;
                            }
                            Navigator.of(context).pop(settings);
                          },
                    child: const Text('Review change'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _choice(
    String key,
    String label,
    String value,
    List<String> choices,
    bool enabled,
    void Function(String) update,
  ) => DropdownButtonFormField<String>(
    key: Key(key),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      ...{value, ...choices},
    ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
    onChanged: !enabled
        ? null
        : (v) {
            if (v != null) setState(() => update(v));
          },
  );
}
