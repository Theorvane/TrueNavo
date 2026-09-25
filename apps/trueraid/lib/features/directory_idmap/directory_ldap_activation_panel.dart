import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import 'directory_ldap_activation_controller.dart';

class DirectoryLdapActivationPanel extends ConsumerStatefulWidget {
  const DirectoryLdapActivationPanel({required this.inventory, super.key});
  final DirectoryIdmapInventory inventory;

  @override
  ConsumerState<DirectoryLdapActivationPanel> createState() =>
      _DirectoryLdapActivationPanelState();
}

class _DirectoryLdapActivationPanelState
    extends ConsumerState<DirectoryLdapActivationPanel> {
  final _confirmation = TextEditingController();
  bool _riskAccepted = false;

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  void _review(bool enable) {
    _confirmation.clear();
    _riskAccepted = false;
    ref.read(directoryLdapActivationControllerProvider.notifier).review(enable);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(directoryLdapActivationControllerProvider);
    final controller = ref.read(
      directoryLdapActivationControllerProvider.notifier,
    );
    final ldap = widget.inventory.ldap!;
    final secure =
        ldap.validateCertificates &&
        (ldap.serverUrls.every((url) => url.startsWith('ldaps://')) &&
                !ldap.startTls ||
            ldap.serverUrls.every((url) => url.startsWith('ldap://')) &&
                ldap.startTls);
    final review = state.review;
    final result = state.result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'LDAP service state',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              'Current state: ${widget.inventory.enabled ? 'enabled' : 'disabled'} · ${widget.inventory.status ?? 'unknown'}',
            ),
            const Text(
              'Only the existing anonymous LDAP service is supported. This operation does not edit its server, credentials, search bases or attribute mappings. Enabling can expose directory identities; disabling can interrupt user/group lookups and access decisions.',
            ),
            if (!widget.inventory.enabled && !secure)
              Text(
                'Enable is unavailable until all LDAP URLs use LDAPS or StartTLS and certificate validation is on.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (state.message case final message?)
              Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (state.busy) const LinearProgressIndicator(),
            if (review == null && result == null)
              FilledButton.tonal(
                onPressed:
                    state.locked ||
                        (!widget.inventory.enabled &&
                            (!secure ||
                                widget.inventory.status != null &&
                                    widget.inventory.status != 'DISABLED')) ||
                        (widget.inventory.enabled &&
                            !{
                              'HEALTHY',
                              'FAULTED',
                            }.contains(widget.inventory.status))
                    ? null
                    : () => _review(!widget.inventory.enabled),
                child: Text(
                  widget.inventory.enabled
                      ? 'Review LDAP disable'
                      : 'Review LDAP enable',
                ),
              ),
            if (review != null) ...[
              const SizedBox(height: 12),
              Text(
                '${review.enable ? 'Enable' : 'Disable'} LDAP on ${review.inventory.endpoint}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                review.enable
                    ? 'Directory accounts and groups may become available to TrueNAS. LDAP reachability and account mappings have not been independently verified.'
                    : 'Directory-backed accounts and groups may stop resolving. Shares, permissions and active sessions may be affected.',
              ),
              CheckboxListTile(
                title: const Text('I understand the directory access risk'),
                value: _riskAccepted,
                onChanged: (value) =>
                    setState(() => _riskAccepted = value ?? false),
              ),
              TextField(
                controller: _confirmation,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Type ${review.confirmation} to confirm',
                ),
                onChanged: (_) => setState(() {}),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: controller.clearReview,
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed:
                        state.locked ||
                            !_riskAccepted ||
                            _confirmation.text != review.confirmation ||
                            DateTime.now().toUtc().isAfter(review.expiresAt)
                        ? null
                        : () => controller.execute(_confirmation.text),
                    child: Text(
                      review.enable ? 'Enable LDAP once' : 'Disable LDAP once',
                    ),
                  ),
                ],
              ),
            ],
            if (result != null) ...[
              Text(result.message),
              if (result.outcome == DirectoryIdmapOutcome.pending &&
                  result.job != null)
                FilledButton.tonal(
                  onPressed: state.busy ? null : controller.poll,
                  child: const Text('Check owned LDAP job'),
                ),
              if (result.outcome == DirectoryIdmapOutcome.unknown)
                const Text(
                  'Outcome is uncertain. Do not repeat the state change; inspect the original TrueNAS server.',
                ),
              if (controller.canAcknowledgeAfterReconnect)
                TextButton(
                  onPressed: controller.acknowledgeAfterReconnect,
                  child: const Text('Acknowledge after same-server reload'),
                ),
              if (!state.locked)
                TextButton(
                  onPressed: controller.clearReview,
                  child: const Text('Dismiss'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
