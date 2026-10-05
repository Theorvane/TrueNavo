import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'iscsi_auth_usage.dart';
import 'iscsi_overview.dart';

final iscsiAuthReferencesProvider =
    FutureProvider.autoDispose<IscsiAuthInventory>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedIscsiAuthSession) {
        throw StateError('Connect to a server to inspect CHAP references.');
      }
      final value = await (repository as AuthenticatedIscsiAuthSession)
          .loadIscsiAuthReferences();
      if (!ref.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        throw StateError('The server connection changed.');
      }
      return value;
    }, retry: (_, _) => null);

class IscsiAuthPanel extends ConsumerStatefulWidget {
  const IscsiAuthPanel({this.overview, super.key});

  final IscsiOverview? overview;

  @override
  ConsumerState<IscsiAuthPanel> createState() => _IscsiAuthPanelState();
}

class _IscsiAuthPanelState extends ConsumerState<IscsiAuthPanel> {
  AuthenticatedSession? _requestedSession;

  @override
  void didUpdateWidget(covariant IscsiAuthPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new topology must never be joined to previously loaded credentials.
    if (!identical(oldWidget.overview, widget.overview)) {
      _requestedSession = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final available = session?.repository is AuthenticatedIscsiAuthSession;
    final requested = session != null && identical(session, _requestedSession);
    final state = requested ? ref.watch(iscsiAuthReferencesProvider) : null;
    return TdPanel(
      title: 'CHAP authentication references',
      description:
          'Load identities only on request. Secrets are never displayed.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('iscsi-load-auth'),
                onPressed: !available || state?.isLoading == true
                    ? null
                    : () {
                        ref.invalidate(iscsiAuthReferencesProvider);
                        setState(() => _requestedSession = session);
                      },
                icon: const Icon(Icons.visibility_outlined),
                label: Text(
                  requested ? 'Refresh references' : 'Load references',
                ),
              ),
              if (requested)
                TextButton(
                  key: const Key('iscsi-hide-auth'),
                  onPressed: () => setState(() => _requestedSession = null),
                  child: const Text('Hide'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (!requested)
            const Text(
              'CHAP usernames and tags are not loaded until requested.',
            )
          else if (state?.isLoading == true)
            const CircularProgressIndicator()
          else
            switch (state) {
              AsyncData(:final value) => _References(
                inventory: value,
                overview: widget.overview,
              ),
              AsyncError() => const Text(
                'CHAP references are unavailable or incomplete for this account.',
              ),
              _ => const CircularProgressIndicator(),
            },
        ],
      ),
    );
  }
}

class _References extends StatelessWidget {
  const _References({required this.inventory, this.overview});
  final IscsiAuthInventory inventory;
  final IscsiOverview? overview;

  @override
  Widget build(BuildContext context) {
    final records = inventory.references;
    final usage = overview == null
        ? null
        : IscsiAuthUsage.from(inventory, overview!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${records.length} credentials · Read ${inventory.observedAt.toIso8601String()} (client UTC)',
        ),
        const SizedBox(height: 8),
        if (records.isEmpty) const Text('No CHAP records configured.'),
        for (final record in records) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'Tag ${record.tag} · ${record.user}${record.peerUser.isEmpty ? '' : ' ↔ ${record.peerUser}'} · Discovery ${record.discoveryAuth}${usage == null ? '' : ' · ${usage.targetUses[record.id] ?? 0} target(s)'}',
            ),
          ),
          if (usage != null &&
              (usage.targetReferences[record.id]?.isNotEmpty ?? false))
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 12),
              child: Text(_targetSummary(usage.targetReferences[record.id]!)),
            ),
        ],
        if (usage != null) IscsiAuthUsageChart(usage: usage),
        const Text(
          'Only references are shown; access cannot be inferred from these rows.',
        ),
      ],
    );
  }
}

String _targetSummary(List<IscsiAuthTargetReference> targets) {
  final shown = targets
      .take(3)
      .map((target) => '${target.name} (#${target.id})');
  final remaining = targets.length - 3;
  return 'Returned targets: ${shown.join(', ')}${remaining > 0 ? ' +$remaining more' : ''}';
}
