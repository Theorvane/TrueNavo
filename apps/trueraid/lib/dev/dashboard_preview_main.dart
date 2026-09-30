import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../app_shell/adaptive_shell.dart';
import '../features/search/global_search.dart';
import '../features/rsync/rsync_page.dart';
import 'rsync_preview.dart';
import '../features/system_power/system_power_page.dart';
import 'system_power_preview.dart';
import '../features/configuration_backup/configuration_backup_page.dart';
import 'configuration_backup_preview.dart';
import '../features/configuration_backup/configuration_backup_file.dart';
import '../features/configuration_restore/configuration_restore_page.dart';
import '../features/configuration_restore/configuration_restore_file.dart';
import 'configuration_restore_preview.dart';
import '../features/configuration_reset/configuration_reset_page.dart';
import 'configuration_reset_preview.dart';
import '../features/time_settings/time_settings_page.dart';
import 'time_settings_preview.dart';
import '../features/email_settings/email_settings_page.dart';
import 'email_settings_preview.dart';
import '../features/alert_settings/alert_settings_page.dart';
import 'alert_settings_preview.dart';
import '../features/alert_policies/alert_policies_page.dart';
import 'alert_policies_preview.dart';
import '../features/notification_providers/notification_providers_page.dart';
import 'notification_providers_preview.dart';
import '../features/smb_settings/smb_settings_page.dart';
import '../features/nfs_settings/nfs_settings_page.dart';
import 'smb_settings_preview.dart';
import 'nfs_settings_preview.dart';
import 'cron_tasks_preview.dart';
import 'init_shutdown_tasks_preview.dart';
import '../features/cron_tasks/cron_tasks_page.dart';
import '../features/init_shutdown_tasks/init_shutdown_tasks_page.dart';
import '../features/admin/admin_workspace.dart';
import '../features/activity/activity_page.dart';
import 'activity_preview.dart';
import 'virtual_machines_preview.dart';
import 'accounts_preview.dart';
import 'zvols_preview.dart';
import 'permissions_preview.dart';
import 'quotas_preview.dart';
import 'snapshot_schedules_preview.dart';
import 'smb_shares_preview.dart';
import 'nfs_shares_preview.dart';
import 'system_updates_preview.dart';
import 'cloud_sync_preview.dart';
import 'replication_preview.dart';
import 'api_keys_preview.dart';
import 'cloud_credentials_preview.dart';
import 'ssh_credentials_preview.dart';
import 'alerts_preview.dart';
import 'disks_preview.dart';
import 'pool_maintenance_preview.dart';
import '../features/disks/disks_page.dart';
import '../features/pool_maintenance/pool_maintenance_page.dart';
import '../features/shares/shares_page.dart';
import '../features/ssh_credentials/ssh_credentials_page.dart';
import '../features/alerts/alerts_page.dart';
import '../features/api_keys/api_keys_page.dart';
import '../features/cloud_credentials/cloud_credentials_page.dart';
import '../features/replication/replication_page.dart';
import '../features/data_protection/data_protection_page.dart';
import '../features/cloud_sync/cloud_sync_page.dart';
import '../features/system_updates/system_updates_page.dart';
import 'boot_environments_preview.dart';
import '../features/zvols/zvols_page.dart';
import '../features/permissions/permissions_page.dart';
import '../features/quotas/quotas_page.dart';
import '../features/snapshot_schedules/snapshot_schedules_page.dart';
import '../features/smb_shares/smb_shares_page.dart';
import '../features/nfs_shares/nfs_shares_page.dart';
import '../features/boot_environments/boot_environments_page.dart';
import '../features/accounts/accounts_page.dart';
import '../features/virtual_machines/virtual_machines_page.dart';
import '../features/apps/apps_page.dart';
import '../features/apps/app_config_page.dart';
import '../features/connection/connection_controller.dart';
import '../features/dashboard/dashboard_controller.dart';
import '../features/dashboard/dashboard_layout_controller.dart';
import '../features/dashboard/dashboard_layout_store.dart';
import '../features/datasets/dataset_properties_page.dart';
import '../features/management/management_page.dart';
import '../features/network/network_page.dart';
import '../features/reporting/reporting_page.dart';
import '../features/server_profiles/server_profile.dart';
import '../features/server_profiles/server_profile_store.dart';
import '../features/server_profiles/server_profiles_controller.dart';
import '../features/snapshots/snapshots_page.dart';
import '../features/tls_trust/tls_trust_providers.dart';

/// Development-only visual preview. No bootstrap, database, credentials or NAS.
/// flutter run -t lib/dev/dashboard_preview_main.dart
/// Add --dart-define=PREVIEW_MANAGE=true for the service control center, or
/// --dart-define=PREVIEW_STORAGE=true for the storage management tab.
/// Use --dart-define=PREVIEW_ADMIN=true for the administration directory.
/// PREVIEW_NETWORK / PREVIEW_REPORTING select their isolated sample screens.
/// PREVIEW_APPS / PREVIEW_SNAPSHOTS select the isolated native workspaces.
void main() {
  if (kReleaseMode) throw StateError('Sample preview is not a release app.');
  runApp(const DashboardPreviewApp());
}

const _profile = ServerProfile(
  id: 'preview-only',
  displayName: 'Atlas · Sample server',
  originalHostInput: 'nas-demo.example',
  normalizedEndpoint: 'wss://nas-demo.example/api/current',
  lastKnownVersion: '25.10.1',
);

const _methods = <String>{
  'system.info',
  'pool.query',
  'pool.dataset.query',
  'service.query',
  'alert.list',
  'core.get_jobs',
  'service.control',
  'pool.dataset.create',
  'pool.dataset.delete',
  'pool.dataset.attachments',
  'pool.snapshot.create',
  'pool.snapshot.query',
  'pool.snapshot.delete',
  'app.query',
  'catalog.apps',
  'catalog.get_app_details',
  'docker.status',
  'docker.config',
  'app.used_ports',
  'app.create',
  'app.start',
  'app.stop',
  'app.redeploy',
  'app.delete',
  'app.upgrade',
  'app.upgrade_summary',
  'app.config',
  'app.update',
};

/// Separate entrypoint only: production main never imports the sample adapter.
class DashboardPreviewApp extends StatelessWidget {
  const DashboardPreviewApp({
    super.key,
    this.initialManagement = false,
    this.initialStorage = false,
    this.initialNetwork = false,
    this.initialReporting = false,
    this.initialDatasets = false,
    this.initialApps = false,
    this.initialSnapshots = false,
    this.initialAppSettings = false,
    this.initialActivity = false,
    this.initialAudit = false,
    this.initialVirtualMachines = false,
    this.initialAccounts = false,
    this.initialZvols = false,
    this.initialPermissions = false,
    this.initialBootEnvironments = false,
    this.initialQuotas = false,
    this.initialSnapshotSchedules = false,
    this.initialSmbShares = false,
    this.initialNfsShares = false,
    this.initialSystemUpdates = false,
    this.initialCloudSync = false,
    this.initialReplication = false,
    this.initialDataProtection = false,
    this.initialApiKeys = false,
    this.initialCloudCredentials = false,
    this.initialSshCredentials = false,
    this.initialAlerts = false,
    this.initialSharesOverview = false,
    this.initialDisks = false,
    this.initialPoolMaintenance = false,
    this.initialRsync = false,
    this.initialSystemPower = false,
    this.initialConfigurationBackup = false,
    this.initialConfigurationRestore = false,
    this.initialConfigurationReset = false,
    this.initialTimeSettings = false,
    this.initialEmailSettings = false,
    this.initialAlertSettings = false,
    this.initialAlertPolicies = false,
    this.initialNotificationProviders = false,
    this.initialSmbSettings = false,
    this.initialNfsSettings = false,
    this.initialCronTasks = false,
    this.initialInitShutdownTasks = false,
  });

  final bool initialManagement;
  final bool initialStorage;
  final bool initialNetwork;
  final bool initialReporting;
  final bool initialDatasets;
  final bool initialApps;
  final bool initialSnapshots;
  final bool initialAppSettings;
  final bool initialActivity;
  final bool initialAudit;
  final bool initialVirtualMachines;
  final bool initialAccounts;
  final bool initialZvols, initialPermissions, initialBootEnvironments;
  final bool initialQuotas, initialSnapshotSchedules;
  final bool initialSmbShares, initialNfsShares;
  final bool initialSystemUpdates;
  final bool initialCloudSync;
  final bool initialReplication;
  final bool initialDataProtection;
  final bool initialApiKeys, initialCloudCredentials;
  final bool initialSshCredentials, initialAlerts, initialSharesOverview;
  final bool initialDisks, initialPoolMaintenance;
  final bool initialRsync;
  final bool initialSystemPower;
  final bool initialConfigurationBackup;
  final bool initialConfigurationRestore;
  final bool initialConfigurationReset;
  final bool initialTimeSettings;
  final bool initialEmailSettings;
  final bool initialAlertSettings;
  final bool initialAlertPolicies;
  final bool initialNotificationProviders;
  final bool initialSmbSettings;
  final bool initialNfsSettings;
  final bool initialCronTasks;
  final bool initialInitShutdownTasks;

  @override
  Widget build(BuildContext context) {
    if (kReleaseMode) throw StateError('Sample preview is not a release app.');
    const repository = _PreviewRepository();
    const session = AuthenticatedSession(
      profileId: 'preview-only',
      repository: repository,
      availableMethodNames: _methods,
      version: '25.10.1',
      endpoint: 'wss://nas-demo.example/api/current',
    );
    final storage =
        initialStorage || const bool.fromEnvironment('PREVIEW_STORAGE');
    final management =
        initialManagement ||
        storage ||
        const bool.fromEnvironment('PREVIEW_MANAGE');
    return ProviderScope(
      overrides: [
        configurationRestoreFilePickerProvider.overrideWithValue(
          const ConfigurationRestorePreviewFilePicker(),
        ),
        configurationBackupFileSaverProvider.overrideWithValue(
          const ConfigurationBackupPreviewFileSaver(),
        ),
        dashboardLayoutStoreProvider.overrideWithValue(
          MemoryDashboardLayoutStore(),
        ),
        initialServerProfileSnapshotProvider.overrideWithValue(
          ServerProfileSnapshot(
            profiles: const [_profile],
            selectedProfileId: _profile.id,
          ),
        ),
        dashboardActiveSessionProvider.overrideWith((ref) {
          final selected = ref
              .watch(serverProfilesControllerProvider)
              .selectedProfileId;
          return selected == _profile.id ? session : null;
        }),
        credentialVaultProvider.overrideWithValue(const NoopCredentialVault()),
        rpcConnectorProvider.overrideWithValue(const _PreviewConnector()),
        tlsTrustRouteProvider.overrideWithValue(
          TlsTrustRoute.platformValidated,
        ),
        sessionRepositoryFactoryProvider.overrideWithValue(
          ({required connector, required credentialVault}) => repository,
        ),
      ],
      child: GlobalSearchHost(
        builder: (navigatorKey, observer) => MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [observer],
          title: 'TrueRAID · Sample preview',
          debugShowCheckedModeBanner: false,
          theme: TrueRAIDTheme.dark(),
          builder: (context, child) => Material(
            color: context.tdTheme.canvas,
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  Container(
                    key: const Key('preview-banner'),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    color: context.tdTheme.statusWarning,
                    child: Text(
                      'PREVIEW · SAMPLE DATA · NO SERVER',
                      textAlign: TextAlign.center,
                      style: TdTypography.micro.copyWith(
                        color: Colors.black,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .7,
                      ),
                    ),
                  ),
                  Expanded(child: child!),
                ],
              ),
            ),
          ),
          home:
              initialCronTasks ||
                  const bool.fromEnvironment('PREVIEW_CRON_TASKS')
              ? const CronTasksPage()
              : initialInitShutdownTasks ||
                    const bool.fromEnvironment('PREVIEW_INIT_SHUTDOWN_TASKS')
              ? const InitShutdownTasksPage()
              : initialSmbSettings ||
                    const bool.fromEnvironment('PREVIEW_SMB_SETTINGS')
              ? const SmbSettingsPage()
              : initialNfsSettings ||
                    const bool.fromEnvironment('PREVIEW_NFS_SETTINGS')
              ? const NfsSettingsPage()
              : initialAlertPolicies ||
                    const bool.fromEnvironment('PREVIEW_ALERT_POLICIES')
              ? const AlertPoliciesPage()
              : initialNotificationProviders ||
                    const bool.fromEnvironment('PREVIEW_NOTIFICATION_PROVIDERS')
              ? const NotificationProvidersPage()
              : initialAlertSettings ||
                    const bool.fromEnvironment('PREVIEW_ALERT_SETTINGS')
              ? const AlertSettingsPage()
              : initialEmailSettings ||
                    const bool.fromEnvironment('PREVIEW_EMAIL_SETTINGS')
              ? const EmailSettingsPage()
              : initialTimeSettings ||
                    const bool.fromEnvironment('PREVIEW_TIME_SETTINGS')
              ? const TimeSettingsPage()
              : initialConfigurationReset ||
                    const bool.fromEnvironment('PREVIEW_CONFIGURATION_RESET')
              ? const ConfigurationResetPage()
              : initialConfigurationRestore ||
                    const bool.fromEnvironment('PREVIEW_CONFIGURATION_RESTORE')
              ? const ConfigurationRestorePage()
              : initialConfigurationBackup ||
                    const bool.fromEnvironment('PREVIEW_CONFIGURATION_BACKUP')
              ? const ConfigurationBackupPage()
              : initialSystemPower ||
                    const bool.fromEnvironment('PREVIEW_SYSTEM_POWER')
              ? const SystemPowerPage()
              : initialRsync || const bool.fromEnvironment('PREVIEW_RSYNC')
              ? const RsyncPage()
              : initialDisks || const bool.fromEnvironment('PREVIEW_DISKS')
              ? const DisksPage()
              : initialPoolMaintenance ||
                    const bool.fromEnvironment('PREVIEW_POOL_MAINTENANCE')
              ? const PoolMaintenancePage()
              : initialSshCredentials ||
                    const bool.fromEnvironment('PREVIEW_SSH_CREDENTIALS')
              ? const SshCredentialsPage()
              : initialAlerts || const bool.fromEnvironment('PREVIEW_ALERTS')
              ? const AlertsPage()
              : initialSharesOverview ||
                    const bool.fromEnvironment('PREVIEW_SHARES_OVERVIEW')
              ? const SharesPage()
              : initialApiKeys || const bool.fromEnvironment('PREVIEW_API_KEYS')
              ? const ApiKeysPage()
              : initialCloudCredentials ||
                    const bool.fromEnvironment('PREVIEW_CLOUD_CREDENTIALS')
              ? const CloudCredentialsPage()
              : initialDataProtection ||
                    const bool.fromEnvironment('PREVIEW_DATA_PROTECTION')
              ? const DataProtectionPage()
              : initialReplication ||
                    const bool.fromEnvironment('PREVIEW_REPLICATION')
              ? const ReplicationPage()
              : initialCloudSync ||
                    const bool.fromEnvironment('PREVIEW_CLOUD_SYNC')
              ? const CloudSyncPage()
              : initialSystemUpdates ||
                    const bool.fromEnvironment('PREVIEW_SYSTEM_UPDATES')
              ? const SystemUpdatesPage()
              : initialSmbShares ||
                    const bool.fromEnvironment('PREVIEW_SMB_SHARES')
              ? const SmbSharesPage()
              : initialNfsShares ||
                    const bool.fromEnvironment('PREVIEW_NFS_SHARES')
              ? const NfsSharesPage()
              : initialQuotas || const bool.fromEnvironment('PREVIEW_QUOTAS')
              ? const QuotasPage()
              : initialSnapshotSchedules ||
                    const bool.fromEnvironment('PREVIEW_SNAPSHOT_SCHEDULES')
              ? const SnapshotSchedulesPage()
              : initialZvols || const bool.fromEnvironment('PREVIEW_ZVOLS')
              ? const ZvolsPage()
              : initialPermissions ||
                    const bool.fromEnvironment('PREVIEW_PERMISSIONS')
              ? const PermissionsPage()
              : initialBootEnvironments ||
                    const bool.fromEnvironment('PREVIEW_BOOT_ENVIRONMENTS')
              ? const BootEnvironmentsPage()
              : initialAccounts ||
                    const bool.fromEnvironment('PREVIEW_ACCOUNTS')
              ? const AccountsPage()
              : initialVirtualMachines ||
                    const bool.fromEnvironment('PREVIEW_VIRTUAL_MACHINES')
              ? const VirtualMachinesPage()
              : initialActivity ||
                    initialAudit ||
                    const bool.fromEnvironment('PREVIEW_ACTIVITY') ||
                    const bool.fromEnvironment('PREVIEW_AUDIT')
              ? ActivityPage(
                  initialAudit:
                      initialAudit ||
                      const bool.fromEnvironment('PREVIEW_AUDIT'),
                )
              : initialAppSettings ||
                    const bool.fromEnvironment('PREVIEW_APP_SETTINGS')
              ? AppConfigPage(session: session, app: _previewInstalledApps[0])
              : initialApps || const bool.fromEnvironment('PREVIEW_APPS')
              ? const AppsPage()
              : initialSnapshots ||
                    const bool.fromEnvironment('PREVIEW_SNAPSHOTS')
              ? const SnapshotsPage()
              : initialDatasets ||
                    const bool.fromEnvironment('PREVIEW_DATASETS')
              ? const DatasetPropertiesPage()
              : initialReporting ||
                    const bool.fromEnvironment('PREVIEW_REPORTING')
              ? const ReportingPage()
              : initialNetwork || const bool.fromEnvironment('PREVIEW_NETWORK')
              ? const NetworkPage()
              : const bool.fromEnvironment('PREVIEW_ADMIN')
              ? const AdminWorkspace()
              : management
              ? ManagementPage(initialStorage: storage)
              : const AdaptiveShell(),
        ),
      ),
    );
  }
}

final _previewNetwork = NetworkInventory(
  interfaces: [
    NetworkInterfaceSnapshot(
      id: 'enp1s0',
      name: 'enp1s0',
      type: 'PHYSICAL',
      description: 'Management · 1 GbE',
      dhcp: false,
      ipv6Auto: false,
      mtu: 1500,
      aliases: const [NetworkAddress(address: '192.168.10.20', netmask: 24)],
    ),
    NetworkInterfaceSnapshot(
      id: 'enp2s0',
      name: 'enp2s0',
      type: 'PHYSICAL',
      description: 'Storage uplink · 10 GbE',
      dhcp: false,
      ipv6Auto: false,
      mtu: 9000,
      aliases: const [NetworkAddress(address: '10.20.0.10', netmask: 24)],
    ),
    NetworkInterfaceSnapshot(
      id: 'br0',
      name: 'br0',
      type: 'BRIDGE',
      description: 'Virtual machine bridge',
      dhcp: false,
      ipv6Auto: false,
      mtu: 1500,
      aliases: const [],
      blockedReason: 'Bridge membership needs the topology-aware editor.',
    ),
  ],
  failoverLicensed: false,
  hasPendingChanges: false,
  checkinWaitingSeconds: null,
);

final _previewGraphs = List<ReportingGraph>.unmodifiable([
  ReportingGraph(
    name: 'cpu',
    title: 'CPU usage',
    verticalLabel: '%CPU',
    identifiers: null,
  ),
  ReportingGraph(
    name: 'memory',
    title: 'Available memory',
    verticalLabel: 'Bytes',
    identifiers: null,
  ),
  ReportingGraph(
    name: 'interface',
    title: 'Network traffic',
    verticalLabel: 'Kilobits/s',
    identifiers: ['enp1s0', 'enp2s0'],
  ),
  ReportingGraph(
    name: 'disk',
    title: 'Disk throughput',
    verticalLabel: 'Kibibytes/s',
    identifiers: ['sda | Model: SAMPLE | Serial: PREVIEW-01'],
  ),
]);

final class _PreviewRealtimeFeed implements RealtimeFeed {
  _PreviewRealtimeFeed() {
    _controller = StreamController<RealtimeSample>(
      onListen: () {
        final end = DateTime.now().toUtc();
        for (var index = 0; index < 60; index++) {
          final usage = 20.0 + (index * 7 % 39);
          _controller.add(
            RealtimeSample(
              receivedAt: end.subtract(Duration(seconds: (59 - index) * 2)),
              cpu: {
                'cpu': RealtimeCpu(usage: usage, temperature: 43 + index % 7),
                'cpu0': RealtimeCpu(usage: usage - 4, temperature: 43),
                'cpu1': RealtimeCpu(usage: usage + 4, temperature: 44),
              },
              interfaces: {
                'enp1s0': RealtimeInterface(
                  linkUp: true,
                  speedMbps: 1000,
                  receivedBytesPerSecond: 12000000 + index * 70000,
                  sentBytesPerSecond: 7000000 + index * 90000,
                ),
                'enp2s0': const RealtimeInterface(
                  linkUp: true,
                  speedMbps: 10000,
                  receivedBytesPerSecond: 210000000,
                  sentBytesPerSecond: 83000000,
                ),
              },
              memoryTotalBytes: 68719476736,
              memoryAvailableBytes: 39728447488,
              arcSizeBytes: 21474836480,
              diskReadBytesPerSecond: 342000000 + index * 30000,
              diskWriteBytesPerSecond: 126000000 + index * 10000,
              diskReadOpsPerSecond: 620,
              diskWriteOpsPerSecond: 350,
              diskBusyPercent: 28,
              arcDataHitPercent: 98.6,
              arcMetadataHitPercent: 99.2,
            ),
          );
        }
      },
    );
  }
  late final StreamController<RealtimeSample> _controller;
  @override
  Stream<RealtimeSample> get samples => _controller.stream;
  @override
  Future<void> close() async {
    await _controller.close();
  }
}

DatasetPropertySnapshot _previewDataset(String id, {bool root = false}) =>
    DatasetPropertySnapshot(
      id: id,
      guid: root ? '100000001' : '100000002',
      usedBytes: 2147483648,
      referencedBytes: 1073741824,
      availableBytes: 1099511627776,
      parentAvailableBytes: 1099511627776,
      properties: const {
        'quota': DatasetPropertyValue(value: 0, source: 'DEFAULT'),
        'refquota': DatasetPropertyValue(value: 0, source: 'DEFAULT'),
        'reservation': DatasetPropertyValue(value: 0, source: 'DEFAULT'),
        'refreservation': DatasetPropertyValue(value: 0, source: 'DEFAULT'),
        'compression': DatasetPropertyValue(value: 'LZ4', source: 'LOCAL'),
        'atime': DatasetPropertyValue(
          value: 'OFF',
          source: 'INHERITED',
          sourceDataset: 'tank',
        ),
        'readonly': DatasetPropertyValue(value: 'OFF', source: 'DEFAULT'),
      },
      parentProperties: const {
        'compression': DatasetPropertyValue(value: 'LZ4', source: 'LOCAL'),
        'atime': DatasetPropertyValue(value: 'OFF', source: 'LOCAL'),
        'readonly': DatasetPropertyValue(value: 'OFF', source: 'DEFAULT'),
      },
      descendants: root ? ['tank/media'] : [],
      descendantCount: root ? 1 : 0,
      blockedReason: root
          ? 'Pool roots require the dedicated topology workflow.'
          : null,
    );

final class _PreviewConnector implements RpcConnector {
  const _PreviewConnector();
  @override
  Future<RpcTransport> connect(Uri endpoint) async =>
      throw UnsupportedError('Network is disabled in the sample preview.');
}

// Every value below is synthetic and local to this preview entrypoint.
const _previewInstalledApps = [
  InstalledApp(
    id: 'sample-media',
    name: 'sample-media',
    state: 'RUNNING',
    version: '1.0.0',
    catalogApp: 'sample-media',
    train: 'stable',
    customApp: false,
    upgradeAvailable: true,
  ),
  InstalledApp(
    id: 'sample-photos',
    name: 'sample-photos',
    state: 'STOPPED',
    version: '1.1.0',
    catalogApp: 'sample-photos',
    train: 'community',
    customApp: false,
  ),
  InstalledApp(
    id: 'sample-metrics',
    name: 'sample-metrics',
    state: 'RUNNING',
    version: '1.1.0',
    catalogApp: 'sample-metrics',
    train: 'stable',
    customApp: false,
  ),
];

final _previewAppsCatalog = List<CatalogApp>.unmodifiable([
  CatalogApp(
    name: 'sample-media',
    train: 'stable',
    title: 'Sample Media Library',
    description: 'Synthetic preview application for browsing a personal media library. No application will be installed.',
    versions: ['1.1.0', '1.0.0'],
    healthy: true,
    supported: true,
  ),
  CatalogApp(
    name: 'sample-photos',
    train: 'community',
    title: 'Sample Photo Gallery',
    description:
        'Synthetic preview of a photo gallery with a bounded settings form.',
    versions: ['1.1.0', '1.0.0'],
    healthy: true,
    supported: true,
  ),
  CatalogApp(
    name: 'sample-metrics',
    train: 'stable',
    title: 'Sample Metrics Board',
    description: 'Synthetic preview of an application that organizes operational measurements.',
    versions: ['1.1.0', '1.0.0'],
    healthy: true,
    supported: true,
  ),
  CatalogApp(
    name: 'sample-unavailable',
    train: 'community',
    title: 'Sample Unavailable App',
    description: 'Synthetic example of an unsupported catalog entry. Installation is disabled.',
    healthy: false,
    supported: false,
  ),
]);

const _previewAppQuestions = <Map<String, Object?>>[
  {
    'variable': 'display_name',
    'label': 'Display name',
    'description': 'A label for this synthetic preview application.',
    'schema': {
      'type': 'string',
      'required': true,
      'default': 'Sample application',
      'min_length': 1,
      'max_length': 80,
    },
  },
  {
    'variable': 'network',
    'label': 'Network settings',
    'schema': {
      'type': 'dict',
      'attrs': [
        {
          'variable': 'web_port',
          'label': 'Web port',
          'schema': {
            'type': 'int',
            'required': true,
            'default': 30800,
            'min': 1024,
            'max': 65535,
            r'$ref': ['definitions/port'],
          },
        },
        {
          'variable': 'public_access',
          'label': 'Allow public access',
          'schema': {'type': 'boolean', 'default': false},
        },
      ],
    },
  },
  {
    'variable': 'storage',
    'label': 'Storage settings',
    'schema': {
      'type': 'dict',
      'attrs': [
        {
          'variable': 'media_path',
          'label': 'Sample media directory',
          'description':
              'Sample path only. No filesystem is accessed by this preview.',
          'schema': {
            'type': 'hostpath',
            'required': true,
            'default': '/mnt/tank/media',
          },
        },
        {
          'variable': 'read_only',
          'label': 'Read-only media access',
          'schema': {'type': 'boolean', 'default': true},
        },
      ],
    },
  },
];
final _previewAppForm = AppFormSchema.fromQuestions(_previewAppQuestions);

const _previewSnapshotDatasets = [
  SnapshotDataset(
    id: 'tank/media',
    guid: '900000000000000001',
    creationSeconds: 1700000000,
  ),
  SnapshotDataset(
    id: 'archive/backups',
    guid: '900000000000000002',
    creationSeconds: 1700000001,
  ),
  SnapshotDataset(
    id: 'flash/projects',
    guid: '900000000000000003',
    creationSeconds: 1700000002,
  ),
];

final _previewSnapshotEntries = List<SnapshotEntry>.unmodifiable([
  for (var index = 0; index < _previewSnapshotDatasets.length; index++)
    for (var variant = 0; variant < 4; variant++)
      SnapshotEntry(
        id: '${_previewSnapshotDatasets[index].id}@sample-${['manual', 'held', 'clone-base', 'deferred'][variant]}-2026-09-12',
        dataset: _previewSnapshotDatasets[index].id,
        name:
            'sample-${['manual', 'held', 'clone-base', 'deferred'][variant]}-2026-09-12',
        guid: '90000000000000${index + 1}${variant + 1}',
        creationSeconds:
            DateTime.utc(2026, 9, 12, variant).millisecondsSinceEpoch ~/ 1000,
        creationTxg: '${700000 + index * 10 + variant}',
        usedBytes: 1048576 * (24 + variant * 8),
        referencedBytes: 1073741824 * (16 + index * 8),
        holds: variant == 1 ? {'truenas': 1789171200} : {},
        userReferences: variant == 1 ? 1 : 0,
        clones: variant == 2
            ? ['${_previewSnapshotDatasets[index].id}-sample-clone']
            : [],
        deferredDestroy: variant == 3,
        blockedReason: switch (variant) {
          1 => 'This sample snapshot has a hold and cannot be deleted here.',
          2 => 'This sample snapshot has a dependent clone and cannot be deleted here.',
          3 =>
            'This sample snapshot is already marked for deferred destruction.',
          _ => null,
        },
      ),
]);

final class _PreviewRepository
    with
        ActivityPreviewAdapter,
        VirtualMachinesPreviewAdapter,
        AccountsPreviewAdapter,
        ZvolsPreviewAdapter,
        PermissionsPreviewAdapter,
        BootEnvironmentsPreviewAdapter,
        QuotasPreviewAdapter,
        SmbSharesPreviewAdapter,
        NfsSharesPreviewAdapter,
        SystemUpdatesPreviewAdapter,
        CloudSyncPreviewAdapter,
        ReplicationPreviewAdapter,
        ApiKeysPreviewAdapter,
        CloudCredentialsPreviewAdapter,
        SshCredentialsPreviewAdapter,
        AlertsPreviewAdapter,
        DisksPreviewAdapter,
        PoolMaintenancePreviewAdapter,
        RsyncPreviewAdapter,
        SystemPowerPreviewAdapter,
        ConfigurationBackupPreviewAdapter,
        ConfigurationRestorePreviewAdapter,
        ConfigurationResetPreviewAdapter,
        TimeSettingsPreviewAdapter,
        EmailSettingsPreviewAdapter,
        AlertSettingsPreviewAdapter,
        AlertPoliciesPreviewAdapter,
        NotificationProvidersPreviewAdapter,
        SmbSettingsPreviewAdapter,
        NfsSettingsPreviewAdapter,
        CronTasksPreviewAdapter,
        InitShutdownTasksPreviewAdapter,
        SnapshotSchedulesPreviewAdapter
    implements
        SessionRepository,
        AuthenticatedSessionQueries,
        AuthenticatedSessionManagement,
        AuthenticatedAdminSession,
        AuthenticatedNetworkSession,
        AuthenticatedReportingSession,
        AuthenticatedRealtimeSession,
        AuthenticatedDatasetPropertiesSession,
        AuthenticatedAppsSession,
        AuthenticatedSnapshotsSession {
  const _PreviewRepository();

  @override
  Future<SnapshotRecoveryReview> reviewSnapshotRecovery(
    SnapshotRecoveryPlan plan,
  ) async =>
      throw const SnapshotsException(SnapshotsExceptionReason.unavailable);
  @override
  Future<SnapshotOperationResult> applySnapshotRecovery(
    SnapshotRecoveryRequest request,
  ) async => const SnapshotOperationResult(
    outcome: SnapshotOperationOutcome.rejected,
    message: 'Sample preview never sends changes.',
  );

  @override
  AppsCapabilities get appsCapabilities => const AppsCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
  );
  @override
  Future<AppsInventory> loadAppsInventory() async => AppsInventory(
    apps: _previewInstalledApps,
    pool: 'tank',
    dockerStatus: 'RUNNING',
  );
  @override
  Future<InstalledAppDetails> loadInstalledAppDetails(InstalledApp app) async =>
      InstalledAppDetails(
        app: app,
        notes: 'Synthetic preview application. No server was contacted.',
        portals: const {},
        workloads: const InstalledAppWorkloads(
          runningContainers: 1,
          portMappings: 1,
          volumes: 1,
          images: 1,
        ),
      );
  @override
  Future<List<String>> loadOutdatedAppImages(InstalledApp app) async => const [
    'example/media:latest',
  ];
  @override
  Future<List<CatalogApp>> loadAppsCatalog({bool cachedOnly = false}) async =>
      _previewAppsCatalog;
  @override
  Future<List<String>> loadAppVersions(CatalogApp app) async => app.versions;
  @override
  Future<AppVersionDetails> loadAppVersionDetails(
    CatalogApp app,
    String version,
  ) async => AppVersionDetails(
    app: app,
    version: version,
    humanVersion: '$version · sample release',
    formSchema: _previewAppForm,
    warnings: [
      'Synthetic preview settings. Every submission is rejected; no app or filesystem is changed.',
    ],
  );
  @override
  Future<AppUpgradeReview> loadAppUpgradeReview(
    InstalledApp app,
    AppVersionDetails details,
  ) async => AppUpgradeReview(
    app: app,
    details: details,
    humanVersion: details.humanVersion,
    changelog: 'SAMPLE RELEASE NOTES\nSynthetic interface improvements and a sample migration description. This preview cannot upgrade applications.',
  );
  @override
  Future<AppOperationResult> installApp(AppInstallRequest request) async =>
      const AppOperationResult(outcome: AppOperationOutcome.rejected);

  @override
  Future<AppConfigReview> loadAppConfigReview(InstalledApp app) async =>
      AppConfigReview(
        app: app,
        schema: AppConfigSchema.fromVersionDetails(
          {
            'schema': {
              'questions': [
                ..._previewAppQuestions,
                {
                  'variable': 'password',
                  'label': 'Application password',
                  'schema': {'type': 'string', 'private': true},
                },
              ],
            },
          },
          currentValues: {
            'display_name': 'Family media library',
            'network': {'web_port': 30900, 'public_access': false},
            'storage': {
              'media_path': '/mnt/tank/family-media',
              'read_only': true,
            },
            'password': 'synthetic-preview-protected-value',
          },
        ),
        warnings: const [
          'Sample settings only. Every update is rejected and no server is contacted.',
        ],
      );

  @override
  Future<AppOperationResult> updateApp(AppConfigUpdateRequest request) async =>
      const AppOperationResult(outcome: AppOperationOutcome.rejected);
  @override
  Future<AppOperationResult> changeAppState(
    InstalledApp app,
    AppLifecycleAction action,
  ) async => const AppOperationResult(outcome: AppOperationOutcome.rejected);
  @override
  Future<AppOperationResult> upgradeApp(AppUpgradeRequest request) async =>
      const AppOperationResult(outcome: AppOperationOutcome.rejected);
  @override
  Future<AppOperationResult> uninstallApp(AppUninstallRequest request) async =>
      const AppOperationResult(outcome: AppOperationOutcome.rejected);
  @override
  Future<AppOperationResult> pollAppJob(AppJob job) async =>
      const AppOperationResult(outcome: AppOperationOutcome.rejected);

  @override
  SnapshotsCapabilities get snapshotsCapabilities =>
      const SnapshotsCapabilities(
        connected: true,
        versionSupported: true,
        canRead: true,
        canCreate: true,
        canDelete: true,
      );
  @override
  Future<List<SnapshotDataset>> loadSnapshotDatasets() async =>
      _previewSnapshotDatasets;
  @override
  Future<SnapshotPageResult> loadSnapshots(SnapshotQuery query) async {
    if (query.validationError != null) {
      throw const SnapshotsException(SnapshotsExceptionReason.invalidRequest);
    }
    final entries =
        _previewSnapshotEntries
            .where(
              (entry) =>
                  entry.dataset == query.dataset &&
                  entry.name.startsWith(query.namePrefix),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    final start = query.page * SnapshotQuery.pageSize;
    return SnapshotPageResult(
      entries: entries.skip(start).take(SnapshotQuery.pageSize).toList(),
      hasMore: entries.length > start + SnapshotQuery.pageSize,
    );
  }

  @override
  Future<SnapshotOperationResult> createSnapshot(
    SnapshotCreateRequest request,
  ) async => const SnapshotOperationResult(
    outcome: SnapshotOperationOutcome.rejected,
    message: 'Preview only. No snapshot was created.',
  );
  @override
  Future<SnapshotOperationResult> deleteSnapshot(
    SnapshotDeleteRequest request,
  ) async => const SnapshotOperationResult(
    outcome: SnapshotOperationOutcome.rejected,
    message: 'Preview only. No snapshot was deleted.',
  );

  @override
  RealtimeCapabilities get realtimeCapabilities =>
      const RealtimeCapabilities(supported: true);
  @override
  Future<RealtimeFeed> openRealtimeFeed() async => _PreviewRealtimeFeed();
  @override
  DatasetPropertiesCapabilities get datasetPropertiesCapabilities =>
      const DatasetPropertiesCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
      );
  @override
  Future<List<DatasetPropertySnapshot>> loadDatasetProperties() async => [
    _previewDataset('tank', root: true),
    _previewDataset('tank/media'),
  ];
  @override
  Future<DatasetPropertyResult> updateDatasetProperties(
    DatasetPropertyUpdate request,
  ) async => const DatasetPropertyResult(
    outcome: DatasetPropertyOutcome.rejected,
    message: 'Preview only. No dataset was changed.',
  );

  @override
  NetworkCapabilities get networkCapabilities => const NetworkCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
  );
  @override
  Future<NetworkInventory> loadNetworkInventory() async => _previewNetwork;
  @override
  Future<NetworkChangeResult> beginNetworkTest(
    NetworkChangeRequest request,
  ) async => const NetworkChangeResult(phase: NetworkChangePhase.rejected);
  @override
  Future<NetworkChangeResult> checkNetworkTest(
    NetworkTransaction transaction,
  ) async => const NetworkChangeResult(phase: NetworkChangePhase.unknown);
  @override
  Future<NetworkChangeResult> keepNetworkTest(
    NetworkTransaction transaction,
  ) async => const NetworkChangeResult(phase: NetworkChangePhase.rejected);
  @override
  Future<NetworkChangeResult> revertNetworkTest(
    NetworkTransaction transaction,
  ) async => const NetworkChangeResult(phase: NetworkChangePhase.rejected);

  @override
  ReportingCapabilities get reportingCapabilities =>
      const ReportingCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
      );
  @override
  Future<List<ReportingGraph>> loadReportingGraphs() async => _previewGraphs;
  @override
  Future<List<ReportingHistory>> loadReportingHistory(
    ReportingRequest request,
  ) async {
    // Deliberately synthetic, isolated behind the persistent sample banner.
    // No production bootstrap, appliance, secret store or transport is used.
    const sample = [
      18.0,
      22.0,
      20.0,
      32.0,
      45.0,
      41.0,
      27.0,
      19.0,
      23.0,
      37.0,
      55.0,
      62.0,
      48.0,
      35.0,
      28.0,
      31.0,
    ];
    final name = request.graph.name;
    final legend = switch (name) {
      'cpu' => ['cpu', 'cpu0', 'cpu1'],
      'interface' => ['received', 'sent'],
      'disk' => ['read', 'write'],
      _ => ['available'],
    };
    final points = <ReportingPoint>[];
    for (var i = 0; i < 64; i++) {
      final base = sample[i % sample.length];
      final List<double?> values = i == 25 || i == 26
          ? List<double?>.filled(legend.length, null)
          : switch (name) {
              'cpu' => [base, base + 6, base - 6],
              'interface' => [base * 850, base * 330],
              'disk' => [base * 180, base * 90],
              _ => [(10 + base / 10) * 1024 * 1024 * 1024],
            };
      points.add(
        ReportingPoint(
          timestamp: request.start.add(
            Duration(
              milliseconds:
                  request.end.difference(request.start).inMilliseconds *
                  i ~/
                  63,
            ),
          ),
          values: values,
        ),
      );
    }
    return [
      ReportingHistory(
        graphName: name,
        identifier: request.identifier ?? name,
        unit: request.graph.verticalLabel,
        legend: legend,
        points: points,
        returnedStart: request.start,
        returnedEnd: request.end,
        aggregations: null,
        hasGaps: true,
      ),
    ];
  }

  @override
  AdminCatalog get adminCatalog => _previewAdminCatalog;

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    final response = AdminRequest(method: request.method, arguments: const []);
    final readValue = switch (request.method.name) {
      'sharing.smb.query' => <Object?>[
        {'id': 1, 'name': 'Media', 'path': '/mnt/tank/media', 'enabled': true},
        {
          'id': 2,
          'name': 'Projects',
          'path': '/mnt/flash/projects',
          'enabled': true,
        },
      ],
      'app.query' => <Object?>[
        for (final app in _previewInstalledApps)
          {'id': app.id, 'name': app.name, 'state': app.state},
      ],
      'user.query' => <Object?>[
        {'id': 1000, 'username': 'operator', 'builtin': false},
      ],
      _ => null,
    };
    if (readValue != null) return AdminCompleted(response, value: readValue);
    return AdminFailed(response, reason: AdminFailureReason.rejected);
  }

  @override
  Future<AdminResult> pollAdminJob(AdminJobSubmitted job) async =>
      AdminFailed(job.request, reason: AdminFailureReason.rejected);

  @override
  ManagementCapabilities get managementCapabilities => ManagementCapabilities(
    connected: true,
    versionSupported: true,
    availableActions: Set.unmodifiable(ManagementAction.values),
  );

  // Exercising confirmation must never resemble a successful real operation.
  @override
  Future<ManagementResult> execute(ManagementCommand command) async =>
      ManagementFailed(command, reason: ManagementFailureReason.rejected);

  @override
  Future<ManagementResult> pollJob(ManagementJobSubmitted job) async =>
      ManagementFailed(job.command, reason: ManagementFailureReason.rejected);

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async =>
      throw UnsupportedError('Connections are disabled in the sample preview.');

  @override
  Future<void> close() async {}

  @override
  Future<Object?> query(String method) async => switch (method) {
    'system.info' => {'hostname': 'atlas', 'version': '25.10.1'},
    'pool.query' => [
      {'name': 'archive', 'status': 'ONLINE', 'capacity': 41.6},
      {'name': 'flash', 'status': 'ONLINE', 'capacity': 27.3},
      {'name': 'tank', 'status': 'ONLINE', 'capacity': 68.4},
    ],
    'pool.dataset.query' => [
      for (final name in [
        'archive',
        'archive/backups',
        'flash',
        'flash/projects',
        'tank',
        'tank/media',
        'tank/documents',
      ])
        {'id': name, 'name': name, 'type': 'FILESYSTEM'},
    ],
    'service.query' => [
      {'service': 'cifs', 'state': 'RUNNING'},
      {'service': 'nfs', 'state': 'RUNNING'},
      {'service': 'ssh', 'state': 'RUNNING'},
      {'service': 'iscsitarget', 'state': 'STOPPED'},
      {'service': 'snmp', 'state': 'STOPPED'},
      {'service': 'ups', 'state': 'RUNNING'},
    ],
    'alert.list' => [
      {'level': 'WARNING', 'klass': 'ZpoolCapacityWarning', 'dismissed': false},
      {
        'level': 'WARNING',
        'klass': 'CertificateIsExpiringSoon',
        'dismissed': false,
      },
      {'level': 'INFO', 'klass': 'UpdateAvailable', 'dismissed': false},
    ],
    'core.get_jobs' => [
      {'id': 248, 'method': 'pool.scrub', 'state': 'SUCCESS'},
      {'id': 247, 'method': 'replication.run', 'state': 'SUCCESS'},
      {'id': 246, 'method': 'pool.snapshot.create', 'state': 'SUCCESS'},
    ],
    _ => throw const SessionQueryException(),
  };
}

Map<String, Object?> _previewAdminMethod(
  List<Object?> parameters, {
  bool job = false,
}) => {
  'accepts': parameters,
  'returns': [
    {
      'type': 'array',
      'items': {'type': 'object'},
    },
  ],
  'job': job,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'filterable': false,
};

final _previewAdminCatalog = AdminCatalog.fromMetadata(
  version: '25.10.1',
  metadata: {
    for (final method in [
      'sharing.smb.query',
      'app.query',
      'user.query',
      'core.get_jobs',
    ])
      method: _previewAdminMethod([]),
    'sharing.smb.create': _previewAdminMethod([
      {
        '_name_': 'share',
        '_required_': true,
        'type': 'object',
        'required': ['name', 'path'],
        'additionalProperties': false,
        'properties': {
          'name': {'type': 'string', 'title': 'Share name', 'minLength': 1},
          'path': {'type': 'string', 'title': 'Dataset path', 'minLength': 1},
          'enabled': {'type': 'boolean', 'title': 'Enabled', 'default': true},
        },
      },
    ]),
    'sharing.smb.delete': _previewAdminMethod([
      {
        '_name_': 'id',
        '_required_': true,
        'type': 'integer',
        'title': 'Share ID',
        'minimum': 1,
      },
    ]),
    for (final method in ['app.start', 'app.stop'])
      method: _previewAdminMethod([
        {
          '_name_': 'app_name',
          '_required_': true,
          'type': 'string',
          'title': 'Application name',
          'minLength': 1,
        },
      ], job: true),
  },
);
