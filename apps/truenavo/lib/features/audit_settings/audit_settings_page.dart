import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

class AuditSettingsPage extends ConsumerStatefulWidget {
  const AuditSettingsPage({super.key});

  @override
  ConsumerState<AuditSettingsPage> createState() => _AuditSettingsPageState();
}

class _AuditSettingsPageState extends ConsumerState<AuditSettingsPage> {
  AuditSettingsInventory? _inventory;
  String? _message;
  bool _loading = false, _working = false, _unknown = false;
  Object? _lockOwner;
  ServerOperationLock? _lock;

  bool get _routeCurrent =>
      mounted &&
      ModalRoute.of(context)?.isCurrent == true &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  @override
  void dispose() {
    // An interrupted dispatch is intentionally not unlocked here.
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || _working || _unknown) return;
    final session = ref.read(dashboardActiveSessionProvider);
    final repository = session?.repository;
    final api = repository is AuthenticatedAuditSettingsSession
        ? repository as AuthenticatedAuditSettingsSession
        : null;
    if (session == null || api == null) return;
    setState(() {
      _loading = true;
      _inventory = null;
      _message = null;
    });
    try {
      final inventory = await api.loadAuditSettings();
      if (!_routeCurrent ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          inventory.endpoint != session.endpoint) {
        return;
      }
      setState(() => _inventory = inventory);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _message = error is AuditSettingsException
              ? error.userMessage
              : 'Audit configuration is unavailable.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit(
    AuthenticatedSession session,
    AuthenticatedAuditSettingsSession api,
    AuditSettingsInventory inventory, {
    bool storage = false,
  }) async {
    if (_working || _unknown || !_routeCurrent) return;
    var days = inventory.settings.retentionDays;
    var reservation = inventory.settings.reservationGiB;
    var quota = inventory.settings.quotaGiB;
    var warning = inventory.settings.warningPercent;
    var critical = inventory.settings.criticalPercent;
    var evidence = false, dataset = false;
    AuditSettingsRequest candidate() => AuditSettingsRequest(
      inventory: inventory,
      retentionDays: days,
      reservationGiB: storage ? reservation : null,
      quotaGiB: storage ? quota : null,
      warningPercent: storage ? warning : null,
      criticalPercent: storage ? critical : null,
      shorterRetentionAccepted: evidence,
      datasetImpactAccepted: dataset,
    );
    final request = await showDialog<AuditSettingsRequest>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          final proposed = candidate();
          return AlertDialog(
            title: Text(
              storage ? "Review audit storage" : "Review audit retention",
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      storage
                          ? "Reservation guarantees pool space. Quota caps audit data; zero disables quota only with zero reservation."
                          : "Choose 1–30 days. Shortening retention may remove security evidence.",
                    ),
                    const SizedBox(height: 12),
                    if (!storage)
                      DropdownButtonFormField<int>(
                        initialValue: days,
                        decoration: const InputDecoration(
                          labelText: "Retention days",
                        ),
                        items: [
                          for (var value = 1; value <= 30; value++)
                            DropdownMenuItem(
                              value: value,
                              child: Text("$value days"),
                            ),
                        ],
                        onChanged: (value) =>
                            update(() => days = value ?? days),
                      ),
                    if (storage) ...[
                      DropdownButtonFormField<int>(
                        initialValue: reservation,
                        decoration: const InputDecoration(
                          labelText: "Reservation GiB",
                        ),
                        items: [
                          for (var value = 0; value <= 100; value++)
                            DropdownMenuItem(
                              value: value,
                              child: Text(value.toString()),
                            ),
                        ],
                        onChanged: (value) =>
                            update(() => reservation = value ?? reservation),
                      ),
                      DropdownButtonFormField<int>(
                        initialValue: quota,
                        decoration: const InputDecoration(
                          labelText: "Quota GiB (0 disables)",
                        ),
                        items: [
                          for (var value = 0; value <= 100; value++)
                            DropdownMenuItem(
                              value: value,
                              child: Text(value.toString()),
                            ),
                        ],
                        onChanged: (value) =>
                            update(() => quota = value ?? quota),
                      ),
                      DropdownButtonFormField<int>(
                        initialValue: warning,
                        decoration: const InputDecoration(
                          labelText: "Warning percent",
                        ),
                        items: [
                          for (var value = 5; value <= 80; value++)
                            DropdownMenuItem(
                              value: value,
                              child: Text("$value%"),
                            ),
                        ],
                        onChanged: (value) =>
                            update(() => warning = value ?? warning),
                      ),
                      DropdownButtonFormField<int>(
                        initialValue: critical,
                        decoration: const InputDecoration(
                          labelText: "Critical percent",
                        ),
                        items: [
                          for (var value = 50; value <= 95; value++)
                            DropdownMenuItem(
                              value: value,
                              child: Text("$value%"),
                            ),
                        ],
                        onChanged: (value) =>
                            update(() => critical = value ?? critical),
                      ),
                    ],
                    if (!storage)
                      CheckboxListTile(
                        value: evidence,
                        onChanged: (value) =>
                            update(() => evidence = value ?? false),
                        title: const Text(
                          "I understand shorter retention can remove audit evidence and reports.",
                        ),
                      ),
                    CheckboxListTile(
                      value: dataset,
                      onChanged: (value) =>
                          update(() => dataset = value ?? false),
                      title: const Text(
                        "I understand this can change audit ZFS properties and pool capacity.",
                      ),
                    ),
                    if (proposed.validationError case final error?)
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text("Cancel"),
              ),
              FilledButton(
                onPressed: proposed.validationError == null
                    ? () => Navigator.pop(dialog, proposed)
                    : null,
                child: const Text("Review"),
              ),
            ],
          );
        },
      ),
    );
    if (request == null ||
        !_routeCurrent ||
        !identical(session, ref.read(dashboardActiveSessionProvider)) ||
        !identical(_inventory, inventory)) {
      return;
    }
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final review = await api.reviewAuditSettings(request);
      if (!_routeCurrent ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(_inventory, inventory)) {
        return;
      }
      final targetController = TextEditingController();
      String? confirmation;
      try {
        if (!mounted) return;
        confirmation = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (dialog) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
              title: const Text('Confirm audit retention'),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final warning in review.warnings) ...[
                        Text(warning),
                        const SizedBox(height: 8),
                      ],
                      SelectableText(review.target),
                      TextField(
                        controller: targetController,
                        decoration: const InputDecoration(
                          labelText: 'Type the exact confirmation above',
                        ),
                        onChanged: (_) => update(() {}),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: targetController.text == review.target
                      ? () => Navigator.pop(dialog, targetController.text)
                      : null,
                  child: const Text('Submit once'),
                ),
              ],
            ),
          ),
        );
      } finally {
        targetController.dispose();
      }
      if (confirmation != review.target ||
          !_routeCurrent ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(_inventory, inventory)) {
        return;
      }
      _lock = ref.read(serverOperationLockProvider);
      _lockOwner = _lock!.acquire();
      if (_lockOwner == null) {
        setState(
          () => _message = 'Another management operation is unresolved.',
        );
        return;
      }
      bool current() =>
          _routeCurrent &&
          identical(session, ref.read(dashboardActiveSessionProvider)) &&
          identical(_inventory, inventory);
      final result = await api.executeAuditSettings(
        review,
        confirmation!,
        isCurrent: current,
      );
      if (!current()) {
        _unknown = true;
        return;
      }
      setState(() {
        _message = result.message;
        _unknown = result.outcome == AuditSettingsOutcome.unknown;
        _inventory = null;
      });
      if (!_unknown) {
        _lock!.release(_lockOwner!);
        _lockOwner = null;
      }
    } on Object catch (error) {
      if (_lockOwner != null) {
        _unknown = true;
        if (mounted) {
          setState(
            () => _message = 'The audit update outcome is uncertain. Inspect the original server before another write.',
          );
        }
      } else if (mounted) {
        setState(
          () => _message = error is AuditSettingsException
              ? error.userMessage
              : 'Audit review failed. No update was submitted.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final repository = session?.repository;
    final api = repository is AuthenticatedAuditSettingsSession
        ? repository as AuthenticatedAuditSettingsSession
        : null;
    final capable = api?.auditSettingsCapabilities;
    final inventory = _inventory;
    final settings = inventory?.settings;
    final total = settings == null
        ? 0
        : settings.usedBytes + settings.availableBytes;
    final quotaBytes = settings == null
        ? 0
        : settings.quotaGiB * 1024 * 1024 * 1024;
    final quotaUsed = settings == null
        ? 0
        : settings.usedByDatasetBytes + settings.usedBySnapshotsBytes;
    return Scaffold(
      appBar: AppBar(title: const Text('Audit storage & retention')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Local audit configuration and dataset usage snapshot. '
            'These charts do not prove complete event capture or remote delivery.',
          ),
          const SizedBox(height: 16),
          if (capable?.supported != true)
            const Text(
              'Stable TrueNAS 25.10 audit configuration is unavailable.',
            ),
          if (_message != null) Text(_message!),
          if (_unknown)
            const Text(
              'Further writes are blocked until the original server is independently inspected.',
            ),
          if (_loading || _working) const LinearProgressIndicator(),
          if (settings != null) ...[
            const SizedBox(height: 16),
            Text('Retention: ${settings.retentionDays} / 30 days'),
            LinearProgressIndicator(value: settings.retentionDays / 30),
            const SizedBox(height: 16),
            Text(
              'Audit dataset space: ${settings.usedBytes} bytes used, '
              '${settings.availableBytes} bytes available',
            ),
            CircularProgressIndicator(
              value: total > 0 ? settings.usedBytes / total : 0,
            ),
            const SizedBox(height: 16),
            Text(
              'Reservation: ${settings.reservationGiB} GiB · '
              'Quota: ${settings.quotaGiB} GiB',
            ),
            if (quotaBytes > 0) ...[
              Text(
                'Quota use: ${(quotaUsed * 100 / quotaBytes).toStringAsFixed(1)}%',
              ),
              LinearProgressIndicator(
                value: (quotaUsed / quotaBytes).clamp(0, 1),
              ),
            ] else
              const Text('Quota disabled'),
            Text(
              'Quota warnings: ${settings.warningPercent}% / '
              '${settings.criticalPercent}%',
            ),
            Text(
              'Remote logging configured: '
              '${settings.remoteLoggingEnabled ? 'yes' : 'no'}',
            ),
            if (inventory!.blockedReason != null)
              Text(inventory.blockedReason!),
            const SizedBox(height: 16),
            FilledButton(
              onPressed:
                  _working ||
                      _unknown ||
                      _loading ||
                      inventory.blockedReason != null ||
                      capable?.canConfigure != true ||
                      session == null ||
                      api == null
                  ? null
                  : () => _edit(session, api, inventory),
              child: const Text('Change retention'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed:
                  _working ||
                      _unknown ||
                      _loading ||
                      inventory.blockedReason != null ||
                      capable?.canConfigure != true ||
                      session == null ||
                      api == null
                  ? null
                  : () => _edit(session, api, inventory, storage: true),
              child: const Text('Change storage policy'),
            ),
          ],
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed:
                _loading || _working || _unknown || capable?.supported != true
                ? null
                : _load,
            child: const Text('Load / refresh configuration'),
          ),
        ],
      ),
    );
  }
}
