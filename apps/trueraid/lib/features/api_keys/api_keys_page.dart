import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'api_key_review.dart';
import 'api_keys_controller.dart';

class ApiKeysPage extends ConsumerStatefulWidget {
  const ApiKeysPage({super.key});
  @override
  ConsumerState<ApiKeysPage> createState() => _ApiKeysPageState();
}

class _ApiKeysPageState extends ConsumerState<ApiKeysPage> {
  bool _reviewing = false;
  String? _error;
  Future<void> _change(
    AuthenticatedSession session,
    ApiKeyInventory inventory,
    ApiKeyAction action, [
    ApiKeySnapshot? key,
  ]) async {
    if (_reviewing) return;
    setState(() {
      _reviewing = true;
      _error = null;
    });
    try {
      final request = action == ApiKeyAction.delete
          ? ApiKeyRequest(inventory: inventory, action: action, key: key)
          : await showDialog<ApiKeyRequest>(
              context: context,
              barrierDismissible: false,
              builder: (_) => ApiKeyEditor(
                session: session,
                inventory: inventory,
                action: action,
                apiKey: key,
              ),
            );
      if (!mounted ||
          request == null ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        return;
      }
      await reviewApiKeyChange(
        context: context,
        ref: ref,
        session: session,
        request: request,
      );
    } on Object {
      if (mounted &&
          identical(session, ref.read(dashboardActiveSessionProvider))) {
        setState(
          () => _error = 'The key change could not be reviewed safely. Remote details were withheld. Reload before another review.',
        );
      }
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final caps = ref.watch(apiKeysSessionProvider)?.apiKeysCapabilities;
    final state = ref.watch(apiKeysControllerProvider);
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) setState(() => _error = null);
    });
    final available = session?.endpoint != null && caps?.supported == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('API keys'),
        actions: [
          IconButton(
            key: const Key('api-keys-refresh'),
            tooltip: 'Reload API keys',
            icon: const Icon(Icons.refresh),
            onPressed: available && !state.locked && !_reviewing
                ? () => ref.invalidate(apiKeysInventoryProvider)
                : null,
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: const Key('api-keys-workspace-scroll'),
        padding: const EdgeInsets.all(TdSpacing.component),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('ACCESS & CREDENTIALS', style: TdTypography.micro),
                const SizedBox(height: 8),
                const Text('API keys', style: TdTypography.titleLarge),
                const SizedBox(height: 8),
                Text(session?.endpoint ?? 'No authenticated connection'),
                const SizedBox(height: 16),
                const Text(
                  'Manage this account’s keys without exposing stored credentials. Creation and rotation return a new key once; existing key values cannot be read.',
                ),
                const SizedBox(height: 16),
                if (state.busy) const LinearProgressIndicator(),
                if (state.result case final result?)
                  TdPanel(
                    title: state.unknown
                        ? 'Verify before continuing'
                        : 'Last operation',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(result.message),
                        if (state.unknown)
                          OutlinedButton(
                            key: const Key('api-keys-acknowledge'),
                            onPressed:
                                ref
                                    .read(apiKeysControllerProvider.notifier)
                                    .canAcknowledge
                                ? () => ref
                                      .read(apiKeysControllerProvider.notifier)
                                      .acknowledgeAfterReconnect()
                                : null,
                            child: const Text(
                              'I verified the original server and reconnected',
                            ),
                          ),
                      ],
                    ),
                  ),
                if (state.recoveryMessage case final message?) Text(message),
                if (_error case final message?) Text(message),
                const SizedBox(height: 16),
                if (!available)
                  TdPanel(
                    title: 'API-key management unavailable',
                    child: Text(
                      caps?.blockedReason ??
                          'Connect to a supported TrueNAS instance.',
                    ),
                  )
                else if (state.locked && !state.connectionCurrent)
                  const TdPanel(
                    title: 'Original operation needs attention',
                    child: Text(
                      'Previous account and key details are hidden. Verify the original server before acknowledging the operation.',
                    ),
                  )
                else
                  ref
                      .watch(apiKeysInventoryProvider)
                      .when(
                        skipLoadingOnRefresh: false,
                        skipLoadingOnReload: false,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => TdPanel(
                          title: 'Key inventory unavailable',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Account and credential identity could not be verified. Remote details were withheld. No automatic retries.',
                              ),
                              OutlinedButton(
                                key: const Key('api-keys-retry'),
                                onPressed: state.locked || _reviewing
                                    ? null
                                    : () => ref.invalidate(
                                        apiKeysInventoryProvider,
                                      ),
                                child: const Text('Retry reads'),
                              ),
                            ],
                          ),
                        ),
                        data: (inventory) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ApiKeyStatusChart(inventory: inventory),
                            const SizedBox(height: 16),
                            Text(
                              'Current account: ${inventory.username} · ${inventory.keys.length} keys',
                            ),
                            if (inventory.blockedReason case final reason?) ...[
                              const SizedBox(height: 8),
                              Text(reason),
                            ],
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: FilledButton.icon(
                                key: const Key('api-keys-create'),
                                icon: const Icon(Icons.add),
                                label: const Text('Create API key'),
                                onPressed:
                                    !state.locked &&
                                        !_reviewing &&
                                        caps!.canCreate &&
                                        inventory.blockedReason == null
                                    ? () => _change(
                                        session!,
                                        inventory,
                                        ApiKeyAction.create,
                                      )
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (inventory.keys.isEmpty)
                              const TdPanel(
                                title: 'No API keys',
                                child: Text(
                                  'This account has no keys. Create one only when a client needs API access.',
                                ),
                              ),
                            for (final key in inventory.keys)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: TdPanel(
                                  title: key.name,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        'Key ID ${key.id} · ${key.revoked
                                            ? 'Revoked'
                                            : key.expired
                                            ? 'Expired'
                                            : 'Not expired'}',
                                      ),
                                      Text(
                                        'Created ${key.createdAt.toUtc().toIso8601String()}',
                                      ),
                                      Text(
                                        'Expiry ${key.expiresAt?.toUtc().toIso8601String() ?? 'Never'}',
                                      ),
                                      if (inventory.targetBlockedReason(key)
                                          case final reason?)
                                        Text(reason),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          for (final action in [
                                            ApiKeyAction.edit,
                                            ApiKeyAction.rotate,
                                            ApiKeyAction.delete,
                                          ])
                                            OutlinedButton(
                                              key: Key(
                                                'api-key-${action.name}-${key.id}',
                                              ),
                                              onPressed:
                                                  !state.locked &&
                                                      !_reviewing &&
                                                      caps!.supports(action) &&
                                                      inventory
                                                              .targetBlockedReason(
                                                                key,
                                                              ) ==
                                                          null
                                                  ? () => _change(
                                                      session!,
                                                      inventory,
                                                      action,
                                                      key,
                                                    )
                                                  : null,
                                              child: Text(switch (action) {
                                                ApiKeyAction.edit =>
                                                  'Name & expiry',
                                                ApiKeyAction.rotate => 'Rotate',
                                                ApiKeyAction.delete =>
                                                  'Delete key',
                                                ApiKeyAction.create => 'Create',
                                              }),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            const Text(
                              'Only the current local non-builtin account is supported. System, legacy, other-account and directory-service key management are intentionally blocked. Deletion does not terminate existing authenticated sessions.',
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

class ApiKeyEditor extends ConsumerStatefulWidget {
  const ApiKeyEditor({
    required this.session,
    required this.inventory,
    required this.action,
    this.apiKey,
    super.key,
  });
  final AuthenticatedSession session;
  final ApiKeyInventory inventory;
  final ApiKeyAction action;
  final ApiKeySnapshot? apiKey;
  @override
  ConsumerState<ApiKeyEditor> createState() => _ApiKeyEditorState();
}

class _ApiKeyEditorState extends ConsumerState<ApiKeyEditor> {
  late final TextEditingController _name, _expiry;
  bool _never = false, _expired = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.apiKey?.name ?? '');
    final expiry = widget.apiKey?.expiresAt;
    _never = widget.apiKey != null && expiry == null;
    _expiry = TextEditingController(
      text:
          '${(expiry ?? DateTime.now().toUtc().add(const Duration(days: 30))).toIso8601String().split('.').first.replaceAll('Z', '')}Z',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _expiry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) {
        setState(() {
          _expired = true;
          _name.clear();
          _expiry.clear();
        });
      }
    });
    ref.listen(apiKeysInventoryProvider, (_, next) {
      if (next.isLoading || !identical(next.asData?.value, widget.inventory)) {
        setState(() => _expired = true);
      }
    });
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider));
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: SingleChildScrollView(
          key: const Key('api-key-editor-scroll'),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  current
                      ? '${widget.action.name.toUpperCase()} API key'
                      : 'Editor is no longer current',
                  style: TdTypography.titleSmall,
                ),
                const SizedBox(height: 16),
                if (!current)
                  const Text(
                    'Previous key details are hidden. Close and reload.',
                  )
                else ...[
                  Text('Account: ${widget.inventory.username}'),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('api-key-editor-name'),
                    controller: _name,
                    maxLength: 200,
                    decoration: const InputDecoration(labelText: 'Key name'),
                    autocorrect: false,
                  ),
                  TextField(
                    key: const Key('api-key-editor-expiry'),
                    controller: _expiry,
                    enabled: !_never,
                    decoration: const InputDecoration(
                      labelText: 'Expiry in UTC',
                      helperText: 'YYYY-MM-DDTHH:MM:SSZ · within one year',
                    ),
                    autocorrect: false,
                  ),
                  CheckboxListTile(
                    key: const Key('api-key-editor-never'),
                    contentPadding: EdgeInsets.zero,
                    value: _never,
                    onChanged: (value) =>
                        setState(() => _never = value == true),
                    title: const Text('Explicitly use no expiry'),
                  ),
                  if (_error case final message?) Text(message),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      key: const Key('api-key-editor-review'),
                      onPressed: current
                          ? () {
                              final date = _never
                                  ? null
                                  : DateTime.tryParse(_expiry.text);
                              if (!_never &&
                                  (date == null ||
                                      !date.isUtc ||
                                      '${date.toIso8601String().split('.').first}Z' !=
                                          _expiry.text ||
                                      !RegExp(
                                        r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$',
                                      ).hasMatch(_expiry.text))) {
                                setState(
                                  () => _error = 'Enter a complete UTC date and time ending in Z.',
                                );
                                return;
                              }
                              final request = ApiKeyRequest(
                                inventory: widget.inventory,
                                action: widget.action,
                                key: widget.apiKey,
                                name: _name.text,
                                expiresAt: date,
                              );
                              if (request.validationError case final error?) {
                                setState(() => _error = error);
                                return;
                              }
                              Navigator.pop(context, request);
                            }
                          : null,
                      child: const Text('Review change'),
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

class ApiKeyStatusChart extends StatelessWidget {
  const ApiKeyStatusChart({required this.inventory, super.key});
  final ApiKeyInventory inventory;
  @override
  Widget build(BuildContext context) {
    final active = inventory.keys.where((k) => !k.revoked && !k.expired).length;
    final expired = inventory.keys.where((k) => !k.revoked && k.expired).length;
    final revoked = inventory.keys.where((k) => k.revoked).length;
    final colors = [
      Theme.of(context).colorScheme.primary,
      Colors.orange,
      Colors.redAccent,
    ];
    return TdPanel(
      title: 'Recorded key status',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Counts from stored metadata and this device’s clock, not proof of authentication validity or session termination.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                label:
                    '$active not expired, $expired expired, $revoked revoked API keys',
                child: SizedBox(
                  width: 124,
                  height: 124,
                  child: CustomPaint(
                    painter: _KeyRing([active, expired, revoked], colors),
                    child: Center(
                      child: Text(
                        '${inventory.keys.length}',
                        style: TdTypography.titleLarge,
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$active Not expired',
                    style: TextStyle(color: colors[0]),
                  ),
                  Text('$expired Expired', style: TextStyle(color: colors[1])),
                  Text('$revoked Revoked', style: TextStyle(color: colors[2])),
                  const SizedBox(height: 8),
                  Text(
                    '${inventory.keys.where((k) => k.expiresAt == null && !k.revoked).length} without an expiry',
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

class _KeyRing extends CustomPainter {
  _KeyRing(this.values, this.colors);
  final List<int> values;
  final List<Color> colors;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(9);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14;
    canvas.drawOval(rect, paint..color = colors.first.withValues(alpha: .12));
    final total = values.fold<int>(0, (a, b) => a + b);
    if (total == 0) return;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2;
      if (sweep > 0) {
        canvas.drawArc(rect, start, sweep, false, paint..color = colors[i]);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _KeyRing oldDelegate) => true;
}
