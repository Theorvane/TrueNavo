import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../apps/apps_page.dart';
import '../accounts/accounts_page.dart';
import '../zvols/zvols_page.dart';
import '../permissions/permissions_page.dart';
import '../quotas/quotas_page.dart';
import '../snapshot_schedules/snapshot_schedules_page.dart';
import '../smb_shares/smb_shares_page.dart';
import '../nfs_shares/nfs_shares_page.dart';
import '../smb_settings/smb_settings_page.dart';
import '../nfs_settings/nfs_settings_page.dart';
import '../cron_tasks/cron_tasks_page.dart';
import '../directory_idmap/directory_idmap_page.dart';
import '../init_shutdown_tasks/init_shutdown_tasks_page.dart';
import '../system_updates/system_updates_page.dart';
import '../cloud_sync/cloud_sync_page.dart';
import '../replication/replication_page.dart';
import '../data_protection/data_protection_page.dart';
import '../api_keys/api_keys_page.dart';
import '../cloud_credentials/cloud_credentials_page.dart';
import '../ssh_credentials/ssh_credentials_page.dart';
import '../alerts/alerts_page.dart';
import '../alert_policies/alert_policies_page.dart';
import '../notification_providers/notification_providers_page.dart';
import '../shares/shares_page.dart';
import '../disks/disks_page.dart';
import '../enclosures/enclosures_page.dart';
import '../iscsi/iscsi_page.dart';
import '../pool_maintenance/pool_maintenance_page.dart';
import '../boot_environments/boot_environments_page.dart';
import '../activity/activity_page.dart';
import '../virtual_machines/virtual_machines_page.dart';
import '../connection/connection_screen.dart';
import '../dashboard/dashboard_controller.dart';
import '../datasets/dataset_properties_page.dart';
import '../management/management_page.dart';
import '../network/network_controller.dart';
import '../network/network_page.dart';
import '../reporting/reporting_page.dart';
import '../server_profiles/server_profiles_controller.dart';
import '../snapshots/snapshots_page.dart';
import 'admin_controller.dart';
import 'admin_operation_page.dart';
import '../search/global_search.dart';
import '../rsync/rsync_page.dart';
import '../system_power/system_power_page.dart';
import '../configuration_backup/configuration_backup_page.dart';
import '../configuration_restore/configuration_restore_page.dart';
import '../configuration_reset/configuration_reset_page.dart';
import '../time_settings/time_settings_page.dart';
import '../email_settings/email_settings_page.dart';
import '../alert_settings/alert_settings_page.dart';
import '../audit_settings/audit_settings_page.dart';
import '../audit_export/audit_export_page.dart';

/// Native, curated administration. Missing specialized flows stay visible as
/// unavailable; a directory entry is not a claim of WebUI feature parity.
class AdminWorkspace extends ConsumerStatefulWidget {
  const AdminWorkspace({super.key});
  @override
  ConsumerState<AdminWorkspace> createState() => _AdminWorkspaceState();
}

class _AdminWorkspaceState extends ConsumerState<AdminWorkspace> {
  String _search = '';
  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final admin = ref.watch(adminSessionProvider);
    final catalog = admin?.adminCatalog;
    final profile = ref.watch(serverProfilesControllerProvider).selectedProfile;
    final td = context.tdTheme;
    final networkChange = ref.watch(networkControllerProvider);
    final matches = adminOperationDefinitions.where(
      (operation) =>
          '${operation.domain.label} ${operation.title} ${operation.description}'
              .toLowerCase()
              .contains(_search),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Administration'),
        actions: const [GlobalSearchButton()],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1320),
            child: ListView(
              padding: const EdgeInsets.all(TdSpacing.pageMobile),
              children: [
                Text(
                  'TRUENAS WORKSPACE',
                  style: TdTypography.micro.copyWith(
                    color: td.actionPrimary,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: TdSpacing.inline),
                Text(
                  profile?.displayName ?? 'Server administration',
                  style: TdTypography.titleLarge,
                ),
                const SizedBox(height: TdSpacing.related),
                Text(
                  'Storage, protection, compute and system settings.',
                  style: TdTypography.body.copyWith(color: td.textSecondary),
                ),
                const SizedBox(height: TdSpacing.group),
                if (session == null || catalog?.connected != true)
                  TdPanel(
                    title: 'Connect to discover available actions',
                    description:
                        'The directory is visible offline. Nothing can be '
                        'sent until a live server supplies verified method metadata.',
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ConnectionScreen(
                            onConnectionSucceeded: () {
                              if (mounted) Navigator.of(context).pop();
                            },
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.link_rounded),
                      label: const Text('Connect a server'),
                    ),
                  )
                else if (catalog?.versionSupported != true)
                  TdPanel(
                    title: 'Version not verified',
                    child: const Text(
                      'This administration adapter is disabled for this version. '
                      'Existing monitoring and dedicated controls remain separate.',
                    ),
                  )
                else
                  Wrap(
                    spacing: TdSpacing.related,
                    runSpacing: TdSpacing.inline,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const TdStatusBadge(
                        status: TdStatus.success,
                        label: 'Connected',
                      ),
                      Text(
                        '${matches.where((op) => adminUnavailableReason(op, catalog) == null).length} '
                        'schema actions available',
                        style: TdTypography.metadata,
                      ),
                      Text(
                        session.version,
                        style: TdTypography.metadata.copyWith(
                          color: td.textMuted,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: TdSpacing.component),
                if (networkChange.active ||
                    (networkChange.phase == NetworkPhase.unknown &&
                        networkChange.request != null)) ...[
                  TdPanel(
                    title: 'Network change needs attention',
                    description: networkChange.serverLabel,
                    child: OutlinedButton.icon(
                      key: const Key('admin-resume-network'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const NetworkPage(),
                        ),
                      ),
                      icon: const Icon(Icons.settings_ethernet_rounded),
                      label: const Text('Review network test'),
                    ),
                  ),
                  const SizedBox(height: TdSpacing.component),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('admin-quick-controls'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ManagementPage(),
                      ),
                    ),
                    icon: const Icon(Icons.tune_rounded),
                    label: const Text('Service & dataset controls'),
                  ),
                ),
                const SizedBox(height: TdSpacing.group),
                TextField(
                  key: const Key('admin-directory-search'),
                  decoration: const InputDecoration(
                    labelText: 'Find a setting or action',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                  onChanged: (value) =>
                      setState(() => _search = value.trim().toLowerCase()),
                ),
                const SizedBox(height: TdSpacing.component),
                if (_search.isNotEmpty)
                  Column(
                    children: [
                      if (matches.isEmpty)
                        const TdPanel(child: Text('No matching actions.')),
                      for (final operation in matches) ...[
                        AdminOperationTile(
                          operation: operation,
                          catalog: catalog,
                        ),
                        const SizedBox(height: TdSpacing.related),
                      ],
                    ],
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final scale =
                          MediaQuery.textScalerOf(context).scale(16) / 16;
                      final columns = constraints.maxWidth >= 1050 * scale
                          ? 3
                          : constraints.maxWidth >= 360 * scale
                          ? 2
                          : 1;
                      final width =
                          (constraints.maxWidth -
                              (columns - 1) * TdSpacing.related) /
                          columns;
                      return Wrap(
                        spacing: TdSpacing.related,
                        runSpacing: TdSpacing.related,
                        children: [
                          for (final domain in AdminDomain.values)
                            SizedBox(
                              width: width,
                              child: _DomainCard(
                                domain: domain,
                                catalog: catalog,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                const SizedBox(height: TdSpacing.group),
                Text(
                  'TrueNAS enforces your account permissions. Reconnect after '
                  'version or privilege changes to refresh available actions. '
                  'WebUI parity is in progress. A listed area is not necessarily '
                  'fully implemented: specialized workflows, unsupported schemas '
                  'and unavailable server features are explicitly marked.',
                  style: TdTypography.metadata.copyWith(color: td.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String? adminUnavailableReason(
  AdminOperationDefinition operation,
  AdminCatalog? catalog,
) {
  if (operation.blockedReason != null) return operation.blockedReason;
  if (catalog == null || !catalog.connected) {
    return 'Connect to load server capabilities.';
  }
  if (!catalog.versionSupported) {
    return 'This server version is not verified for this adapter.';
  }
  final method = catalog.method(operation.method);
  if (method == null) return 'Not advertised by this server or account.';
  if (!method.supported) {
    return method.unsupportedReason ??
        'This input schema needs a dedicated workflow.';
  }
  return null;
}

class _DomainCard extends StatelessWidget {
  const _DomainCard({required this.domain, required this.catalog});
  final AdminDomain domain;
  final AdminCatalog? catalog;
  @override
  Widget build(BuildContext context) {
    final operations = adminOperationDefinitions.where(
      (op) => op.domain == domain,
    );
    final available = operations
        .where((op) => adminUnavailableReason(op, catalog) == null)
        .length;
    final td = context.tdTheme;
    return Material(
      color: td.surfaceBase,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TdRadius.card),
        side: BorderSide(color: td.borderSubtle),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(TdRadius.card),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AdminDomainPage(domain: domain),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(TdSpacing.component),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    adminDomainIcon(domain),
                    color: td.actionPrimary,
                    size: 28,
                  ),
                  const Spacer(),
                  Icon(
                    Icons.arrow_forward_rounded,
                    color: td.textMuted,
                    size: 20,
                  ),
                ],
              ),
              const SizedBox(height: TdSpacing.component),
              Text(domain.label, style: TdTypography.titleSmall),
              const SizedBox(height: TdSpacing.inline),
              Text(
                {
                      AdminDomain.apps,
                      AdminDomain.storage,
                      AdminDomain.dataProtection,
                      AdminDomain.datasets,
                      AdminDomain.network,
                      AdminDomain.reporting,
                      AdminDomain.credentials,
                      AdminDomain.alerts,
                      AdminDomain.shares,
                      AdminDomain.virtualization,
                      AdminDomain.jobs,
                      AdminDomain.system,
                    }.contains(domain)
                    ? 'Native workspace · $available schema actions'
                    : '$available available · ${operations.length} listed',
                style: TdTypography.metadata.copyWith(color: td.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AdminDomainPage extends ConsumerStatefulWidget {
  const AdminDomainPage({required this.domain, super.key});
  final AdminDomain domain;
  @override
  ConsumerState<AdminDomainPage> createState() => _AdminDomainPageState();
}

class _AdminDomainPageState extends ConsumerState<AdminDomainPage> {
  String _filter = '';
  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(adminSessionProvider)?.adminCatalog;
    final operations = adminOperationDefinitions
        .where(
          (op) =>
              op.domain == widget.domain &&
              '${op.title} ${op.description}'.toLowerCase().contains(_filter),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.domain.label),
        actions: const [GlobalSearchButton()],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              padding: const EdgeInsets.all(TdSpacing.pageMobile),
              children: [
                if (widget.domain == AdminDomain.storage) ...[
                  const _NativeWorkspaceLink(
                    title: 'Pool maintenance',
                    description: 'Inspect recorded scrub progress, review integrity-check schedules and track explicitly requested scrub jobs.',
                    label: 'Open pool maintenance',
                    icon: Icons.fact_check_outlined,
                    page: PoolMaintenancePage(),
                    id: 'pool-maintenance',
                  ),
                  const _NativeWorkspaceLink(
                    title: 'Disk inventory & settings',
                    description: 'Compare disk types and raw capacities, verify passive identities and review stored description or power policies.',
                    label: 'Open disks',
                    icon: Icons.disc_full_outlined,
                    page: DisksPage(),
                    id: 'disks',
                  ),
                ],
                if (widget.domain == AdminDomain.dataProtection)
                  const _NativeWorkspaceLink(
                    title: 'Rsync transfers',
                    description: 'Review SSH PUSH task settings, scheduled enablement and explicitly requested transfer jobs.',
                    label: 'Open Rsync',
                    icon: Icons.sync_alt_rounded,
                    page: RsyncPage(),
                    id: 'rsync',
                  ),
                if (widget.domain == AdminDomain.datasets)
                  const _NativeWorkspaceLink(
                    title: 'User & group quotas',
                    description: 'Inspect per-identity byte and object usage and review exact limit changes.',
                    label: 'Open quotas',
                    icon: Icons.data_usage_outlined,
                    page: QuotasPage(),
                    id: 'quotas',
                  ),
                if (widget.domain == AdminDomain.dataProtection)
                  const _NativeWorkspaceLink(
                    title: 'Protection overview',
                    description: 'Compare snapshot, replication, Cloud Sync and Rsync policy counts, recorded states and native editing restrictions.',
                    label: 'Open protection overview',
                    icon: Icons.shield_outlined,
                    page: DataProtectionPage(),
                    id: 'data-protection',
                  ),
                if (widget.domain == AdminDomain.dataProtection)
                  const _NativeWorkspaceLink(
                    title: 'Dataset replication',
                    description: 'Review local source and destination identities, snapshot compatibility and retention effects.',
                    label: 'Open replication',
                    icon: Icons.sync_alt_outlined,
                    page: ReplicationPage(),
                    id: 'replication',
                  ),
                if (widget.domain == AdminDomain.dataProtection)
                  const _NativeWorkspaceLink(
                    title: 'Cloud Sync',
                    description: 'Review cloud destinations, copy/move/sync direction and deletion effects using existing credential references.',
                    label: 'Open Cloud Sync',
                    icon: Icons.cloud_sync_outlined,
                    page: CloudSyncPage(),
                    id: 'cloud-sync',
                  ),
                if (widget.domain == AdminDomain.dataProtection)
                  const _NativeWorkspaceLink(
                    title: 'Periodic snapshot schedules',
                    description: 'Configure calendar schedules, review retention impact and request policy runs.',
                    label: 'Open snapshot schedules',
                    icon: Icons.event_repeat_outlined,
                    page: SnapshotSchedulesPage(),
                    id: 'snapshot-schedules',
                  ),
                if (widget.domain == AdminDomain.datasets)
                  const _NativeWorkspaceLink(
                    title: 'Filesystem permissions',
                    description: 'Review POSIX/NFSv4 access entries and exact nonrecursive dataset-root permission changes.',
                    label: 'Open permissions',
                    icon: Icons.admin_panel_settings_outlined,
                    page: PermissionsPage(),
                    id: 'permissions',
                  ),
                if (widget.domain == AdminDomain.shares) ...[
                  const _NativeWorkspaceLink(
                    title: 'SMB server settings',
                    description: 'Review global server identity, multichannel and encryption with client-interruption safeguards.',
                    label: 'Open SMB server settings',
                    icon: Icons.settings_ethernet_outlined,
                    page: SmbSettingsPage(),
                    id: 'smb-settings',
                  ),
                  const _NativeWorkspaceLink(
                    title: 'NFS server settings',
                    description: 'Configure a stopped NFS service with protocol, worker, binding and export-dependency checks.',
                    label: 'Open NFS server settings',
                    icon: Icons.settings_ethernet_outlined,
                    page: NfsSettingsPage(),
                    id: 'nfs-settings',
                  ),
                  const _NativeWorkspaceLink(
                    title: 'File-sharing overview',
                    description: 'Compare SMB/NFS service state, configured access and exact shared paths.',
                    label: 'Open file-sharing overview',
                    icon: Icons.share_outlined,
                    page: SharesPage(),
                    id: 'shares-overview',
                  ),
                  const _NativeWorkspaceLink(
                    title: 'SMB file shares',
                    description: 'Inspect Windows and macOS shares and review exact filesystem and client-access changes.',
                    label: 'Open SMB shares',
                    icon: Icons.folder_shared_outlined,
                    page: SmbSharesPage(),
                    id: 'smb-shares',
                  ),
                  const _NativeWorkspaceLink(
                    title: 'NFS file shares',
                    description: 'Inspect Unix exports and review client restrictions, identity mapping and service impact.',
                    label: 'Open NFS shares',
                    icon: Icons.lan_outlined,
                    page: NfsSharesPage(),
                    id: 'nfs-shares',
                  ),
                  const _NativeWorkspaceLink(
                    title: 'iSCSI topology',
                    description: 'Inspect configured targets, backing extents and LUN mappings without exposing authentication material.',
                    label: 'Open iSCSI topology',
                    icon: Icons.hub_outlined,
                    page: IscsiPage(),
                    id: 'iscsi-topology',
                  ),
                ],
                if (widget.domain == AdminDomain.datasets ||
                    widget.domain == AdminDomain.storage)
                  const _NativeWorkspaceLink(
                    title: 'Virtual block storage',
                    description: 'Create and grow Zvols, inspect provisioning and review consumer-safe changes.',
                    label: 'Open Zvols',
                    icon: Icons.storage_rounded,
                    page: ZvolsPage(),
                    id: 'zvols',
                  ),
                if (widget.domain == AdminDomain.system) ...[
                  const _NativeWorkspaceLink(
                    title: 'Audit retention',
                    description: 'Inspect local audit usage and review evidence-retention and dataset effects.',
                    label: 'Open audit retention',
                    icon: Icons.shield_outlined,
                    page: AuditSettingsPage(),
                    id: 'audit-settings',
                  ),
                  const _NativeWorkspaceLink(
                    title: 'Cron tasks',
                    description: 'Review scheduled commands, verified local users and global scheduler effects without revealing stored command bodies.',
                    label: 'Open cron tasks',
                    icon: Icons.event_repeat_outlined,
                    page: CronTasksPage(),
                    id: 'cron-tasks',
                  ),
                  const _NativeWorkspaceLink(
                    title: 'Startup & shutdown tasks',
                    description: 'Manage disabled-first commands with separate root-execution, boot and shutdown impact review.',
                    label: 'Open startup & shutdown tasks',
                    icon: Icons.power_settings_new_outlined,
                    page: InitShutdownTasksPage(),
                    id: 'init-shutdown-tasks',
                  ),
                ],
                if (widget.domain == AdminDomain.system)
                  const _NativeWorkspaceLink(
                    title: 'Email settings',
                    description: 'Inspect SMTP configuration and review protected credential changes or one explicitly addressed test message.',
                    label: 'Open email settings',
                    icon: Icons.alternate_email_rounded,
                    page: EmailSettingsPage(),
                    id: 'email-settings',
                  ),
                if (widget.domain == AdminDomain.system)
                  const _NativeWorkspaceLink(
                    title: 'Time settings',
                    description: 'Inspect configured time sources and polling charts, then review timezone or NTP changes and their service effects.',
                    label: 'Open time settings',
                    icon: Icons.schedule_rounded,
                    page: TimeSettingsPage(),
                    id: 'time-settings',
                  ),
                if (widget.domain == AdminDomain.system)
                  const _NativeWorkspaceLink(
                    title: 'Configuration restore',
                    description: 'Inspect a trusted backup and review configuration replacement, automatic reboot and recovery access.',
                    label: 'Open configuration restore',
                    icon: Icons.settings_backup_restore_rounded,
                    page: ConfigurationRestorePage(),
                    id: 'configuration-restore',
                  ),
                if (widget.domain == AdminDomain.system)
                  const _NativeWorkspaceLink(
                    title: 'Configuration backup',
                    description: 'Review sensitive backup contents and save through the protected Android file workflow.',
                    label: 'Open configuration backup',
                    icon: Icons.save_alt_rounded,
                    page: ConfigurationBackupPage(),
                    id: 'configuration-backup',
                  ),
                if (widget.domain == AdminDomain.system)
                  const _NativeWorkspaceLink(
                    title: 'System power',
                    description: 'Inspect standalone boot readiness and review interruption before one reboot or shutdown request.',
                    label: 'Open system power',
                    icon: Icons.power_settings_new_rounded,
                    page: SystemPowerPage(),
                    id: 'system-power',
                  ),
                if (widget.domain == AdminDomain.system)
                  const _NativeWorkspaceLink(
                    title: 'System updates',
                    description: 'Review release checks, download staging and installation without automatic reboot.',
                    label: 'Open system updates',
                    icon: Icons.system_update_outlined,
                    page: SystemUpdatesPage(),
                    id: 'system-updates',
                  ),
                if (widget.domain == AdminDomain.system)
                  const _NativeWorkspaceLink(
                    title: 'Boot environments',
                    description: 'Clone and protect recovery environments, or select the next boot without rebooting.',
                    label: 'Open boot environments',
                    icon: Icons.restore_page_outlined,
                    page: BootEnvironmentsPage(),
                    id: 'boot-environments',
                  ),
                if (widget.domain == AdminDomain.system)
                  const _NativeWorkspaceLink(
                    title: 'Factory reset',
                    description: 'Review loss of server settings, automatic reboot and independent recovery access before resetting.',
                    label: 'Open factory reset review',
                    icon: Icons.restart_alt_rounded,
                    page: ConfigurationResetPage(),
                    id: 'configuration-reset',
                  ),
                if (widget.domain == AdminDomain.credentials)
                  const _NativeWorkspaceLink(
                    title: 'Directory ID mapping',
                    description: 'Inspect Active Directory backends and UID/GID ranges, including overlaps, without exposing stored credentials.',
                    label: 'Open ID mapping',
                    icon: Icons.account_tree_outlined,
                    page: DirectoryIdmapPage(),
                    id: 'directory-idmap',
                  ),
                if (widget.domain == AdminDomain.credentials)
                  const _NativeWorkspaceLink(
                    title: 'API key lifecycle',
                    description: 'Inspect safe key metadata, protect the current key and review one-time key creation or rotation.',
                    label: 'Open API keys',
                    icon: Icons.key_outlined,
                    page: ApiKeysPage(),
                    id: 'api-keys',
                  ),
                if (widget.domain == AdminDomain.credentials)
                  const _NativeWorkspaceLink(
                    title: 'SSH credentials',
                    description: 'Manage key pairs and manually trusted connections without remote scans or private-key disclosure.',
                    label: 'Open SSH credentials',
                    icon: Icons.key_outlined,
                    page: SshCredentialsPage(),
                    id: 'ssh-credentials',
                  ),
                if (widget.domain == AdminDomain.alerts)
                  const _NativeWorkspaceLink(
                    title: 'Alert policies',
                    description: 'Review per-class severity, timing, suppression and proactive support while preserving unrelated policies.',
                    label: 'Open alert policies',
                    icon: Icons.rule_outlined,
                    page: AlertPoliciesPage(),
                    id: 'alert-policies',
                  ),
                if (widget.domain == AdminDomain.alerts)
                  const _NativeWorkspaceLink(
                    title: 'Notification providers',
                    description: 'Configure typed external providers with write-only credentials and separate enablement review.',
                    label: 'Open notification providers',
                    icon: Icons.hub_outlined,
                    page: NotificationProvidersPage(),
                    id: 'notification-providers',
                  ),
                if (widget.domain == AdminDomain.alerts)
                  const _NativeWorkspaceLink(
                    title: 'Notification services',
                    description: 'Inspect configured delivery destinations and severity thresholds, then review email service lifecycle and disclosure effects.',
                    label: 'Open notification services',
                    icon: Icons.notification_add_outlined,
                    page: AlertSettingsPage(),
                    id: 'alert-settings',
                  ),
                if (widget.domain == AdminDomain.alerts)
                  const _NativeWorkspaceLink(
                    title: 'Alert center',
                    description: 'Inspect coded alert metadata and review supported dismiss or restore actions.',
                    label: 'Open alert center',
                    icon: Icons.notifications_outlined,
                    page: AlertsPage(),
                    id: 'alerts',
                  ),
                if (widget.domain == AdminDomain.credentials)
                  const _NativeWorkspaceLink(
                    title: 'Cloud credentials',
                    description: 'Inspect task references and review write-only S3 or Dropbox credentials without reading stored secrets.',
                    label: 'Open cloud credentials',
                    icon: Icons.cloud_outlined,
                    page: CloudCredentialsPage(),
                    id: 'cloud-credentials',
                  ),
                if (widget.domain == AdminDomain.credentials)
                  _NativeWorkspaceLink(
                    title: 'Local users & groups',
                    description: 'Create accounts, edit profiles and memberships, and review access safeguards.',
                    label: 'Open accounts',
                    icon: Icons.manage_accounts_outlined,
                    page: const AccountsPage(),
                    id: 'accounts',
                  ),
                if (widget.domain == AdminDomain.virtualization)
                  _NativeWorkspaceLink(
                    title: 'Virtual machine workspace',
                    description: 'Review VM configuration, device attachments and lifecycle operations.',
                    label: 'Open virtual machines',
                    icon: Icons.computer_outlined,
                    page: const VirtualMachinesPage(),
                    id: 'virtual-machines',
                  ),
                if (widget.domain == AdminDomain.enterprise)
                  const _NativeWorkspaceLink(
                    title: 'Enclosure layout',
                    description: 'Inspect TrueNAS chassis and reported disk slots without changing hardware indicators.',
                    label: 'Open enclosures',
                    icon: Icons.developer_board_outlined,
                    page: EnclosuresPage(),
                    id: 'enclosures',
                  ),
                if (widget.domain == AdminDomain.jobs ||
                    widget.domain == AdminDomain.system)
                  _NativeWorkspaceLink(
                    title: widget.domain == AdminDomain.jobs
                        ? 'Background jobs'
                        : 'Audit trail',
                    description: 'Filter activity, inspect progress and review exact job cancellations.',
                    label: widget.domain == AdminDomain.jobs
                        ? 'Open jobs'
                        : 'Open audit trail',
                    icon: Icons.history_rounded,
                    page: ActivityPage(
                      initialAudit: widget.domain == AdminDomain.system,
                    ),
                    id: 'activity',
                  ),
                if (widget.domain == AdminDomain.apps) ...[
                  TdPanel(
                    title: 'Application workspace',
                    description: 'Browse installed apps and the catalog, and review supported lifecycle changes.',
                    child: FilledButton.icon(
                      key: const Key('admin-apps-workspace'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const AppsPage(),
                        ),
                      ),
                      icon: const Icon(Icons.apps_rounded),
                      label: const Text('Open applications'),
                    ),
                  ),
                  const SizedBox(height: TdSpacing.component),
                ],
                if (widget.domain == AdminDomain.dataProtection) ...[
                  TdPanel(
                    title: 'Filesystem snapshots',
                    description: 'Browse history, create snapshot sets, clone, roll back, manage holds and review exact deletions.',
                    child: FilledButton.icon(
                      key: const Key('admin-snapshots-workspace'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SnapshotsPage(),
                        ),
                      ),
                      icon: const Icon(Icons.history_rounded),
                      label: const Text('Open snapshots'),
                    ),
                  ),
                  const SizedBox(height: TdSpacing.component),
                ],
                if (widget.domain == AdminDomain.reporting) ...[
                  TdPanel(
                    title: 'Performance graphs',
                    description:
                        'Explore CPU, memory, network, disk and other '
                        'histories discovered on this server.',
                    child: FilledButton.icon(
                      key: const Key('admin-reporting-graphs'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ReportingPage(),
                        ),
                      ),
                      icon: const Icon(Icons.insights_rounded),
                      label: const Text('Open performance graphs'),
                    ),
                  ),
                  const SizedBox(height: TdSpacing.component),
                ],
                if (widget.domain == AdminDomain.datasets) ...[
                  TdPanel(
                    title: 'Dataset property editor',
                    description: 'Review quotas, reservations, compression, access time and read-only settings before applying.',
                    child: FilledButton.icon(
                      key: const Key('admin-dataset-properties'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const DatasetPropertiesPage(),
                        ),
                      ),
                      icon: const Icon(Icons.folder_copy_outlined),
                      label: const Text('Open dataset properties'),
                    ),
                  ),
                  const SizedBox(height: TdSpacing.component),
                ],
                if (widget.domain == AdminDomain.network) ...[
                  TdPanel(
                    title: 'Network interface editor',
                    description:
                        'Review IPv4 settings, test temporarily and '
                        'explicitly keep or revert the change.',
                    child: FilledButton.icon(
                      key: const Key('admin-network-editor'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const NetworkPage(),
                        ),
                      ),
                      icon: const Icon(Icons.settings_ethernet_rounded),
                      label: const Text('Open interface editor'),
                    ),
                  ),
                  const SizedBox(height: TdSpacing.component),
                ],
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Filter actions',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                  onChanged: (value) =>
                      setState(() => _filter = value.toLowerCase()),
                ),
                const SizedBox(height: TdSpacing.group),
                if (operations.isEmpty)
                  const TdPanel(child: Text('No actions match this filter.')),
                for (final operation in operations) ...[
                  AdminOperationTile(operation: operation, catalog: catalog),
                  const SizedBox(height: TdSpacing.related),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NativeWorkspaceLink extends StatelessWidget {
  const _NativeWorkspaceLink({
    required this.title,
    required this.description,
    required this.label,
    required this.icon,
    required this.page,
    required this.id,
  });
  final String title, description, label, id;
  final IconData icon;
  final Widget page;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: TdSpacing.component),
    child: TdPanel(
      title: title,
      description: description,
      child: FilledButton.icon(
        key: ValueKey('admin-$id-workspace'),
        onPressed: () =>
            Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => page)),
        icon: Icon(icon),
        label: Text(label),
      ),
    ),
  );
}

class AdminOperationTile extends StatelessWidget {
  const AdminOperationTile({
    required this.operation,
    required this.catalog,
    super.key,
  });
  final AdminOperationDefinition operation;
  final AdminCatalog? catalog;

  /// A single native routing table shared by the directory and local search.
  static Widget? nativePageForMethod(String method) => switch (method) {
    'audit.config' || 'audit.update' => const AuditSettingsPage(),
    'directoryservices.config' => const DirectoryIdmapPage(),
    'audit.export' => const AuditExportPage(),
    'cronjob.query' ||
    'cronjob.create' ||
    'cronjob.update' ||
    'cronjob.delete' => const CronTasksPage(),
    'initshutdownscript.query' ||
    'initshutdownscript.create' ||
    'initshutdownscript.update' ||
    'initshutdownscript.delete' => const InitShutdownTasksPage(),
    'smb.config' || 'smb.update' => const SmbSettingsPage(),
    'nfs.config' || 'nfs.update' => const NfsSettingsPage(),
    'alertclasses.config' || 'alertclasses.update' => const AlertPoliciesPage(),
    'alertservice.query' ||
    'alertservice.create' ||
    'alertservice.update' ||
    'alertservice.delete' => const AlertSettingsPage(),
    'mail.config' || 'mail.update' || 'mail.send' => const EmailSettingsPage(),
    'system.general.config' ||
    'system.general.update' ||
    'system.ntpserver.query' ||
    'system.ntpserver.create' ||
    'system.ntpserver.update' ||
    'system.ntpserver.delete' => const TimeSettingsPage(),
    'iscsi.global.config' ||
    'iscsi.global.update' ||
    'iscsi.global.sessions' ||
    'iscsi.portal.query' ||
    'iscsi.portal.listen_ip_choices' ||
    'iscsi.portal.update' ||
    'iscsi.initiator.query' ||
    'iscsi.initiator.update' ||
    'iscsi.target.query' ||
    'iscsi.target.validate_name' ||
    'iscsi.target.create' ||
    'iscsi.target.delete' ||
    'iscsi.target.update' ||
    'iscsi.target.get_instance' ||
    'iscsi.extent.query' ||
    'iscsi.extent.get_instance' ||
    'iscsi.extent.update' ||
    'iscsi.targetextent.query' => const IscsiPage(),
    'config.reset' => const ConfigurationResetPage(),
    'config.upload' => const ConfigurationRestorePage(),
    'config.save' => const ConfigurationBackupPage(),
    'system.reboot' || 'system.shutdown' => const SystemPowerPage(),
    'rsynctask.query' ||
    'rsynctask.create' ||
    'rsynctask.update' ||
    'rsynctask.delete' ||
    'rsynctask.run' => const RsyncPage(),
    'disk.query' || 'disk.update' => const DisksPage(),
    'webui.enclosure.dashboard' => const EnclosuresPage(),
    'pool.scrub.query' ||
    'pool.scrub.create' ||
    'pool.scrub.update' ||
    'pool.scrub.delete' ||
    'pool.scrub.run' ||
    'pool.scrub.scrub' => const PoolMaintenancePage(),
    'alert.list' || 'alert.dismiss' || 'alert.restore' => const AlertsPage(),
    'keychaincredential.query' ||
    'keychaincredential.create' ||
    'keychaincredential.update' ||
    'keychaincredential.delete' ||
    'keychaincredential.generate_ssh_key_pair' => const SshCredentialsPage(),
    'api_key.query' ||
    'api_key.create' ||
    'api_key.update' ||
    'api_key.delete' => const ApiKeysPage(),
    'cloudsync.credentials.query' ||
    'cloudsync.credentials.create' ||
    'cloudsync.credentials.update' ||
    'cloudsync.credentials.delete' => const CloudCredentialsPage(),
    'replication.query' ||
    'replication.create' ||
    'replication.update' ||
    'replication.delete' ||
    'replication.run' => const ReplicationPage(),
    'cloudsync.query' ||
    'cloudsync.create' ||
    'cloudsync.update' ||
    'cloudsync.delete' ||
    'cloudsync.sync' => const CloudSyncPage(),
    'update.config' ||
    'update.status' ||
    'update.available_versions' ||
    'update.download' ||
    'update.run' => const SystemUpdatesPage(),
    'sharing.smb.query' ||
    'sharing.smb.create' ||
    'sharing.smb.update' ||
    'sharing.smb.delete' => const SmbSharesPage(),
    'sharing.nfs.query' ||
    'sharing.nfs.create' ||
    'sharing.nfs.update' ||
    'sharing.nfs.delete' => const NfsSharesPage(),
    'pool.dataset.get_quota' || 'pool.dataset.set_quota' => const QuotasPage(),
    'pool.snapshottask.query' ||
    'pool.snapshottask.create' ||
    'pool.snapshottask.update' ||
    'pool.snapshottask.delete' ||
    'pool.snapshottask.run' => const SnapshotSchedulesPage(),
    'core.job_abort' => const ActivityPage(),
    'filesystem.setacl' || 'filesystem.setperm' => const PermissionsPage(),
    'boot.environment.clone' ||
    'boot.environment.keep' ||
    'boot.environment.activate' ||
    'boot.environment.destroy' => const BootEnvironmentsPage(),
    'user.create' ||
    'user.update' ||
    'user.delete' ||
    'user.set_password' ||
    'group.create' ||
    'group.update' ||
    'group.delete' => const AccountsPage(),
    'pool.snapshot.clone' ||
    'pool.snapshot.rollback' ||
    'pool.snapshot.hold' ||
    'pool.snapshot.release' ||
    'pool.snapshot.delete' => const SnapshotsPage(),
    'vm.create' ||
    'vm.update' ||
    'vm.delete' ||
    'vm.device.create' ||
    'vm.device.update' ||
    'vm.device.delete' ||
    'vm.start' ||
    'vm.stop' ||
    'vm.restart' ||
    'vm.poweroff' => const VirtualMachinesPage(),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final unavailable = adminUnavailableReason(operation, catalog);
    final nativePage = nativePageForMethod(operation.method);
    final td = context.tdTheme;
    return TdPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: TdSpacing.related,
            runSpacing: TdSpacing.inline,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(operation.title, style: TdTypography.titleSmall),
              TdStatusBadge(
                status: unavailable != null
                    ? TdStatus.neutral
                    : operation.risk == AdminRisk.read
                    ? TdStatus.info
                    : TdStatus.warning,
                label: nativePage != null
                    ? 'Native workspace'
                    : unavailable != null
                    ? 'Unavailable'
                    : operation.risk == AdminRisk.read
                    ? 'Read'
                    : 'Changes server',
              ),
            ],
          ),
          const SizedBox(height: TdSpacing.inline),
          Text(
            operation.description,
            style: TdTypography.body.copyWith(color: td.textSecondary),
          ),
          if (unavailable != null || nativePage != null) ...[
            const SizedBox(height: TdSpacing.related),
            Text(
              nativePage != null
                  ? operation.risk == AdminRisk.read
                        ? 'Inspect the projected fields in the dedicated workspace.'
                        : 'Select the exact target and review this change in its dedicated workspace.'
                  : unavailable!,
              style: TdTypography.metadata.copyWith(color: td.textMuted),
            ),
          ],
          const SizedBox(height: TdSpacing.related),
          OutlinedButton.icon(
            key: ValueKey('admin-open-${operation.id}'),
            onPressed: nativePage != null || unavailable == null
                ? () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          nativePage ??
                          AdminOperationPage(operation: operation),
                    ),
                  )
                : null,
            icon: Icon(
              operation.risk == AdminRisk.read
                  ? Icons.visibility_outlined
                  : Icons.tune_rounded,
              size: 18,
            ),
            label: Text(
              nativePage != null
                  ? 'Open workspace'
                  : operation.risk == AdminRisk.read
                  ? 'View'
                  : 'Configure',
            ),
          ),
        ],
      ),
    );
  }
}

IconData adminDomainIcon(AdminDomain domain) => switch (domain) {
  AdminDomain.dashboard => Icons.dashboard_outlined,
  AdminDomain.storage => Icons.storage_outlined,
  AdminDomain.datasets => Icons.folder_copy_outlined,
  AdminDomain.shares => Icons.folder_shared_outlined,
  AdminDomain.dataProtection => Icons.shield_outlined,
  AdminDomain.network => Icons.lan_outlined,
  AdminDomain.credentials => Icons.manage_accounts_outlined,
  AdminDomain.apps => Icons.apps_rounded,
  AdminDomain.containers => Icons.inventory_2_outlined,
  AdminDomain.virtualization => Icons.computer_outlined,
  AdminDomain.reporting => Icons.monitor_heart_outlined,
  AdminDomain.system => Icons.settings_outlined,
  AdminDomain.alerts => Icons.notifications_outlined,
  AdminDomain.jobs => Icons.work_outline,
  AdminDomain.enterprise => Icons.business_outlined,
};
