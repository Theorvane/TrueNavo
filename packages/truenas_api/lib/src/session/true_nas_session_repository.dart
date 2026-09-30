import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../endpoint/validated_endpoint.dart';
import '../protocol/json_rpc_client.dart';
import '../protocol/json_rpc_exceptions.dart';
import '../transport/rpc_transport.dart';
import 'authentication_exception.dart';
import 'credential_vault.dart';
import 'server_summary.dart';
import 'admin_policy.dart';

part 'session_management.dart';
part 'admin_schema.dart';
part 'session_admin.dart';
part 'session_network.dart';
part 'session_reporting.dart';
part 'session_realtime.dart';
part 'session_dataset_properties.dart';
part 'session_snapshots.dart';
part 'app_form_schema.dart';
part 'app_config_schema.dart';
part 'session_apps.dart';
part 'session_activity.dart';
part 'session_accounts.dart';
part 'session_virtual_machines.dart';
part 'session_zvols.dart';
part 'session_boot_environments.dart';
part 'session_permissions.dart';
part 'session_quotas.dart';
part 'session_snapshot_schedules.dart';
part 'session_smb_shares.dart';
part 'session_nfs_shares.dart';
part 'session_password_login.dart';
part 'session_system_updates.dart';
part 'session_replication.dart';
part 'session_cloud_sync.dart';
part 'session_api_keys.dart';
part 'session_cloud_credentials.dart';
part 'session_alerts.dart';
part 'session_ssh_credentials.dart';
part 'session_disks.dart';
part 'session_pool_maintenance.dart';
part 'session_rsync.dart';
part 'session_system_power.dart';
part 'session_config_backup.dart';
part 'session_config_restore.dart';
part 'session_config_reset.dart';
part 'session_time_settings.dart';
part 'session_email_settings.dart';
part 'session_alert_settings.dart';
part 'session_alert_policies.dart';
part 'session_notification_providers.dart';
part 'session_smb_settings.dart';
part 'session_nfs_settings.dart';
part 'session_cron_tasks.dart';
part 'session_directory_idmap.dart';
part 'session_directory_idmap_write.dart';
part 'session_directory_maintenance.dart';
part 'session_directory_ldap.dart';
part 'session_directory_ldap_activation.dart';
part 'session_init_shutdown_tasks.dart';
part 'session_audit_settings.dart';
part 'session_audit_export.dart';
part 'session_iscsi_auth.dart';
part 'session_nvme_hosts.dart';

typedef JsonRpcClientFactory = JsonRpcClient Function(RpcTransport transport);

/// The inventory capability exposed after authentication.
/// It deliberately accepts no parameters and only permits safe inventory reads.
abstract interface class AuthenticatedSessionQueries {
  Future<Object?> query(String method);
}

final class SessionQueryException implements Exception {
  const SessionQueryException();

  /// Never expose remote messages or payloads to the app layer.
  String get userMessage => 'Unable to load server data safely.';
}

abstract interface class SessionRepository {
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  });
  Future<void> close();
}

final class TrueNasSessionRepository
    implements
        SessionRepository,
        PasswordSessionRepository,
        AuthenticatedSessionQueries,
        AuthenticatedSessionManagement,
        AuthenticatedAdminSession,
        AuthenticatedNetworkSession,
        AuthenticatedReportingSession,
        AuthenticatedRealtimeSession,
        AuthenticatedDatasetPropertiesSession,
        AuthenticatedSnapshotsSession,
        AuthenticatedAppsSession,
        AuthenticatedCatalogOverviewSession,
        AuthenticatedActivitySession,
        AuthenticatedAccountsSession,
        AuthenticatedVirtualMachinesSession,
        AuthenticatedZvolsSession,
        AuthenticatedBootEnvironmentsSession,
        AuthenticatedPermissionsSession,
        AuthenticatedQuotasSession,
        AuthenticatedSnapshotSchedulesSession,
        AuthenticatedSmbSharesSession,
        AuthenticatedNfsSharesSession,
        AuthenticatedSystemUpdatesSession,
        AuthenticatedReplicationSession,
        AuthenticatedCloudSyncSession,
        AuthenticatedApiKeysSession,
        AuthenticatedCloudCredentialsSession,
        AuthenticatedAlertsSession,
        AuthenticatedSshCredentialsSession,
        AuthenticatedDisksSession,
        AuthenticatedPoolMaintenanceSession,
        AuthenticatedRsyncSession,
        AuthenticatedSystemPowerSession,
        AuthenticatedConfigurationBackupSession,
        AuthenticatedConfigurationRestoreSession,
        AuthenticatedConfigurationResetSession,
        AuthenticatedTimeSettingsSession,
        AuthenticatedEmailSettingsSession,
        AuthenticatedAlertSettingsSession,
        AuthenticatedAlertPoliciesSession,
        AuthenticatedNotificationProvidersSession,
        AuthenticatedSmbSettingsSession,
        AuthenticatedNfsSettingsSession,
        AuthenticatedCronTasksSession,
        AuthenticatedDirectoryIdmapSession,
        AuthenticatedInitShutdownTasksSession,
        AuthenticatedAuditSettingsSession,
        AuthenticatedAuditExportSession,
        AuthenticatedIscsiAuthSession,
        AuthenticatedNvmeHostSession,
        AuthenticatedNvmeHostAuthenticationSession,
        AuthenticatedNvmeHostAuthenticationClearSession,
        AuthenticatedNvmeHostChoicesSession,
        AuthenticatedNvmeHostCreateSession,
        AuthenticatedNvmeHostKeyCreateSession,
        AuthenticatedNvmeHostKeyReplaceSession,
        AuthenticatedNvmeHostKeyGenerationSession,
        AuthenticatedNvmeHostRenameSession,
        AuthenticatedNvmeHostHashSession,
        AuthenticatedNvmeHostAccessSession,
        AuthenticatedNvmePortAccessSession {
  TrueNasSessionRepository({
    required RpcConnector connector,
    CredentialVault? credentialVault,
    JsonRpcClientFactory? clientFactory,
    this.managementRequestTimeout = const Duration(seconds: 30),
    this.authenticationRequestTimeout = const Duration(seconds: 30),
    this.otpChallengeTimeout = const Duration(minutes: 2),
    this.systemPowerNow,
    this.configurationBackupNow,
    this.configurationRestoreNow,
    this.configurationResetNow,
    this.timeSettingsNow,
    this.emailSettingsNow,
    this.alertSettingsNow,
    this.alertPoliciesNow,
    this.notificationProvidersNow,
    this.smbSettingsNow,
    this.nfsSettingsNow,
    this.cronTasksNow,
    this.initShutdownTasksNow,
    this.auditSettingsNow,
    this.auditExportNow,
    this.nvmeHostKeyNow,
    // Preserve the public connector argument and private storage name.
    // ignore: prefer_initializing_formals
  }) : _connector = connector,
       _credentialVault = credentialVault ?? const NoopCredentialVault(),
       _clientFactory = clientFactory ?? JsonRpcClient.new;

  final RpcConnector _connector;
  final CredentialVault _credentialVault;
  final JsonRpcClientFactory _clientFactory;
  JsonRpcClient? _client;
  final Duration managementRequestTimeout;
  final Duration authenticationRequestTimeout, otpChallengeTimeout;

  /// Injectable clock for deterministic power-review expiry tests.
  /// The power adapter defaults to DateTime.now and retains its fixed max age.
  final DateTime Function()? systemPowerNow;
  final DateTime Function()? configurationBackupNow;
  final DateTime Function()? configurationRestoreNow;
  final DateTime Function()? configurationResetNow;
  final DateTime Function()? timeSettingsNow;
  final DateTime Function()? emailSettingsNow;
  final DateTime Function()? alertSettingsNow;
  final DateTime Function()? alertPoliciesNow;
  final DateTime Function()? notificationProvidersNow;
  final DateTime Function()? smbSettingsNow;
  final DateTime Function()? nfsSettingsNow;
  final DateTime Function()? cronTasksNow;
  final DateTime Function()? initShutdownTasksNow;
  final DateTime Function()? auditSettingsNow;
  final DateTime Function()? auditExportNow;
  final DateTime Function()? nvmeHostKeyNow;
  _SessionManagement? _management;
  _SessionAdmin? _admin;
  _SessionNetwork? _network;
  _SessionReporting? _reporting;
  _SessionRealtime? _realtime;
  _SessionDatasetProperties? _datasetProperties;
  _SessionSnapshots? _snapshots;
  _SessionApps? _apps;
  _SessionActivity? _activity;
  _SessionAccounts? _accounts;
  _SessionVirtualMachines? _virtualMachines;
  _SessionZvols? _zvols;
  _SessionBootEnvironments? _bootEnvironments;
  _SessionPermissions? _permissions;
  _SessionQuotas? _quotas;
  _SessionSnapshotSchedules? _snapshotSchedules;
  _SessionSmbShares? _smbShares;
  _SessionNfsShares? _nfsShares;
  _SessionSystemUpdates? _systemUpdates;
  _SessionReplication? _replication;
  _SessionCloudSync? _cloudSync;
  _SessionApiKeys? _apiKeys;
  _SessionCloudCredentials? _cloudCredentials;
  _SessionAlerts? _alerts;
  _SessionSshCredentials? _sshCredentials;
  _SessionDisks? _disks;
  _SessionPoolMaintenance? _poolMaintenance;
  _SessionRsync? _rsync;
  _SessionSystemPower? _systemPower;
  _SessionConfigurationBackup? _configurationBackup;
  _SessionConfigurationRestore? _configurationRestore;
  _SessionConfigurationReset? _configurationReset;
  _SessionTimeSettings? _timeSettings;
  _SessionEmailSettings? _emailSettings;
  _SessionAlertSettings? _alertSettings;
  _SessionAlertPolicies? _alertPolicies;
  _SessionNotificationProviders? _notificationProviders;
  _SessionSmbSettings? _smbSettings;
  _SessionNfsSettings? _nfsSettings;
  _SessionCronTasks? _cronTasks;
  _SessionDirectoryIdmap? _directoryIdmap;
  _SessionInitShutdownTasks? _initShutdownTasks;
  _SessionAuditSettings? _auditSettings;
  _SessionAuditExport? _auditExport;
  bool get _nativeMaintenanceBusy =>
      _directoryIdmap?.isBusy == true ||
      _auditExport?.isBusy == true ||
      _auditSettings?.isBusy == true ||
      _cronTasks?.isBusy == true ||
      _initShutdownTasks?.isBusy == true ||
      _smbSettings?.isBusy == true ||
      _nfsSettings?.isBusy == true ||
      _alertPolicies?.isBusy == true ||
      _notificationProviders?.isBusy == true ||
      _alertSettings?.isBusy == true ||
      _emailSettings?.isBusy == true ||
      _timeSettings?.isBusy == true ||
      _configurationReset?.isBusy == true ||
      _configurationRestore?.isBusy == true ||
      _configurationBackup?.isBusy == true ||
      _systemPower?.isBusy == true ||
      _rsync?.isBusy == true ||
      _disks?.isBusy == true ||
      _poolMaintenance?.isBusy == true;
  bool get _nativeCredentialBusy =>
      _apiKeys?.isBusy == true ||
      _cloudCredentials?.isBusy == true ||
      _sshCredentials?.isBusy == true;
  bool get _nativeAuxBusy =>
      _nativeMaintenanceBusy ||
      _alerts?.isBusy == true ||
      _nativeCredentialBusy ||
      _systemUpdates?.isBusy == true ||
      _replication?.isBusy == true ||
      _cloudSync?.isBusy == true;
  bool get _nativeSharesBusy =>
      _smbShares?.isBusy == true || _nfsShares?.isBusy == true;
  bool get _nativeStorageBusy =>
      _nativeAuxBusy ||
      _nativeSharesBusy ||
      _zvols?.isBusy == true ||
      _bootEnvironments?.isBusy == true ||
      _permissions?.isBusy == true ||
      _quotas?.isBusy == true ||
      _snapshotSchedules?.isBusy == true;
  bool get _nativeComputeBusy =>
      _accounts?.isBusy == true ||
      _virtualMachines?.isBusy == true ||
      _nativeStorageBusy;
  var _connectionGeneration = 0;
  var _nextId = 0;

  @override
  DirectoryIdmapCapabilities get directoryIdmapCapabilities =>
      _directoryIdmap?.capabilities ??
      const DirectoryIdmapCapabilities.disconnected();

  @override
  Future<DirectoryIdmapInventory> loadDirectoryIdmap() async =>
      (_directoryIdmap ?? (throw const DirectoryIdmapException())).load();

  @override
  Future<DirectoryIdmapReview> reviewDirectoryIdmap(
    DirectoryIdmapRangeDraft draft,
  ) => (_directoryIdmap ?? (throw const DirectoryIdmapException())).review(
    draft,
  );

  @override
  Future<DirectoryIdmapResult> executeDirectoryIdmap(
    DirectoryIdmapReview review,
    String confirmation,
  ) => (_directoryIdmap ?? (throw const DirectoryIdmapException())).execute(
    review,
    confirmation,
  );

  @override
  Future<DirectoryIdmapResult> pollDirectoryIdmap(DirectoryIdmapJob job) =>
      (_directoryIdmap ?? (throw const DirectoryIdmapException())).poll(job);

  @override
  Future<DirectoryLdapReview> reviewDirectoryLdap(DirectoryLdapDraft draft) =>
      (_directoryIdmap ?? (throw const DirectoryIdmapException())).reviewLdap(
        draft,
      );

  @override
  Future<DirectoryLdapResult> executeDirectoryLdap(
    DirectoryLdapReview review,
    String confirmation,
  ) => (_directoryIdmap ?? (throw const DirectoryIdmapException())).executeLdap(
    review,
    confirmation,
  );

  @override
  Future<DirectoryLdapResult> pollDirectoryLdap(DirectoryLdapJob job) =>
      (_directoryIdmap ?? (throw const DirectoryIdmapException())).pollLdap(
        job,
      );

  @override
  Future<DirectoryLdapActivationReview> reviewDirectoryLdapActivation(
    bool enable,
  ) => (_directoryIdmap ?? (throw const DirectoryIdmapException()))
      .reviewLdapActivation(enable);

  @override
  Future<DirectoryLdapActivationResult> executeDirectoryLdapActivation(
    DirectoryLdapActivationReview review,
    String confirmation,
  ) => (_directoryIdmap ?? (throw const DirectoryIdmapException()))
      .executeLdapActivation(review, confirmation);

  @override
  Future<DirectoryLdapActivationResult> pollDirectoryLdapActivation(
    DirectoryLdapActivationJob job,
  ) => (_directoryIdmap ?? (throw const DirectoryIdmapException()))
      .pollLdapActivation(job);
  @override
  Future<DirectoryMaintenanceReview> reviewDirectoryCacheRefresh() =>
      (_directoryIdmap ?? (throw const DirectoryIdmapException()))
          .reviewCacheRefresh();

  @override
  Future<DirectoryMaintenanceResult> executeDirectoryCacheRefresh(
    DirectoryMaintenanceReview review,
    String confirmation,
  ) => (_directoryIdmap ?? (throw const DirectoryIdmapException()))
      .executeCacheRefresh(review, confirmation);

  @override
  Future<DirectoryMaintenanceResult> pollDirectoryCacheRefresh(
    DirectoryMaintenanceJob job,
  ) => (_directoryIdmap ?? (throw const DirectoryIdmapException()))
      .pollCacheRefresh(job);

  @override
  Future<DirectoryMaintenanceReview> reviewDirectoryKeytabSync() =>
      (_directoryIdmap ?? (throw const DirectoryIdmapException()))
          .reviewKeytabSync();

  @override
  Future<DirectoryMaintenanceResult> executeDirectoryKeytabSync(
    DirectoryMaintenanceReview review,
    String confirmation,
  ) => (_directoryIdmap ?? (throw const DirectoryIdmapException()))
      .executeKeytabSync(review, confirmation);

  @override
  Future<DirectoryMaintenanceResult> pollDirectoryKeytabSync(
    DirectoryMaintenanceJob job,
  ) => (_directoryIdmap ?? (throw const DirectoryIdmapException()))
      .pollKeytabSync(job);

  @override
  CronTasksCapabilities get cronTasksCapabilities =>
      _cronTasks?.capabilities ?? const CronTasksCapabilities.disconnected();
  _SessionCronTasks get _authenticatedCronTasks =>
      _cronTasks ??
      (throw const CronTasksException(
        CronTasksExceptionReason.notAuthenticated,
      ));
  @override
  Future<CronTasksInventory> loadCronTasks() async =>
      _authenticatedCronTasks.load();
  @override
  Future<CronTasksReview> reviewCronTasks(CronTasksRequest request) async =>
      _authenticatedCronTasks.review(request);
  @override
  Future<CronTasksResult> executeCronTasks(
    CronTasksReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedCronTasks.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );

  @override
  InitShutdownTasksCapabilities get initShutdownTasksCapabilities =>
      _initShutdownTasks?.capabilities ??
      const InitShutdownTasksCapabilities.disconnected();
  _SessionInitShutdownTasks get _authenticatedInitShutdownTasks =>
      _initShutdownTasks ??
      (throw const InitShutdownTasksException(
        InitShutdownTasksExceptionReason.notAuthenticated,
      ));
  @override
  Future<InitShutdownTasksInventory> loadInitShutdownTasks() async =>
      _authenticatedInitShutdownTasks.load();
  @override
  Future<InitShutdownTasksReview> reviewInitShutdownTasks(
    InitShutdownTasksRequest request,
  ) async => _authenticatedInitShutdownTasks.review(request);
  @override
  Future<InitShutdownTasksResult> executeInitShutdownTasks(
    InitShutdownTasksReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedInitShutdownTasks.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );

  @override
  SmbSettingsCapabilities get smbSettingsCapabilities =>
      _smbSettings?.capabilities ??
      const SmbSettingsCapabilities.disconnected();
  _SessionSmbSettings get _authenticatedSmbSettings =>
      _smbSettings ??
      (throw const SmbSettingsException(
        SmbSettingsExceptionReason.notAuthenticated,
      ));
  @override
  Future<SmbSettingsInventory> loadSmbSettings() async =>
      _authenticatedSmbSettings.load();
  @override
  Future<SmbSettingsReview> reviewSmbSettings(
    SmbSettingsRequest request,
  ) async => _authenticatedSmbSettings.review(request);
  @override
  Future<SmbSettingsResult> executeSmbSettings(
    SmbSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedSmbSettings.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );

  @override
  NfsSettingsCapabilities get nfsSettingsCapabilities =>
      _nfsSettings?.capabilities ??
      const NfsSettingsCapabilities.disconnected();
  _SessionNfsSettings get _authenticatedNfsSettings =>
      _nfsSettings ??
      (throw const NfsSettingsException(
        NfsSettingsExceptionReason.notAuthenticated,
      ));
  @override
  Future<NfsSettingsInventory> loadNfsSettings() async =>
      _authenticatedNfsSettings.load();
  @override
  Future<NfsSettingsReview> reviewNfsSettings(
    NfsSettingsRequest request,
  ) async => _authenticatedNfsSettings.review(request);
  @override
  Future<NfsSettingsResult> executeNfsSettings(
    NfsSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedNfsSettings.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );

  @override
  AlertPoliciesCapabilities get alertPoliciesCapabilities =>
      _alertPolicies?.capabilities ??
      const AlertPoliciesCapabilities.disconnected();
  _SessionAlertPolicies get _authenticatedAlertPolicies =>
      _alertPolicies ??
      (throw const AlertPoliciesException(
        AlertPoliciesExceptionReason.notAuthenticated,
      ));
  @override
  Future<AlertPoliciesInventory> loadAlertPolicies() async =>
      _authenticatedAlertPolicies.load();
  @override
  Future<AlertPoliciesReview> reviewAlertPolicies(
    AlertPoliciesRequest request,
  ) async => _authenticatedAlertPolicies.review(request);
  @override
  Future<AlertPoliciesResult> executeAlertPolicies(
    AlertPoliciesReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedAlertPolicies.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );

  @override
  NotificationProvidersCapabilities get notificationProvidersCapabilities =>
      _notificationProviders?.capabilities ??
      const NotificationProvidersCapabilities.disconnected();
  _SessionNotificationProviders get _authenticatedNotificationProviders =>
      _notificationProviders ??
      (throw const NotificationProvidersException(
        NotificationProvidersExceptionReason.notAuthenticated,
      ));
  @override
  Future<NotificationProvidersInventory> loadNotificationProviders() async =>
      _authenticatedNotificationProviders.load();
  @override
  Future<NotificationProvidersReview> reviewNotificationProviders(
    NotificationProvidersRequest request,
  ) async => _authenticatedNotificationProviders.review(request);
  @override
  Future<NotificationProvidersResult> executeNotificationProviders(
    NotificationProvidersReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedNotificationProviders.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );

  @override
  AuditSettingsCapabilities get auditSettingsCapabilities =>
      _auditSettings?.capabilities ??
      const AuditSettingsCapabilities.disconnected();
  _SessionAuditSettings get _authenticatedAuditSettings =>
      _auditSettings ??
      (throw const AuditSettingsException(
        AuditSettingsExceptionReason.notAuthenticated,
      ));
  @override
  Future<AuditSettingsInventory> loadAuditSettings() async =>
      _authenticatedAuditSettings.load();
  @override
  Future<AuditSettingsReview> reviewAuditSettings(
    AuditSettingsRequest request,
  ) async => _authenticatedAuditSettings.review(request);
  @override
  Future<AuditSettingsResult> executeAuditSettings(
    AuditSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedAuditSettings.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );

  @override
  AuditExportCapabilities get auditExportCapabilities =>
      _auditExport?.capabilities ??
      const AuditExportCapabilities.disconnected();
  _SessionAuditExport get _authenticatedAuditExport =>
      _auditExport ??
      (throw const AuditExportException(
        AuditExportExceptionReason.notAuthenticated,
      ));
  @override
  Future<AuditExportReview> reviewAuditExport(
    AuditExportRequest request,
  ) async => _authenticatedAuditExport.review(request);
  @override
  Future<AuditExportResult> executeAuditExport(
    AuditExportReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedAuditExport.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );
  @override
  Future<AuditExportResult> pollAuditExport(
    AuditExportOperation operation, {
    required bool Function() isCurrent,
  }) async => _authenticatedAuditExport.poll(operation, isCurrent: isCurrent);

  @override
  AlertSettingsCapabilities get alertSettingsCapabilities =>
      _alertSettings?.capabilities ??
      const AlertSettingsCapabilities.disconnected();
  _SessionAlertSettings get _authenticatedAlertSettings =>
      _alertSettings ??
      (throw const AlertSettingsException(
        AlertSettingsExceptionReason.notAuthenticated,
      ));
  @override
  Future<AlertSettingsInventory> loadAlertSettings() async =>
      _authenticatedAlertSettings.load();
  @override
  Future<AlertSettingsReview> reviewAlertSettings(
    AlertSettingsRequest request,
  ) async => _authenticatedAlertSettings.review(request);
  @override
  Future<AlertSettingsResult> executeAlertSettings(
    AlertSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedAlertSettings.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );

  @override
  EmailSettingsCapabilities get emailSettingsCapabilities =>
      _emailSettings?.capabilities ??
      const EmailSettingsCapabilities.disconnected();
  _SessionEmailSettings get _authenticatedEmailSettings =>
      _emailSettings ??
      (throw const EmailSettingsException(
        EmailSettingsExceptionReason.notAuthenticated,
      ));
  @override
  Future<EmailSettingsInventory> loadEmailSettings() async =>
      _authenticatedEmailSettings.load();
  @override
  Future<EmailSettingsReview> reviewEmailSettings(
    EmailSettingsRequest request,
  ) async => _authenticatedEmailSettings.review(request);
  @override
  Future<EmailSettingsResult> executeEmailSettings(
    EmailSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedEmailSettings.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );
  @override
  Future<EmailSettingsResult> checkEmailSettingsJob(
    int jobId, {
    required bool Function() isCurrent,
  }) async => _authenticatedEmailSettings.check(jobId, isCurrent: isCurrent);

  @override
  TimeSettingsCapabilities get timeSettingsCapabilities =>
      _timeSettings?.capabilities ??
      const TimeSettingsCapabilities.disconnected();
  _SessionTimeSettings get _authenticatedTimeSettings =>
      _timeSettings ??
      (throw const TimeSettingsException(
        TimeSettingsExceptionReason.notAuthenticated,
      ));
  @override
  Future<TimeSettingsInventory> loadTimeSettings() async =>
      _authenticatedTimeSettings.load();
  @override
  Future<TimeSettingsReview> reviewTimeSettings(
    TimeSettingsRequest request,
  ) async => _authenticatedTimeSettings.review(request);
  @override
  Future<TimeSettingsResult> executeTimeSettings(
    TimeSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedTimeSettings.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );

  @override
  ConfigurationResetCapabilities get configurationResetCapabilities =>
      _configurationReset?.capabilities ??
      const ConfigurationResetCapabilities.disconnected();
  _SessionConfigurationReset get _authenticatedConfigurationReset =>
      _configurationReset ??
      (throw const ConfigurationResetException(
        ConfigurationResetExceptionReason.notAuthenticated,
      ));
  @override
  Future<ConfigurationResetInventory> loadConfigurationReset() async =>
      _authenticatedConfigurationReset.load();
  @override
  Future<ConfigurationResetReview> reviewConfigurationReset(
    ConfigurationResetRequest request,
  ) async => _authenticatedConfigurationReset.review(request);
  @override
  Future<ConfigurationResetResult> executeConfigurationReset(
    ConfigurationResetReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedConfigurationReset.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );

  @override
  ConfigurationRestoreCapabilities get configurationRestoreCapabilities =>
      _configurationRestore?.capabilities ??
      const ConfigurationRestoreCapabilities.disconnected();
  _SessionConfigurationRestore get _authenticatedConfigurationRestore =>
      _configurationRestore ??
      (throw const ConfigurationRestoreException(
        ConfigurationRestoreExceptionReason.notAuthenticated,
      ));
  @override
  Future<ConfigurationRestoreFile> prepareConfigurationRestore(
    Uint8List bytes,
  ) async {
    try {
      return _authenticatedConfigurationRestore.prepare(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  @override
  Future<ConfigurationRestoreInventory> loadConfigurationRestore() async =>
      _authenticatedConfigurationRestore.load();
  @override
  Future<ConfigurationRestoreReview> reviewConfigurationRestore(
    ConfigurationRestoreRequest request,
  ) async => _authenticatedConfigurationRestore.review(request);
  @override
  Future<ConfigurationRestoreResult> executeConfigurationRestore(
    ConfigurationRestoreReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => _authenticatedConfigurationRestore.execute(
    review,
    confirmation,
    isCurrent: isCurrent,
  );

  @override
  ConfigurationBackupCapabilities get configurationBackupCapabilities =>
      _configurationBackup?.capabilities ??
      const ConfigurationBackupCapabilities.disconnected();
  _SessionConfigurationBackup get _authenticatedConfigurationBackup =>
      _configurationBackup ??
      (throw const ConfigurationBackupException(
        ConfigurationBackupExceptionReason.notAuthenticated,
      ));
  @override
  Future<ConfigurationBackupInventory> loadConfigurationBackup() async =>
      _authenticatedConfigurationBackup.load();
  @override
  Future<ConfigurationBackupReview> reviewConfigurationBackup(
    ConfigurationBackupRequest request,
  ) async => _authenticatedConfigurationBackup.review(request);
  @override
  Future<ConfigurationBackupResult> executeConfigurationBackup(
    ConfigurationBackupReview review,
    String confirmation,
  ) async => _authenticatedConfigurationBackup.execute(review, confirmation);

  @override
  SystemPowerCapabilities get systemPowerCapabilities =>
      _systemPower?.capabilities ??
      const SystemPowerCapabilities.disconnected();
  _SessionSystemPower get _authenticatedSystemPower =>
      _systemPower ??
      (throw const SystemPowerException(
        SystemPowerExceptionReason.notAuthenticated,
      ));
  @override
  Future<SystemPowerInventory> loadSystemPower() async =>
      _authenticatedSystemPower.load();
  @override
  Future<SystemPowerReview> reviewSystemPower(
    SystemPowerRequest request,
  ) async => _authenticatedSystemPower.review(request);
  @override
  Future<SystemPowerResult> executeSystemPower(
    SystemPowerReview review,
    String confirmation,
  ) async => _authenticatedSystemPower.execute(review, confirmation);

  @override
  RsyncCapabilities get rsyncCapabilities =>
      _rsync?.capabilities ?? const RsyncCapabilities.disconnected();
  _SessionRsync get _authenticatedRsync =>
      _rsync ??
      (throw const RsyncException(RsyncExceptionReason.notAuthenticated));
  @override
  Future<RsyncInventory> loadRsync() async => _authenticatedRsync.load();
  @override
  Future<RsyncReview> reviewRsync(RsyncRequest request) async =>
      _authenticatedRsync.review(request);
  @override
  Future<RsyncResult> executeRsync(
    RsyncReview review,
    String confirmation,
  ) async => _authenticatedRsync.execute(review, confirmation);
  @override
  Future<RsyncResult> checkRsyncJob(RsyncJob job) async =>
      _authenticatedRsync.check(job);

  @override
  DisksCapabilities get disksCapabilities =>
      _disks?.capabilities ?? const DisksCapabilities.disconnected();
  _SessionDisks get _authenticatedDisks =>
      _disks ??
      (throw const DisksException(DisksExceptionReason.notAuthenticated));
  @override
  Future<DiskInventory> loadDisks() async => _authenticatedDisks.load();
  @override
  Future<DiskReview> reviewDisk(DiskRequest request) async =>
      _authenticatedDisks.review(request);
  @override
  Future<DiskResult> executeDisk(
    DiskReview review,
    String confirmation,
  ) async => _authenticatedDisks.execute(review, confirmation);

  @override
  PoolMaintenanceCapabilities get poolMaintenanceCapabilities =>
      _poolMaintenance?.capabilities ??
      const PoolMaintenanceCapabilities.disconnected();
  _SessionPoolMaintenance get _authenticatedPoolMaintenance =>
      _poolMaintenance ??
      (throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.notAuthenticated,
      ));
  @override
  Future<PoolMaintenanceInventory> loadPoolMaintenance() async =>
      _authenticatedPoolMaintenance.load();
  @override
  Future<PoolMaintenanceReview> reviewPoolMaintenance(
    PoolMaintenanceRequest request,
  ) async => _authenticatedPoolMaintenance.review(request);
  @override
  Future<PoolMaintenanceResult> executePoolMaintenance(
    PoolMaintenanceReview review,
    String confirmation,
  ) async => _authenticatedPoolMaintenance.execute(review, confirmation);
  @override
  Future<PoolMaintenanceResult> checkPoolMaintenanceJob(
    PoolMaintenanceJob job,
  ) async => _authenticatedPoolMaintenance.check(job);

  @override
  SshCredentialsCapabilities get sshCredentialsCapabilities =>
      _sshCredentials?.capabilities ??
      const SshCredentialsCapabilities.disconnected();
  _SessionSshCredentials get _authenticatedSshCredentials =>
      _sshCredentials ??
      (throw const SshCredentialsException(
        SshCredentialsExceptionReason.notAuthenticated,
      ));
  @override
  Future<SshCredentialInventory> loadSshCredentials() async =>
      _authenticatedSshCredentials.load();
  @override
  Future<SshCredentialReview> reviewSshCredential(
    SshCredentialRequest request,
  ) async => _authenticatedSshCredentials.review(request);
  @override
  Future<SshCredentialResult> executeSshCredential(
    SshCredentialReview review,
    String confirmation, {
    SshCredentialWriteOnlyInput? input,
  }) async {
    try {
      return await _authenticatedSshCredentials.execute(
        review,
        confirmation,
        input: input,
      );
    } finally {
      input?.dispose();
    }
  }

  @override
  AlertsCapabilities get alertsCapabilities =>
      _alerts?.capabilities ?? const AlertsCapabilities.disconnected();
  _SessionAlerts get _authenticatedAlerts =>
      _alerts ??
      (throw const AlertsException(AlertsExceptionReason.notAuthenticated));
  @override
  Future<AlertInventory> loadAlerts() async => _authenticatedAlerts.load();
  @override
  Future<AlertReview> reviewAlert(AlertRequest request) async =>
      _authenticatedAlerts.review(request);
  @override
  Future<AlertResult> executeAlert(
    AlertReview review,
    String confirmation,
  ) async => _authenticatedAlerts.execute(review, confirmation);

  @override
  ApiKeysCapabilities get apiKeysCapabilities =>
      _apiKeys?.capabilities ?? const ApiKeysCapabilities.disconnected();
  _SessionApiKeys get _authenticatedApiKeys =>
      _apiKeys ??
      (throw const ApiKeysException(ApiKeysExceptionReason.notAuthenticated));
  @override
  Future<ApiKeyInventory> loadApiKeys() async => _authenticatedApiKeys.load();
  @override
  Future<ApiKeyReview> reviewApiKey(ApiKeyRequest request) async =>
      _authenticatedApiKeys.review(request);
  @override
  Future<ApiKeyResult> executeApiKey(
    ApiKeyReview review,
    String confirmation,
  ) async => _authenticatedApiKeys.execute(review, confirmation);

  @override
  CloudCredentialsCapabilities get cloudCredentialsCapabilities =>
      _cloudCredentials?.capabilities ??
      const CloudCredentialsCapabilities.disconnected();
  _SessionCloudCredentials get _authenticatedCloudCredentials =>
      _cloudCredentials ??
      (throw const CloudCredentialsException(
        CloudCredentialsExceptionReason.notAuthenticated,
      ));
  @override
  Future<CloudCredentialInventory> loadCloudCredentials() async =>
      _authenticatedCloudCredentials.load();
  @override
  Future<CloudCredentialReview> reviewCloudCredential(
    CloudCredentialRequest request,
  ) async => _authenticatedCloudCredentials.review(request);
  @override
  Future<CloudCredentialResult> executeCloudCredential(
    CloudCredentialReview review,
    String confirmation, {
    CloudCredentialWriteOnlyInput? input,
  }) async {
    try {
      return await _authenticatedCloudCredentials.execute(
        review,
        confirmation,
        input: input,
      );
    } finally {
      input?.dispose();
    }
  }

  @override
  ReplicationCapabilities get replicationCapabilities =>
      _replication?.capabilities ??
      const ReplicationCapabilities.disconnected();
  _SessionReplication get _authenticatedReplication =>
      _replication ??
      (throw const ReplicationException(
        ReplicationExceptionReason.notAuthenticated,
      ));
  @override
  Future<ReplicationInventory> loadReplication() async =>
      _authenticatedReplication.load();
  @override
  Future<ReplicationReview> reviewReplication(
    ReplicationRequest request,
  ) async => _authenticatedReplication.review(request);
  @override
  Future<ReplicationResult> executeReplication(
    ReplicationReview review,
    String confirmation,
  ) async => _authenticatedReplication.execute(review, confirmation);
  @override
  Future<ReplicationResult> pollReplication(ReplicationJob job) async =>
      _authenticatedReplication.poll(job);

  @override
  CloudSyncCapabilities get cloudSyncCapabilities =>
      _cloudSync?.capabilities ?? const CloudSyncCapabilities.disconnected();
  _SessionCloudSync get _authenticatedCloudSync =>
      _cloudSync ??
      (throw const CloudSyncException(
        CloudSyncExceptionReason.notAuthenticated,
      ));
  @override
  Future<CloudSyncInventory> loadCloudSync() async =>
      _authenticatedCloudSync.load();
  @override
  Future<CloudSyncReview> reviewCloudSync(CloudSyncRequest request) async =>
      _authenticatedCloudSync.review(request);
  @override
  Future<CloudSyncResult> executeCloudSync(
    CloudSyncReview review,
    String confirmation,
  ) async => _authenticatedCloudSync.execute(review, confirmation);
  @override
  Future<CloudSyncResult> pollCloudSync(CloudSyncJob job) async =>
      _authenticatedCloudSync.poll(job);

  @override
  SystemUpdatesCapabilities get systemUpdatesCapabilities =>
      _systemUpdates?.capabilities ??
      const SystemUpdatesCapabilities.disconnected();
  _SessionSystemUpdates get _authenticatedSystemUpdates =>
      _systemUpdates ??
      (throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.notAuthenticated,
      ));
  @override
  Future<SystemUpdateInventory> loadSystemUpdates() async =>
      _authenticatedSystemUpdates.load();
  @override
  Future<SystemUpdateReview> reviewSystemUpdate(
    SystemUpdateRequest request,
  ) async => _authenticatedSystemUpdates.review(request);
  @override
  Future<SystemUpdateResult> executeSystemUpdate(
    SystemUpdateReview review,
    String confirmation,
  ) async => _authenticatedSystemUpdates.execute(review, confirmation);
  @override
  Future<SystemUpdateResult> pollSystemUpdate(SystemUpdateJob job) async =>
      _authenticatedSystemUpdates.poll(job);

  @override
  SmbSharesCapabilities get smbSharesCapabilities =>
      _smbShares?.capabilities ?? const SmbSharesCapabilities.disconnected();
  _SessionSmbShares get _authenticatedSmbShares =>
      _smbShares ??
      (throw const SmbSharesException(
        SmbSharesExceptionReason.notAuthenticated,
      ));
  @override
  Future<SmbShareInventory> loadSmbShares() async =>
      _authenticatedSmbShares.load();
  @override
  Future<SmbShareReview> reviewSmbShare(SmbShareRequest request) async =>
      _authenticatedSmbShares.review(request);
  @override
  Future<SmbShareResult> executeSmbShare(
    SmbShareReview review,
    String confirmation,
  ) async => _authenticatedSmbShares.execute(review, confirmation);

  @override
  NfsSharesCapabilities get nfsSharesCapabilities =>
      _nfsShares?.capabilities ?? const NfsSharesCapabilities.disconnected();
  _SessionNfsShares get _authenticatedNfsShares =>
      _nfsShares ??
      (throw const NfsSharesException(
        NfsSharesExceptionReason.notAuthenticated,
      ));
  @override
  Future<NfsShareInventory> loadNfsShares() async =>
      _authenticatedNfsShares.load();
  @override
  Future<NfsShareReview> reviewNfsShare(NfsShareRequest request) async =>
      _authenticatedNfsShares.review(request);
  @override
  Future<NfsShareResult> executeNfsShare(
    NfsShareReview review,
    String confirmation,
  ) async => _authenticatedNfsShares.execute(review, confirmation);

  @override
  QuotaCapabilities get quotaCapabilities =>
      _quotas?.capabilities ?? const QuotaCapabilities.disconnected();
  _SessionQuotas get _authenticatedQuotas =>
      _quotas ??
      (throw const QuotaException(QuotaExceptionReason.notAuthenticated));
  @override
  Future<List<QuotaDataset>> loadQuotaDatasets() async =>
      _authenticatedQuotas.datasets();
  @override
  Future<QuotaInventory> loadQuotas(QuotaDataset dataset) async =>
      _authenticatedQuotas.load(dataset);
  @override
  Future<QuotaIdentity> resolveQuotaIdentity(
    QuotaInventory inventory,
    QuotaKind kind,
    int id,
  ) async => _authenticatedQuotas.resolve(inventory, kind, id);
  @override
  Future<QuotaReview> reviewQuotaChange(QuotaChange change) async =>
      _authenticatedQuotas.review(change);
  @override
  Future<QuotaResult> executeQuotaReview(
    QuotaReview review,
    String confirmation,
  ) async => _authenticatedQuotas.execute(review, confirmation);

  @override
  SnapshotSchedulesCapabilities get snapshotSchedulesCapabilities =>
      _snapshotSchedules?.capabilities ??
      const SnapshotSchedulesCapabilities.disconnected();
  _SessionSnapshotSchedules get _authenticatedSnapshotSchedules =>
      _snapshotSchedules ??
      (throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.notAuthenticated,
      ));
  @override
  Future<SnapshotScheduleInventory> loadSnapshotSchedules() async =>
      _authenticatedSnapshotSchedules.load();
  @override
  Future<SnapshotScheduleReview> reviewSnapshotSchedule(
    SnapshotScheduleRequest request,
  ) async => _authenticatedSnapshotSchedules.review(request);
  @override
  Future<SnapshotScheduleResult> executeSnapshotSchedule(
    SnapshotScheduleReview review,
    String confirmation,
  ) async => _authenticatedSnapshotSchedules.execute(review, confirmation);

  @override
  PermissionsCapabilities get permissionsCapabilities =>
      _permissions?.capabilities ??
      const PermissionsCapabilities.disconnected();
  _SessionPermissions get _authenticatedPermissions =>
      _permissions ??
      (throw const PermissionsException(
        PermissionsExceptionReason.notAuthenticated,
      ));
  @override
  Future<List<PermissionDataset>> loadPermissionDatasets() async =>
      _authenticatedPermissions.datasets();
  @override
  Future<PermissionReview> loadPermissionReview(
    PermissionDataset dataset,
  ) async => _authenticatedPermissions.review(dataset);
  @override
  Future<PermissionIdentity?> lookupPermissionIdentity(
    PermissionIdentityKind kind,
    int id,
  ) async => _authenticatedPermissions.lookup(kind, id);
  @override
  Future<PermissionOperationResult> applyPermissions(
    PermissionApplyRequest request,
  ) async => _authenticatedPermissions.apply(request);
  @override
  Future<PermissionOperationResult> checkPermissionOperation(
    PermissionOperationResult operation,
  ) async => _authenticatedPermissions.check(operation);

  @override
  ZvolCapabilities get zvolCapabilities =>
      _zvols?.capabilities ?? const ZvolCapabilities.disconnected();
  _SessionZvols get _authenticatedZvols =>
      _zvols ??
      (throw const ZvolException(ZvolExceptionReason.notAuthenticated));
  @override
  Future<ZvolInventory> loadZvols() async => _authenticatedZvols.inventory();
  @override
  Future<String> loadZvolRecommendedBlockSize(ZvolParent parent) async =>
      _authenticatedZvols.recommend(parent);
  @override
  Future<ZvolReview> reviewZvolCreate(ZvolCreate request) async =>
      _authenticatedZvols.reviewCreate(request);
  @override
  Future<ZvolReview> reviewZvolUpdate(ZvolUpdate request) async =>
      _authenticatedZvols.reviewUpdate(request);
  @override
  Future<ZvolReview> reviewZvolDelete(ZvolEntry volume) async =>
      _authenticatedZvols.reviewDelete(volume);
  @override
  Future<ZvolResult> executeZvolReview(
    ZvolReview review,
    String confirmation,
  ) async => _authenticatedZvols.execute(review, confirmation);

  @override
  BootEnvironmentsCapabilities get bootEnvironmentsCapabilities =>
      _bootEnvironments?.capabilities ??
      const BootEnvironmentsCapabilities.disconnected();
  _SessionBootEnvironments get _authenticatedBootEnvironments =>
      _bootEnvironments ??
      (throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.notAuthenticated,
      ));
  @override
  Future<BootEnvironmentInventory> loadBootEnvironments() async =>
      _authenticatedBootEnvironments.load();
  @override
  Future<BootEnvironmentReview> reviewBootEnvironment(
    BootEnvironmentRequest request,
  ) async => _authenticatedBootEnvironments.review(request);
  @override
  Future<BootEnvironmentResult> executeBootEnvironment(
    BootEnvironmentReview review,
  ) async => _authenticatedBootEnvironments.execute(review);

  @override
  AccountsCapabilities get accountsCapabilities =>
      _accounts?.capabilities ?? const AccountsCapabilities.disconnected();
  _SessionAccounts get _authenticatedAccounts =>
      _accounts ??
      (throw const AccountsException(AccountsExceptionReason.notAuthenticated));
  @override
  Future<AccountsInventory> loadAccounts() async =>
      _authenticatedAccounts.load();
  @override
  Future<AccountsOperationResult> createAccountUser(
    AccountUserCreate request,
  ) async => _authenticatedAccounts.createUser(request);
  @override
  Future<AccountsOperationResult> updateAccountUser(
    AccountUser user,
    AccountUserUpdate request,
  ) async => _authenticatedAccounts.updateUser(user, request);
  @override
  Future<AccountsOperationResult> deleteAccountUser(
    AccountUser user,
    String confirmedName,
  ) async => _authenticatedAccounts.deleteUser(user, confirmedName);
  @override
  Future<AccountsOperationResult> createAccountGroup(
    AccountGroupCreate request,
  ) async => _authenticatedAccounts.createGroup(request);
  @override
  Future<AccountsOperationResult> updateAccountGroup(
    AccountGroup group,
    AccountGroupUpdate request,
  ) async => _authenticatedAccounts.updateGroup(group, request);
  @override
  Future<AccountsOperationResult> deleteAccountGroup(
    AccountGroup group,
    String confirmedName,
  ) async => _authenticatedAccounts.deleteGroup(group, confirmedName);

  @override
  VmCapabilities get virtualMachineCapabilities =>
      _virtualMachines?.capabilities ?? const VmCapabilities.disconnected();
  _SessionVirtualMachines get _authenticatedVirtualMachines =>
      _virtualMachines ??
      (throw const VmException(VmExceptionReason.disconnected));
  @override
  Future<VmInventory> loadVirtualMachines() async =>
      _authenticatedVirtualMachines.inventory();
  @override
  Future<VmChoices> loadVmChoices() async =>
      _authenticatedVirtualMachines.choices();
  @override
  Future<VmReview> reviewVmCreate(VmConfiguration configuration) async =>
      _authenticatedVirtualMachines.reviewCreate(configuration);
  @override
  Future<VmReview> reviewVmUpdate(
    VirtualMachine vm,
    VmConfiguration configuration,
  ) async => _authenticatedVirtualMachines.reviewUpdate(vm, configuration);
  @override
  Future<VmReview> reviewVmAction(VirtualMachine vm, VmAction action) async =>
      _authenticatedVirtualMachines.reviewAction(vm, action);
  @override
  Future<VmReview> reviewVmDevice(
    VirtualMachine vm,
    VmDeviceChange change,
  ) async => _authenticatedVirtualMachines.reviewDevice(vm, change);
  @override
  Future<VmOperationResult> executeVmReview(
    VmReview review, {
    required String confirmation,
  }) async =>
      _authenticatedVirtualMachines.execute(review, confirmation: confirmation);
  @override
  Future<VmOperationResult> pollVmOperation(
    VmOperationHandle operation,
  ) async => _authenticatedVirtualMachines.poll(operation);

  @override
  ActivityCapabilities get activityCapabilities =>
      _activity?.capabilities ?? const ActivityCapabilities.disconnected();
  _SessionActivity get _authenticatedActivity =>
      _activity ??
      (throw const ActivityException(ActivityExceptionReason.disconnected));
  @override
  Future<JobPage> loadActivityJobs(JobQuery query) async =>
      _authenticatedActivity.jobs(query);
  @override
  Future<AuditPage> loadAuditEvents(AuditQuery query) async =>
      _authenticatedActivity.audit(query);
  @override
  Future<JobCancelResult> cancelActivityJob(
    ActivityJob job,
    String confirmation,
  ) async => _authenticatedActivity.cancel(job, confirmation);
  @override
  Future<JobCancelResult> checkActivityCancellation(ActivityJob job) async =>
      _authenticatedActivity.check(job);

  @override
  AppsCapabilities get appsCapabilities =>
      _apps?.capabilities ?? const AppsCapabilities.disconnected();
  _SessionApps get _authenticatedApps =>
      _apps ??
      (throw const AppsException(AppsExceptionReason.notAuthenticated));
  @override
  Future<AppsInventory> loadAppsInventory() async =>
      _authenticatedApps.loadInventory();
  @override
  Future<InstalledAppDetails> loadInstalledAppDetails(InstalledApp app) async =>
      _authenticatedApps.loadInstalledDetails(app);
  @override
  Future<List<CatalogApp>> loadAppsCatalog({bool cachedOnly = false}) async =>
      _authenticatedApps.loadCatalog(cachedOnly: cachedOnly);
  @override
  Future<CatalogOverview> loadCatalogOverview() async =>
      _authenticatedApps.loadCatalogOverview();
  @override
  Future<AppOperationResult> syncCatalog(CatalogOverview overview) async =>
      _authenticatedApps.syncCatalog(overview);
  @override
  Future<AppOperationResult> updateCatalogPreferredTrains(
    CatalogOverview overview,
    List<String> preferredTrains,
  ) async =>
      _authenticatedApps.updatePreferredTrains(overview, preferredTrains);
  @override
  Future<List<String>> loadAppVersions(CatalogApp app) async =>
      _authenticatedApps.versions(app);
  @override
  Future<AppVersionDetails> loadAppVersionDetails(
    CatalogApp app,
    String version,
  ) async => _authenticatedApps.versionDetails(app, version);

  @override
  Future<AppUpgradeReview> loadAppUpgradeReview(
    InstalledApp app,
    AppVersionDetails details,
  ) async => _authenticatedApps.upgradeReview(app, details);
  @override
  Future<AppOperationResult> installApp(AppInstallRequest request) async =>
      _authenticatedApps.install(request);
  @override
  Future<AppConfigReview> loadAppConfigReview(InstalledApp app) async =>
      _authenticatedApps.configReview(app);
  @override
  Future<AppOperationResult> updateApp(AppConfigUpdateRequest request) async =>
      _authenticatedApps.update(request);
  @override
  Future<AppOperationResult> changeAppState(
    InstalledApp app,
    AppLifecycleAction action,
  ) async => _authenticatedApps.changeState(app, action);
  @override
  Future<AppOperationResult> upgradeApp(AppUpgradeRequest request) async =>
      _authenticatedApps.upgrade(request);
  @override
  Future<AppOperationResult> uninstallApp(AppUninstallRequest request) async =>
      _authenticatedApps.uninstall(request);
  @override
  Future<AppOperationResult> pollAppJob(AppJob job) async =>
      _authenticatedApps.poll(job);

  @override
  SnapshotsCapabilities get snapshotsCapabilities =>
      _snapshots?.capabilities ?? const SnapshotsCapabilities.disconnected();

  _SessionSnapshots get _authenticatedSnapshots =>
      _snapshots ??
      (throw const SnapshotsException(
        SnapshotsExceptionReason.notAuthenticated,
      ));

  @override
  Future<List<SnapshotDataset>> loadSnapshotDatasets() async =>
      _authenticatedSnapshots.loadDatasets();
  @override
  Future<SnapshotPageResult> loadSnapshots(SnapshotQuery query) async =>
      _authenticatedSnapshots.load(query);
  @override
  Future<SnapshotOperationResult> createSnapshot(
    SnapshotCreateRequest request,
  ) async => _authenticatedSnapshots.create(request);
  @override
  Future<SnapshotOperationResult> deleteSnapshot(
    SnapshotDeleteRequest request,
  ) async => _authenticatedSnapshots.delete(request);
  @override
  Future<SnapshotRecoveryReview> reviewSnapshotRecovery(
    SnapshotRecoveryPlan plan,
  ) async => _authenticatedSnapshots.reviewRecovery(plan);
  @override
  Future<SnapshotOperationResult> applySnapshotRecovery(
    SnapshotRecoveryRequest request,
  ) async => _authenticatedSnapshots.applyRecovery(request);

  @override
  RealtimeCapabilities get realtimeCapabilities =>
      _realtime?.capabilities ??
      const RealtimeCapabilities(
        supported: false,
        blockedReason: 'Connect to a server to view live measurements.',
      );

  @override
  Future<RealtimeFeed> openRealtimeFeed() async {
    final realtime = _realtime;
    if (realtime == null) throw const RealtimeException();
    return realtime.open();
  }

  @override
  DatasetPropertiesCapabilities get datasetPropertiesCapabilities =>
      _datasetProperties?.capabilities ??
      const DatasetPropertiesCapabilities.disconnected();

  @override
  Future<List<DatasetPropertySnapshot>> loadDatasetProperties() async {
    final properties = _datasetProperties;
    if (properties == null) {
      throw const DatasetPropertiesException(
        DatasetPropertiesExceptionReason.notAuthenticated,
      );
    }
    return properties.load();
  }

  @override
  Future<DatasetPropertyResult> updateDatasetProperties(
    DatasetPropertyUpdate request,
  ) async {
    final properties = _datasetProperties;
    if (properties == null) {
      throw const DatasetPropertiesException(
        DatasetPropertiesExceptionReason.notAuthenticated,
      );
    }
    return properties.update(request);
  }

  @override
  ReportingCapabilities get reportingCapabilities =>
      _reporting?.capabilities ?? const ReportingCapabilities.disconnected();

  _SessionReporting get _authenticatedReporting =>
      _reporting ??
      (throw const ReportingException(
        ReportingExceptionReason.notAuthenticated,
      ));

  @override
  Future<List<ReportingGraph>> loadReportingGraphs() async =>
      _authenticatedReporting.graphs();

  @override
  Future<List<ReportingHistory>> loadReportingHistory(
    ReportingRequest request,
  ) async => _authenticatedReporting.history(request);

  @override
  NetworkCapabilities get networkCapabilities =>
      _network?.capabilities ?? const NetworkCapabilities.disconnected();

  _SessionNetwork get _authenticatedNetwork =>
      _network ??
      (throw const NetworkException(NetworkExceptionReason.notAuthenticated));

  @override
  Future<NetworkInventory> loadNetworkInventory() async =>
      _authenticatedNetwork.loadInventory();

  @override
  Future<NetworkChangeResult> beginNetworkTest(
    NetworkChangeRequest request,
  ) async => _authenticatedNetwork.begin(request);

  @override
  Future<NetworkChangeResult> checkNetworkTest(
    NetworkTransaction transaction,
  ) async => _authenticatedNetwork.check(transaction);

  @override
  Future<NetworkChangeResult> keepNetworkTest(
    NetworkTransaction transaction,
  ) async => _authenticatedNetwork.finish(transaction, keep: true);

  @override
  Future<NetworkChangeResult> revertNetworkTest(
    NetworkTransaction transaction,
  ) async => _authenticatedNetwork.finish(transaction, keep: false);

  @override
  AdminCatalog get adminCatalog =>
      _admin?.catalog ?? const AdminCatalog.disconnected();

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    final admin = _admin;
    if (admin == null) {
      throw const AdminException(AdminExceptionReason.notAuthenticated);
    }
    return admin.invoke(request);
  }

  @override
  Future<AdminResult> pollAdminJob(AdminJobSubmitted job) async {
    final admin = _admin;
    if (admin == null) {
      return AdminOutcomeUnknown(
        AdminRequest(method: job.request.method, arguments: const []),
        jobId: job.jobId,
      );
    }
    return admin.poll(job);
  }

  @override
  ManagementCapabilities get managementCapabilities =>
      _management?.capabilities ?? const ManagementCapabilities.disconnected();

  @override
  Future<ManagementResult> execute(ManagementCommand command) async {
    if (_nativeComputeBusy ||
        _activity?.isBusy == true ||
        _admin?.isBusy == true ||
        _network?.isBusy == true ||
        _datasetProperties?.isBusy == true ||
        _snapshots?.isBusy == true ||
        _apps?.isBusy == true) {
      throw const ManagementException(ManagementExceptionReason.busy);
    }
    final management = _management;
    if (management == null) {
      throw const ManagementException(
        ManagementExceptionReason.notAuthenticated,
      );
    }
    return management.execute(command);
  }

  @override
  Future<ManagementResult> pollJob(ManagementJobSubmitted job) async {
    final management = _management;
    if (management == null) {
      return ManagementOutcomeUnknown(job.command, jobId: job.jobId);
    }
    return management.pollJob(job);
  }

  static const readOnlyMethods = <String>{
    'system.info',
    'pool.query',
    'pool.dataset.query',
    'service.query',
    'alert.list',
    'core.get_jobs',
  };

  @override
  Future<Object?> query(String method) async {
    // Validate before obtaining the client or writing a frame. This is the
    // security boundary between dashboard code and JSON-RPC.
    if (!readOnlyMethods.contains(method)) throw const SessionQueryException();
    final client = _client;
    if (client == null || _management?.isCurrent() != true || !client.isOpen) {
      throw const SessionQueryException();
    }
    try {
      return await client.call(method, id: _id());
    } on Object {
      throw const SessionQueryException();
    }
  }

  @override
  Future<IscsiAuthInventory> loadIscsiAuthReferences() async {
    final management = _management;
    final client = _client;
    if (management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('iscsi.auth.query') ||
        client == null ||
        !client.isOpen) {
      throw const IscsiAuthException();
    }
    try {
      // Request only public references. A nonconforming response is projected
      // before it can cross the SDK boundary into the application.
      final raw = await client
          .call(
            'iscsi.auth.query',
            id: _id(),
            params: const [
              [],
              {
                'select': ['id', 'tag', 'user', 'peeruser', 'discovery_auth'],
                'limit': 101,
              },
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const IscsiAuthException();
      return IscsiAuthInventory.parse(raw, DateTime.now().toUtc());
    } on Object {
      throw const IscsiAuthException();
    }
  }

  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    final management = _management;
    final client = _client;
    if (management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('nvmet.host.query') ||
        !management.methods.contains('nvmet.host_subsys.query') ||
        client == null ||
        !client.isOpen) {
      throw const NvmeHostException();
    }
    try {
      final hosts = await client
          .call(
            'nvmet.host.query',
            id: _id(),
            params: const [
              [],
              {
                'select': ['id', 'hostnqn'],
                'limit': 101,
              },
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostException();
      final mappings = await client
          .call(
            'nvmet.host_subsys.query',
            id: _id(),
            params: const [
              [],
              {
                'select': ['id', 'host.id', 'subsys.id'],
                'limit': 101,
              },
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostException();
      return NvmeHostPublicRows.project(hosts, mappings);
    } on Object {
      throw const NvmeHostException();
    }
  }

  @override
  Future<NvmeHostAuthenticationChoices>
  loadNvmeHostAuthenticationChoices() async {
    final management = _management;
    final client = _client;
    if (management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('nvmet.host.dhchap_hash_choices') ||
        !management.methods.contains('nvmet.host.dhchap_dhgroup_choices') ||
        client == null ||
        !client.isOpen) {
      throw const NvmeHostChoicesException();
    }
    try {
      final hashes = await client
          .call('nvmet.host.dhchap_hash_choices', id: _id(), params: const [])
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostChoicesException();
      final groups = await client
          .call(
            'nvmet.host.dhchap_dhgroup_choices',
            id: _id(),
            params: const [],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostChoicesException();
      return NvmeHostAuthenticationChoices.project(hashes, groups);
    } on Object {
      throw const NvmeHostChoicesException();
    }
  }

  @override
  Future<NvmeGeneratedHostKey> generateNvmeHostKey({
    required String hash,
    String? nqn,
  }) async {
    final management = _management;
    final client = _client;
    final format = const {
      'SHA-256': '01',
      'SHA-384': '02',
      'SHA-512': '03',
    }[hash];
    bool current() =>
        management != null &&
        management.isCurrent() &&
        identical(client, _client) &&
        client != null &&
        client.isOpen;
    if (management == null ||
        management.version != _ManagementVersion.v2510 ||
        !current() ||
        format == null ||
        (nqn != null && !isSupportedNvmeHostNqn(nqn)) ||
        !management.methods.contains('nvmet.host.generate_key') ||
        !management.methods.contains('nvmet.host.dhchap_hash_choices')) {
      throw const NvmeHostKeyGenerationException();
    }
    try {
      final rawHashes = await client!
          .call('nvmet.host.dhchap_hash_choices', id: _id(), params: const [])
          .timeout(managementRequestTimeout);
      if (!current() ||
          !NvmeHostAuthenticationChoices.project(
            rawHashes,
            const [],
          ).hashes.contains(hash)) {
        throw const NvmeHostKeyGenerationException();
      }
      // Two positional arguments, including an explicit null NQN. No retry,
      // host query, persistence, registration, association or configuration edit.
      final raw = await client
          .call('nvmet.host.generate_key', id: _id(), params: [hash, nqn])
          .timeout(managementRequestTimeout);
      if (!current() || raw is! String || !raw.startsWith('DHHC-1:$format:')) {
        throw const NvmeHostKeyGenerationException();
      }
      final validation = NvmeHostKeyDraft.import(hostKey: raw);
      validation.dispose();
      final now = nvmeHostKeyNow ?? DateTime.now;
      final issuedAt = now();
      return NvmeGeneratedHostKey._(
        hash,
        nqn,
        Uint8List.fromList(ascii.encode(raw)),
        () {
          final age = now().difference(issuedAt);
          return current() &&
              !age.isNegative &&
              age < const Duration(minutes: 5);
        },
      );
    } on Object {
      throw const NvmeHostKeyGenerationException();
    }
  }

  @override
  Future<NvmeHostAuthentication> loadNvmeHostAuthenticationTarget(
    int id,
  ) async {
    final management = _management;
    final client = _client;
    if (id <= 0 ||
        management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('nvmet.host.query') ||
        client == null ||
        !client.isOpen) {
      throw const NvmeHostException();
    }
    try {
      final raw = await client
          .call(
            'nvmet.host.query',
            id: _id(),
            params: [
              [
                ['id', '=', id],
              ],
              {
                'select': [
                  'id',
                  'hostnqn',
                  'dhchap_key',
                  'dhchap_ctrl_key',
                  'dhchap_dhgroup',
                  'dhchap_hash',
                ],
                'limit': 2,
              },
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent() || raw is! List || raw.length != 1) {
        throw const NvmeHostException();
      }
      final target = NvmeHostAuthenticationInventory.project(raw).hosts.single;
      if (target.id != id) throw const NvmeHostException();
      return target;
    } on Object {
      throw const NvmeHostException();
    }
  }

  @override
  Future<NvmeHostAuthentication> clearNvmeHostAuthentication({
    required NvmeHostAuthentication expected,
  }) async {
    final management = _management;
    final client = _client;
    if (expected.id <= 0 ||
        !isSupportedNvmeHostNqn(expected.nqn) ||
        !expected.hasReturnedAuthentication ||
        management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('nvmet.host.update') ||
        client == null ||
        !client.isOpen) {
      throw const NvmeHostException();
    }
    try {
      final before = await loadNvmeHostAuthenticationTarget(expected.id);
      if (!management.isCurrent() || !before.sameReturnedSettings(expected)) {
        throw const NvmeHostException();
      }
      final raw = await client
          .call(
            'nvmet.host.update',
            id: _id(),
            params: [
              expected.id,
              {
                'dhchap_key': null,
                'dhchap_ctrl_key': null,
                'dhchap_dhgroup': null,
              },
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostException();
      final result = NvmeHostAuthenticationInventory.project([raw])
          .hosts
          .single;
      if (result.id != expected.id ||
          result.nqn != expected.nqn ||
          result.hash != expected.hash ||
          result.hasReturnedAuthentication) {
        throw const NvmeHostException();
      }
      return result;
    } on Object {
      throw const NvmeHostException();
    }
  }

  @override
  Future<NvmeHostAuthenticationInventory> loadNvmeHostAuthentication() async {
    final management = _management;
    final client = _client;
    if (management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('nvmet.host.query') ||
        client == null ||
        !client.isOpen) {
      throw const NvmeHostException();
    }
    try {
      final raw = await client
          .call(
            'nvmet.host.query',
            id: _id(),
            params: const [
              [],
              {
                'select': [
                  'id',
                  'hostnqn',
                  'dhchap_key',
                  'dhchap_ctrl_key',
                  'dhchap_dhgroup',
                  'dhchap_hash',
                ],
                'limit': 101,
              },
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostException();
      return NvmeHostAuthenticationInventory.project(raw);
    } on Object {
      throw const NvmeHostException();
    }
  }

  _SessionManagement _nvmeKeyReplacementSession() {
    final management = _management;
    if (management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        _client?.isOpen != true ||
        ![
          'nvmet.host.query',
          'nvmet.host_subsys.query',
          'nvmet.host.update',
          'nvmet.host.dhchap_hash_choices',
          'nvmet.host.dhchap_dhgroup_choices',
        ].every(management.methods.contains)) {
      throw const NvmeHostException();
    }
    return management;
  }

  Future<Object?> _nvmeKeyReplacementTarget(
    int id,
    _SessionManagement management,
  ) async {
    if (!management.isCurrent() ||
        !identical(_management, management) ||
        _client?.isOpen != true) {
      throw const NvmeHostException();
    }
    final raw = await _client!
        .call(
          'nvmet.host.query',
          id: _id(),
          params: [
            [
              ['id', '=', id],
            ],
            {
              'select': [
                'id',
                'hostnqn',
                'dhchap_key',
                'dhchap_ctrl_key',
                'dhchap_hash',
                'dhchap_dhgroup',
              ],
              'limit': 2,
            },
          ],
        )
        .timeout(managementRequestTimeout);
    if (!management.isCurrent() ||
        raw is! List ||
        raw.length != 1 ||
        NvmeHostAuthenticationInventory.project(raw).hosts.single.id != id) {
      throw const NvmeHostException();
    }
    return raw.single;
  }

  String _nvmeUnassociatedReferenceProof(
    NvmeHostPublicRows rows,
    NvmeHostAuthentication target,
  ) {
    if (rows.hosts
                .where(
                  (h) => h['id'] == target.id && h['hostnqn'] == target.nqn,
                )
                .length !=
            1 ||
        rows.hosts
                .where(
                  (h) =>
                      (h['hostnqn'] as String).toLowerCase() ==
                      target.nqn.toLowerCase(),
                )
                .length !=
            1 ||
        rows.mappings.any((m) => (m['host'] as Map)['id'] == target.id)) {
      throw const NvmeHostException();
    }
    return _nvmeHostReferenceProof(rows);
  }

  @override
  Future<NvmeHostKeyReplacementReview> reviewNvmeHostKeyReplacement(
    int id,
  ) async {
    Uint8List? salt, digest;
    var retained = false;
    try {
      if (id <= 0) throw const NvmeHostException();
      final management = _nvmeKeyReplacementSession();
      final before = await loadNvmeHostReferences();
      final raw = await _nvmeKeyReplacementTarget(id, management);
      final target = NvmeHostAuthenticationInventory.project([raw])
          .hosts
          .single;
      if (target.inconsistent) throw const NvmeHostException();
      final proof = _nvmeUnassociatedReferenceProof(before, target);
      final after = await loadNvmeHostReferences();
      if (!management.isCurrent() ||
          _nvmeUnassociatedReferenceProof(after, target) != proof) {
        throw const NvmeHostException();
      }
      final random = math.Random.secure();
      salt = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
      digest = _nvmeCredentialProof(raw, salt);
      final review = NvmeHostKeyReplacementReview._(
        target,
        (nvmeHostKeyNow ?? DateTime.now)().toUtc(),
        management,
        proof,
        salt,
        digest,
      );
      retained = true;
      return review;
    } on Object {
      throw const NvmeHostException();
    } finally {
      if (!retained) {
        salt?.fillRange(0, salt.length, 0);
        digest?.fillRange(0, digest.length, 0);
      }
    }
  }

  @override
  Future<NvmeHostAuthentication> replaceNvmeHostImportedKeys({
    required NvmeHostKeyReplacementReview review,
    required String hash,
    required String? group,
    required NvmeHostKeyDraft keys,
  }) async {
    var ownsKeys = false, ownsReview = false;
    try {
      keys._claim();
      ownsKeys = true;
      final management = _nvmeKeyReplacementSession();
      if (!identical(review._owner, management)) {
        throw const NvmeHostException();
      }
      review._claim();
      ownsReview = true;
      void guardReview() {
        final now = (nvmeHostKeyNow ?? DateTime.now)().toUtc();
        if (!management.isCurrent() ||
            review.isDisposed ||
            keys.isDisposed ||
            now.isBefore(review.issuedAt) ||
            now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
          throw const NvmeHostException();
        }
      }

      guardReview();
      if (!const {'SHA-256', 'SHA-384', 'SHA-512'}.contains(hash) ||
          (group != null &&
              !const {
                '2048-BIT',
                '3072-BIT',
                '4096-BIT',
                '6144-BIT',
                '8192-BIT',
              }.contains(group))) {
        throw const NvmeHostException();
      }
      final choices = await loadNvmeHostAuthenticationChoices();
      guardReview();
      if (!choices.hashes.contains(hash) ||
          (group != null && !choices.groups.contains(group))) {
        throw const NvmeHostException();
      }
      final before = await loadNvmeHostReferences();
      guardReview();
      if (_nvmeUnassociatedReferenceProof(before, review.target) !=
          review._references) {
        throw const NvmeHostException();
      }
      final old = await _nvmeKeyReplacementTarget(review.target.id, management);
      guardReview();
      final oldDigest = _nvmeCredentialProof(old, review._salt!);
      try {
        if (!_nvmeSameDigest(oldDigest, review._digest!)) {
          throw const NvmeHostException();
        }
      } finally {
        oldDigest.fillRange(0, oldDigest.length, 0);
      }
      // Reread mappings immediately before sending; reads are still non-atomic.
      final latest = await loadNvmeHostReferences();
      guardReview();
      if (_nvmeUnassociatedReferenceProof(latest, review.target) !=
          review._references) {
        throw const NvmeHostException();
      }
      final raw = await _client!
          .call(
            'nvmet.host.update',
            id: _id(),
            params: [
              review.target.id,
              {
                'dhchap_key': keys._hostText,
                'dhchap_ctrl_key': keys._controllerText,
                'dhchap_hash': hash,
                'dhchap_dhgroup': group,
              },
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostException();
      NvmeHostAuthentication verify(Object? row) {
        final result = NvmeHostAuthenticationInventory.project([row])
            .hosts
            .single;
        if (row is! Map ||
            result.id != review.target.id ||
            result.nqn != review.target.nqn ||
            result.hash != hash ||
            result.group != group ||
            row['dhchap_key'] != keys._hostText ||
            row['dhchap_ctrl_key'] != keys._controllerText) {
          throw const NvmeHostException();
        }
        return result;
      }

      verify(raw);
      final confirmed = verify(
        await _nvmeKeyReplacementTarget(review.target.id, management),
      );
      final after = await loadNvmeHostReferences();
      if (!management.isCurrent() ||
          _nvmeUnassociatedReferenceProof(after, confirmed) !=
              review._references) {
        throw const NvmeHostException();
      }
      return confirmed;
    } on Object {
      throw const NvmeHostException();
    } finally {
      if (ownsKeys) keys.dispose();
      if (ownsReview) review.dispose();
    }
  }

  @override
  Future<NvmeHostAuthentication> createNvmeHostWithImportedKeys({
    required String hostNqn,
    required String hash,
    required String? group,
    required NvmeHostKeyDraft keys,
  }) async {
    var ownsDraft = false;
    try {
      keys._claim();
      ownsDraft = true;
      final management = _management;
      final client = _client;
      if (!isSupportedNvmeHostNqn(hostNqn) ||
          !const {'SHA-256', 'SHA-384', 'SHA-512'}.contains(hash) ||
          (group != null &&
              !const {
                '2048-BIT',
                '3072-BIT',
                '4096-BIT',
                '6144-BIT',
                '8192-BIT',
              }.contains(group)) ||
          management == null ||
          management.version != _ManagementVersion.v2510 ||
          !management.isCurrent() ||
          !management.methods.contains('nvmet.host.create') ||
          client == null ||
          !client.isOpen) {
        throw const NvmeHostException();
      }
      final choices = await loadNvmeHostAuthenticationChoices();
      if (!management.isCurrent() ||
          !choices.hashes.contains(hash) ||
          (group != null && !choices.groups.contains(group))) {
        throw const NvmeHostException();
      }
      final before = await loadNvmeHostReferences();
      if (!management.isCurrent() ||
          before.hosts.length >= 99 ||
          before.hosts.any(
            (h) =>
                (h['hostnqn'] as String).toLowerCase() == hostNqn.toLowerCase(),
          )) {
        throw const NvmeHostException();
      }
      final proof = _nvmeHostReferenceProof(before);
      final raw = await client
          .call(
            'nvmet.host.create',
            id: _id(),
            params: [
              {
                'hostnqn': hostNqn,
                'dhchap_key': keys._hostText,
                'dhchap_ctrl_key': keys._controllerText,
                'dhchap_hash': hash,
                'dhchap_dhgroup': group,
              },
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostException();
      NvmeHostAuthentication verify(Object? row) {
        final projected = NvmeHostAuthenticationInventory.project([row])
            .hosts
            .single;
        if (row is! Map ||
            projected.nqn != hostNqn ||
            projected.hash != hash ||
            projected.group != group ||
            row['dhchap_key'] != keys._hostText ||
            row['dhchap_ctrl_key'] != keys._controllerText) {
          throw const NvmeHostException();
        }
        return projected;
      }

      final created = verify(raw);
      if (before.hosts.any((h) => h['id'] == created.id)) {
        throw const NvmeHostException();
      }
      final reread = await client
          .call(
            'nvmet.host.query',
            id: _id(),
            params: [
              [
                ['id', '=', created.id],
              ],
              {
                'select': [
                  'id',
                  'hostnqn',
                  'dhchap_key',
                  'dhchap_ctrl_key',
                  'dhchap_hash',
                  'dhchap_dhgroup',
                ],
                'limit': 2,
              },
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent() || reread is! List || reread.length != 1) {
        throw const NvmeHostException();
      }
      final confirmed = verify(reread.single);
      if (confirmed.id != created.id) throw const NvmeHostException();
      final after = await loadNvmeHostReferences();
      if (!management.isCurrent() ||
          after.hosts.length != before.hosts.length + 1 ||
          after.hosts
                  .where(
                    (h) => h['id'] == created.id && h['hostnqn'] == hostNqn,
                  )
                  .length !=
              1 ||
          after.mappings.any((m) => (m['host'] as Map)['id'] == created.id) ||
          _nvmeHostReferenceProof(after, omitHost: created.id) != proof) {
        throw const NvmeHostException();
      }
      return confirmed;
    } on Object {
      throw const NvmeHostException();
    } finally {
      if (ownsDraft) keys.dispose();
    }
  }

  @override
  Future<NvmeHostCreated> createUnassociatedNvmeHost({
    required String hostNqn,
  }) async {
    final management = _management;
    final client = _client;
    if (!isSupportedNvmeHostNqn(hostNqn) ||
        management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('nvmet.host.create') ||
        client == null ||
        !client.isOpen) {
      throw const NvmeHostException();
    }
    try {
      final raw = await client
          .call(
            'nvmet.host.create',
            id: _id(),
            params: [
              {
                'hostnqn': hostNqn,
                'dhchap_key': null,
                'dhchap_ctrl_key': null,
                'dhchap_dhgroup': null,
              },
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostException();
      return NvmeHostCreated.project(raw);
    } on Object {
      throw const NvmeHostException();
    }
  }

  @override
  Future<NvmeUncredentialedHost> loadUncredentialedNvmeHost(int id) async {
    final management = _management;
    final client = _client;
    if (id <= 0 ||
        management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('nvmet.host.query') ||
        client == null ||
        !client.isOpen) {
      throw const NvmeHostException();
    }
    try {
      final raw = await client
          .call(
            'nvmet.host.query',
            id: _id(),
            params: [
              [
                ['id', '=', id],
              ],
              {
                'select': [
                  'id',
                  'hostnqn',
                  'dhchap_key',
                  'dhchap_ctrl_key',
                  'dhchap_dhgroup',
                  'dhchap_hash',
                ],
                'limit': 2,
              },
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent() || raw is! List || raw.length != 1) {
        throw const NvmeHostException();
      }
      final result = NvmeUncredentialedHost.project(raw.single);
      if (result.id != id) throw const NvmeHostException();
      return result;
    } on Object {
      throw const NvmeHostException();
    }
  }

  @override
  Future<NvmeUncredentialedHost> renameUncredentialedNvmeHost({
    required int id,
    required String expectedNqn,
    required String expectedHash,
    required String newNqn,
  }) async {
    final management = _management;
    final client = _client;
    if (id <= 0 ||
        !isSupportedNvmeHostNqn(expectedNqn) ||
        !isSupportedNvmeHostNqn(newNqn) ||
        expectedNqn == newNqn ||
        !const {'SHA-256', 'SHA-384', 'SHA-512'}.contains(expectedHash) ||
        management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('nvmet.host.update') ||
        client == null ||
        !client.isOpen) {
      throw const NvmeHostException();
    }
    try {
      final before = await loadUncredentialedNvmeHost(id);
      if (!management.isCurrent() ||
          before.nqn != expectedNqn ||
          before.hash != expectedHash) {
        throw const NvmeHostException();
      }
      final raw = await client
          .call(
            'nvmet.host.update',
            id: _id(),
            params: [
              id,
              {'hostnqn': newNqn},
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostException();
      final result = NvmeUncredentialedHost.project(raw);
      if (result.id != id ||
          result.nqn != newNqn ||
          result.hash != expectedHash) {
        throw const NvmeHostException();
      }
      return result;
    } on Object {
      throw const NvmeHostException();
    }
  }

  @override
  Future<NvmeUncredentialedHost> changeUncredentialedNvmeHostHash({
    required int id,
    required String expectedNqn,
    required String expectedHash,
    required String newHash,
  }) async {
    final management = _management;
    final client = _client;
    if (id <= 0 ||
        !isSupportedNvmeHostNqn(expectedNqn) ||
        !const {'SHA-256', 'SHA-384', 'SHA-512'}.contains(expectedHash) ||
        !const {'SHA-256', 'SHA-384', 'SHA-512'}.contains(newHash) ||
        expectedHash == newHash ||
        management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('nvmet.host.update') ||
        client == null ||
        !client.isOpen) {
      throw const NvmeHostException();
    }
    try {
      final choices = await loadNvmeHostAuthenticationChoices();
      if (!management.isCurrent() || !choices.hashes.contains(newHash)) {
        throw const NvmeHostException();
      }
      final before = await loadUncredentialedNvmeHost(id);
      if (!management.isCurrent() ||
          before.nqn != expectedNqn ||
          before.hash != expectedHash) {
        throw const NvmeHostException();
      }
      final raw = await client
          .call(
            'nvmet.host.update',
            id: _id(),
            params: [
              id,
              {'dhchap_hash': newHash},
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostException();
      final result = NvmeUncredentialedHost.project(raw);
      if (result.id != id ||
          result.nqn != expectedNqn ||
          result.hash != newHash) {
        throw const NvmeHostException();
      }
      return result;
    } on Object {
      throw const NvmeHostException();
    }
  }

  @override
  Future<NvmeHostAssociationCreated> createNvmeHostAssociation({
    required int hostId,
    required int subsystemId,
  }) async {
    final management = _management;
    final client = _client;
    if (hostId <= 0 ||
        subsystemId <= 0 ||
        management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('nvmet.host_subsys.create') ||
        client == null ||
        !client.isOpen) {
      throw const NvmeHostException();
    }
    try {
      final raw = await client
          .call(
            'nvmet.host_subsys.create',
            id: _id(),
            params: [
              {'host_id': hostId, 'subsys_id': subsystemId},
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostException();
      return NvmeHostAssociationCreated.project(raw);
    } on Object {
      throw const NvmeHostException();
    }
  }

  @override
  Future<NvmePortAssociationCreated> createNvmePortAssociation({
    required int portId,
    required int subsystemId,
  }) async {
    final management = _management;
    final client = _client;
    if (portId <= 0 ||
        subsystemId <= 0 ||
        management == null ||
        management.version != _ManagementVersion.v2510 ||
        !management.isCurrent() ||
        !management.methods.contains('nvmet.port_subsys.create') ||
        client == null ||
        !client.isOpen) {
      throw const NvmeHostException();
    }
    try {
      final raw = await client
          .call(
            'nvmet.port_subsys.create',
            id: _id(),
            params: [
              {'port_id': portId, 'subsys_id': subsystemId},
            ],
          )
          .timeout(managementRequestTimeout);
      if (!management.isCurrent()) throw const NvmeHostException();
      return NvmePortAssociationCreated.project(raw);
    } on Object {
      throw const NvmeHostException();
    }
  }

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => _connect(
    serverInput: serverInput,
    apiKey: apiKey,
    username: username,
    rememberApiKey: rememberApiKey,
    isConnectionCurrent: isConnectionCurrent,
  );

  @override
  Future<ServerSummary> connectWithPassword({
    required String serverInput,
    required String password,
    required String username,
    PasswordOtpResponder? onOtpRequired,
    bool Function()? isConnectionCurrent,
  }) => _connect(
    serverInput: serverInput,
    apiKey: null,
    username: username,
    password: password,
    onOtpRequired: onOtpRequired,
    isConnectionCurrent: isConnectionCurrent,
  );

  Future<ServerSummary> _connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    String? password,
    PasswordOtpResponder? onOtpRequired,
    bool Function()? isConnectionCurrent,
  }) async {
    final generation = ++_connectionGeneration;
    final previousClient = _client;
    final previousRealtime = _realtime;
    _realtime = null;
    _datasetProperties = null;
    _snapshots = null;
    _apps = null;
    _activity = null;
    _accounts = null;
    _virtualMachines = null;
    _zvols = null;
    _bootEnvironments = null;
    _permissions = null;
    _quotas = null;
    _snapshotSchedules = null;
    _smbShares = null;
    _nfsShares = null;
    _systemUpdates = null;
    _replication = null;
    _cloudSync = null;
    _apiKeys = null;
    _cloudCredentials = null;
    _alerts = null;
    _sshCredentials = null;
    _disks = null;
    _poolMaintenance = null;
    _rsync = null;
    _systemPower = null;
    _configurationBackup = null;
    _configurationRestore?.dispose();
    _configurationRestore = null;
    _configurationReset = null;
    _timeSettings = null;
    _emailSettings?.dispose();
    _emailSettings = null;
    _auditSettings?.dispose();
    _auditSettings = null;
    _auditExport?.dispose();
    _auditExport = null;
    _alertSettings = null;
    _alertPolicies = null;
    _notificationProviders?.dispose();
    _notificationProviders = null;
    _smbSettings?.dispose();
    _smbSettings = null;
    _nfsSettings?.dispose();
    _nfsSettings = null;
    _cronTasks?.dispose();
    _directoryIdmap?.dispose();
    _directoryIdmap = null;
    _cronTasks = null;
    _initShutdownTasks?.dispose();
    _initShutdownTasks = null;
    _client = null;
    _management = null;
    _admin = null;
    _network = null;
    _reporting = null;
    await previousRealtime?.close();
    await previousClient?.close();
    final externalIsCurrent = isConnectionCurrent;
    isConnectionCurrent = () =>
        generation == _connectionGeneration &&
        (externalIsCurrent?.call() ?? true);
    final endpoint = ValidatedEndpoint.parse(serverInput);
    // `auth.login_ex` binds an API key to the account that owns it, so the
    // account name is part of the credential, not an optional hint.
    final account = validateTrueNasAccountName(username);
    if (password != null) validateTrueNasPassword(password);
    RpcTransport? connectedTransport;
    JsonRpcClient? client;
    try {
      connectedTransport = await _connector.connect(endpoint.connectionUri);
      client = _clientFactory(connectedTransport);
      _requireCurrent(isConnectionCurrent);
      _client = client;
      final explicitKey = password == null && apiKey?.isNotEmpty == true
          ? apiKey
          : null;
      if (password != null) {
        await _passwordLogin(
          client: client,
          nextId: _id,
          requireCurrent: () => _requireCurrent(isConnectionCurrent),
          endpoint: endpoint.connectionUri.toString(),
          username: account,
          password: password,
          requestTimeout: authenticationRequestTimeout,
          challengeTimeout: otpChallengeTimeout,
          responder: onOtpRequired,
        );
      } else {
        final key =
            explicitKey ??
            await _readRememberedKey(
              endpoint.connectionUri.toString(),
              isConnectionCurrent,
            );
        _requireCurrent(isConnectionCurrent);
        if (key == null || key.isEmpty) {
          throw const CredentialUnavailableException(
            CredentialUnavailableReason.missing,
          );
        }
        final login = await client.call(
          'auth.login_ex',
          id: _id(),
          params: [
            <String, Object?>{
              'mechanism': 'API_KEY_PLAIN',
              'username': account,
              'api_key': key,
            },
          ],
        );
        _requireSuccess(login);
      }
      _requireCurrent(isConnectionCurrent);
      final me = await client
          .call('auth.me', id: _id())
          .timeout(authenticationRequestTimeout);
      _requireCurrent(isConnectionCurrent);
      final info = await client
          .call('system.info', id: _id())
          .timeout(authenticationRequestTimeout);
      _requireCurrent(isConnectionCurrent);
      if (password != null &&
          _managementVersion(_version(info)) != _ManagementVersion.v2510) {
        throw const PasswordLoginException(PasswordLoginFailure.unsupported);
      }
      final methods = await client
          .call('core.get_methods', id: _id())
          .timeout(authenticationRequestTimeout);
      _requireCurrent(isConnectionCurrent);
      final summary = ServerSummary(
        originalHostInput: endpoint.originalInput,
        endpointUri: endpoint.connectionUri,
        identity: _identity(me),
        version: _version(info),
        availableMethodNames: _methods(methods),
      );
      if (rememberApiKey && explicitKey != null) {
        await _writeRememberedKey(
          endpoint.connectionUri.toString(),
          explicitKey,
          isConnectionCurrent,
        );
        // A successful vault write is the credential commit point. Do not let
        // a later cancellable callback report a failed connection after the
        // vault can no longer compensate the persisted replacement.
        if (generation == _connectionGeneration && identical(_client, client)) {
          _enableManagement(
            client,
            summary,
            generation,
            methods,
            connectedTransport,
            isConnectionCurrent,
          );
        }
        return summary;
      }
      _requireCurrent(isConnectionCurrent);
      _enableManagement(
        client,
        summary,
        generation,
        methods,
        connectedTransport,
        isConnectionCurrent,
      );
      return summary;
    } catch (error) {
      if (identical(_client, client)) _client = null;
      try {
        if (client != null) {
          await client.close();
        } else {
          await connectedTransport?.close();
        }
      } catch (_) {
        // The connection error remains the actionable failure.
      }
      if (error is TlsHandshakeException) {
        throw const TlsCertificateException();
      }
      if (password != null && error is TimeoutException) {
        throw const PasswordLoginException(PasswordLoginFailure.timeout);
      }
      if (password != null &&
          (error is JsonRpcRemoteException ||
              error is JsonRpcProtocolException)) {
        throw const PasswordLoginException(PasswordLoginFailure.unsupported);
      }
      rethrow;
    }
  }

  void _enableManagement(
    JsonRpcClient client,
    ServerSummary summary,
    int generation,
    Object? methodsMetadata,
    RpcTransport transport,
    bool Function() externalIsCurrent,
  ) {
    bool current() {
      if (generation != _connectionGeneration ||
          !identical(_client, client) ||
          !client.isOpen) {
        return false;
      }
      try {
        return externalIsCurrent() &&
            generation == _connectionGeneration &&
            identical(_client, client) &&
            client.isOpen;
      } on Object {
        return false;
      }
    }

    _management = _SessionManagement(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
    );
    _admin = _SessionAdmin(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      isOtherBusy: () =>
          _nativeComputeBusy ||
          _activity?.isBusy == true ||
          _management?.isBusy == true ||
          _network?.isBusy == true ||
          _datasetProperties?.isBusy == true ||
          _snapshots?.isBusy == true ||
          _apps?.isBusy == true,
      requestTimeout: managementRequestTimeout,
    );
    _network = _SessionNetwork(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      isOtherBusy: () =>
          _nativeComputeBusy ||
          _activity?.isBusy == true ||
          _management?.isBusy == true ||
          _admin?.isBusy == true ||
          _datasetProperties?.isBusy == true ||
          _snapshots?.isBusy == true ||
          _apps?.isBusy == true,
      requestTimeout: managementRequestTimeout,
    );
    _reporting = _SessionReporting(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
    );
    _realtime = _SessionRealtime(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
    );
    _datasetProperties = _SessionDatasetProperties(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      isOtherMutationBusy: () =>
          _nativeComputeBusy ||
          _activity?.isBusy == true ||
          _management?.isBusy == true ||
          _admin?.isBusy == true ||
          _network?.isBusy == true ||
          _snapshots?.isBusy == true ||
          _apps?.isBusy == true,
      requestTimeout: managementRequestTimeout,
    );
    _snapshots = _SessionSnapshots(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      isOtherBusy: () =>
          _nativeComputeBusy ||
          _activity?.isBusy == true ||
          _management?.isBusy == true ||
          _admin?.isBusy == true ||
          _network?.isBusy == true ||
          _datasetProperties?.isBusy == true ||
          _apps?.isBusy == true,
      requestTimeout: managementRequestTimeout,
    );
    _apps = _SessionApps(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      isOtherBusy: () =>
          _nativeComputeBusy ||
          _activity?.isBusy == true ||
          _management?.isBusy == true ||
          _admin?.isBusy == true ||
          _network?.isBusy == true ||
          _datasetProperties?.isBusy == true ||
          _snapshots?.isBusy == true,
      requestTimeout: managementRequestTimeout,
    );
    _activity = _SessionActivity(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherBusy: () =>
          _nativeComputeBusy ||
          _management?.isBusy == true ||
          _admin?.isBusy == true ||
          _network?.isBusy == true ||
          _datasetProperties?.isBusy == true ||
          _snapshots?.isBusy == true ||
          _apps?.isBusy == true,
    );
    _accounts = _SessionAccounts(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherBusy: () =>
          _nativeStorageBusy ||
          _virtualMachines?.isBusy == true ||
          _activity?.isBusy == true ||
          _management?.isBusy == true ||
          _admin?.isBusy == true ||
          _network?.isBusy == true ||
          _datasetProperties?.isBusy == true ||
          _snapshots?.isBusy == true ||
          _apps?.isBusy == true,
    );
    _virtualMachines = _SessionVirtualMachines(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherBusy: () =>
          _nativeStorageBusy ||
          _accounts?.isBusy == true ||
          _activity?.isBusy == true ||
          _management?.isBusy == true ||
          _admin?.isBusy == true ||
          _network?.isBusy == true ||
          _datasetProperties?.isBusy == true ||
          _snapshots?.isBusy == true ||
          _apps?.isBusy == true,
    );
    bool otherStorageBusy() =>
        _accounts?.isBusy == true ||
        _virtualMachines?.isBusy == true ||
        _activity?.isBusy == true ||
        _management?.isBusy == true ||
        _admin?.isBusy == true ||
        _network?.isBusy == true ||
        _datasetProperties?.isBusy == true ||
        _snapshots?.isBusy == true ||
        _apps?.isBusy == true;
    _zvols = _SessionZvols(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherBusy: () =>
          _nativeAuxBusy ||
          _nativeSharesBusy ||
          otherStorageBusy() ||
          _quotas?.isBusy == true ||
          _snapshotSchedules?.isBusy == true ||
          _bootEnvironments?.isBusy == true ||
          _permissions?.isBusy == true,
    );
    _bootEnvironments = _SessionBootEnvironments(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherMutationBusy: () =>
          _nativeAuxBusy ||
          _nativeSharesBusy ||
          otherStorageBusy() ||
          _quotas?.isBusy == true ||
          _snapshotSchedules?.isBusy == true ||
          _zvols?.isBusy == true ||
          _permissions?.isBusy == true,
    );
    _permissions = _SessionPermissions(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherBusy: () =>
          _nativeAuxBusy ||
          _nativeSharesBusy ||
          otherStorageBusy() ||
          _quotas?.isBusy == true ||
          _snapshotSchedules?.isBusy == true ||
          _zvols?.isBusy == true ||
          _bootEnvironments?.isBusy == true,
    );
    _quotas = _SessionQuotas(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherBusy: () =>
          _nativeAuxBusy ||
          _nativeSharesBusy ||
          otherStorageBusy() ||
          _zvols?.isBusy == true ||
          _bootEnvironments?.isBusy == true ||
          _permissions?.isBusy == true ||
          _snapshotSchedules?.isBusy == true,
    );
    _snapshotSchedules = _SessionSnapshotSchedules(
      client: client,
      summary: summary,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherBusy: () =>
          _nativeAuxBusy ||
          _nativeSharesBusy ||
          otherStorageBusy() ||
          _zvols?.isBusy == true ||
          _bootEnvironments?.isBusy == true ||
          _permissions?.isBusy == true ||
          _quotas?.isBusy == true,
    );
    bool existingStorageBusy() =>
        otherStorageBusy() ||
        _zvols?.isBusy == true ||
        _bootEnvironments?.isBusy == true ||
        _permissions?.isBusy == true ||
        _quotas?.isBusy == true ||
        _snapshotSchedules?.isBusy == true;
    _smbShares = _SessionSmbShares(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherBusy: () =>
          _nativeAuxBusy || existingStorageBusy() || _nfsShares?.isBusy == true,
    );
    _nfsShares = _SessionNfsShares(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherBusy: () =>
          _nativeAuxBusy || existingStorageBusy() || _smbShares?.isBusy == true,
    );
    _systemUpdates = _SessionSystemUpdates(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherMutationBusy: () =>
          _nativeMaintenanceBusy ||
          _alerts?.isBusy == true ||
          _nativeCredentialBusy ||
          existingStorageBusy() ||
          _nativeSharesBusy ||
          _replication?.isBusy == true ||
          _cloudSync?.isBusy == true,
    );
    _replication = _SessionReplication(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherMutationBusy: () =>
          _nativeMaintenanceBusy ||
          _alerts?.isBusy == true ||
          _nativeCredentialBusy ||
          existingStorageBusy() ||
          _nativeSharesBusy ||
          _systemUpdates?.isBusy == true ||
          _cloudSync?.isBusy == true,
    );
    _cloudSync = _SessionCloudSync(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherMutationBusy: () =>
          _nativeMaintenanceBusy ||
          _alerts?.isBusy == true ||
          _nativeCredentialBusy ||
          existingStorageBusy() ||
          _nativeSharesBusy ||
          _systemUpdates?.isBusy == true ||
          _replication?.isBusy == true,
    );
    _apiKeys = _SessionApiKeys(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherMutationBusy: () =>
          _nativeMaintenanceBusy ||
          _sshCredentials?.isBusy == true ||
          _alerts?.isBusy == true ||
          _cloudCredentials?.isBusy == true ||
          existingStorageBusy() ||
          _nativeSharesBusy ||
          _systemUpdates?.isBusy == true ||
          _replication?.isBusy == true ||
          _cloudSync?.isBusy == true,
    );
    _cloudCredentials = _SessionCloudCredentials(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherMutationBusy: () =>
          _nativeMaintenanceBusy ||
          _sshCredentials?.isBusy == true ||
          _alerts?.isBusy == true ||
          _apiKeys?.isBusy == true ||
          existingStorageBusy() ||
          _nativeSharesBusy ||
          _systemUpdates?.isBusy == true ||
          _replication?.isBusy == true ||
          _cloudSync?.isBusy == true,
    );
    _sshCredentials = _SessionSshCredentials(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherMutationBusy: () =>
          _nativeMaintenanceBusy ||
          _apiKeys?.isBusy == true ||
          _cloudCredentials?.isBusy == true ||
          _alerts?.isBusy == true ||
          existingStorageBusy() ||
          _nativeSharesBusy ||
          _systemUpdates?.isBusy == true ||
          _replication?.isBusy == true ||
          _cloudSync?.isBusy == true,
    );
    _alerts = _SessionAlerts(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherMutationBusy: () =>
          _nativeMaintenanceBusy ||
          _nativeCredentialBusy ||
          existingStorageBusy() ||
          _nativeSharesBusy ||
          _systemUpdates?.isBusy == true ||
          _replication?.isBusy == true ||
          _cloudSync?.isBusy == true,
    );
    bool existingMaintenancePeersBusy({
      bool includeTime = true,
      bool includeEmail = true,
      bool includeAlertSettings = true,
      bool includeAlertPolicies = true,
      bool includeNotificationProviders = true,
      bool includeSmbSettings = true,
      bool includeNfsSettings = true,
      bool includeCronTasks = true,
      bool includeInitShutdownTasks = true,
      bool includeAuditSettings = true,
      bool includeAuditExport = true,
    }) =>
        _directoryIdmap?.isBusy == true ||
        includeAuditExport && _auditExport?.isBusy == true ||
        includeAuditSettings && _auditSettings?.isBusy == true ||
        includeCronTasks && _cronTasks?.isBusy == true ||
        includeInitShutdownTasks && _initShutdownTasks?.isBusy == true ||
        includeSmbSettings && _smbSettings?.isBusy == true ||
        includeNfsSettings && _nfsSettings?.isBusy == true ||
        includeAlertPolicies && _alertPolicies?.isBusy == true ||
        includeNotificationProviders &&
            _notificationProviders?.isBusy == true ||
        includeAlertSettings && _alertSettings?.isBusy == true ||
        includeEmail && _emailSettings?.isBusy == true ||
        includeTime && _timeSettings?.isBusy == true ||
        existingStorageBusy() ||
        _nativeSharesBusy ||
        _nativeCredentialBusy ||
        _alerts?.isBusy == true ||
        _systemUpdates?.isBusy == true ||
        _replication?.isBusy == true ||
        _cloudSync?.isBusy == true;
    _disks = _SessionDisks(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy() ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true ||
          _systemPower?.isBusy == true,
    );
    _poolMaintenance = _SessionPoolMaintenance(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy() ||
          _disks?.isBusy == true ||
          _rsync?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true ||
          _systemPower?.isBusy == true,
    );
    _rsync = _SessionRsync(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy() ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true ||
          _systemPower?.isBusy == true,
    );
    _systemPower = _SessionSystemPower(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: systemPowerNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy() ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true ||
          _rsync?.isBusy == true,
    );
    _configurationBackup = _SessionConfigurationBackup(
      client: client,
      transport: transport is ConfigurationBackupDownloadTransport
          ? transport as ConfigurationBackupDownloadTransport
          : null,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: configurationBackupNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy() ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true ||
          _systemPower?.isBusy == true,
    );
    _configurationRestore = _SessionConfigurationRestore(
      client: client,
      transport: transport is ConfigurationRestoreUploadTransport
          ? transport as ConfigurationRestoreUploadTransport
          : null,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: configurationRestoreNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy() ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationReset?.isBusy == true ||
          _configurationBackup?.isBusy == true,
    );
    _configurationReset = _SessionConfigurationReset(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: configurationResetNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy() ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true,
    );
    _timeSettings = _SessionTimeSettings(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: timeSettingsNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy(includeTime: false) ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true,
    );
    _emailSettings = _SessionEmailSettings(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: emailSettingsNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy(includeEmail: false) ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true,
    );
    _auditSettings = _SessionAuditSettings(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: auditSettingsNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy(includeAuditSettings: false) ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true,
    );
    _auditExport = _SessionAuditExport(
      client: client,
      transport: transport is ConfigurationBackupDownloadTransport
          ? transport as ConfigurationBackupDownloadTransport
          : null,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: auditExportNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy(includeAuditExport: false) ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true,
    );
    _alertSettings = _SessionAlertSettings(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: alertSettingsNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy(includeAlertSettings: false) ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true,
    );
    _alertPolicies = _SessionAlertPolicies(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: alertPoliciesNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy(includeAlertPolicies: false) ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true,
    );
    _notificationProviders = _SessionNotificationProviders(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: notificationProvidersNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy(includeNotificationProviders: false) ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true,
    );
    _smbSettings = _SessionSmbSettings(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: smbSettingsNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy(includeSmbSettings: false) ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true,
    );
    _nfsSettings = _SessionNfsSettings(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: nfsSettingsNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy(includeNfsSettings: false) ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true,
    );
    _cronTasks = _SessionCronTasks(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: cronTasksNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy(includeCronTasks: false) ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true,
    );
    _initShutdownTasks = _SessionInitShutdownTasks(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      requestTimeout: managementRequestTimeout,
      now: initShutdownTasksNow,
      isOtherMutationBusy: () =>
          existingMaintenancePeersBusy(includeInitShutdownTasks: false) ||
          _disks?.isBusy == true ||
          _poolMaintenance?.isBusy == true ||
          _rsync?.isBusy == true ||
          _systemPower?.isBusy == true ||
          _configurationBackup?.isBusy == true ||
          _configurationRestore?.isBusy == true ||
          _configurationReset?.isBusy == true,
    );
    _directoryIdmap = _SessionDirectoryIdmap(
      client: client,
      summary: summary,
      metadata: methodsMetadata,
      nextId: _id,
      isCurrent: current,
      isOtherMutationBusy: () =>
          _nativeMaintenanceBusy ||
          _nativeCredentialBusy ||
          _nativeSharesBusy ||
          _nativeComputeBusy,
      requestTimeout: managementRequestTimeout,
    );
  }

  Future<String?> _readRememberedKey(
    String endpointIdentifier,
    bool Function()? isConnectionCurrent,
  ) async {
    _requireCurrent(isConnectionCurrent);
    try {
      final key = await _credentialVault.readApiKey(endpointIdentifier);
      _requireCurrent(isConnectionCurrent);
      return key;
    } on CredentialUnavailableException {
      rethrow;
    } on Object {
      throw const CredentialUnavailableException(
        CredentialUnavailableReason.unavailable,
      );
    }
  }

  Future<void> _writeRememberedKey(
    String endpointIdentifier,
    String apiKey,
    bool Function()? isConnectionCurrent,
  ) async {
    _requireCurrent(isConnectionCurrent);
    try {
      await _credentialVault.writeApiKey(
        endpointIdentifier,
        apiKey,
        isCurrent: isConnectionCurrent,
      );
    } on CredentialWriteCancelledException {
      throw const CredentialUnavailableException(
        CredentialUnavailableReason.cancelled,
      );
    } on CredentialUnavailableException {
      rethrow;
    } on Object {
      throw const CredentialUnavailableException(
        CredentialUnavailableReason.unavailable,
      );
    }
  }

  void _requireCurrent(bool Function()? isConnectionCurrent) {
    final bool current;
    try {
      current = isConnectionCurrent?.call() ?? true;
    } on Object {
      throw const CredentialUnavailableException(
        CredentialUnavailableReason.cancelled,
      );
    }
    if (!current) {
      throw const CredentialUnavailableException(
        CredentialUnavailableReason.cancelled,
      );
    }
  }

  String _id() => 'm0-${++_nextId}';

  void _requireSuccess(Object? response) {
    // TrueNAS 25.10 names this field `response_type`; older middleware used
    // `state`. Read whichever the server actually sent, and never treat an
    // unrecognized shape as success.
    final state = response is Map
        ? response['response_type'] ?? response['state']
        : response;
    if (state == 'SUCCESS') return;
    throw AuthenticationStateException(switch (state) {
      'OTP_REQUIRED' => AuthenticationState.otpRequired,
      'AUTH_ERR' => AuthenticationState.authenticationFailed,
      'EXPIRED' => AuthenticationState.expired,
      'REDIRECT' => AuthenticationState.redirect,
      _ => AuthenticationState.unknown,
    });
  }

  String _identity(Object? value) {
    if (value is! Map) return 'unknown';
    for (final key in const ['username', 'pw_name', 'name', 'user', 'id']) {
      final candidate = value[key];
      if (candidate is String && candidate.isNotEmpty) return candidate;
      if (candidate is num) return candidate.toString();
    }
    return 'unknown';
  }

  String _version(Object? value) {
    if (value is Map &&
        value['version'] is String &&
        (value['version'] as String).isNotEmpty) {
      return value['version'] as String;
    }
    return 'unknown';
  }

  Set<String> _methods(Object? value) {
    if (value is Map) return value.keys.whereType<String>().toSet();
    if (value is List) return value.whereType<String>().toSet();
    return const <String>{};
  }

  @override
  Future<void> close() async {
    _connectionGeneration++;
    final realtime = _realtime;
    _realtime = null;
    _datasetProperties = null;
    _snapshots = null;
    _apps = null;
    _activity = null;
    _accounts = null;
    _virtualMachines = null;
    _zvols = null;
    _bootEnvironments = null;
    _permissions = null;
    _quotas = null;
    _snapshotSchedules = null;
    _smbShares = null;
    _nfsShares = null;
    _management = null;
    _systemUpdates = null;
    _replication = null;
    _cloudSync = null;
    _apiKeys = null;
    _cloudCredentials = null;
    _alerts = null;
    _sshCredentials = null;
    _disks = null;
    _poolMaintenance = null;
    _rsync = null;
    _systemPower = null;
    _configurationBackup = null;
    _configurationRestore?.dispose();
    _configurationRestore = null;
    _configurationReset = null;
    _timeSettings = null;
    _emailSettings?.dispose();
    _emailSettings = null;
    _auditSettings?.dispose();
    _auditSettings = null;
    _auditExport?.dispose();
    _auditExport = null;
    _alertSettings = null;
    _alertPolicies = null;
    _notificationProviders?.dispose();
    _notificationProviders = null;
    _smbSettings?.dispose();
    _smbSettings = null;
    _nfsSettings?.dispose();
    _nfsSettings = null;
    _cronTasks?.dispose();
    _directoryIdmap?.dispose();
    _directoryIdmap = null;
    _cronTasks = null;
    _initShutdownTasks?.dispose();
    _initShutdownTasks = null;
    _admin = null;
    _network = null;
    _reporting = null;
    final client = _client;
    _client = null;
    await realtime?.close();
    await client?.close();
  }
}
