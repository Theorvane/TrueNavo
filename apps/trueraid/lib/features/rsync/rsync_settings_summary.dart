import 'package:flutter/material.dart';
import 'package:truenas_api/truenas_api.dart';

/// Only typed, public configuration. No RPC snapshots, key bytes or job logs.
class RsyncSettingsSummary extends StatelessWidget {
  const RsyncSettingsSummary({required this.request, super.key});
  final RsyncRequest request;
  @override
  Widget build(BuildContext context) {
    final before = request.task?.settings, after = request.desired;
    final connection = after == null
        ? null
        : request.inventory.connections
              .where((c) => c.id == after.connectionId)
              .firstOrNull;
    Widget settings(
      String title,
      RsyncSettings value, {
      bool? enabled,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        Text(
          'Description: ${value.description.isEmpty ? '(empty)' : value.description}',
        ),
        Text('Local dataset: ${value.path}'),
        Text('Local user: ${value.user}'),
        Text('SSH connection ID: ${value.connectionId}'),
        Text('Remote directory: ${value.remotePath}'),
        Text(
          'Schedule: ${value.cron.expression} · ${request.inventory.timezone}',
        ),
        Text('Enabled: ${(enabled ?? value.enabled) ? 'Yes' : 'No'}'),
        Text(
          'Recursive: Yes · Times: ${value.times ? 'Yes' : 'No'} · Compression: ${value.compress ? 'Yes' : 'No'} · Delay updates: ${value.delayUpdates ? 'Yes' : 'No'}',
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        if (before != null) ...[
          settings('Before', before),
          Text(
            'Cross-filesystem protection: ${request.task!.crossFilesystemProtection ? 'Configured' : 'Not configured'}',
          ),
        ],
        const SizedBox(height: 12),
        if (request.action == RsyncAction.delete)
          const Text(
            'After: task configuration removed; copied destination files remain.',
          )
        else if (request.action == RsyncAction.run)
          const Text(
            'After: one remote PUSH transfer is requested; task settings stay unchanged.',
          )
        else if (after != null)
          settings(
            'After',
            after,
            enabled: switch (request.action) {
              RsyncAction.enable => true,
              RsyncAction.disable => false,
              _ => null,
            },
          ),
        if (request.action == RsyncAction.create ||
            request.action == RsyncAction.update)
          const Text('After: fixed --one-file-system protection configured.'),
        if (connection != null) ...[
          const SizedBox(height: 12),
          Text('SSH destination: ${connection.destination}'),
          Text(
            'SSH identity: ${connection.name} · key pair ${connection.keyPairId}',
          ),
          Text('Public key fingerprint: ${connection.publicKeyFingerprint}'),
          for (final fingerprint in connection.hostKeyFingerprints)
            Text('Pinned host key: $fingerprint'),
        ],
        const SizedBox(height: 12),
        const Text(
          'PUSH over an existing SSH connection. The exact local path has no added trailing slash. An existing destination directory receives the source directory; an absent destination may produce a different layout. Remote existence and layout are not verified. Destination files may be overwritten even with deletion disabled.',
        ),
        const Text(
          'Archive, deletion and preserved permissions/attributes are disabled. Only fixed --one-file-system protection is allowed, with no custom arguments. It reduces cross-device traversal but does not exclude every same-device bind mount. No remote validation, key scan or connection test is performed. A server-reported success is not proof of identical contents or recoverability.',
        ),
      ],
    );
  }
}
