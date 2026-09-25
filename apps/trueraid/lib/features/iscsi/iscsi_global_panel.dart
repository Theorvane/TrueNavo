import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_global.dart';

final iscsiGlobalProvider = FutureProvider<IscsiGlobalSummary>((ref) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null || repository is! AuthenticatedAdminSession) {
    throw StateError('Connect to a server to read iSCSI settings.');
  }
  final api = repository as AuthenticatedAdminSession;
  final configMethod = api.adminCatalog.method('iscsi.global.config');
  if (!api.adminCatalog.versionSupported ||
      configMethod == null ||
      !configMethod.supported) {
    throw StateError('Global iSCSI settings are unavailable on this server.');
  }
  final configResult = await api.invokeAdmin(
    AdminRequest(method: configMethod, arguments: const []),
  );
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider))) {
    throw StateError('The server connection changed.');
  }
  if (configResult is! AdminCompleted) {
    throw StateError('Global iSCSI settings are unavailable for this account.');
  }
  final config = IscsiGlobalConfig.parse(configResult.value);

  IscsiServiceStatus? service;
  final serviceMethod = api.adminCatalog.method('service.query');
  if (serviceMethod != null && serviceMethod.supported) {
    try {
      final result = await api.invokeAdmin(
        AdminRequest(
          method: serviceMethod,
          arguments: const [
            [
              ['service', '=', 'iscsitarget'],
            ],
            {'limit': 2},
          ],
        ),
      );
      if (result is AdminCompleted) {
        service = IscsiServiceStatus.parse(result.value);
      }
    } catch (_) {
      // The configuration remains useful when SERVICE_READ is unavailable.
    }
  }
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider))) {
    throw StateError('The server connection changed.');
  }
  return IscsiGlobalSummary(
    config: config,
    service: service,
    observedAt: DateTime.now().toUtc(),
  );
}, retry: (_, _) => null);

class IscsiGlobalPanel extends ConsumerWidget {
  const IscsiGlobalPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(iscsiGlobalProvider);
    return TdPanel(
      title: 'Global iSCSI settings',
      description: 'Saved settings and separately reported service state.',
      child: switch (state) {
        AsyncData(:final value) => _GlobalContent(value: value),
        AsyncError(:final error) => Text(
          error is StateError
              ? error.message.toString()
              : 'The server did not return a complete iSCSI configuration.',
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _GlobalContent extends StatelessWidget {
  const _GlobalContent({required this.value});
  final IscsiGlobalSummary value;

  @override
  Widget build(BuildContext context) {
    final config = value.config;
    final service = value.service;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Read ${value.observedAt.toIso8601String()} (client UTC)'),
        const SizedBox(height: 8),
        Text('Target base name: ${config.basename}'),
        Text(
          'iSNS servers: ${config.isnsServers.isEmpty ? 'None configured' : config.isnsServers.join(', ')}',
        ),
        Text('Listen port: ${config.listenPort?.toString() ?? 'Not reported'}'),
        Text(
          'Pool free-space threshold: ${config.poolAvailThreshold == null ? 'Disabled or not reported' : '${config.poolAvailThreshold}%'}',
        ),
        Text(
          'ALUA: ${config.alua ? 'Enabled' : 'Disabled'} · iSER: ${config.iser ? 'Enabled' : 'Disabled'}',
        ),
        const SizedBox(height: 8),
        Text('Service: ${service?.state ?? 'Status unavailable'}'),
        Text(
          'Start on boot: ${service == null
              ? 'Unknown'
              : service.enabledOnBoot
              ? 'Enabled'
              : 'Disabled'}',
        ),
        const Text(
          'Configured or RUNNING does not prove a client can connect.',
        ),
      ],
    );
  }
}
