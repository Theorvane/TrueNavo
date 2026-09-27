import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_overview.dart';
import 'nvme_port_inline_coordinator.dart';

class NvmePortInlineEditor extends ConsumerStatefulWidget {
  const NvmePortInlineEditor({super.key});

  @override
  ConsumerState<NvmePortInlineEditor> createState() =>
      _NvmePortInlineEditorState();
}

class _NvmePortInlineEditorState extends ConsumerState<NvmePortInlineEditor> {
  final _id = TextEditingController();
  final _limit = TextEditingController();
  final _confirmation = TextEditingController();
  bool _useDefault = true;
  NvmePortInlineReview? _review;
  NvmePortInlineCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _id.dispose();
    _limit.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _discardReview() {
    final review = _review;
    if (review != null) _reviewCoordinator?.cancel(review);
    _review = null;
    _reviewCoordinator = null;
    _reviewSession = null;
  }

  Future<void> _prepare(NvmePortInlineCoordinator coordinator) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final id = int.tryParse(_id.text.trim());
      if (id == null || id <= 0) {
        throw StateError('Enter a positive port ID. Nothing was sent.');
      }
      final rawLimit = _limit.text.trim();
      final parsedLimit = int.tryParse(rawLimit);
      if (!_useDefault &&
          (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(rawLimit) ||
              parsedLimit == null ||
              parsedLimit > 2147483647)) {
        throw StateError(
          'Enter an inline data size from 0 to 2147483647. Nothing was sent.',
        );
      }
      final review = await coordinator.prepare(
        id,
        NvmePortInlineChoice(_useDefault ? null : parsedLimit),
      );
      if (!mounted) {
        coordinator.cancel(review);
        return;
      }
      setState(() {
        _review = review;
        _reviewCoordinator = coordinator;
        _reviewSession = ref.read(dashboardActiveSessionProvider);
        _confirmation.clear();
      });
    } on StateError catch (error) {
      if (mounted) setState(() => _message = error.message.toString());
    } on Object {
      if (mounted) {
        setState(() => _message = 'Preflight failed. Nothing was sent.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmePortInlineCoordinator coordinator,
    NvmePortInlineReview review,
  ) async {
    final phrase = _confirmation.text;
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    final result = await coordinator.execute(review, phrase);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
    if (result.outcome == NvmePortInlineOutcome.completed) {
      _id.clear();
      _limit.clear();
      _useDefault = true;
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmePortInlineCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _id.text.trim() == _review?.id.toString() &&
            _useDefault == (_review?.choice.wireValue == null) &&
            (_useDefault ||
                _limit.text.trim() == _review?.choice.wireValue?.toString())
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Set inline data size on a disabled NVMe-oF port',
      description: 'Changes only a disabled port with a returned inline-data-size field and no subsystem associations. This editor supports a conservative nonnegative integer range or server default. Zero is sent literally; saved settings do not verify client behavior.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-port-inline-id'),
            controller: _id,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Disabled port ID from topology',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          Row(
            children: [
              const Expanded(child: Text('Use server default')),
              Switch(
                key: const Key('nvme-port-inline-default'),
                value: _useDefault,
                onChanged: enabled
                    ? (value) => setState(() {
                        _discardReview();
                        _useDefault = value;
                      })
                    : null,
              ),
            ],
          ),
          TextField(
            key: const Key('nvme-port-inline-limit'),
            controller: _limit,
            enabled: enabled && !_useDefault,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Inline data size (0–2147483647)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('nvme-port-inline-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review inline data size'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'This server does not expose the required NVMe-oF methods and protected host inventory.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An NVMe-oF change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text('Disabled port #${review.id}: ${review.transport}'),
            Text('Inline data size: ${review.oldLabel} → ${review.newLabel}'),
            const Text(
              'Only nvmet.port.update(port ID, {inline_data_size: selected value}) is submitted. No mapping or other port field is sent.',
            ),
            const Text(
              'Dependencies are checked again before submission. Sequential reads cannot exclude a concurrent administrator.',
            ),
            TextField(
              key: const Key('nvme-port-inline-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-port-inline-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Set inline data size'),
            ),
            TextButton(
              onPressed: _busy ? null : () => setState(_discardReview),
              child: const Text('Cancel'),
            ),
          ],
          if (_message != null) Text(_message!),
        ],
      ),
    );
  }
}
