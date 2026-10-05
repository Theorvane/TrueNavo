import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';

bool _available(AuthenticatedSession? session) {
  final repository = session?.repository;
  if (session?.endpoint == null ||
      repository is! AuthenticatedAdminSession ||
      repository is! AuthenticatedNvmeHostChoicesSession) {
    return false;
  }
  final catalog = (repository as AuthenticatedAdminSession).adminCatalog;
  return catalog.versionSupported &&
      catalog.method('nvmet.host.dhchap_hash_choices')?.supported == true &&
      catalog.method('nvmet.host.dhchap_dhgroup_choices')?.supported == true;
}

final nvmeHostAuthenticationChoicesProvider = FutureProvider.autoDispose
    .family<NvmeHostAuthenticationChoices, AuthenticatedSession>((
      ref,
      session,
    ) async {
      if (!_available(session) ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        throw const NvmeHostChoicesException();
      }
      final value =
          await (session.repository as AuthenticatedNvmeHostChoicesSession)
              .loadNvmeHostAuthenticationChoices();
      if (!ref.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        throw const NvmeHostChoicesException();
      }
      return value;
    });

class NvmeHostAuthenticationChoicesPanel extends ConsumerStatefulWidget {
  const NvmeHostAuthenticationChoicesPanel({super.key});
  @override
  ConsumerState<NvmeHostAuthenticationChoicesPanel> createState() =>
      _ChoicesState();
}

class _ChoicesState extends ConsumerState<NvmeHostAuthenticationChoicesPanel> {
  Object? _session;
  bool _loaded = false;
  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    if (!identical(_session, session)) {
      _session = session;
      _loaded = false;
    }
    final available = _available(session);
    final state = _loaded && available
        ? ref.watch(nvmeHostAuthenticationChoicesProvider(session!))
        : null;
    Widget reload(String label) => OutlinedButton(
      key: const Key('nvme-auth-choices-reload'),
      onPressed: () => ref.invalidate(nvmeHostAuthenticationChoicesProvider),
      child: Text(label),
    );
    return TdPanel(
      title: 'Supported host authentication algorithms',
      description: 'On-demand public algorithm choices from this server. No host keys are queried or generated, and no settings are changed. These choices do not prove initiator compatibility or runtime authentication.',
      child: !available
          ? const Text(
              'Algorithm discovery is unavailable on this connection; supported choices are unknown.',
            )
          : state == null
          ? OutlinedButton(
              key: const Key('nvme-auth-choices-load'),
              onPressed: () => setState(() => _loaded = true),
              child: const Text('Load supported authentication algorithms'),
            )
          : state.isLoading
          ? const Center(child: CircularProgressIndicator())
          : switch (state) {
              AsyncData(:final value) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Advertised DH-CHAP hashes'),
                  if (value.hashes.isEmpty)
                    const Text('The server returned no hash choices.')
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final hash in value.hashes)
                          Chip(label: Text(hash)),
                      ],
                    ),
                  const SizedBox(height: 12),
                  const Text('Advertised Diffie-Hellman groups'),
                  if (value.groups.isEmpty)
                    const Text('The server returned no DH group choices.')
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final group in value.groups)
                          Chip(label: Text(group)),
                      ],
                    ),
                  const SizedBox(height: 12),
                  const Text(
                    'TrueNAS 25.10 also permits an unset DH group. Unset is not an advertised group and does not mean authentication is enabled or disabled. Key configuration remains unavailable in this panel.',
                  ),
                  reload('Reload supported authentication algorithms'),
                ],
              ),
              _ => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Algorithm discovery failed; supported choices are unknown. Previous choices are hidden.',
                  ),
                  reload('Retry algorithm discovery'),
                ],
              ),
            },
    );
  }
}
