import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../sample/sample_backend.dart';
import '../app_shell/adaptive_shell.dart';
import '../features/search/global_search.dart';
import '../features/rsync/rsync_page.dart';
import '../features/system_power/system_power_page.dart';
import '../features/configuration_backup/configuration_backup_page.dart';
import '../sample/configuration_backup_preview.dart';
import '../features/configuration_backup/configuration_backup_file.dart';
import '../features/configuration_restore/configuration_restore_page.dart';
import '../features/configuration_restore/configuration_restore_file.dart';
import '../sample/configuration_restore_preview.dart';
import '../features/configuration_reset/configuration_reset_page.dart';
import '../features/time_settings/time_settings_page.dart';
import '../features/email_settings/email_settings_page.dart';
import '../features/alert_settings/alert_settings_page.dart';
import '../features/alert_policies/alert_policies_page.dart';
import '../features/notification_providers/notification_providers_page.dart';
import '../features/smb_settings/smb_settings_page.dart';
import '../features/nfs_settings/nfs_settings_page.dart';
import '../features/cron_tasks/cron_tasks_page.dart';
import '../features/init_shutdown_tasks/init_shutdown_tasks_page.dart';
import '../features/admin/admin_workspace.dart';
import '../features/activity/activity_page.dart';
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

/// Debug-only entrypoint using connector-free data shared with offline demo.
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
    const repository = SampleRepository();
    const session = AuthenticatedSession(
      profileId: 'preview-only',
      repository: repository,
      availableMethodNames: sampleMethodNames,
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
            profiles: const [sampleProfile],
            selectedProfileId: sampleProfile.id,
          ),
        ),
        dashboardActiveSessionProvider.overrideWith((ref) {
          final selected = ref
              .watch(serverProfilesControllerProvider)
              .selectedProfileId;
          return selected == sampleProfile.id ? session : null;
        }),
        credentialVaultProvider.overrideWithValue(const NoopCredentialVault()),
        rpcConnectorProvider.overrideWithValue(const DisabledSampleConnector()),
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
          title: 'TrueNavo · Sample preview',
          debugShowCheckedModeBanner: false,
          theme: TrueNavoTheme.dark(),
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
              ? AppConfigPage(session: session, app: sampleInstalledApps[0])
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
