import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'iscsi_listener_choices.dart';
import 'iscsi_overview.dart';

final iscsiListenerChoicesProvider =
    FutureProvider.autoDispose<IscsiListenerChoices>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession) {
        throw StateError('Connect to a server to inspect listener choices.');
      }
      final api = repository as AuthenticatedAdminSession;
      final method = api.adminCatalog.method('iscsi.portal.listen_ip_choices');
      if (!api.adminCatalog.versionSupported ||
          method == null ||
          !method.supported) {
        throw StateError('Listener choices are unavailable on this server.');
      }
      final result = await api.invokeAdmin(
        AdminRequest(method: method, arguments: const []),
      );
      if (!ref.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        throw StateError('The server connection changed.');
      }
      if (result is! AdminCompleted) {
        throw StateError('Listener choices are unavailable for this account.');
      }
      return IscsiListenerChoices.parse(result.value);
    }, retry: (_, _) => null);

class IscsiListenerChoicesPanel extends ConsumerStatefulWidget {
  const IscsiListenerChoicesPanel({required this.overview, super.key});

  final IscsiOverview overview;

  @override
  ConsumerState<IscsiListenerChoicesPanel> createState() =>
      _IscsiListenerChoicesPanelState();
}

class _IscsiListenerChoicesPanelState
    extends ConsumerState<IscsiListenerChoicesPanel> {
  AuthenticatedSession? _requestedSession;

  @override
  void didUpdateWidget(covariant IscsiListenerChoicesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _requestedSession = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final api = session?.repository;
    final admin = api is AuthenticatedAdminSession
        ? api as AuthenticatedAdminSession
        : null;
    final method = admin?.adminCatalog.method('iscsi.portal.listen_ip_choices');
    final available =
        session?.endpoint != null &&
        admin?.adminCatalog.versionSupported == true &&
        method?.supported == true;
    final requested = session != null && identical(session, _requestedSession);
    final state = requested ? ref.watch(iscsiListenerChoicesProvider) : null;
    return TdPanel(
      title: 'Portal listener address choices',
      description:
          'Server-offered static IP choices compared with configured listeners. '
          'Not a reachability test or permission to change a live portal.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('iscsi-load-listener-choices'),
                onPressed: !available || state?.isLoading == true
                    ? null
                    : () {
                        ref.invalidate(iscsiListenerChoicesProvider);
                        setState(() => _requestedSession = session);
                      },
                icon: const Icon(Icons.list_alt_outlined),
                label: Text(requested ? 'Refresh choices' : 'Load choices'),
              ),
              if (requested)
                TextButton(
                  key: const Key('iscsi-hide-listener-choices'),
                  onPressed: () => setState(() => _requestedSession = null),
                  child: const Text('Hide'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (!available)
            const Text('This server does not expose listener address choices.')
          else if (!requested)
            const Text('Choices are loaded only when requested.')
          else if (state?.isLoading == true)
            const CircularProgressIndicator()
          else
            switch (state) {
              AsyncData(:final value) => _ChoicesContent(
                overview: widget.overview,
                choices: value,
              ),
              AsyncError() => const Text(
                'Listener choices are unavailable or incomplete for this account.',
              ),
              _ => const CircularProgressIndicator(),
            },
        ],
      ),
    );
  }
}

class _ChoicesContent extends StatelessWidget {
  const _ChoicesContent({required this.overview, required this.choices});

  final IscsiOverview overview;
  final IscsiListenerChoices choices;

  @override
  Widget build(BuildContext context) {
    final configured = [
      for (final portal in overview.portals)
        for (final listener in portal.listeners)
          (portalId: portal.id, ip: listener.ip, port: listener.port),
    ];
    final listed = configured
        .where((listener) => choices.addresses.contains(listener.ip))
        .length;
    final sortedChoices = choices.addresses.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Read ${choices.observedAt.toIso8601String()} (client UTC)'),
        const SizedBox(height: 8),
        Text(
          '${choices.addresses.length} server-offered IP choices · '
          '$listed of ${configured.length} configured listener entries appear in the list',
        ),
        if (configured.isNotEmpty) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            key: const Key('iscsi-listener-choice-ratio'),
            value: listed / configured.length,
            minHeight: 8,
            borderRadius: BorderRadius.circular(4),
            semanticsLabel:
                'Configured iSCSI listener entries in current choice list',
          ),
          const SizedBox(height: 12),
          for (final listener in configured.take(20))
            Text(
              'Portal #${listener.portalId} · ${listener.ip}:${listener.port} · '
              '${choices.addresses.contains(listener.ip) ? 'Listed choice' : 'Not in current choice list'}',
            ),
          if (configured.length > 20)
            Text(
              '${configured.length - 20} more configured listener entries not shown.',
            ),
        ] else
          const Text('No portal listeners are configured.'),
        const SizedBox(height: 12),
        Text(
          sortedChoices.isEmpty
              ? 'The server offered no IP choices.'
              : 'Offered IPs: ${sortedChoices.take(30).join(', ')}'
                    '${sortedChoices.length > 30 ? ' · ${sortedChoices.length - 30} more' : ''}',
        ),
        const SizedBox(height: 8),
        const Text(
          'Choices include static addresses only. A configured address absent from this list '
          'is not proof that clients are disconnected; HA mappings and interface changes '
          'require separate verification.',
        ),
      ],
    );
  }
}
