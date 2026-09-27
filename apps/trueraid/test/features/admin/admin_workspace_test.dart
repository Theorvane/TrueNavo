import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/admin/admin_controller.dart';
import 'package:trueraid/features/admin/admin_operation_page.dart';
import 'package:trueraid/features/admin/admin_workspace.dart';
import 'package:trueraid/features/apps/apps_page.dart';
import 'package:trueraid/features/accounts/accounts_page.dart';
import 'package:trueraid/features/activity/activity_page.dart';
import 'package:trueraid/features/audit_export/audit_export_page.dart';
import 'package:trueraid/features/boot_environments/boot_environments_page.dart';
import 'package:trueraid/features/permissions/permissions_page.dart';
import 'package:trueraid/features/quotas/quotas_page.dart';
import 'package:trueraid/features/snapshot_schedules/snapshot_schedules_page.dart';
import 'package:trueraid/features/smb_shares/smb_shares_page.dart';
import 'package:trueraid/features/nfs_shares/nfs_shares_page.dart';
import 'package:trueraid/features/smb_settings/smb_settings_page.dart';
import 'package:trueraid/features/nfs_settings/nfs_settings_page.dart';
import 'package:trueraid/features/cron_tasks/cron_tasks_page.dart';
import 'package:trueraid/features/init_shutdown_tasks/init_shutdown_tasks_page.dart';
import 'package:trueraid/features/iscsi/iscsi_page.dart';
import 'package:trueraid/features/nvme/nvme_page.dart';
import 'package:trueraid/features/zvols/zvols_page.dart';
import 'package:trueraid/features/virtual_machines/virtual_machines_page.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/server_profiles/server_profile.dart';
import 'package:trueraid/features/server_profiles/server_profile_store.dart';
import 'package:trueraid/features/server_profiles/server_profiles_controller.dart';
import 'package:trueraid/features/snapshots/snapshots_page.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:trueraid/features/system_updates/system_updates_page.dart';
import 'package:trueraid/features/cloud_sync/cloud_sync_page.dart';
import 'package:trueraid/features/replication/replication_page.dart';
import 'package:trueraid/features/data_protection/data_protection_page.dart';
import 'package:trueraid/features/api_keys/api_keys_page.dart';
import 'package:trueraid/features/cloud_credentials/cloud_credentials_page.dart';
import 'package:trueraid/features/ssh_credentials/ssh_credentials_page.dart';
import 'package:trueraid/features/alerts/alerts_page.dart';
import 'package:trueraid/features/shares/shares_page.dart';
import 'package:trueraid/features/disks/disks_page.dart';
import 'package:trueraid/features/pool_maintenance/pool_maintenance_page.dart';
import 'package:trueraid/features/rsync/rsync_page.dart';
import 'package:trueraid/features/system_power/system_power_page.dart';
import 'package:trueraid/features/configuration_backup/configuration_backup_page.dart';
import 'package:trueraid/features/configuration_restore/configuration_restore_page.dart';
import 'package:trueraid/features/configuration_reset/configuration_reset_page.dart';
import 'package:trueraid/features/time_settings/time_settings_page.dart';
import 'package:trueraid/features/email_settings/email_settings_page.dart';
import 'package:trueraid/features/alert_settings/alert_settings_page.dart';
import 'package:trueraid/features/alert_policies/alert_policies_page.dart';
import 'package:trueraid/features/audit_settings/audit_settings_page.dart';

const _server = 'wss://nas.example/api/current';

void main() {
  for (final method in [
    'cronjob.query',
    'cronjob.create',
    'cronjob.update',
    'cronjob.delete',
    'cronjob.run',
    'initshutdownscript.query',
    'initshutdownscript.create',
    'smb.config',
    'smb.update',
    'nfs.config',
    'nfs.update',
    'alertclasses.config',
    'alertclasses.update',
    'alertservice.query',
    'alertservice.create',
    'mail.config',
    'mail.update',
    'system.general.config',
    'system.general.update',
    'system.ntpserver.query',
    'system.ntpserver.create',
    'system.ntpserver.update',
    'system.ntpserver.delete',
  ]) {
    testWidgets(
      '$method generic bypass stays blocked even with ordinary metadata',
      (tester) async {
        final (_, api) = await _pump(tester, _page(method));
        expect(api.adminCatalog.method(method), isNotNull);
        expect(find.text('This action is unavailable'), findsOneWidget);
        expect(_key('admin-review-submit'), findsNothing);
        expect(api.requests, isEmpty);
      },
    );
  }
  test('audit operations map to native page', () {
    expect(
      AdminOperationTile.nativePageForMethod('audit.config'),
      isA<AuditSettingsPage>(),
    );
    expect(
      AdminOperationTile.nativePageForMethod('audit.update'),
      isA<AuditSettingsPage>(),
    );
    expect(
      AdminOperationTile.nativePageForMethod('audit.export'),
      isA<AuditExportPage>(),
    );
  });
  for (final method in ['config.upload', 'config.reset']) {
    testWidgets('$method cannot execute through a generic form', (
      tester,
    ) async {
      expect(
        AdminOperationTile.nativePageForMethod(method)?.runtimeType,
        method == 'config.upload'
            ? ConfigurationRestorePage
            : ConfigurationResetPage,
      );
      final (_, api) = await _pump(tester, _page(method));
      expect(api.adminCatalog.method(method), isNotNull);
      expect(find.text('This action is unavailable'), findsOneWidget);
      expect(_key('admin-review-submit'), findsNothing);
      expect(api.requests, isEmpty);
    });
  }
  for (final (method, pageType) in [
    ('config.save', ConfigurationBackupPage),
    ('alertservice.query', AlertSettingsPage),
    ('mail.config', EmailSettingsPage),
    ('system.general.config', TimeSettingsPage),
    ('system.ntpserver.query', TimeSettingsPage),
    ('rsynctask.query', RsyncPage),
    ('disk.query', DisksPage),
    ('pool.scrub.query', PoolMaintenancePage),
    ('keychaincredential.query', SshCredentialsPage),
    ('alert.list', AlertsPage),
    ('api_key.query', ApiKeysPage),
    ('cloudsync.credentials.query', CloudCredentialsPage),
    ('replication.query', ReplicationPage),
    ('cloudsync.query', CloudSyncPage),
    ('update.config', SystemUpdatesPage),
    ('update.status', SystemUpdatesPage),
    ('update.available_versions', SystemUpdatesPage),
    ('pool.dataset.get_quota', QuotasPage),
    ('pool.snapshottask.query', SnapshotSchedulesPage),
    ('sharing.smb.query', SmbSharesPage),
    ('sharing.nfs.query', NfsSharesPage),
  ]) {
    testWidgets(
      '$method read tile opens native inventory without a generic query',
      (tester) async {
        final operation = _page(method).operation;
        final (_, api) = await _pump(
          tester,
          Scaffold(
            body: SingleChildScrollView(
              child: AdminOperationTile(
                operation: operation,
                catalog: _Admin().adminCatalog,
              ),
            ),
          ),
        );
        await _tap(tester, 'admin-open-$method');
        expect(find.byType(pageType), findsOneWidget);
        expect(find.byType(AdminOperationPage), findsNothing);
        expect(api.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final (domain, key, pageType) in [
    (
      AdminDomain.system,
      'admin-configuration-reset-workspace',
      ConfigurationResetPage,
    ),
    (
      AdminDomain.system,
      'admin-configuration-restore-workspace',
      ConfigurationRestorePage,
    ),
    (
      AdminDomain.system,
      'admin-configuration-backup-workspace',
      ConfigurationBackupPage,
    ),
    (AdminDomain.system, 'admin-system-power-workspace', SystemPowerPage),
    (AdminDomain.system, 'admin-time-settings-workspace', TimeSettingsPage),
    (AdminDomain.system, 'admin-email-settings-workspace', EmailSettingsPage),
    (AdminDomain.alerts, 'admin-alert-settings-workspace', AlertSettingsPage),
    (AdminDomain.dataProtection, 'admin-rsync-workspace', RsyncPage),
    (AdminDomain.storage, 'admin-disks-workspace', DisksPage),
    (
      AdminDomain.storage,
      'admin-pool-maintenance-workspace',
      PoolMaintenancePage,
    ),
    (
      AdminDomain.credentials,
      'admin-ssh-credentials-workspace',
      SshCredentialsPage,
    ),
    (AdminDomain.alerts, 'admin-alerts-workspace', AlertsPage),
    (AdminDomain.shares, 'admin-shares-overview-workspace', SharesPage),
    (AdminDomain.credentials, 'admin-api-keys-workspace', ApiKeysPage),
    (
      AdminDomain.credentials,
      'admin-cloud-credentials-workspace',
      CloudCredentialsPage,
    ),
    (
      AdminDomain.dataProtection,
      'admin-data-protection-workspace',
      DataProtectionPage,
    ),
    (
      AdminDomain.dataProtection,
      'admin-replication-workspace',
      ReplicationPage,
    ),
    (AdminDomain.dataProtection, 'admin-cloud-sync-workspace', CloudSyncPage),
    (AdminDomain.system, 'admin-system-updates-workspace', SystemUpdatesPage),
    (AdminDomain.shares, 'admin-smb-shares-workspace', SmbSharesPage),
    (AdminDomain.shares, 'admin-nfs-shares-workspace', NfsSharesPage),
    (AdminDomain.datasets, 'admin-quotas-workspace', QuotasPage),
    (
      AdminDomain.dataProtection,
      'admin-snapshot-schedules-workspace',
      SnapshotSchedulesPage,
    ),
    (AdminDomain.datasets, 'admin-permissions-workspace', PermissionsPage),
    (AdminDomain.datasets, 'admin-zvols-workspace', ZvolsPage),
    (AdminDomain.storage, 'admin-zvols-workspace', ZvolsPage),
    (
      AdminDomain.system,
      'admin-boot-environments-workspace',
      BootEnvironmentsPage,
    ),
    (AdminDomain.apps, 'admin-apps-workspace', AppsPage),
    (AdminDomain.dataProtection, 'admin-snapshots-workspace', SnapshotsPage),
    (AdminDomain.credentials, 'admin-accounts-workspace', AccountsPage),
    (
      AdminDomain.virtualization,
      'admin-virtual-machines-workspace',
      VirtualMachinesPage,
    ),
    (AdminDomain.jobs, 'admin-activity-workspace', ActivityPage),
    (AdminDomain.system, 'admin-activity-workspace', ActivityPage),
  ]) {
    testWidgets(
      '${domain.name} $key opens its native workspace without generic writes at 320px and 200%',
      (tester) async {
        final (_, api) = await _pump(
          tester,
          AdminDomainPage(domain: domain),
          width: 320,
          scale: 2,
        );
        await _tap(tester, key);
        expect(find.byType(pageType), findsOneWidget);
        expect(api.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final (method, pageType) in [
    ('pool.dataset.set_quota', QuotasPage),
    ('config.save', ConfigurationBackupPage),
    ('system.reboot', SystemPowerPage),
    ('config.upload', ConfigurationRestorePage),
    ('config.reset', ConfigurationResetPage),
    ('system.general.update', TimeSettingsPage),
    ('mail.update', EmailSettingsPage),
    ('alertservice.create', AlertSettingsPage),
    ('alertclasses.config', AlertPoliciesPage),
    ('alertclasses.update', AlertPoliciesPage),
    ('system.ntpserver.create', TimeSettingsPage),
    ('system.ntpserver.update', TimeSettingsPage),
    ('system.ntpserver.delete', TimeSettingsPage),
    ('system.shutdown', SystemPowerPage),
    ('rsynctask.create', RsyncPage),
    ('rsynctask.update', RsyncPage),
    ('rsynctask.delete', RsyncPage),
    ('rsynctask.run', RsyncPage),
    ('disk.update', DisksPage),
    ('pool.scrub.create', PoolMaintenancePage),
    ('pool.scrub.update', PoolMaintenancePage),
    ('pool.scrub.delete', PoolMaintenancePage),
    ('pool.scrub.run', PoolMaintenancePage),
    ('pool.scrub.scrub', PoolMaintenancePage),
    ('keychaincredential.create', SshCredentialsPage),
    ('keychaincredential.update', SshCredentialsPage),
    ('keychaincredential.delete', SshCredentialsPage),
    ('keychaincredential.generate_ssh_key_pair', SshCredentialsPage),
    ('alert.dismiss', AlertsPage),
    ('alert.restore', AlertsPage),
    ('api_key.create', ApiKeysPage),
    ('api_key.update', ApiKeysPage),
    ('api_key.delete', ApiKeysPage),
    ('cloudsync.credentials.create', CloudCredentialsPage),
    ('cloudsync.credentials.update', CloudCredentialsPage),
    ('cloudsync.credentials.delete', CloudCredentialsPage),
    ('replication.create', ReplicationPage),
    ('replication.update', ReplicationPage),
    ('replication.delete', ReplicationPage),
    ('replication.run', ReplicationPage),
    ('cloudsync.create', CloudSyncPage),
    ('cloudsync.update', CloudSyncPage),
    ('cloudsync.delete', CloudSyncPage),
    ('cloudsync.sync', CloudSyncPage),
    ('update.download', SystemUpdatesPage),
    ('update.run', SystemUpdatesPage),
    ('sharing.smb.create', SmbSharesPage),
    ('sharing.smb.update', SmbSharesPage),
    ('smb.config', SmbSettingsPage),
    ('cronjob.query', CronTasksPage),
    ('cronjob.create', CronTasksPage),
    ('cronjob.update', CronTasksPage),
    ('cronjob.delete', CronTasksPage),
    ('initshutdownscript.query', InitShutdownTasksPage),
    ('initshutdownscript.create', InitShutdownTasksPage),
    ('smb.update', SmbSettingsPage),
    ('nfs.config', NfsSettingsPage),
    ('nfs.update', NfsSettingsPage),
    ('sharing.smb.delete', SmbSharesPage),
    ('sharing.nfs.create', NfsSharesPage),
    ('sharing.nfs.update', NfsSharesPage),
    ('sharing.nfs.delete', NfsSharesPage),
    ('pool.snapshottask.create', SnapshotSchedulesPage),
    ('pool.snapshottask.update', SnapshotSchedulesPage),
    ('pool.snapshottask.delete', SnapshotSchedulesPage),
    ('pool.snapshottask.run', SnapshotSchedulesPage),
    ('filesystem.setacl', PermissionsPage),
    ('filesystem.setperm', PermissionsPage),
    ('boot.environment.clone', BootEnvironmentsPage),
    ('boot.environment.keep', BootEnvironmentsPage),
    ('boot.environment.activate', BootEnvironmentsPage),
    ('boot.environment.destroy', BootEnvironmentsPage),
    ('iscsi.global.update', IscsiPage),
    ('iscsi.portal.listen_ip_choices', IscsiPage),
    ('iscsi.portal.update', IscsiPage),
    ('iscsi.extent.get_instance', IscsiPage),
    ('iscsi.extent.update', IscsiPage),
    ('iscsi.target.validate_name', IscsiPage),
    ('iscsi.target.create', IscsiPage),
    ('iscsi.target.delete', IscsiPage),
    ('iscsi.target.update', IscsiPage),
    ('iscsi.target.get_instance', IscsiPage),
    ('iscsi.initiator.update', IscsiPage),
    ('iscsi.initiator.create', IscsiPage),
    ('iscsi.initiator.delete', IscsiPage),
    ('iscsi.portal.delete', IscsiPage),
    ('iscsi.portal.create', IscsiPage),
    ('iscsi.targetextent.delete', IscsiPage),
    ('iscsi.targetextent.create', IscsiPage),
    ('iscsi.targetextent.update', IscsiPage),
    ('nvmet.subsys.delete', NvmePage),
  ]) {
    testWidgets(
      '$method catalog tile routes to native workspace, never a generic setter',
      (tester) async {
        final operation = _page(method).operation;
        final catalog = _Admin().adminCatalog;
        final (_, api) = await _pump(
          tester,
          Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AdminOperationTile(
                  operation: operation,
                  catalog: catalog,
                ),
              ),
            ),
          ),
          width: 320,
          scale: 2,
        );
        expect(
          catalog.method(method),
          isNotNull,
          reason: 'Verified metadata must not bypass the dedicated flow.',
        );
        expect(find.text('Native workspace'), findsOneWidget);
        await _tap(tester, 'admin-open-$method');
        expect(find.byType(pageType), findsOneWidget);
        expect(find.byType(AdminOperationPage), findsNothing);
        expect(_key('admin-review-submit'), findsNothing);
        expect(api.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '$method direct generic route stays blocked even with method metadata',
      (tester) async {
        final (_, api) = await _pump(tester, _page(method));
        expect(api.adminCatalog.method(method), isNotNull);
        expect(find.text('This action is unavailable'), findsOneWidget);
        expect(_key('admin-review-submit'), findsNothing);
        expect(api.requests, isEmpty);
      },
    );
  }
  testWidgets(
    'dataset domain opens the dedicated editor without generic writes',
    (tester) async {
      final (_, api) = await _pump(
        tester,
        const AdminDomainPage(domain: AdminDomain.datasets),
      );
      await _tap(tester, 'admin-dataset-properties');
      expect(find.text('Dataset properties'), findsOneWidget);
      expect(find.text('Editor unavailable'), findsOneWidget);
      expect(api.requests, isEmpty);
    },
  );
  test(
    'server-wide confirmation never uses arbitrary reason or config identity',
    () {
      for (final method in [
        'system.shutdown',
        'system.reboot',
        'reporting.update',
        'audit.update',
      ]) {
        final operation = _page(method).operation;
        for (final argument in <Object?>[
          'maintenance',
          42,
          {'name': 'not-the-server', 'id': 42},
        ]) {
          expect(
            adminConfirmationTarget(operation, [argument], _server),
            _server,
            reason: method,
          );
        }
      }
    },
  );

  test(
    'reviewed resource targets preserve exact identifiers and fail closed',
    () {
      final operation = _page('app.stop').operation;
      final exactName = '${'x' * 800}/exact-suffix ';
      expect(
        adminConfirmationTarget(operation, [exactName], _server),
        exactName,
      );
      expect(
        adminConfirmationTarget(_page('iscsi.portal.delete').operation, [
          42,
        ], _server),
        '42',
      );
      for (final argument in <Object?>[
        '',
        '[redacted]',
        null,
        {'name': 'unexpected-shape'},
      ]) {
        expect(
          adminConfirmationTarget(operation, [argument], _server),
          _server,
        );
      }
      expect(adminConfirmationTarget(operation, [], _server), _server);
    },
  );

  testWidgets(
    'shutdown cannot use a generic reason form to bypass native safety',
    (tester) async {
      final (_, api) = await _pump(tester, _page('system.shutdown'));
      expect(api.adminCatalog.method('system.shutdown'), isNotNull);
      expect(find.text('This action is unavailable'), findsOneWidget);
      expect(_key('admin-value-reason'), findsNothing);
      expect(_key('admin-review-submit'), findsNothing);
      expect(api.requests, isEmpty);
    },
  );

  testWidgets('same-endpoint reconnect hides earlier account result details', (
    tester,
  ) async {
    final (container, _) = await _pump(tester, _page('reporting.config'));
    await _tap(tester, 'admin-review-submit');
    expect(find.text('nas-fixture'), findsOneWidget);
    final next = _Admin();
    container
        .read(_sessionProvider.notifier)
        .select(
          AuthenticatedSession(
            profileId: 'nas',
            repository: next,
            availableMethodNames: next.adminCatalog.methods.keys.toSet(),
            version: '25.10.1',
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('nas-fixture'), findsNothing);
    expect(
      find.textContaining('previous connection are hidden'),
      findsOneWidget,
    );
    expect(next.requests, isEmpty);
  });

  testWidgets('cancelled review erases secret inputs without sending', (
    tester,
  ) async {
    final (_, api) = await _pump(tester, _page('nvmet.port.create'));
    await tester.enterText(_key('admin-value-data.name'), 'Media');
    await _tap(tester, 'admin-include-data.password');
    await tester.enterText(
      _key('admin-value-data.password'),
      'test-private-value',
    );
    await _tap(tester, 'admin-review-submit');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.requests, isEmpty);
    expect(_key('admin-value-data.password'), findsNothing);
  });

  testWidgets('oversized confirmation cannot acknowledge hidden changes', (
    tester,
  ) async {
    final (_, api) = await _pump(tester, _page('nvmet.port.create'));
    await tester.enterText(_key('admin-value-data.name'), 'x' * 2049);
    await _tap(tester, 'admin-review-submit');
    expect(find.textContaining('too large or deeply nested'), findsOneWidget);
    await _tap(tester, 'admin-impact-acknowledge');
    expect(_sendButton(tester).onPressed, isNull);
    expect(api.requests, isEmpty);
  });

  testWidgets(
    'offline native directory opens guarded workspaces without writes',
    (tester) async {
      await _pump(tester, const AdminWorkspace(), connected: false);
      expect(
        find.text('Connect to discover available actions'),
        findsOneWidget,
      );
      for (final domain in AdminDomain.values) {
        expect(find.text(domain.label), findsOneWidget);
      }
      await tester.enterText(
        _key('admin-directory-search'),
        'Create iSCSI portal',
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == 'Create iSCSI portal',
        ),
        findsOneWidget,
      );
      final button = tester.widget<OutlinedButton>(
        _key('admin-open-iscsi.portal.create'),
      );
      expect(button.onPressed, isNotNull);
      await _tap(tester, 'admin-open-iscsi.portal.create');
      expect(find.byType(IscsiPage), findsOneWidget);
      expect(find.byType(AdminOperationPage), findsNothing);
    },
  );

  testWidgets('connected portal search opens the native workspace', (
    tester,
  ) async {
    final (_, api) = await _pump(tester, const AdminWorkspace());
    await tester.enterText(
      _key('admin-directory-search'),
      'Create iSCSI portal',
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'admin-open-iscsi.portal.create');
    expect(find.byType(IscsiPage), findsOneWidget);
    expect(find.byType(AdminOperationPage), findsNothing);
    expect(
      api.requests.where(
        (request) => request.method.name == 'iscsi.portal.create',
      ),
      isEmpty,
      reason: 'Opening a workspace never creates a portal.',
    );
  });

  testWidgets('unknown directory search is a truthful empty state', (
    tester,
  ) async {
    await _pump(tester, const AdminWorkspace());
    await tester.enterText(
      _key('admin-directory-search'),
      'no-such-setting-zxq',
    );
    await tester.pumpAndSettle();
    expect(find.text('No matching actions.'), findsOneWidget);
    expect(find.byType(AdminOperationTile), findsNothing);
  });

  testWidgets('read action loads current data without mutation confirmation', (
    tester,
  ) async {
    final (_, api) = await _pump(tester, _page('reporting.config'));
    expect(api.requests, isEmpty);
    await _tap(tester, 'admin-review-submit');
    expect(find.byType(AdminReviewDialog), findsNothing);
    expect(api.requests.single.method.name, 'reporting.config');
    expect(api.requests.single.arguments, isEmpty);
    expect(find.text('Server response received'), findsOneWidget);
    expect(find.text('nas-fixture'), findsOneWidget);
  });

  testWidgets(
    'write action sends only after explicit review and acknowledgement',
    (tester) async {
      final (_, api) = await _pump(tester, _page('nvmet.port.create'));
      await tester.enterText(_key('admin-value-data.name'), 'Media');
      await _tap(tester, 'admin-review-submit');
      expect(api.requests, isEmpty);
      expect(find.byType(AdminReviewDialog), findsOneWidget);
      expect(_sendButton(tester).onPressed, isNull);
      expect(find.text(_server), findsWidgets);
      expect(find.text('Media'), findsWidgets);
      await _tap(tester, 'admin-impact-acknowledge');
      expect(_sendButton(tester).onPressed, isNotNull);
      await _tap(tester, 'admin-confirm-send');
      expect(api.requests.single.arguments, [
        {'name': 'Media'},
      ]);
      expect(find.byType(AdminReviewDialog), findsNothing);
    },
  );

  testWidgets('cancelling review does not submit changes', (tester) async {
    final (_, api) = await _pump(tester, _page('nvmet.port.create'));
    await tester.enterText(_key('admin-value-data.name'), 'Media');
    await _tap(tester, 'admin-review-submit');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.requests, isEmpty);
    expect(find.byType(AdminReviewDialog), findsNothing);
  });

  testWidgets('invalid native form cannot open review or send requests', (
    tester,
  ) async {
    final (_, api) = await _pump(tester, _page('nvmet.port.create'));
    await _tap(tester, 'admin-review-submit');
    expect(find.byType(AdminReviewDialog), findsNothing);
    expect(find.textContaining('Check the highlighted fields'), findsOneWidget);
    expect(api.requests, isEmpty);
  });

  testWidgets(
    'reboot cannot bypass native safety through no-argument metadata',
    (tester) async {
      final (_, api) = await _pump(tester, _page('system.reboot'));
      expect(api.adminCatalog.method('system.reboot'), isNotNull);
      expect(find.text('This action is unavailable'), findsOneWidget);
      expect(_key('admin-review-submit'), findsNothing);
      expect(api.requests, isEmpty);
    },
  );

  testWidgets(
    'confirmation redacts secrets while submitted request keeps value',
    (tester) async {
      final (_, api) = await _pump(tester, _page('nvmet.port.create'));
      await tester.enterText(_key('admin-value-data.name'), 'Media');
      await _tap(tester, 'admin-include-data.password');
      await tester.enterText(
        _key('admin-value-data.password'),
        'private-test-password',
      );
      await _tap(tester, 'admin-review-submit');
      final dialog = find.byType(AdminReviewDialog);
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('private-test-password'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('[redacted]')),
        findsOneWidget,
      );
      await _tap(tester, 'admin-impact-acknowledge');
      await _tap(tester, 'admin-confirm-send');
      expect(api.requests.single.arguments, [
        {'name': 'Media', 'password': 'private-test-password'},
      ]);
      expect(_key('admin-value-data.password'), findsNothing);
    },
  );

  testWidgets(
    'connection change during review prevents sending to either server',
    (tester) async {
      final (container, api) = await _pump(tester, _page('nvmet.port.create'));
      await tester.enterText(_key('admin-value-data.name'), 'Media');
      await _tap(tester, 'admin-review-submit');
      container.read(_sessionProvider.notifier).select(null);
      await tester.pump();
      await _tap(tester, 'admin-impact-acknowledge');
      await _tap(tester, 'admin-confirm-send');
      expect(api.requests, isEmpty);
      expect(container.read(adminControllerProvider).phase, AdminPhase.failed);
      expect(
        container.read(adminControllerProvider).message,
        contains('connection changed'),
      );
    },
  );

  testWidgets(
    'blocked workflow remains unavailable even with server metadata',
    (tester) async {
      final (_, api) = await _pump(tester, _page('pool.create'));
      expect(find.text('This action is unavailable'), findsOneWidget);
      expect(
        find.textContaining('topology-aware storage wizard'),
        findsOneWidget,
      );
      expect(_key('admin-review-submit'), findsNothing);
      expect(api.requests, isEmpty);
    },
  );

  testWidgets('NVMe subsystem generic route is blocked despite metadata', (
    tester,
  ) async {
    final (_, api) = await _pump(tester, _page('nvmet.subsys.create'));
    expect(api.adminCatalog.method('nvmet.subsys.create'), isNotNull);
    expect(find.text('This action is unavailable'), findsOneWidget);
    expect(_key('admin-review-submit'), findsNothing);
    expect(api.requests, isEmpty);
  });

  testWidgets('directory and review fit 320px with large text', (tester) async {
    await _pump(tester, const AdminWorkspace(), width: 320, scale: 2);
    expect(tester.takeException(), isNull);
    await _reveal(tester, 'admin-directory-search');
    await tester.enterText(
      _key('admin-directory-search'),
      'Create NVMe subsystem',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _tap(tester, 'admin-open-nvmet.subsys.create');
    expect(find.byType(NvmePage), findsOneWidget);
    expect(_key('admin-review-submit'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native result list expands records without framework errors', (
    tester,
  ) async {
    await _pump(
      tester,
      Scaffold(
        body: TdPanel(
          child: AdminResultView(
            value: const [
              {
                'name': 'Media',
                'id': 1,
                'paths': ['/mnt/tank/media'],
              },
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Media'));
    await tester.pumpAndSettle();
    expect(find.text('paths (1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

AdminOperationPage _page(String method) => AdminOperationPage(
  operation: adminOperationDefinitions.singleWhere(
    (operation) => operation.method == method,
  ),
);
Finder _key(String key) => find.byKey(ValueKey(key));
FilledButton _sendButton(WidgetTester tester) =>
    tester.widget<FilledButton>(_key('admin-confirm-send'));
Future<void> _tap(WidgetTester tester, String key) async {
  await _reveal(tester, key);
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, String key) async {
  if (_key(key).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      _key(key),
      400,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
}

final _sessionProvider = NotifierProvider<_TestSession, AuthenticatedSession?>(
  _TestSession.new,
);

class _TestSession extends Notifier<AuthenticatedSession?> {
  @override
  AuthenticatedSession? build() => null;
  void select(AuthenticatedSession? session) => state = session;
}

Future<(ProviderContainer, _Admin)> _pump(
  WidgetTester tester,
  Widget home, {
  bool connected = true,
  double width = 800,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _Admin();
  final session = AuthenticatedSession(
    profileId: 'nas',
    repository: api,
    availableMethodNames: api.adminCatalog.methods.keys.toSet(),
    version: '25.10.1',
  );
  final container = ProviderContainer(
    overrides: [
      dashboardActiveSessionProvider.overrideWith(
        (ref) => ref.watch(_sessionProvider),
      ),
      adminPollDelayProvider.overrideWithValue(() async {}),
      initialServerProfileSnapshotProvider.overrideWithValue(
        ServerProfileSnapshot(
          profiles: const [
            ServerProfile(
              id: 'nas',
              displayName: 'Fixture NAS',
              originalHostInput: 'nas.example',
              normalizedEndpoint: _server,
              lastKnownVersion: '25.10.1',
            ),
          ],
          selectedProfileId: 'nas',
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(_sessionProvider.notifier).select(connected ? session : null);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: TrueRAIDTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container, api);
}

class _Admin implements SessionRepository, AuthenticatedAdminSession {
  final requests = <AdminRequest>[];
  @override
  final adminCatalog = AdminCatalog.fromMetadata(
    version: '25.10.1',
    metadata: {
      'system.general.config': _metadata([]),
      'cronjob.query': _metadata([]),
      'cronjob.create': _metadata([]),
      'cronjob.update': _metadata([]),
      'cronjob.delete': _metadata([]),
      'cronjob.run': _metadata([]),
      'initshutdownscript.query': _metadata([]),
      'initshutdownscript.create': _metadata([]),
      'alertservice.query': _metadata([]),
      'smb.config': _metadata([]),
      'smb.update': _metadata([]),
      'nfs.config': _metadata([]),
      'nfs.update': _metadata([]),
      'alertclasses.config': _metadata([]),
      'alertclasses.update': _metadata([]),
      'alertservice.create': _metadata([]),
      'mail.config': _metadata([]),
      'mail.update': _metadata([]),
      'mail.send': _metadata([]),
      'reporting.config': _metadata([]),
      'system.general.update': _metadata([]),
      'system.ntpserver.query': _metadata([]),
      'system.ntpserver.create': _metadata([]),
      'system.ntpserver.update': _metadata([]),
      'system.ntpserver.delete': _metadata([]),
      'iscsi.global.update': _metadata([]),
      'iscsi.portal.listen_ip_choices': _metadata([]),
      'iscsi.portal.update': _metadata([]),
      'iscsi.extent.get_instance': _metadata([]),
      'iscsi.extent.update': _metadata([]),
      'iscsi.target.validate_name': _metadata([]),
      'iscsi.target.create': _metadata([]),
      'iscsi.target.delete': _metadata([]),
      'iscsi.target.update': _metadata([]),
      'iscsi.target.get_instance': _metadata([]),
      'iscsi.initiator.update': _metadata([]),
      'iscsi.initiator.create': _metadata([]),
      'iscsi.initiator.delete': _metadata([]),
      // Deliberately ordinary-looking metadata must not enable JSON execution.
      'config.save': _metadata([]),
      'config.upload': _metadata([]),
      'config.reset': _metadata([]),
      // Synthetic form metadata tests generic review behavior, not iSCSI's
      // real wire contract. SMB/NFS mutations now require native workspaces.
      'iscsi.portal.create': _metadata([
        {
          '_name_': 'data',
          '_required_': true,
          'type': 'object',
          'required': ['name'],
          'properties': {
            'name': {'type': 'string', 'minLength': 1},
            'password': {'type': 'string', 'secret': true, 'minLength': 1},
          },
        },
      ]),
      'nvmet.subsys.create': _metadata([
        {
          '_name_': 'data',
          '_required_': true,
          'type': 'object',
          'required': ['name'],
          'properties': {
            'name': {'type': 'string', 'minLength': 1},
            'password': {'type': 'string', 'secret': true, 'minLength': 1},
          },
        },
      ]),
      'nvmet.subsys.delete': _metadata([
        {'_name_': 'id', '_required_': true, 'type': 'integer'},
        {'_name_': 'options', '_required_': false, 'type': 'object'},
      ]),
      // Synthetic generic-form fixture retained on a different NVMe method;
      // subsystem creation now has a dedicated reviewed workflow.
      'nvmet.port.create': _metadata([
        {
          '_name_': 'data',
          '_required_': true,
          'type': 'object',
          'required': ['name'],
          'properties': {
            'name': {'type': 'string', 'minLength': 1},
            'password': {'type': 'string', 'secret': true, 'minLength': 1},
          },
        },
      ]),
      'iscsi.targetextent.create': _metadata([
        {
          '_name_': 'data',
          '_required_': true,
          'type': 'object',
          'properties': {
            'target': {'type': 'integer'},
            'extent': {'type': 'integer'},
            'lunid': {'type': 'integer'},
          },
        },
      ]),
      'iscsi.portal.delete': _metadata([
        {'_name_': 'id', '_required_': true, 'type': 'integer'},
      ]),
      'iscsi.targetextent.delete': _metadata([
        {'_name_': 'id', '_required_': true, 'type': 'integer'},
      ]),
      'iscsi.targetextent.update': _metadata([
        {'_name_': 'id', '_required_': true, 'type': 'integer'},
      ]),
      'system.reboot': _metadata([]),
      'system.shutdown': _metadata([
        {
          '_name_': 'reason',
          '_required_': true,
          'type': 'string',
          'minLength': 1,
        },
        {
          '_name_': 'options',
          '_required_': false,
          'type': 'object',
          'default': {'delay': null},
          'properties': {
            'delay': {
              'anyOf': [
                {'type': 'integer'},
                {'type': 'null'},
              ],
              'default': null,
            },
          },
        },
      ]),
      'pool.create': _metadata([]),
      for (final method in [
        'rsynctask.query',
        'rsynctask.create',
        'rsynctask.update',
        'rsynctask.delete',
        'rsynctask.run',
        'disk.query',
        'disk.update',
        'disk.temperatures',
        'pool.scrub.query',
        'pool.scrub.create',
        'pool.scrub.update',
        'pool.scrub.delete',
        'pool.scrub.run',
        'pool.scrub.scrub',
        'replication.query',
        'keychaincredential.query',
        'keychaincredential.create',
        'keychaincredential.update',
        'keychaincredential.delete',
        'keychaincredential.generate_ssh_key_pair',
        'alert.list',
        'alert.dismiss',
        'alert.restore',
        'api_key.query',
        'api_key.create',
        'api_key.update',
        'api_key.delete',
        'cloudsync.credentials.query',
        'cloudsync.credentials.create',
        'cloudsync.credentials.update',
        'cloudsync.credentials.delete',
        'replication.create',
        'replication.update',
        'replication.delete',
        'replication.run',
        'cloudsync.query',
        'cloudsync.create',
        'cloudsync.update',
        'cloudsync.delete',
        'cloudsync.sync',
        'update.download',
        'update.run',
        'update.config',
        'update.status',
        'update.available_versions',
        'sharing.smb.create',
        'sharing.smb.update',
        'sharing.smb.delete',
        'sharing.nfs.create',
        'sharing.nfs.update',
        'sharing.nfs.delete',
        'pool.dataset.set_quota',
        'pool.snapshottask.create',
        'pool.snapshottask.update',
        'pool.snapshottask.delete',
        'pool.snapshottask.run',
        'filesystem.setacl',
        'filesystem.setperm',
        'boot.environment.clone',
        'boot.environment.keep',
        'boot.environment.activate',
        'boot.environment.destroy',
      ])
        method: _metadata([]),
    },
  );

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    requests.add(request);
    return AdminCompleted(
      AdminRequest(
        method: request.method,
        arguments: request.redactedArguments,
      ),
      value: {'hostname': 'nas-fixture'},
    );
  }

  @override
  Future<AdminResult> pollAdminJob(AdminJobSubmitted job) =>
      throw StateError('No jobs in this fixture');
  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw StateError('Fixtures must never connect to a real NAS');
}

Map<String, Object?> _metadata(List<Map<String, Object?>> accepts) => {
  'accepts': accepts,
  'returns': [
    {'type': 'object', 'properties': {}},
  ],
  'job': false,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'filterable': false,
};
