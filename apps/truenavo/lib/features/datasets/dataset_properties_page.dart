import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'dataset_properties_controller.dart';
import 'dataset_size_input.dart';

const _labels = {
  'quota': 'Dataset quota',
  'refquota': 'Reference quota',
  'reservation': 'Dataset reservation',
  'refreservation': 'Reference reservation',
  'compression': 'Compression',
  'atime': 'Access time',
  'readonly': 'Read-only',
};

class DatasetPropertiesPage extends ConsumerWidget {
  const DatasetPropertiesPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final capability = ref
        .watch(datasetPropertiesSessionProvider)
        ?.datasetPropertiesCapabilities;
    final state = ref.watch(datasetPropertiesControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Dataset properties')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Storage policies', style: TdTypography.titleLarge),
            const SizedBox(height: 8),
            Text(session?.endpoint ?? 'No authenticated server'),
            const SizedBox(height: 16),
            if (state.result != null)
              TdPanel(
                title: state.result!.outcome == DatasetPropertyOutcome.verified
                    ? 'Properties verified'
                    : state.unresolved
                    ? 'Outcome unknown'
                    : 'Update not applied',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${state.server ?? ''}\n${state.target ?? ''}'),
                    Text(state.result!.message),
                    if (state.unresolved)
                      TextButton(
                        onPressed: () => ref
                            .read(datasetPropertiesControllerProvider.notifier)
                            .acknowledgeUnknown(),
                        child: const Text(
                          'I inspected the outcome and reconnected',
                        ),
                      ),
                  ],
                ),
              ),
            if (capability?.supported != true || session?.endpoint == null)
              TdPanel(
                title: 'Editor unavailable',
                child: Text(
                  capability?.blockedReason ??
                      'Connect to a supported TrueNAS server.',
                ),
              )
            else
              ref
                  .watch(datasetPropertiesProvider)
                  .when(
                    loading: () => const LinearProgressIndicator(),
                    error: (_, _) => TdPanel(
                      title: 'Dataset properties unavailable',
                      child: OutlinedButton(
                        onPressed: () =>
                            ref.invalidate(datasetPropertiesProvider),
                        child: const Text('Reload properties'),
                      ),
                    ),
                    data: (items) => Column(
                      children: [
                        if (items.isEmpty)
                          const TdPanel(
                            title: 'No filesystems returned',
                            child: Text(
                              'The server did not return any filesystem datasets.',
                            ),
                          ),
                        for (final item in items)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: TdPanel(
                              title: item.id,
                              description: item.blockedReason,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Used ${_bytes(item.usedBytes)} · available ${_bytes(item.availableBytes)}',
                                  ),
                                  Text(
                                    'Compression ${item.properties['compression']!.value} · ${item.descendants.length} visible descendants',
                                  ),
                                  const SizedBox(height: 8),
                                  FilledButton.tonalIcon(
                                    onPressed:
                                        item.editable &&
                                            !state.busy &&
                                            !state.unresolved
                                        ? () => Navigator.of(context).push(
                                            MaterialPageRoute<void>(
                                              builder: (_) =>
                                                  DatasetPropertyEditorPage(
                                                    session: session!,
                                                    snapshot: item,
                                                  ),
                                            ),
                                          )
                                        : null,
                                    icon: const Icon(Icons.tune),
                                    label: const Text('Edit properties'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
            const SizedBox(height: 20),
            const Text(
              'Filesystem quotas and reservations use exact bytes. Encryption, ACLs, mountpoints and ZVOLs are not changed by this editor. Compression affects new writes; existing blocks are not recompressed.',
            ),
          ],
        ),
      ),
    );
  }
}

class DatasetPropertyEditorPage extends ConsumerStatefulWidget {
  const DatasetPropertyEditorPage({
    required this.session,
    required this.snapshot,
    super.key,
  });
  final AuthenticatedSession session;
  final DatasetPropertySnapshot snapshot;
  @override
  ConsumerState<DatasetPropertyEditorPage> createState() =>
      _DatasetPropertyEditorState();
}

class _DatasetPropertyEditorState
    extends ConsumerState<DatasetPropertyEditorPage> {
  final _bytesInputs = <String, TextEditingController>{};
  final _settings = <String, String>{};
  final _units = <String, DatasetSizeUnit>{};
  String? _error;
  @override
  void initState() {
    super.initState();
    for (final key in datasetByteProperties) {
      _units[key] = DatasetSizeUnit.bytes;
      _bytesInputs[key] = TextEditingController(
        text: widget.snapshot.properties[key]!.value.toString(),
      );
    }
    for (final key in datasetInheritedProperties) {
      _settings[key] = 'KEEP';
    }
  }

  @override
  void dispose() {
    for (final c in _bytesInputs.values) {
      c.dispose();
    }
    super.dispose();
  }

  DatasetPropertyUpdate? _request() {
    final changes = <String, Object>{};
    for (final key in datasetByteProperties) {
      final value = parseDatasetSize(_bytesInputs[key]!.text, _units[key]!);
      if (value == null) {
        setState(
          () => _error = 'Enter whole non-negative byte values. Unit conversions must be exact, within 9007199254740991 bytes.',
        );
        return null;
      }
      if (value != widget.snapshot.properties[key]!.value) changes[key] = value;
    }
    for (final key in datasetInheritedProperties) {
      if (_settings[key] != 'KEEP') changes[key] = _settings[key]!;
    }
    final request = DatasetPropertyUpdate(
      snapshot: widget.snapshot,
      changes: changes,
    );
    setState(() => _error = request.validationError);
    return _error == null ? request : null;
  }

  Future<void> _review() async {
    final request = _request();
    if (request == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DatasetPropertyReviewDialog(
        server: widget.session.endpoint!,
        request: request,
      ),
    );
    if (!mounted ||
        confirmed != true ||
        !identical(ref.read(dashboardActiveSessionProvider), widget.session)) {
      return;
    }
    await ref
        .read(datasetPropertiesControllerProvider.notifier)
        .apply(expectedSession: widget.session, request: request);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _sizeField(String key, bool enabled) => LayoutBuilder(
    builder: (context, constraints) {
      final input = TextField(
        key: ValueKey('dataset-$key'),
        controller: _bytesInputs[key],
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: _labels[key],
          helperText:
              'Current: ${widget.snapshot.properties[key]!.description}',
          helperMaxLines: 3,
        ),
      );
      final unit = InputDecorator(
        decoration: const InputDecoration(labelText: 'Unit'),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<DatasetSizeUnit>(
            key: ValueKey('dataset-$key-unit'),
            value: _units[key],
            isExpanded: true,
            items: [
              for (final value in DatasetSizeUnit.values)
                DropdownMenuItem(value: value, child: Text(value.label)),
            ],
            onChanged: enabled
                ? (next) {
                    if (next == null) return;
                    final bytes = parseDatasetSize(
                      _bytesInputs[key]!.text,
                      _units[key]!,
                    );
                    if (bytes == null) {
                      setState(
                        () => _error = 'Enter a valid exact size before changing its unit.',
                      );
                      return;
                    }
                    setState(() {
                      _units[key] = next;
                      _bytesInputs[key]!.text = formatDatasetSize(bytes, next);
                      _error = null;
                    });
                  }
                : null,
          ),
        ),
      );
      if (constraints.maxWidth < 340 ||
          MediaQuery.textScalerOf(context).scale(14) > 18) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [input, const SizedBox(height: 8), unit],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: input),
          const SizedBox(width: 12),
          SizedBox(width: 110, child: unit),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final current = identical(
      ref.watch(dashboardActiveSessionProvider),
      widget.session,
    );
    final state = ref.watch(datasetPropertiesControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Edit dataset')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(widget.snapshot.id, style: TdTypography.titleLarge),
            Text(widget.session.endpoint ?? 'Unknown server'),
            const SizedBox(height: 16),
            TdPanel(
              title: 'Space limits',
              description: 'Choose B, KiB, MiB, GiB or TiB. Changing units preserves the exact size. 0 removes the limit or reservation; quotas must otherwise be at least 1 GiB.',
              child: Column(
                children: [
                  Text(
                    'Used: ${_bytes(widget.snapshot.usedBytes)}\nReferenced: ${_bytes(widget.snapshot.referencedBytes)}\nParent available: ${_bytes(widget.snapshot.parentAvailableBytes)}',
                  ),
                  for (final key in datasetByteProperties)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: _sizeField(key, current && !state.busy),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TdPanel(
              title: 'Filesystem behavior',
              description: widget.snapshot.verifiedLeaf
                  ? 'Inherited values follow the parent and may change later.'
                  : 'Behavior changes require a verified leaf. The server must report filesystem_count 0; public inventory can hide internal descendants. Byte limits remain editable.',
              child: Column(
                children: [
                  for (final key in datasetInheritedProperties)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('dataset-$key'),
                        initialValue: _settings[key],
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: _labels[key],
                          helperText:
                              'Current: ${widget.snapshot.properties[key]!.description}\nParent: ${widget.snapshot.parentProperties[key]?.description ?? 'unavailable'}',
                          helperMaxLines: 4,
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: 'KEEP',
                            child: Text('Keep current source and value'),
                          ),
                          const DropdownMenuItem(
                            value: 'INHERIT',
                            child: Text('Inherit from parent'),
                          ),
                          for (final choice
                              in key == 'compression'
                                  ? datasetCompressionChoices
                                  : const ['ON', 'OFF'])
                            DropdownMenuItem(
                              value: choice,
                              child: Text(choice),
                            ),
                        ],
                        onChanged:
                            current &&
                                !state.busy &&
                                widget.snapshot.verifiedLeaf
                            ? (value) => setState(() => _settings[key] = value!)
                            : null,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Changing limits can stop writes or consume shared pool space. Read-only changes with service attachments are blocked. There is no automatic rollback for property updates.',
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (!current)
              const Text(
                'The authenticated connection changed. Close this editor and reload.',
              ),
            FilledButton.icon(
              onPressed: current && !state.busy && !state.unresolved
                  ? _review
                  : null,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Review changes'),
            ),
          ],
        ),
      ),
    );
  }
}

class DatasetPropertyReviewDialog extends StatefulWidget {
  const DatasetPropertyReviewDialog({
    required this.server,
    required this.request,
    super.key,
  });
  final String server;
  final DatasetPropertyUpdate request;
  @override
  State<DatasetPropertyReviewDialog> createState() =>
      _DatasetPropertyReviewState();
}

class _DatasetPropertyReviewState extends State<DatasetPropertyReviewDialog> {
  bool _accepted = false;
  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Review dataset changes',
              style: TdTypography.titleMedium,
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${widget.server}\n${widget.request.snapshot.id}'),
                    Text('Dataset GUID: ${widget.request.snapshot.guid}'),
                    for (final change in widget.request.changes.entries)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _labels[change.key]!,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Before: ${widget.request.snapshot.properties[change.key]!.description}',
                            ),
                            Text(
                              'After: ${widget.request.effective(change.key)} · ${change.value == 'INHERIT' ? 'INHERIT from parent' : 'LOCAL'}',
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'Changes apply immediately and may interrupt client writes. Available space can change during review. TrueNAS performs final validation; other administrators must not edit this dataset concurrently. There is no automatic rollback.',
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _accepted,
                      onChanged: (v) => setState(() => _accepted = v!),
                      title: const Text(
                        'I reviewed this server, dataset and write impact.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: _accepted
                      ? () => Navigator.of(context).pop(true)
                      : null,
                  child: const Text('Apply properties'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

String _bytes(int value) {
  if (value < 1024) return '$value B';
  var scaled = value.toDouble();
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var unit = 0;
  while (scaled >= 1024 && unit < units.length - 1) {
    scaled /= 1024;
    unit++;
  }
  return '${scaled.toStringAsFixed(2)} ${units[unit]} ($value B)';
}
