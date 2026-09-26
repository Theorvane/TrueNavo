import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;
import 'iscsi_portal_create_coordinator.dart';

class IscsiPortalListenerEditor extends ConsumerStatefulWidget {
  const IscsiPortalListenerEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiPortalListenerEditor> createState() =>
      _IscsiPortalListenerEditorState();
}

class _IscsiPortalListenerEditorState
    extends ConsumerState<IscsiPortalListenerEditor> {
  final _ip = TextEditingController();
  final _confirmation = TextEditingController();
  int? _selected;
  IscsiPortalListenerReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiPortalListenerEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _selected = null;
      _review = null;
      _confirmation.clear();
    }
  }

  @override
  void dispose() {
    _ip.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(IscsiPortalListenerCoordinator coordinator) async {
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(_selected!, _ip.text);
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
    IscsiPortalListenerCoordinator coordinator,
    IscsiPortalListenerReview review,
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
    if (result.outcome == IscsiPortalListenerOutcome.completed) {
      _selected = null;
      _ip.clear();
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiPortalListenerCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            _selected == _review?.id &&
            _ip.text == _review?.proposed
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    final portals = widget.overview.portals;
    return TdPanel(
      title: 'Replace an unassigned portal listener',
      description: 'Only a portal with one explicit IPv4 listener and no target references qualifies. Stop iSCSI and disconnect all clients first. The new IP must be offered by the server and unused by other portals.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('iscsi-portal-listener-select'),
            isExpanded: true,
            initialValue: portals.any((portal) => portal.id == _selected)
                ? _selected
                : null,
            decoration: const InputDecoration(
              labelText: 'Portal',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final portal in portals)
                DropdownMenuItem(
                  value: portal.id,
                  child: Text('Portal #${portal.id}'),
                ),
            ],
            onChanged: enabled
                ? (id) => setState(() {
                    _selected = id;
                    _review = null;
                    _message = null;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('iscsi-portal-listener-new'),
            controller: _ip,
            enabled: enabled,
            maxLength: 15,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'New static IPv4 address',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {
              _review = null;
              _message = null;
            }),
          ),
          OutlinedButton(
            key: const Key('iscsi-portal-listener-review'),
            onPressed: enabled && _selected != null
                ? () => _prepare(coordinator)
                : null,
            child: const Text('Review listener replacement'),
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
            Text('Portal #${review.id} · tag ${review.tag}'),
            Text(
              '${review.before}:${review.port} → ${review.proposed}:${review.port}',
            ),
            Text(
              'Description unchanged: ${review.comment.isEmpty ? '(none)' : review.comment}',
            ),
            const Text(
              'Portal, target, address-choice, service and session state are checked again before submission. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('iscsi-portal-listener-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-portal-listener-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Replace listener'),
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
