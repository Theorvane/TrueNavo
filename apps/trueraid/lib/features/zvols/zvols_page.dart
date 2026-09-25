import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../datasets/dataset_size_input.dart';
import 'zvols_controller.dart';

String zvolBytes(int bytes) {
  if (bytes < 1048576) return '$bytes B';
  for (final unit in [
    DatasetSizeUnit.tebibytes,
    DatasetSizeUnit.gibibytes,
    DatasetSizeUnit.mebibytes,
  ]) {
    if (bytes >= unit.multiplier) {
      return '${(bytes / unit.multiplier).toStringAsFixed(1)} ${unit.label}';
    }
  }
  return '$bytes B';
}

class ZvolsPage extends ConsumerWidget {
  const ZvolsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final api = ref.watch(zvolsSessionProvider);
    final state = ref.watch(zvolsControllerProvider);
    final capabilities =
        api?.zvolCapabilities ?? const ZvolCapabilities.disconnected();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zvols'),
        actions: [
          IconButton(
            tooltip: 'Refresh inventory',
            onPressed: state.busy || !capabilities.supported
                ? null
                : () => ref.invalidate(zvolsInventoryProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'Virtual block storage',
                  style: TdTypography.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Create, grow and configure Zvols. A block device is not a mounted filesystem or a ready-to-use guest disk.',
                ),
                const SizedBox(height: 16),
                if (state.busy || state.result != null)
                  _OperationPanel(state: state),
                if (!capabilities.supported || session == null)
                  Text(
                    capabilities.blockedReason ?? 'Reconnect to load storage.',
                  )
                else
                  _ZvolInventoryView(
                    key: ObjectKey(session),
                    session: session,
                    capabilities: capabilities,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OperationPanel extends ConsumerWidget {
  const _OperationPanel({required this.state});
  final ZvolsState state;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TdPanel(
      title: state.busy
          ? 'Applying storage change'
          : state.unknown
          ? 'Outcome needs verification'
          : 'Storage operation',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          if (state.target != null) Text('Operation target: ${state.target}'),
          if (state.server != null) Text('Original server: ${state.server}'),
          if (state.busy)
            const LinearProgressIndicator()
          else
            Text(state.result!.message),
          if (state.unknown && !state.connectionCurrent)
            TextButton(
              onPressed: () => ref
                  .read(zvolsControllerProvider.notifier)
                  .acknowledgeAfterReconnect(),
              child: const Text(
                'I reconnected to the original server and inspected the result',
              ),
            ),
        ],
      ),
    ),
  );
}

class _ZvolInventoryView extends ConsumerWidget {
  const _ZvolInventoryView({
    required this.session,
    required this.capabilities,
    super.key,
  });
  final AuthenticatedSession session;
  final ZvolCapabilities capabilities;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(zvolsInventoryProvider);
    final state = ref.watch(zvolsControllerProvider);
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Storage could not be loaded. No background retries are running.',
          ),
          TextButton(
            onPressed: () => ref.invalidate(zvolsInventoryProvider),
            child: const Text('Retry read'),
          ),
        ],
      ),
      data: (inventory) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 16,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('zvol-create'),
              onPressed:
                  state.locked ||
                      !capabilities.canCreate ||
                      !inventory.parents.any((p) => p.available)
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (_) => ZvolEditorDialog(
                        session: session,
                        inventory: inventory,
                      ),
                    ),
              icon: const Icon(Icons.add),
              label: const Text('Create Zvol'),
            ),
          ),
          if (!capabilities.canCreate ||
              !capabilities.canUpdate ||
              !capabilities.canDelete)
            const Text(
              'Management requires the corresponding write method and VM, iSCSI, NVMe and service dependency-read permissions. Deletion also requires snapshot reads.',
            ),
          ZvolProvisioningChart(volumes: inventory.volumes),
          if (inventory.volumes.isEmpty)
            const Text('No Zvols in the returned inventory.'),
          for (final volume in inventory.volumes)
            TdPanel(
              title: volume.id,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 10,
                children: [
                  Text(
                    '${volume.provisioning} · ${volume.readonly ? 'Read-only' : 'Writable'}',
                  ),
                  Text(
                    'Logical device: ${zvolBytes(volume.sizeBytes)} · Block: ${zvolBytes(volume.blockSizeBytes)}',
                  ),
                  Text(
                    'ZFS used: ${zvolBytes(volume.usedBytes)} · Referenced: ${zvolBytes(volume.referencedBytes)}',
                  ),
                  Text(
                    'Volume reservation: ${zvolBytes(volume.refreservationBytes)}',
                  ),
                  Text(
                    'Compression: ${volume.compression} · Sync: ${volume.sync}',
                  ),
                  Material(
                    color: Colors.transparent,
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Exact storage details'),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(
                            'GUID ${volume.guid}\nLogical size ${volume.sizeBytes} bytes\nBlock ${volume.blockSizeBytes} bytes\nZFS used ${volume.usedBytes} bytes\nReferenced ${volume.referencedBytes} bytes\nReservation ${volume.reservationBytes} bytes\nRefreservation ${volume.refreservationBytes} bytes',
                          ),
                        ),
                        const Text(
                          'Used space can include reservations, metadata and snapshots. It is not guest filesystem usage or guaranteed reclaimable space.',
                        ),
                      ],
                    ),
                  ),
                  if (volume.blockedReason != null) Text(volume.blockedReason!),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        key: Key('zvol-edit-${volume.id}'),
                        onPressed:
                            state.locked ||
                                !capabilities.canUpdate ||
                                !volume.editable
                            ? null
                            : () => showDialog<void>(
                                context: context,
                                builder: (_) => ZvolEditorDialog(
                                  session: session,
                                  inventory: inventory,
                                  volume: volume,
                                ),
                              ),
                        child: const Text('Edit / grow'),
                      ),
                      OutlinedButton(
                        key: Key('zvol-delete-${volume.id}'),
                        onPressed:
                            state.locked ||
                                !capabilities.canDelete ||
                                !volume.editable
                            ? null
                            : () => _delete(context, ref, volume),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    ZvolEntry volume,
  ) async {
    try {
      final review = await ref
          .read(zvolsSessionProvider)!
          .reviewZvolDelete(volume);
      if (!context.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (_) => ZvolReviewDialog(session: session, review: review),
      );
    } catch (error) {
      if (context.mounted &&
          identical(session, ref.read(dashboardActiveSessionProvider))) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is ZvolException ? error.userMessage : 'The storage review could not be prepared. Reload and try again.',
            ),
          ),
        );
      }
    }
  }
}

class ZvolProvisioningChart extends StatelessWidget {
  const ZvolProvisioningChart({required this.volumes, super.key});
  final List<ZvolEntry> volumes;
  @override
  Widget build(BuildContext context) {
    const labels = ['Thin', 'Reserved', 'Custom reservation'];
    final counts = [
      for (final label in labels)
        volumes.where((v) => v.provisioning == label).length,
    ];
    final td = context.tdTheme;
    final colors = [td.statusInfo, td.statusSuccess, td.statusWarning];
    return TdPanel(
      title: 'Provisioning counts',
      description: 'Returned volume counts, not guest usage or pool capacity.',
      child: Wrap(
        spacing: 24,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            label:
                'Zvol provisioning: ${counts[0]} thin, ${counts[1]} reserved, ${counts[2]} custom.',
            child: ExcludeSemantics(
              child: SizedBox(
                width: 112,
                height: 112,
                child: CustomPaint(
                  painter: _ProvisioningRing(counts, colors, td.borderSubtle),
                  child: Center(
                    child: FittedBox(
                      child: Text(
                        '${volumes.length}',
                        style: TdTypography.metricMedium,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              for (var i = 0; i < labels.length; i++)
                Text('${labels[i]} · ${counts[i]}'),
            ],
          ),
          if (volumes.isEmpty)
            const Text('No volume data; no percentages are inferred.'),
        ],
      ),
    );
  }
}

class _ProvisioningRing extends CustomPainter {
  const _ProvisioningRing(this.counts, this.colors, this.track);
  final List<int> counts;
  final List<Color> colors;
  final Color track;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(8);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10;
    canvas.drawOval(rect, paint..color = track);
    final total = counts.fold(0, (a, b) => a + b);
    if (total == 0) return;
    var start = -math.pi / 2;
    for (var i = 0; i < counts.length; i++) {
      final sweep = counts[i] / total * math.pi * 2;
      if (sweep > 0) {
        canvas.drawArc(rect, start, sweep, false, paint..color = colors[i]);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _ProvisioningRing oldDelegate) => true;
}

class ZvolEditorDialog extends ConsumerStatefulWidget {
  const ZvolEditorDialog({
    required this.session,
    required this.inventory,
    this.volume,
    super.key,
  });
  final AuthenticatedSession session;
  final ZvolInventory inventory;
  final ZvolEntry? volume;
  @override
  ConsumerState<ZvolEditorDialog> createState() => _ZvolEditorDialogState();
}

class _ZvolEditorDialogState extends ConsumerState<ZvolEditorDialog> {
  final _name = TextEditingController(), _size = TextEditingController();
  ZvolParent? _parent;
  DatasetSizeUnit _unit = DatasetSizeUnit.gibibytes;
  String _block = '16K', _compression = 'LZ4', _sync = 'STANDARD';
  bool _thin = false, _readonly = false, _loading = false, _preparing = false;
  String? _error, _recommendation;
  int _generation = 0;
  bool get _current =>
      identical(widget.session, ref.read(dashboardActiveSessionProvider));
  @override
  void initState() {
    super.initState();
    final v = widget.volume;
    _parent = widget.inventory.parents.where((p) => p.available).firstOrNull;
    _size.text = formatDatasetSize(v?.sizeBytes ?? 10 * 1073741824, _unit);
    _compression = v?.compression ?? 'LZ4';
    _sync = v?.sync ?? 'STANDARD';
    _readonly = v?.readonly ?? false;
    if (v == null && _parent != null) Future.microtask(_loadRecommendation);
  }

  @override
  void dispose() {
    _generation++;
    _name.dispose();
    _size.dispose();
    super.dispose();
  }

  Future<void> _loadRecommendation() async {
    if (!mounted || !_current || _parent == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _recommendation = null;
    });
    try {
      final value = await ref
          .read(zvolsSessionProvider)!
          .loadZvolRecommendedBlockSize(_parent!);
      if (mounted && _current && generation == _generation) {
        setState(() {
          _block = value;
          _recommendation = value;
        });
      }
    } catch (error) {
      if (mounted && _current && generation == _generation) {
        setState(
          () => _error = error is ZvolException
              ? error.userMessage
              : 'Block-size recommendation could not be loaded.',
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(dashboardActiveSessionProvider);
    final state = ref.watch(zvolsControllerProvider);
    if (!identical(active, widget.session)) return _expired(context);
    final creating = widget.volume == null;
    final enabled = !state.locked && !_preparing && !_loading;
    return AlertDialog(
      title: Text(creating ? 'Create Zvol' : 'Edit / grow Zvol'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 14,
            children: [
              Text(widget.session.endpoint ?? ''),
              if (creating) ...[
                DropdownButtonFormField<ZvolParent>(
                  key: const Key('zvol-parent'),
                  initialValue: _parent,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Parent filesystem',
                  ),
                  items: [
                    for (final p in widget.inventory.parents)
                      DropdownMenuItem(
                        value: p,
                        enabled: p.available,
                        child: Text(p.id, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: enabled
                      ? (p) {
                          setState(() => _parent = p);
                          _loadRecommendation();
                        }
                      : null,
                ),
                TextField(
                  key: const Key('zvol-name'),
                  controller: _name,
                  enabled: enabled,
                  decoration: const InputDecoration(labelText: 'New Zvol name'),
                  maxLength: 63,
                ),
              ] else ...[
                Text(widget.volume!.id, style: TdTypography.titleMedium),
                Text(
                  'Current logical size: ${widget.volume!.sizeBytes} bytes. Only growth is allowed. Existing block size ${widget.volume!.blockSizeBytes} bytes is fixed.',
                ),
                if (widget.volume!.refreservationBytes > 0)
                  const Text(
                    'Reserved-volume growth is unavailable here because allocation overhead must be recalculated by the server. Existing reservations are preserved; other settings can still be edited.',
                  ),
              ],
              TextField(
                key: const Key('zvol-size'),
                controller: _size,
                enabled:
                    enabled &&
                    (creating || widget.volume!.refreservationBytes == 0),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Logical size'),
              ),
              DropdownButtonFormField<DatasetSizeUnit>(
                key: const Key('zvol-unit'),
                initialValue: _unit,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Exact binary unit',
                ),
                items: [
                  for (final unit in DatasetSizeUnit.values)
                    DropdownMenuItem(value: unit, child: Text(unit.label)),
                ],
                onChanged:
                    enabled &&
                        (creating || widget.volume!.refreservationBytes == 0)
                    ? (unit) {
                        if (unit == null) return;
                        final bytes = parseDatasetSize(_size.text, _unit);
                        if (bytes == null) {
                          setState(
                            () => _error =
                                'Enter a valid size before changing its unit.',
                          );
                          return;
                        }
                        setState(() {
                          _unit = unit;
                          _size.text = formatDatasetSize(bytes, unit);
                          _error = null;
                        });
                      }
                    : null,
              ),
              if (creating) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey('zvol-block-$_block'),
                  initialValue: _block,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Block size (fixed after creation)',
                  ),
                  items: [
                    for (final block in zvolBlockSizes.keys)
                      DropdownMenuItem(
                        value: block,
                        enabled:
                            _recommendation != null &&
                            zvolBlockSizes[block]! >=
                                zvolBlockSizes[_recommendation]!,
                        child: Text(block),
                      ),
                  ],
                  onChanged: enabled
                      ? (v) => setState(() => _block = v!)
                      : null,
                ),
                if (_loading) const LinearProgressIndicator(),
                if (_recommendation != null)
                  Text(
                    'Server recommendation: $_recommendation; parent available: ${zvolBytes(_parent!.availableBytes)}.',
                  ),
                if (!_loading && _recommendation == null)
                  TextButton(
                    onPressed: _preparing ? null : _loadRecommendation,
                    child: const Text('Retry recommendation read'),
                  ),
                SwitchListTile(
                  key: const Key('zvol-thin'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Thin provisioning'),
                  subtitle: const Text(
                    'No full space reservation. Pool exhaustion can fail guest writes.',
                  ),
                  value: _thin,
                  onChanged: enabled ? (v) => setState(() => _thin = v) : null,
                ),
              ],
              DropdownButtonFormField<String>(
                key: const Key('zvol-compression'),
                initialValue: _compression,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Compression'),
                items: [
                  for (final c in {...zvolCompressionChoices, _compression})
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: enabled
                    ? (v) => setState(() => _compression = v!)
                    : null,
              ),
              DropdownButtonFormField<String>(
                key: const Key('zvol-sync'),
                initialValue: _sync,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Synchronous writes',
                ),
                items: [
                  for (final s in {...zvolSyncChoices, _sync})
                    DropdownMenuItem(value: s, child: Text(s)),
                ],
                onChanged: enabled ? (v) => setState(() => _sync = v!) : null,
              ),
              if (!creating)
                SwitchListTile(
                  key: const Key('zvol-readonly'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Read-only block device'),
                  value: _readonly,
                  onChanged: enabled
                      ? (v) => setState(() => _readonly = v)
                      : null,
                ),
              const Text(
                'Shrinking, forced oversizing, block-size changes, encryption changes and attaching consumers are not part of this editor.',
              ),
              if (_error != null)
                Text(_error!, key: const Key('zvol-editor-error')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _preparing ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('zvol-prepare'),
          onPressed: !enabled || creating && _recommendation == null
              ? null
              : _prepare,
          child: Text(_preparing ? 'Checking dependencies…' : 'Review changes'),
        ),
      ],
    );
  }

  Future<void> _prepare() async {
    final bytes = parseDatasetSize(_size.text, _unit);
    if (bytes == null) {
      setState(() => _error = 'Enter an exact size in the selected unit.');
      return;
    }
    final api = ref.read(zvolsSessionProvider);
    if (api == null || !_current) return;
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final v = widget.volume;
      final ZvolReview review;
      if (v == null) {
        final request = ZvolCreate(
          parent: _parent!,
          name: _name.text,
          sizeBytes: bytes,
          blockSize: _block,
          thin: _thin,
          compression: _compression,
          sync: _sync,
        );
        if (request.validationError != null) {
          setState(() => _error = request.validationError);
          return;
        }
        review = await api.reviewZvolCreate(request);
      } else {
        final request = ZvolUpdate(
          volume: v,
          sizeBytes: bytes == v.sizeBytes ? null : bytes,
          compression: _compression == v.compression ? null : _compression,
          sync: _sync == v.sync ? null : _sync,
          readonly: _readonly == v.readonly ? null : _readonly,
        );
        if (request.validationError != null) {
          setState(() => _error = request.validationError);
          return;
        }
        review = await api.reviewZvolUpdate(request);
      }
      if (!mounted || !_current) return;
      await showDialog<void>(
        context: context,
        builder: (_) =>
            ZvolReviewDialog(session: widget.session, review: review),
      );
      if (mounted && _current) Navigator.pop(context);
    } catch (error) {
      if (mounted && _current) {
        setState(
          () => _error = error is ZvolException
              ? error.userMessage
              : 'A fresh storage review could not be prepared.',
        );
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }
}

class ZvolReviewDialog extends ConsumerStatefulWidget {
  const ZvolReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final ZvolReview review;
  @override
  ConsumerState<ZvolReviewDialog> createState() => _ZvolReviewDialogState();
}

class _ZvolReviewDialogState extends ConsumerState<ZvolReviewDialog> {
  final _confirmation = TextEditingController();
  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    if (!identical(session, widget.session)) return _expired(context);
    final state = ref.watch(zvolsControllerProvider), review = widget.review;
    return AlertDialog(
      title: const Text('Confirm storage change'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Text('Server: ${widget.session.endpoint}'),
              Text('Target: ${review.target}'),
              Text('Identity: ${review.identity}'),
              for (final line in review.changes) Text(line),
              for (final warning in review.warnings) Text(warning),
              TextField(
                key: const Key('zvol-confirmation'),
                controller: _confirmation,
                enabled: !state.locked,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Type exactly ${review.target}',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: state.busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('zvol-confirm-submit'),
          onPressed: state.locked || _confirmation.text != review.target
              ? null
              : () async {
                  await ref
                      .read(zvolsControllerProvider.notifier)
                      .execute(widget.session, review, _confirmation.text);
                  if (context.mounted) Navigator.pop(context);
                },
          child: Text(state.busy ? 'Applying…' : 'Apply reviewed change'),
        ),
      ],
    );
  }
}

Widget _expired(BuildContext context) => AlertDialog(
  title: const Text('Connection changed'),
  content: const Text(
    'Previous storage settings are hidden. Close this dialog and reload the current server.',
  ),
  actions: [
    TextButton(
      onPressed: () => Navigator.pop(context),
      child: const Text('Close'),
    ),
  ],
);
