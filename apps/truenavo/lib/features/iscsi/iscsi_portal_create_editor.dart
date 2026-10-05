import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;
import 'iscsi_portal_create_coordinator.dart';

class IscsiPortalCreateEditor extends ConsumerStatefulWidget {
  const IscsiPortalCreateEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiPortalCreateEditor> createState() =>
      _IscsiPortalCreateEditorState();
}

class _IscsiPortalCreateEditorState
    extends ConsumerState<IscsiPortalCreateEditor> {
  final _ip = TextEditingController();
  final _comment = TextEditingController();
  final _confirmation = TextEditingController();
  IscsiPortalCreateReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiPortalCreateEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _review = null;
      _confirmation.clear();
    }
  }

  @override
  void dispose() {
    _ip.dispose();
    _comment.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(IscsiPortalCreateCoordinator coordinator) async {
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(_ip.text, _comment.text);
      if (!mounted) return;
      setState(() {
        _review = review;
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
    IscsiPortalCreateCoordinator coordinator,
    IscsiPortalCreateReview review,
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
    if (result.outcome == IscsiPortalCreateOutcome.completed) {
      _ip.clear();
      _comment.clear();
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiPortalCreateCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            _ip.text == _review?.ip &&
            _comment.text == _review?.comment
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Create an unassigned portal',
      description: 'Use one server-offered static IPv4 address that no existing portal uses. The iSCSI service must be stopped with no active sessions. This does not assign the portal to a target.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('iscsi-portal-create-ip'),
            controller: _ip,
            enabled: enabled,
            maxLength: 15,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Listener IPv4 address',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {
              _review = null;
              _message = null;
            }),
          ),
          TextField(
            key: const Key('iscsi-portal-create-comment'),
            controller: _comment,
            enabled: enabled,
            maxLength: 128,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {
              _review = null;
              _message = null;
            }),
          ),
          OutlinedButton(
            key: const Key('iscsi-portal-create-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review portal creation'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'This server does not expose the required portal methods.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An iSCSI change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text('Listener: ${review.ip} (server-selected port)'),
            Text(
              'Description: ${review.comment.isEmpty ? '(none)' : review.comment}',
            ),
            const Text(
              'Fresh portal, target, address-choice, service and session reads are required before creation. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('iscsi-portal-create-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-portal-create-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Create portal'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      coordinator.cancel(review);
                      setState(() => _review = null);
                    },
              child: const Text('Cancel'),
            ),
          ],
          if (_message != null) Text(_message!),
        ],
      ),
    );
  }
}
