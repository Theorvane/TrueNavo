import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'iscsi_sessions.dart';

final iscsiSessionsProvider = FutureProvider.autoDispose<IscsiSessionsSnapshot>(
  (ref) async {
    final session = ref.watch(dashboardActiveSessionProvider);
    final repository = session?.repository;
    if (session?.endpoint == null || repository is! AuthenticatedAdminSession) {
      throw StateError('Connect to a server to read active sessions.');
    }
    final api = repository as AuthenticatedAdminSession;
    final method = api.adminCatalog.method('iscsi.global.sessions');
    if (!api.adminCatalog.versionSupported ||
        method == null ||
        !method.supported) {
      throw StateError('Active iSCSI sessions are unavailable on this server.');
    }
    final result = await api.invokeAdmin(
      AdminRequest(method: method, arguments: const []),
    );
    if (!ref.mounted ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      throw StateError('The server connection changed.');
    }
    if (result is! AdminCompleted) {
      throw StateError(
        'Active iSCSI sessions are unavailable for this account.',
      );
    }
    return IscsiSessionsSnapshot.parse(result.value, DateTime.now().toUtc());
  },
  retry: (_, _) => null,
);

class IscsiSessionsPanel extends ConsumerStatefulWidget {
  const IscsiSessionsPanel({super.key});

  @override
  ConsumerState<IscsiSessionsPanel> createState() => _IscsiSessionsPanelState();
}

class _IscsiSessionsPanelState extends ConsumerState<IscsiSessionsPanel> {
  AuthenticatedSession? _requestedSession;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final requested = session != null && identical(session, _requestedSession);
    final state = requested ? ref.watch(iscsiSessionsProvider) : null;
    return TdPanel(
      title: 'Active iSCSI sessions',
      description: 'On-demand snapshot only. No polling or automatic refresh.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('iscsi-load-sessions'),
                onPressed: session == null || state?.isLoading == true
                    ? null
                    : () {
                        ref.invalidate(iscsiSessionsProvider);
                        setState(() => _requestedSession = session);
                      },
                icon: const Icon(Icons.visibility_outlined),
                label: Text(requested ? 'Refresh sessions' : 'Load sessions'),
              ),
              if (requested)
                TextButton(
                  key: const Key('iscsi-hide-sessions'),
                  onPressed: () => setState(() => _requestedSession = null),
                  child: const Text('Hide'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (!requested)
            const Text(
              'Client identities and IP addresses are not loaded until requested.',
            )
          else
            switch (state) {
              AsyncData(:final value) => _SessionList(snapshot: value),
              AsyncError(:final error) => Text(
                error is StateError
                    ? error.message.toString()
                    : 'The session snapshot was incomplete. Refresh to retry.',
              ),
              _ => const CircularProgressIndicator(),
            },
        ],
      ),
    );
  }
}

class _SessionList extends StatelessWidget {
  const _SessionList({required this.snapshot});
  final IscsiSessionsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final sessions = snapshot.sessions;
    final grouped = <String, int>{};
    for (final session in sessions) {
      grouped.update(session.target, (count) => count + 1, ifAbsent: () => 1);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${sessions.length} sessions · Read ${snapshot.observedAt.toIso8601String()} (client UTC)',
        ),
        const SizedBox(height: 4),
        const Text(
          'This is a momentary server report; an initiator may disconnect immediately afterward.',
        ),
        if (sessions.isEmpty) ...[
          const SizedBox(height: 12),
          const Text('No active iSCSI sessions reported.'),
        ],
        for (final entry in grouped.entries) ...[
          const SizedBox(height: 12),
          Text('${entry.key} · ${entry.value}'),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: entry.value / sessions.length,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
        ],
        for (final session in sessions) ...[
          const SizedBox(height: 12),
          Text('${session.initiator} · ${session.initiatorAddress}'),
          Text(
            'Target: ${session.target}${session.iser ? ' · iSER' : ''}${session.offload ? ' · offload' : ''}',
          ),
        ],
      ],
    );
  }
}
