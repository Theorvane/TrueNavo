import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../dashboard/dashboard_controller.dart';

/// A bounded projection of public nvmet.global.config fields. These are saved
/// preferences, not evidence of an active listener or hardware capability.
final class NvmeGlobalConfig {
  const NvmeGlobalConfig({
    required this.baseNqn,
    required this.kernel,
    required this.ana,
    required this.rdma,
    required this.transportReferrals,
  });

  final String baseNqn;
  final bool kernel;
  final bool ana;
  final bool rdma;
  final bool transportReferrals;

  factory NvmeGlobalConfig.parse(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Invalid NVMe-oF configuration');
    }
    final baseNqn = raw['basenqn'];
    final kernel = raw['kernel'];
    final ana = raw['ana'];
    final rdma = raw['rdma'];
    final referrals = raw['xport_referral'];
    if (baseNqn is! String ||
        baseNqn.length < 5 ||
        baseNqn.length > 223 ||
        !baseNqn.startsWith('nqn.') ||
        baseNqn.trim() != baseNqn ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(baseNqn) ||
        kernel is! bool ||
        ana is! bool ||
        rdma is! bool ||
        referrals is! bool) {
      throw const FormatException('Invalid NVMe-oF configuration');
    }
    return NvmeGlobalConfig(
      baseNqn: baseNqn,
      kernel: kernel,
      ana: ana,
      rdma: rdma,
      transportReferrals: referrals,
    );
  }
}

final class NvmeGlobalSummary {
  const NvmeGlobalSummary({
    required this.config,
    required this.service,
    required this.observedAt,
  });
  final NvmeGlobalConfig config;
  final NvmeServiceStatus? service;
  final DateTime observedAt;
}

final class NvmeServiceStatus {
  const NvmeServiceStatus({required this.enabledOnBoot, required this.state});
  final bool enabledOnBoot;
  final String state;

  static NvmeServiceStatus? parse(Object? raw) {
    if (raw is! List || raw.length != 1 || raw.single is! Map) return null;
    final row = raw.single as Map;
    final enabled = row['enable'];
    final state = row['state'];
    if (row['service'] != 'nvmet' ||
        enabled is! bool ||
        state is! String ||
        !RegExp(r'^[A-Z_]{3,30}$').hasMatch(state)) {
      return null;
    }
    return NvmeServiceStatus(enabledOnBoot: enabled, state: state);
  }
}

final nvmeGlobalProvider = FutureProvider.autoDispose<NvmeGlobalSummary>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null || repository is! AuthenticatedAdminSession) {
    throw StateError('Connect to a server to read NVMe-oF settings.');
  }
  final api = repository as AuthenticatedAdminSession;
  final method = api.adminCatalog.method('nvmet.global.config');
  if (!api.adminCatalog.versionSupported ||
      method == null ||
      !method.supported) {
    throw StateError('Global NVMe-oF settings are unavailable on this server.');
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
      'Global NVMe-oF settings are unavailable for this account.',
    );
  }
  final config = NvmeGlobalConfig.parse(result.value);
  NvmeServiceStatus? service;
  final serviceMethod = api.adminCatalog.method('service.query');
  if (serviceMethod != null && serviceMethod.supported) {
    try {
      final serviceResult = await api.invokeAdmin(
        AdminRequest(
          method: serviceMethod,
          arguments: [
            [
              ['service', '=', 'nvmet'],
            ],
            {
              'select': ['service', 'enable', 'state'],
              'limit': 2,
            },
          ],
        ),
      );
      if (serviceResult is AdminCompleted) {
        service = NvmeServiceStatus.parse(serviceResult.value);
      }
    } catch (_) {
      // Saved settings remain useful when SERVICE_READ is unavailable.
    }
  }
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider))) {
    throw StateError('The server connection changed.');
  }
  return NvmeGlobalSummary(
    config: config,
    service: service,
    observedAt: DateTime.now().toUtc(),
  );
}, retry: (_, _) => null);

class NvmeGlobalPanel extends ConsumerWidget {
  const NvmeGlobalPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(nvmeGlobalProvider);
    return TdPanel(
      title: 'Global NVMe-oF settings',
      description: 'Saved target settings; read-only and independent of the topology inventory.',
      child: switch (state) {
        AsyncData(:final value) => _GlobalContent(value: value),
        AsyncError(:final error) => Text(
          error is StateError
              ? error.message.toString()
              : 'The server did not return a complete NVMe-oF configuration.',
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _GlobalContent extends StatelessWidget {
  const _GlobalContent({required this.value});
  final NvmeGlobalSummary value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Read ${value.observedAt.toIso8601String()} (client UTC)'),
      const SizedBox(height: 8),
      Text('Base NQN: ${value.config.baseNqn}'),
      Text(
        'Kernel backend: ${value.config.kernel ? 'Selected' : 'Not selected'}',
      ),
      Text('ANA: ${value.config.ana ? 'Configured on' : 'Configured off'}'),
      Text('RDMA: ${value.config.rdma ? 'Configured on' : 'Configured off'}'),
      Text(
        'Transport referrals: ${value.config.transportReferrals ? 'Configured on' : 'Configured off'}',
      ),
      const SizedBox(height: 8),
      Text('Service: ${value.service?.state ?? 'Status unavailable'}'),
      Text(
        'Start on boot: ${value.service == null
            ? 'Unknown'
            : value.service!.enabledOnBoot
            ? 'Enabled'
            : 'Disabled'}',
      ),
      const Text(
        'Saved settings and reported service state are separate reads. Neither proves that a listener is reachable, RDMA hardware is available, or a client can connect.',
      ),
    ],
  );
}
