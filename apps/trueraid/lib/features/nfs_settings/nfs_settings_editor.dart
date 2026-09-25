import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'nfs_settings_controller.dart';

class NfsSettingsEditorDialog extends ConsumerStatefulWidget {
  const NfsSettingsEditorDialog({
    required this.session,
    required this.inventory,
    super.key,
  });
  final AuthenticatedSession session;
  final NfsSettingsInventory inventory;
  @override
  ConsumerState<NfsSettingsEditorDialog> createState() =>
      _NfsSettingsEditorDialogState();
}

class _NfsSettingsEditorDialogState
    extends ConsumerState<NfsSettingsEditorDialog> {
  late final TextEditingController _threads;
  late bool _automatic, _mountdLog, _statdLog;
  late List<String> _protocols, _bindings;
  bool _expired = false, _closing = false;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    final s = widget.inventory.config.settings;
    _threads = TextEditingController(
      text: '${s.serverThreads ?? widget.inventory.config.reportedServers}',
    );
    _automatic = s.serverThreads == null;
    _mountdLog = s.mountdLog;
    _statdLog = s.statdLockdLog;
    _protocols = s.protocols.toList();
    _bindings = s.bindAddresses.toList();
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _clear() {
    _threads.clear();
  }

  void _expire() {
    if (_expired || _closing || !mounted) return;
    ref.read(nfsSettingsControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _clear();
    });
  }

  NfsSettingsRequest get _request => NfsSettingsRequest(
    inventory: widget.inventory,
    settings: NfsGlobalSettings(
      serverThreads: _automatic ? null : int.tryParse(_threads.text) ?? 0,
      protocols: _protocols,
      bindAddresses: _bindings,
      mountdLog: _mountdLog,
      statdLockdLog: _statdLog,
    ),
  );
  void _finish(NfsSettingsRequest? request) {
    _closing = true;
    _clear();
    Navigator.of(context).pop(request);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _clear();
    _threads.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      ref.read(nfsSettingsControllerProvider.notifier).abandonRoute();
      scheduleMicrotask(() {
        if (mounted) _clear();
      });
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(nfsSettingsInventoryProvider, (_, next) {
      if (next.isLoading || !identical(widget.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(nfsSettingsInventoryProvider);
    final current =
        !_expired &&
        !_closing &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(inventory.asData?.value, widget.inventory);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('nfs-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Edit global NFS settings'
                    : 'NFS settings editor expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server fields were cleared. Reload configuration and begin again.',
                )
              else ...[
                const Text(
                  'Configure NFS while stopped. No service start, client test or performance probe is offered. Protected fields and exports remain unchanged.',
                ),
                CheckboxListTile(
                  key: const Key('nfs-automatic'),
                  contentPadding: EdgeInsets.zero,
                  value: _automatic,
                  title: const Text('Automatic thread tuning'),
                  subtitle: const Text(
                    'Server chooses 1–32 from CPU cores; this is not utilization.',
                  ),
                  onChanged: (v) => setState(() => _automatic = v ?? true),
                ),
                if (!_automatic)
                  TextField(
                    key: const Key('nfs-threads'),
                    controller: _threads,
                    keyboardType: TextInputType.number,
                    maxLength: 3,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Server threads (1–256)',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                const SizedBox(height: 12),
                const Text('Supported protocol versions'),
                for (final protocol in ['NFSV3', 'NFSV4'])
                  CheckboxListTile(
                    key: Key('nfs-protocol-$protocol'),
                    contentPadding: EdgeInsets.zero,
                    value: _protocols.contains(protocol),
                    title: Text(protocol),
                    onChanged: widget.inventory.enabledExportCount == 0
                        ? (value) => setState(() {
                            if (value == true) {
                              _protocols.add(protocol);
                            } else {
                              _protocols.remove(protocol);
                            }
                          })
                        : null,
                  ),
                if (widget.inventory.enabledExportCount != 0)
                  const Text(
                    'Disable all configured exports independently before changing protocols or bindings.',
                  ),
                const SizedBox(height: 12),
                const Text('Static interface bindings'),
                Text(
                  'Current: ${_bindings.isEmpty ? 'All interfaces when started' : _bindings.join(', ')}',
                ),
                const Text(
                  'IPv4 choices only; existing IPv6 bindings are preserved and cannot be edited here. An empty selection listens on all interfaces when started.',
                ),
                for (final address in widget.inventory.bindChoices.where(
                  (v) => !v.contains(':'),
                ))
                  CheckboxListTile(
                    key: Key('nfs-bind-$address'),
                    contentPadding: EdgeInsets.zero,
                    value: _bindings.contains(address),
                    title: Text(address),
                    onChanged:
                        widget.inventory.enabledExportCount == 0 &&
                            !widget.inventory.config.settings.bindAddresses.any(
                              (v) => v.contains(':'),
                            )
                        ? (value) => setState(() {
                            if (value == true) {
                              _bindings.add(address);
                            } else {
                              _bindings.remove(address);
                            }
                          })
                        : null,
                  ),
                CheckboxListTile(
                  key: const Key('nfs-mountd-log'),
                  contentPadding: EdgeInsets.zero,
                  value: _mountdLog,
                  title: const Text('Mountd logging'),
                  subtitle: const Text('Changing this also reloads syslogd.'),
                  onChanged: (v) => setState(() => _mountdLog = v ?? false),
                ),
                CheckboxListTile(
                  key: const Key('nfs-statd-log'),
                  contentPadding: EdgeInsets.zero,
                  value: _statdLog,
                  title: const Text('Statd / lockd logging'),
                  onChanged: (v) => setState(() => _statdLog = v ?? false),
                ),
                if (_request.validationError != null)
                  Text(_request.validationError!),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('nfs-editor-cancel'),
                    onPressed: () => _finish(null),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('nfs-editor-review'),
                    onPressed: current && _request.validationError == null
                        ? () => _finish(_request)
                        : null,
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
}
