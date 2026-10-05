import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/nfs_settings/nfs_settings_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import '../alert_settings/alert_settings_fakes.dart' show alertInventory;

const nfsEndpoint = 'wss://sample.example/api/current';
const nfsHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const nfsCaps = NfsSettingsCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canUpdate: true,
);
NfsSettingsInventory nfsInventory({
  String endpoint = nfsEndpoint,
  String hostId = nfsHost,
  bool admin = true,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  String state = 'READY',
  bool nextChanged = false,
  String serviceState = 'STOPPED',
  bool directoryConfigured = false,
  bool kerberos = false,
  bool rdma = false,
  int? threads,
  List<String>? protocols,
  List<String>? bindings,
  List<NfsConfiguredExport>? exports,
}) => NfsSettingsInventory(
  readiness: alertInventory(
    endpoint: endpoint,
    hostId: hostId,
    admin: admin,
    ha: ha,
    jobs: jobs,
    healthy: healthy,
    state: state,
    nextChanged: nextChanged,
    services: const [],
  ),
  config: NfsConfigSnapshot(
    id: 1,
    settings: NfsGlobalSettings(
      serverThreads: threads,
      protocols: protocols ?? ['NFSV3', 'NFSV4'],
      bindAddresses: bindings ?? ['192.0.2.10'],
      mountdLog: true,
      statdLockdLog: false,
    ),
    reportedServers: threads ?? 8,
    managedNfsd: threads == null,
    allowNonroot: false,
    v4Krb: kerberos,
    v4Domain: '',
    v4KrbEnabled: kerberos,
    keytabHasNfsSpn: false,
    rdma: rdma,
    userdManageGids: false,
    mountdPort: null,
    rpcstatdPort: null,
    rpclockdPort: null,
  ),
  exports:
      exports ??
      [
        NfsConfiguredExport(id: 4, enabled: false, security: ['SYS']),
      ],
  serviceState: serviceState,
  serviceEnabled: false,
  bindChoices: ['192.0.2.10', '192.0.2.11', '2001:db8::10'],
  directoryConfigured: directoryConfigured,
);
NfsSettingsRequest nfsRequest(
  NfsSettingsInventory i, {
  int? threads = 12,
  List<String>? protocols,
  List<String>? bindings,
  bool? mountdLog,
  bool? statdLockdLog,
}) => NfsSettingsRequest(
  inventory: i,
  settings: NfsGlobalSettings(
    serverThreads: threads,
    protocols: protocols ?? i.config.settings.protocols,
    bindAddresses: bindings ?? i.config.settings.bindAddresses,
    mountdLog: mountdLog ?? i.config.settings.mountdLog,
    statdLockdLog: statdLockdLog ?? i.config.settings.statdLockdLog,
  ),
);

class NfsFake implements SessionRepository, AuthenticatedNfsSettingsSession {
  NfsFake({NfsSettingsInventory? inventory, this.caps = nfsCaps})
    : inventory = inventory ?? nfsInventory();
  NfsSettingsInventory inventory;
  NfsSettingsCapabilities caps;
  int reads = 0, mutations = 0;
  final reviews = <NfsSettingsRequest>[], executes = <NfsSettingsReview>[];
  Future<NfsSettingsInventory> Function()? onLoad;
  Future<NfsSettingsReview> Function(NfsSettingsRequest)? onReview;
  Future<NfsSettingsResult> Function(NfsSettingsReview, bool Function())?
  onExecute;
  @override
  NfsSettingsCapabilities get nfsSettingsCapabilities => caps;
  @override
  Future<NfsSettingsInventory> loadNfsSettings() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<NfsSettingsReview> reviewNfsSettings(
    NfsSettingsRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        NfsSettingsReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const [
            'Synthetic supplemental details. No live NFS contact.',
          ],
        );
  }

  @override
  Future<NfsSettingsResult> executeNfsSettings(
    NfsSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    executes.add(review);
    if (onExecute != null) return onExecute!(review, isCurrent);
    if (isCurrent()) mutations++;
    return const NfsSettingsResult(
      NfsSettingsOutcome.completed,
      'Synthetic configuration verification',
    );
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnsupportedError('No connector in NFS fixtures.');
}

class NfsHarness {
  NfsHarness({NfsFake? fake}) : api = fake ?? NfsFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final NfsFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = nfsEndpoint}) =>
      AuthenticatedSession(
        profileId: 'sample',
        repository: api,
        availableMethodNames: const {},
        version: '25.10.1',
        endpoint: endpoint,
      );
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  Future<void> load() => container.read(nfsSettingsInventoryProvider.future);
  void dispose() => container.dispose();
}
