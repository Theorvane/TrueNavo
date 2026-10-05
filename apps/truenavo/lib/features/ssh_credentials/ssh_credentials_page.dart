import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'ssh_credentials_controller.dart';
import 'ssh_credentials_editor.dart';
import 'ssh_credentials_review.dart';

class SshCredentialsPage extends ConsumerStatefulWidget {
  const SshCredentialsPage({super.key});
  @override
  ConsumerState<SshCredentialsPage> createState() => _SshCredentialsPageState();
}

class _SshCredentialsPageState extends ConsumerState<SshCredentialsPage> {
  bool _reviewing = false;
  String? _error;
  SshCredentialWriteOnlyInput? _pendingInput;
  @override
  void dispose() {
    _pendingInput?.dispose();
    _pendingInput = null;
    super.dispose();
  }

  Future<void> _change(
    AuthenticatedSession session,
    SshCredentialInventory inventory,
    SshCredentialAction action, [
    SshCredentialEntry? credential,
  ]) async {
    if (_reviewing) return;
    setState(() {
      _reviewing = true;
      _error = null;
    });
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    var expired =
        lifecycleState != null && lifecycleState != AppLifecycleState.resumed;
    SshCredentialWriteOnlyInput? input;
    final lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) {
          expired = true;
          input?.dispose();
        }
      },
    );
    final sessionWatch = ref.listenManual(dashboardActiveSessionProvider, (
      a,
      b,
    ) {
      if (!identical(a, b)) {
        expired = true;
        input?.dispose();
      }
    });
    final inventoryWatch = ref.listenManual(sshCredentialsInventoryProvider, (
      _,
      next,
    ) {
      if (next.isLoading || !identical(inventory, next.asData?.value)) {
        expired = true;
        input?.dispose();
      }
    });
    bool current() =>
        mounted &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(sshCredentialsInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(sshCredentialsInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      SshCredentialRequest request;
      if (action == SshCredentialAction.delete) {
        request = SshCredentialRequest(
          inventory: inventory,
          action: action,
          credential: credential,
        );
      } else {
        final edit = await showDialog<SshCredentialEdit>(
          context: context,
          barrierDismissible: false,
          builder: (_) => SshCredentialsEditor(
            session: session,
            inventory: inventory,
            action: action,
            credential: credential,
          ),
        );
        input = edit?.input;
        _pendingInput = input;
        if (edit == null || !current()) return;
        request = edit.request;
      }
      if (!current() || request.validationError != null) return;
      final api = ref.read(sshCredentialsSessionProvider);
      if (api == null) return;
      final review = await api.reviewSshCredential(request);
      if (!mounted || !current()) return;
      if (!identical(review.request, request) ||
          review.endpoint != session.endpoint) {
        throw StateError('Mismatching reviewed intent');
      }
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            SshCredentialsReviewDialog(session: session, review: review),
      );
      if (confirmed != true || !current()) return;
      await ref
          .read(sshCredentialsControllerProvider.notifier)
          .execute(
            expectedSession: session,
            review: review,
            confirmation: review.target,
            input: input,
          );
    } on Object {
      if (current()) {
        setState(
          () => _error = 'SSH credential review could not be completed safely. Remote details were withheld. Reload before reviewing again.',
        );
      }
    } finally {
      input?.dispose();
      if (identical(_pendingInput, input)) _pendingInput = null;
      sessionWatch.close();
      inventoryWatch.close();
      lifecycle.dispose();
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider),
        api = ref.watch(sshCredentialsSessionProvider);
    final state = ref.watch(sshCredentialsControllerProvider),
        controller = ref.read(sshCredentialsControllerProvider.notifier);
    final caps = api?.sshCredentialsCapabilities;
    final available = session?.endpoint != null && caps?.supported == true;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) {
        _pendingInput?.dispose();
        setState(() => _error = null);
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('SSH credentials'),
        actions: [
          IconButton(
            key: const Key('ssh-credentials-refresh'),
            tooltip: 'Reload local SSH credential references',
            onPressed: available && !state.locked && !_reviewing
                ? () => ref.invalidate(sshCredentialsInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: const Key('ssh-credentials-workspace-scroll'),
        padding: const EdgeInsets.all(20),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'CREDENTIALS · SSH ACCESS',
                  style: TdTypography.micro,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Keys & trusted destinations',
                  style: TdTypography.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(session?.endpoint ?? 'No authenticated connection'),
                const SizedBox(height: 12),
                const Text(
                  'Inspect public keys, destination settings and dependency counts. Inventory reads exclude private-key material. No automatic SSH connection, host-key scan, remote key installation or replication run.',
                ),
                const SizedBox(height: 16),
                if (state.busy) const LinearProgressIndicator(),
                if (state.result case final result?)
                  TdPanel(
                    title: state.unknown
                        ? 'Verify before continuing'
                        : 'Last credential operation',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(result.message),
                        if (state.connectionCurrent &&
                            result.publicKey != null &&
                            sshPublicKeyFingerprint(result.publicKey!) !=
                                null) ...[
                          const SizedBox(height: 12),
                          const Text(
                            'Public key only · private material is never displayed here',
                          ),
                          SelectableText(
                            result.publicKey!,
                            key: const Key('ssh-credentials-result-public-key'),
                          ),
                        ],
                        if (state.unknown)
                          OutlinedButton(
                            key: const Key('ssh-credentials-acknowledge'),
                            onPressed: controller.canAcknowledge
                                ? controller.acknowledgeAfterReconnect
                                : null,
                            child: const Text(
                              'I inspected the original server and reconnected',
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_error case final message?) Text(message),
                const SizedBox(height: 16),
                if (!available)
                  TdPanel(
                    title: 'SSH credential management unavailable',
                    child: Text(
                      caps?.blockedReason ??
                          'Connect to a supported TrueNAS instance.',
                    ),
                  )
                else if (state.locked && !state.connectionCurrent)
                  const TdPanel(
                    title: 'Original operation needs attention',
                    child: Text(
                      'Previous destination and key details are hidden. Inspect the original server before another change.',
                    ),
                  )
                else
                  ref
                      .watch(sshCredentialsInventoryProvider)
                      .when(
                        skipLoadingOnRefresh: false,
                        skipLoadingOnReload: false,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => TdPanel(
                          title: 'SSH credential inventory unavailable',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Public identities, usage or job state could not be verified. Remote details were withheld. No automatic retries.',
                              ),
                              OutlinedButton(
                                key: const Key('ssh-credentials-retry'),
                                onPressed: state.locked || _reviewing
                                    ? null
                                    : () => ref.invalidate(
                                        sshCredentialsInventoryProvider,
                                      ),
                                child: const Text('Retry reads'),
                              ),
                            ],
                          ),
                        ),
                        data: (inventory) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SshCredentialSummary(inventory: inventory),
                            const SizedBox(height: 16),
                            if (inventory.blockedReason case final reason?)
                              Text(reason),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                for (final action in [
                                  SshCredentialAction.importKeyPair,
                                  SshCredentialAction.generateKeyPair,
                                  SshCredentialAction.createConnection,
                                ])
                                  FilledButton.tonal(
                                    key: Key('ssh-credentials-${action.name}'),
                                    onPressed:
                                        !state.locked &&
                                            !_reviewing &&
                                            caps!.allows(action) &&
                                            inventory.blockedReason == null &&
                                            (action !=
                                                    SshCredentialAction
                                                        .createConnection ||
                                                inventory.keyPairs.isNotEmpty)
                                        ? () => _change(
                                            session!,
                                            inventory,
                                            action,
                                          )
                                        : null,
                                    child: Text(switch (action) {
                                      SshCredentialAction.importKeyPair =>
                                        'Import keypair',
                                      SshCredentialAction.generateKeyPair =>
                                        'Generate & store keypair',
                                      _ => 'Create connection configuration',
                                    }),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Available actions depend on public API permissions. Connections require an existing keypair. Rename and delete require zero dependencies; cascade and attribute replacement are not supported.',
                            ),
                            if (inventory.credentials.isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 16),
                                child: TdPanel(
                                  title: 'No SSH credentials',
                                  child: Text(
                                    'Import or explicitly generate a keypair before preparing a trusted destination.',
                                  ),
                                ),
                              ),
                            for (final entry in inventory.credentials)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: TdPanel(
                                  title: entry.name,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        'ID ${entry.id} · ${entry.isKeyPair ? 'Keypair record' : 'Connection configuration'} · ${entry.usageCount} dependencies',
                                      ),
                                      if (entry.isKeyPair) ...[
                                        const Text(
                                          'Public inventory does not verify private-key availability.',
                                        ),
                                        if (entry.publicKeyFingerprint
                                            case final fingerprint?)
                                          SelectableText(fingerprint),
                                        if (entry.publicKey
                                            case final publicKey?)
                                          SelectableText(publicKey),
                                      ],
                                      if (entry.connection
                                          case final connection?) ...[
                                        Text(
                                          '${connection.username}@${connection.host}:${connection.port}',
                                        ),
                                        Text(
                                          'Keypair ID ${connection.keyPairId} · timeout ${connection.connectTimeout}s',
                                        ),
                                        const Text(
                                          'Stored host fingerprints · not a fresh trust or connectivity check',
                                        ),
                                        for (final fingerprint
                                            in connection.hostKeyFingerprints)
                                          SelectableText(fingerprint),
                                      ],
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 12,
                                        runSpacing: 12,
                                        children: [
                                          for (final action in [
                                            SshCredentialAction.rename,
                                            SshCredentialAction.delete,
                                          ])
                                            OutlinedButton(
                                              key: Key(
                                                'ssh-credential-${action.name}-${entry.id}',
                                              ),
                                              onPressed:
                                                  !state.locked &&
                                                      !_reviewing &&
                                                      inventory.blockedReason ==
                                                          null &&
                                                      entry.usageCount == 0 &&
                                                      caps!.allows(action)
                                                  ? () => _change(
                                                      session!,
                                                      inventory,
                                                      action,
                                                      entry,
                                                    )
                                                  : null,
                                              child: Text(
                                                action ==
                                                        SshCredentialAction
                                                            .rename
                                                    ? 'Rename'
                                                    : 'Delete without cascade',
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            const SizedBox(height: 16),
                            const Text(
                              'Manual configuration only. Remote setup, scans, connection testing, key export and cascading deletion remain outside this workspace. Changes made by another administrator can race after the final preflight.',
                            ),
                          ],
                        ),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SshCredentialSummary extends StatelessWidget {
  const SshCredentialSummary({required this.inventory, super.key});
  final SshCredentialInventory inventory;
  @override
  Widget build(BuildContext context) {
    final keys = inventory.keyPairs.length,
        connections = inventory.connections.length;
    final used = inventory.credentials.where((e) => e.usageCount > 0).length;
    final colors = Theme.of(context).colorScheme;
    return TdPanel(
      title: 'Stored credential inventory',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Counts describe stored configuration, not working authentication or verified remote access.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                label:
                    '$keys keypair records, $connections connection configurations',
                child: SizedBox(
                  width: 124,
                  height: 124,
                  child: CustomPaint(
                    key: const Key('ssh-credentials-inventory-donut'),
                    painter: _SshRing(
                      keys,
                      connections,
                      colors.primary,
                      colors.tertiary,
                    ),
                    child: Center(
                      child: Text(
                        '${inventory.credentials.length}',
                        style: TdTypography.titleLarge,
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SshLegendItem(
                    color: colors.primary,
                    label: '$keys Keypair records',
                    dotKey: const Key('ssh-credentials-keypair-color'),
                  ),
                  _SshLegendItem(
                    color: colors.tertiary,
                    label: '$connections Connection configurations',
                    dotKey: const Key('ssh-credentials-connection-color'),
                  ),
                  const SizedBox(height: 8),
                  const Text('Dependency status', style: TdTypography.micro),
                  Text('$used Referenced credentials'),
                  Text(
                    '${inventory.credentials.length - used} Unused credentials',
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SshLegendItem extends StatelessWidget {
  const _SshLegendItem({
    required this.color,
    required this.label,
    required this.dotKey,
  });
  final Color color;
  final String label;
  final Key dotKey;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ExcludeSemantics(
          child: Icon(Icons.circle, key: dotKey, color: color, size: 12),
        ),
      ),
      const SizedBox(width: 8),
      Flexible(child: Text(label)),
    ],
  );
}

class _SshRing extends CustomPainter {
  _SshRing(this.keys, this.connections, this.primary, this.secondary);
  final int keys, connections;
  final Color primary, secondary;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(9),
        paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 14;
    canvas.drawOval(rect, paint..color = primary.withValues(alpha: .12));
    if (keys + connections == 0) return;
    final sweep = keys / (keys + connections) * math.pi * 2;
    canvas.drawArc(rect, -math.pi / 2, sweep, false, paint..color = primary);
    canvas.drawArc(
      rect,
      -math.pi / 2 + sweep,
      math.pi * 2 - sweep,
      false,
      paint..color = secondary,
    );
  }

  @override
  bool shouldRepaint(covariant _SshRing old) =>
      old.keys != keys ||
      old.connections != connections ||
      old.primary != primary ||
      old.secondary != secondary;
}
