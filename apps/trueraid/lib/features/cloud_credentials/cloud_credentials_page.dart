import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'cloud_credentials_controller.dart';
import 'cloud_credentials_editor.dart';
import 'cloud_credentials_review.dart';

class CloudCredentialsPage extends ConsumerStatefulWidget {
  const CloudCredentialsPage({super.key});
  @override
  ConsumerState<CloudCredentialsPage> createState() =>
      _CloudCredentialsPageState();
}

class _CloudCredentialsPageState extends ConsumerState<CloudCredentialsPage> {
  bool _reviewing = false;
  String? _error;
  Future<void> _change(
    AuthenticatedSession session,
    CloudCredentialInventory inventory,
    CloudCredentialAction action, [
    CloudCredentialEntry? credential,
  ]) async {
    if (_reviewing) return;
    setState(() {
      _reviewing = true;
      _error = null;
    });
    final initialLifecycle = WidgetsBinding.instance.lifecycleState;
    var expired =
        initialLifecycle != null &&
        initialLifecycle != AppLifecycleState.resumed;
    CloudCredentialWriteOnlyInput? input;
    final lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) {
          expired = true;
          input?.dispose();
        }
      },
    );
    final watch = ref.listenManual(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) {
        expired = true;
        input?.dispose();
      }
    });
    final inventoryWatch = ref.listenManual(cloudCredentialsInventoryProvider, (
      _,
      b,
    ) {
      if (b.isLoading || !identical(inventory, b.asData?.value)) {
        expired = true;
        input?.dispose();
      }
    });
    bool current() =>
        mounted &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(cloudCredentialsInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(cloudCredentialsInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      CloudCredentialEdit? edit;
      if (action != CloudCredentialAction.delete) {
        edit = await showDialog<CloudCredentialEdit>(
          context: context,
          barrierDismissible: false,
          builder: (_) => CloudCredentialsEditor(
            session: session,
            inventory: inventory,
            action: action,
            credential: credential,
          ),
        );
        input = edit?.input;
        if (edit == null) return;
      }
      if (!mounted || !current()) return;
      final request = CloudCredentialRequest(
        inventory: inventory,
        action: action,
        credential: credential,
        name: edit?.name,
        provider: edit?.provider,
      );
      if (request.validationError != null) {
        setState(() => _error = request.validationError);
        return;
      }
      final api = ref.read(cloudCredentialsSessionProvider);
      if (api == null) return;
      final review = await api.reviewCloudCredential(request);
      if (!mounted || !current()) return;
      if (!identical(review.request, request) ||
          review.endpoint != session.endpoint) {
        throw StateError('Mismatching review');
      }
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            CloudCredentialsReviewDialog(session: session, review: review),
      );
      if (!current() || confirmed != true) return;
      await ref
          .read(cloudCredentialsControllerProvider.notifier)
          .execute(
            expectedSession: session,
            review: review,
            confirmation: review.target,
            input: input,
          );
    } on Object {
      if (current()) {
        setState(
          () => _error = 'This change could not be reviewed safely. Nothing was submitted. Reload credential references.',
        );
      }
    } finally {
      input?.dispose();
      lifecycle.dispose();
      watch.close();
      inventoryWatch.close();
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider),
        api = ref.watch(cloudCredentialsSessionProvider),
        state = ref.watch(cloudCredentialsControllerProvider),
        controller = ref.read(cloudCredentialsControllerProvider.notifier);
    final caps = api?.cloudCredentialsCapabilities;
    final available = session?.endpoint != null && caps?.supported == true;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) setState(() => _error = null);
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloud credentials'),
        actions: [
          IconButton(
            key: const Key('cloud-credentials-refresh'),
            tooltip: 'Reload local credential references',
            onPressed: available && !state.locked && !_reviewing
                ? () => ref.invalidate(cloudCredentialsInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: const Key('cloud-credentials-workspace-scroll'),
        padding: const EdgeInsets.all(20),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'CREDENTIALS · CLOUD ACCESS',
                  style: TdTypography.micro,
                ),
                const SizedBox(height: 8),
                const Text('Cloud credentials', style: TdTypography.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'Names, providers and task references only. Existing access keys, tokens and hidden provider settings are never requested or displayed.',
                ),
                const SizedBox(height: 20),
                if (state.result case final result?)
                  TdPanel(
                    title: 'Operation · ${result.outcome.name}',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(result.message),
                        if (controller.canAcknowledge)
                          TextButton(
                            onPressed: controller.acknowledgeAfterReconnect,
                            child: const Text(
                              'I inspected the original server; reload',
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_error != null) Text(_error!),
                if (!available)
                  TdPanel(
                    title: 'Cloud credentials unavailable',
                    child: Text(
                      caps?.blockedReason ??
                          'Connect to inspect cloud credential references.',
                    ),
                  )
                else
                  ref
                      .watch(cloudCredentialsInventoryProvider)
                      .when(
                        skipLoadingOnRefresh: false,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => const TdPanel(
                          title: 'References unavailable',
                          child: Text(
                            'Credential and dependency information could not be validated. Remote details were withheld. No verification or write was attempted.',
                          ),
                        ),
                        data: (inventory) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _CloudCredentialOverview(inventory: inventory),
                            const SizedBox(height: 16),
                            if (inventory.conflictingJob)
                              const TdPanel(
                                title: 'Active operation',
                                child: Text(
                                  'Wait for cloud, storage and system jobs to finish before changing credentials.',
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: FilledButton.icon(
                                key: const Key('cloud-credential-create'),
                                onPressed:
                                    !state.locked &&
                                        !_reviewing &&
                                        !inventory.conflictingJob &&
                                        caps!.canCreate
                                    ? () => _change(
                                        session!,
                                        inventory,
                                        CloudCredentialAction.create,
                                      )
                                    : null,
                                icon: const Icon(Icons.add_rounded),
                                label: const Text('Add credential'),
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (inventory.credentials.isEmpty)
                              const TdPanel(
                                title: 'No cloud credentials',
                                child: Text(
                                  'Add complete S3 credentials or an already-issued Dropbox token. No cloud sign-in happens automatically.',
                                ),
                              ),
                            for (final entry in inventory.credentials)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: TdPanel(
                                  title: entry.name,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        '${entry.provider} · ID ${entry.id}',
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        '${inventory.referencesFor(entry.id).length} task references · ${inventory.referencesFor(entry.id).where((r) => r.enabled).length} enabled schedules',
                                      ),
                                      for (final reference
                                          in inventory.referencesFor(entry.id))
                                        Text(
                                          '${reference.kind == 'cloudsync' ? 'Cloud sync' : 'Cloud backup'} #${reference.id} · ${reference.enabled ? 'enabled' : 'disabled'}',
                                        ),
                                      if (!entry.supported)
                                        const Text(
                                          'This provider requires its specialized TrueNAS workflow. Its secrets remain hidden.',
                                        ),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          for (final action in [
                                            CloudCredentialAction.rename,
                                            CloudCredentialAction.replace,
                                            CloudCredentialAction.delete,
                                          ])
                                            TextButton(
                                              key: Key(
                                                'cloud-credential-${action.name}-${entry.id}',
                                              ),
                                              onPressed:
                                                  !state.locked &&
                                                      !_reviewing &&
                                                      entry.supported &&
                                                      caps!.allows(action) &&
                                                      !inventory
                                                          .conflictingJob &&
                                                      (action !=
                                                              CloudCredentialAction
                                                                  .delete ||
                                                          inventory
                                                              .referencesFor(
                                                                entry.id,
                                                              )
                                                              .isEmpty) &&
                                                      (action !=
                                                              CloudCredentialAction
                                                                  .replace ||
                                                          !inventory
                                                              .referencesFor(
                                                                entry.id,
                                                              )
                                                              .any(
                                                                (r) =>
                                                                    r.enabled,
                                                              ))
                                                  ? () => _change(
                                                      session!,
                                                      inventory,
                                                      action,
                                                      entry,
                                                    )
                                                  : null,
                                              child: Text(switch (action) {
                                                CloudCredentialAction.rename =>
                                                  'Rename',
                                                CloudCredentialAction.replace =>
                                                  'Replace provider values',
                                                CloudCredentialAction.delete =>
                                                  'Delete',
                                                _ => '',
                                              }),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            const TdPanel(
                              title: 'Native scope',
                              child: Text(
                                'S3 and Dropbox lifecycle only. OAuth authorization, provider verification, cloud file browsing and other providers remain in TrueNAS. Replacement requires disabled dependent schedules and a full new provider record. Secret-only changes made elsewhere cannot be detected by this secret-free inventory.',
                              ),
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

class _CloudCredentialOverview extends StatelessWidget {
  const _CloudCredentialOverview({required this.inventory});
  final CloudCredentialInventory inventory;
  @override
  Widget build(BuildContext context) {
    final used = inventory.credentials
            .where((e) => inventory.referencesFor(e.id).isNotEmpty)
            .length,
        total = inventory.credentials.length;
    return TdPanel(
      title: 'Credential coverage',
      child: Wrap(
        spacing: 24,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            label: '$used of $total credentials referenced by tasks',
            child: SizedBox(
              width: 100,
              height: 100,
              child: CustomPaint(
                painter: _CredentialDonut(
                  total == 0 ? 0 : used / total,
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: Center(
                  child: Text(
                    '$used / $total',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$total stored credentials'),
              Text('$used used · ${total - used} unreferenced'),
              Text(
                '${inventory.references.where((r) => r.kind == 'cloudsync').length} cloud sync references',
              ),
              Text(
                '${inventory.references.where((r) => r.kind == 'cloud_backup').length} cloud backup references',
              ),
              const Text('Reference counts, not cloud health'),
            ],
          ),
        ],
      ),
    );
  }
}

class _CredentialDonut extends CustomPainter {
  const _CredentialDonut(this.value, this.foreground, this.background);
  final double value;
  final Color foreground, background;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(6, 6, size.width - 12, size.height - 12),
        paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 9;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2,
      false,
      paint..color = background,
    );
    if (value > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * value,
        false,
        paint..color = foreground,
      );
    }
  }

  @override
  bool shouldRepaint(_CredentialDonut old) =>
      old.value != value ||
      old.foreground != foreground ||
      old.background != background;
}
