import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/smb_settings/smb_settings_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import '../alert_settings/alert_settings_fakes.dart'
    show alertInventory, alertEndpoint;

const smbCaps = SmbSettingsCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canUpdate: true,
);
const smbDefault = SmbGlobalSettings(
  netbiosName: 'NAS',
  workgroup: 'WORKGROUP',
  description: 'Storage',
  multichannel: false,
  encryption: SmbTransportEncryption.defaultMode,
);
SmbSettingsInventory smbInventory({
  String? hostId,
  String endpoint = alertEndpoint,
  bool admin = true,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  bool? directory = false,
  bool? security = false,
  List<SmbConfiguredShare>? shares,
  bool aux = false,
  SmbGlobalSettings settings = smbDefault,
}) => SmbSettingsInventory(
  readiness: alertInventory(
    endpoint: endpoint,
    hostId:
        hostId ??
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    admin: admin,
    ha: ha,
    jobs: jobs,
    healthy: healthy,
    services: const [],
  ),
  config: SmbConfigSnapshot(
    id: 1,
    settings: settings,
    aliases: const ['ALIAS'],
    smb1Enabled: false,
    ntlmv1Enabled: false,
    appleExtensions: true,
    localMaster: false,
    syslogEnabled: false,
    debugEnabled: false,
    auxiliaryParametersPresent: aux,
    serverSidKnown: true,
    defaultGuestAccount: true,
    privilegedGroupConfigured: false,
  ),
  shares:
      shares ??
      const [
        SmbConfiguredShare(id: 1, enabled: true),
        SmbConfiguredShare(id: 2, enabled: false),
      ],
  directoryConfigured: directory,
  securityManaged: security,
  appleDependentShareCount: 0,
);
SmbSettingsRequest smbRequest(
  SmbSettingsInventory i, {
  bool rename = false,
  bool encryption = false,
  bool multichannel = false,
}) => SmbSettingsRequest(
  inventory: i,
  settings: SmbGlobalSettings(
    netbiosName: rename ? 'NEWNAS' : i.config.settings.netbiosName,
    workgroup: i.config.settings.workgroup,
    description: 'New description',
    multichannel: multichannel ? true : i.config.settings.multichannel,
    encryption: encryption
        ? SmbTransportEncryption.required
        : i.config.settings.encryption,
  ),
);

class SmbFake implements SessionRepository, AuthenticatedSmbSettingsSession {
  SmbFake({SmbSettingsInventory? inventory, this.caps = smbCaps})
    : inventory = inventory ?? smbInventory();
  SmbSettingsInventory inventory;
  SmbSettingsCapabilities caps;
  int reads = 0, mutations = 0;
  final reviews = <SmbSettingsRequest>[], executes = <SmbSettingsReview>[];
  Future<SmbSettingsInventory> Function()? onLoad;
  Future<SmbSettingsReview> Function(SmbSettingsRequest)? onReview;
  Future<SmbSettingsResult> Function(SmbSettingsReview, bool Function())?
  onExecute;
  @override
  SmbSettingsCapabilities get smbSettingsCapabilities => caps;
  @override
  Future<SmbSettingsInventory> loadSmbSettings() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<SmbSettingsReview> reviewSmbSettings(SmbSettingsRequest r) async {
    reviews.add(r);
    return onReview?.call(r) ??
        SmbSettingsReview(
          request: r,
          endpoint: inventory.endpoint,
          warnings: const [
            'Synthetic SMB impact review. No live server contact.',
          ],
        );
  }

  @override
  Future<SmbSettingsResult> executeSmbSettings(
    SmbSettingsReview r,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    executes.add(r);
    if (onExecute != null) return onExecute!(r, isCurrent);
    if (isCurrent()) mutations++;
    return const SmbSettingsResult(
      SmbSettingsOutcome.completed,
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
  }) => throw UnsupportedError('Synthetic SMB only');
}

class SmbHarness {
  SmbHarness({SmbFake? fake}) : api = fake ?? SmbFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final SmbFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = alertEndpoint}) =>
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

  Future<void> load() => container.read(smbSettingsInventoryProvider.future);
  void dispose() => container.dispose();
}
