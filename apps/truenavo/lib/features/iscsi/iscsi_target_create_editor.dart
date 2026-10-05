import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;
import 'iscsi_target_create_coordinator.dart';

class IscsiTargetCreateEditor extends ConsumerStatefulWidget {
  const IscsiTargetCreateEditor({super.key});

  @override
  ConsumerState<IscsiTargetCreateEditor> createState() =>
      _IscsiTargetCreateEditorState();
}

class _IscsiTargetCreateEditorState
    extends ConsumerState<IscsiTargetCreateEditor> {
  final _name = TextEditingController();
  final _confirmation = TextEditingController();
  IscsiTargetCreateReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(IscsiTargetCreateCoordinator coordinator) async {
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(_name.text);
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
    IscsiTargetCreateCoordinator coordinator,
    IscsiTargetCreateReview review,
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
    if (result.outcome == IscsiTargetCreateOutcome.completed) {
      _name.clear();
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiTargetCreateCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) && _name.text == _review?.name
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Create an unbound iSCSI target',
      description: 'Creates an iSCSI-only target with no portal or initiator group, CHAP credential, authorized network or LUN mapping. The iSCSI service must be stopped and have no active sessions.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('iscsi-target-create-name'),
            controller: _name,
            enabled: enabled,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'New target name',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _review = null),
          ),
          OutlinedButton(
            key: const Key('iscsi-target-create-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review unbound target creation'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'This server does not expose the required target methods.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An iSCSI change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text('New target: ${review.name}'),
            const Text(
              'Payload: iSCSI mode, no access groups and no authorized networks. No LUN mapping is submitted.',
            ),
            const Text(
              'Target names and stopped/zero-session state are checked again. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('iscsi-target-create-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-target-create-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Create unbound target'),
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
