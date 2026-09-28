import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';
import 'nvme_port_create_coordinator.dart';

class NvmePortCreateEditor extends ConsumerStatefulWidget {
  const NvmePortCreateEditor({super.key});

  @override
  ConsumerState<NvmePortCreateEditor> createState() =>
      _NvmePortCreateEditorState();
}

class _NvmePortCreateEditorState extends ConsumerState<NvmePortCreateEditor> {
  final _address = TextEditingController();
  final _service = TextEditingController(text: '4420');
  final _confirmation = TextEditingController();
  NvmePortCreateReview? _review;
  NvmePortCreateCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;
  String _transport = 'TCP';

  @override
  void dispose() {
    _address.dispose();
    _service.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(NvmePortCreateCoordinator coordinator) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final port = int.tryParse(_service.text);
      if (port == null || !RegExp(r'^[1-9][0-9]*$').hasMatch(_service.text)) {
        throw StateError('Enter a port from 1024 to 65535. Nothing was sent.');
      }
      final review = await coordinator.prepare(
        NvmePortCreateChoice(_address.text, port, transport: _transport),
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

  void _discardReview() {
    final review = _review;
    if (review != null) _reviewCoordinator?.cancel(review);
    _review = null;
    _reviewCoordinator = null;
    _reviewSession = null;
  }

  Future<void> _submit(
    NvmePortCreateCoordinator coordinator,
    NvmePortCreateReview review,
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
    if (result.outcome == NvmePortCreateOutcome.completed) {
      _address.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmePortCreateCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _transport == _review?.choice.transport &&
            _address.text == _review?.choice.address &&
            _service.text == _review?.choice.servicePort.toString()
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Create a disabled NVMe-oF TCP/RDMA port',
      description: 'Creates only a disabled TCP or RDMA port at an explicit IPv4 or global/ULA IPv6 address. Wildcard, scoped/link-local and IPv4-mapped IPv6 inputs are unavailable. No subsystem association or service start is requested. Enabling later may open a listener; RDMA hardware support, interface ownership and client access are not tested.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            key: const Key('nvme-port-create-transport'),
            initialValue: _transport,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Transport',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'TCP', child: Text('TCP')),
              DropdownMenuItem(value: 'RDMA', child: Text('RDMA')),
            ],
            onChanged: enabled
                ? (value) {
                    if (value == null) return;
                    setState(() {
                      _discardReview();
                      _transport = value;
                    });
                  }
                : null,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('nvme-port-create-address'),
            controller: _address,
            enabled: enabled,
            maxLength: 39,
            decoration: const InputDecoration(
              labelText: 'Explicit IPv4 or IPv6 bind address',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          TextField(
            key: const Key('nvme-port-create-service'),
            controller: _service,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 5,
            decoration: const InputDecoration(
              labelText: 'Service port (1024–65535)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          OutlinedButton(
            key: const Key('nvme-port-create-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: Text('Review disabled $_transport port creation'),
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
            Text(
              '${review.choice.transport} ${review.choice.bindingLabel}, disabled',
            ),
            Text(
              'Payload: ${review.choice.transport} transport, explicit address, service port and enabled=false only. No association or service operation is submitted.',
            ),
            const Text(
              'The inventory is checked again before creation. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('nvme-port-create-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-port-create-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: Text('Create disabled ${review.choice.transport} port'),
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
