import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/dev/dashboard_preview_main.dart';
import 'package:truenavo/features/apps/apps_page.dart';
import 'package:truenavo/features/activity/activity_page.dart';
import 'package:truenavo/features/accounts/accounts_page.dart';
import 'package:truenavo/features/boot_environments/boot_environments_page.dart';
import 'package:truenavo/features/permissions/permissions_page.dart';
import 'package:truenavo/features/quotas/quotas_page.dart';
import 'package:truenavo/features/smb_shares/smb_shares_page.dart';
import 'package:truenavo/features/nfs_shares/nfs_shares_page.dart';
import 'package:truenavo/features/snapshot_schedules/snapshot_schedules_page.dart';
import 'package:truenavo/features/zvols/zvols_page.dart';
import 'package:truenavo/features/virtual_machines/virtual_machines_page.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/snapshots/snapshots_page.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenavo/features/system_updates/system_updates_page.dart';
import 'package:truenavo/features/cloud_sync/cloud_sync_page.dart';
import 'package:truenavo/features/replication/replication_page.dart';
import 'package:truenavo/features/data_protection/data_protection_page.dart';
import 'package:truenavo/features/api_keys/api_keys_page.dart';
import 'package:truenavo/features/cloud_credentials/cloud_credentials_page.dart';
import 'package:truenavo/features/ssh_credentials/ssh_credentials_page.dart';
import 'package:truenavo/features/alerts/alerts_page.dart';
import 'package:truenavo/features/shares/shares_page.dart';
import 'package:truenavo/features/disks/disks_page.dart';
import 'package:truenavo/features/pool_maintenance/pool_maintenance_page.dart';
import 'package:truenavo/features/rsync/rsync_page.dart';
import 'package:truenavo/features/configuration_backup/configuration_backup_page.dart';
import 'package:truenavo/features/configuration_backup/configuration_backup_file.dart';
import 'package:truenavo/features/configuration_restore/configuration_restore_page.dart';
import 'package:truenavo/features/configuration_restore/configuration_restore_file.dart';
import 'package:truenavo/features/configuration_reset/configuration_reset_page.dart';
import 'package:truenavo/features/time_settings/time_settings_page.dart';
import 'package:truenavo/features/email_settings/email_settings_page.dart';
import 'package:truenavo/features/alert_settings/alert_settings_page.dart';
import 'package:truenavo/features/alert_policies/alert_policies_page.dart';
import 'package:truenavo/features/notification_providers/notification_providers_page.dart';
import 'package:truenavo/features/smb_settings/smb_settings_page.dart';
import 'package:truenavo/features/nfs_settings/nfs_settings_page.dart';
import 'package:truenavo/features/cron_tasks/cron_tasks_page.dart';
import 'package:truenavo/features/init_shutdown_tasks/init_shutdown_tasks_page.dart';
import 'package:truenavo/features/system_power/system_power_page.dart';
import 'package:truenavo/features/shares/shares_overview.dart';
import 'package:truenavo/app_shell/app_destination.dart';
import 'package:truenavo/features/dashboard/dashboard_page.dart';
import 'package:truenavo/features/data_protection/data_protection_overview.dart';

void main() {
  testWidgets(
    'cron preview rejects every lifecycle action and discards drafts',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialCronTasks: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CronTasksPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedCronTasksSession;
      final inventory = await api.loadCronTasks();
      final disabled = inventory.tasks.firstWhere((t) => !t.enabled);
      final enabled = inventory.tasks.firstWhere((t) => t.enabled);
      const settings = CronTaskSettings(
        user: 'operator',
        description: 'Sample reviewed task',
        schedule: CronTaskSchedule(minute: '15'),
        hideStdout: true,
        hideStderr: true,
      );
      for (final action in CronTasksAction.values) {
        final editing =
            action == CronTasksAction.create || action == CronTasksAction.edit;
        final command = editing
            ? CronTaskCommand.fromText('SYNTHETIC_COMMAND_DO_NOT_RUN')
            : null;
        final review = await api.reviewCronTasks(
          CronTasksRequest(
            inventory: inventory,
            action: action,
            task: action == CronTasksAction.create
                ? null
                : action == CronTasksAction.disable ||
                      action == CronTasksAction.run
                ? enabled
                : disabled,
            settings: editing ? settings : null,
            command: command,
          ),
        );
        expect(review.warnings.first, contains('SAMPLE ONLY'));
        for (final current in [false, true]) {
          expect(
            (await api.executeCronTasks(
              review,
              review.target,
              isCurrent: () => current,
            )).outcome,
            CronTasksOutcome.rejected,
          );
        }
        if (command != null) expect(command.isDisposed, isTrue);
      }
      final abandoned = CronTaskCommand.fromText(
        'SYNTHETIC_COMMAND_DO_NOT_RUN',
      );
      await expectLater(
        api.reviewCronTasks(
          CronTasksRequest(
            inventory: inventory,
            action: CronTasksAction.edit,
            task: enabled,
            settings: settings,
            command: abandoned,
          ),
        ),
        throwsA(isA<CronTasksException>()),
      );
      expect(abandoned.isDisposed, isTrue);
      expect(identical(await api.loadCronTasks(), inventory), isTrue);
      expect(inventory.tasks.where((t) => t.enabled), hasLength(2));
      expect(inventory.timezone, 'Asia/Seoul');
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'init shutdown preview rejects commands and protected file tasks',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialInitShutdownTasks: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(InitShutdownTasksPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedInitShutdownTasksSession;
      final inventory = await api.loadInitShutdownTasks();
      final disabled = inventory.tasks.firstWhere(
        (t) => !t.enabled && t.isCommand,
      );
      final enabled = inventory.tasks.firstWhere((t) => t.enabled);
      for (final action in InitShutdownTasksAction.values) {
        final replacing =
            action == InitShutdownTasksAction.create ||
            action == InitShutdownTasksAction.replace;
        final command = replacing
            ? InitShutdownTaskCommand('SYNTHETIC_COMMAND_DO_NOT_RUN')
            : null;
        final review = await api.reviewInitShutdownTasks(
          InitShutdownTasksRequest(
            inventory: inventory,
            action: action,
            task: action == InitShutdownTasksAction.create
                ? null
                : action == InitShutdownTasksAction.disable
                ? enabled
                : disabled,
            settings: replacing
                ? const InitShutdownTaskSettings(
                    phase: InitShutdownTaskPhase.postinit,
                    timeoutSeconds: 45,
                  )
                : null,
            command: command,
          ),
        );
        expect(review.warnings.first, contains('SAMPLE ONLY'));
        expect(review.commandReference, matches(RegExp(r'^[a-f0-9]{64}$')));
        for (final current in [false, true]) {
          expect(
            (await api.executeInitShutdownTasks(
              review,
              review.target,
              isCurrent: () => current,
            )).outcome,
            InitShutdownTasksOutcome.rejected,
          );
        }
        if (command != null) expect(command.isDisposed, isTrue);
      }
      await expectLater(
        api.reviewInitShutdownTasks(
          InitShutdownTasksRequest(
            inventory: inventory,
            action: InitShutdownTasksAction.enable,
            task: inventory.tasks.firstWhere((t) => !t.isCommand),
          ),
        ),
        throwsA(isA<InitShutdownTasksException>()),
      );
      expect(identical(await api.loadInitShutdownTasks(), inventory), isTrue);
      expect(inventory.tasks.where((t) => t.enabled), hasLength(1));
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'global SMB settings preview rejects all review attempts to submit',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialSmbSettings: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SmbSettingsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedSmbSettingsSession;
      final inventory = await api.loadSmbSettings();
      final before = inventory.config.settings;
      final review = await api.reviewSmbSettings(
        SmbSettingsRequest(
          inventory: inventory,
          settings: SmbGlobalSettings(
            netbiosName: before.netbiosName,
            workgroup: before.workgroup,
            description: 'Reviewed sample description',
            multichannel: false,
            encryption: SmbTransportEncryption.required,
          ),
        ),
      );
      expect(review.warnings.first, contains('SAMPLE ONLY'));
      for (final current in [false, true]) {
        expect(
          (await api.executeSmbSettings(
            review,
            review.target,
            isCurrent: () => current,
          )).outcome,
          SmbSettingsOutcome.rejected,
        );
      }
      expect(identical(await api.loadSmbSettings(), inventory), isTrue);
      expect(inventory.config.settings.description, before.description);
      expect(inventory.config.settings.encryption, before.encryption);
      await expectLater(
        api.reviewSmbSettings(
          SmbSettingsRequest(inventory: inventory, settings: before),
        ),
        throwsA(isA<SmbSettingsException>()),
      );
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'global NFS settings preview preserves stopped service and rejects writes',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialNfsSettings: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NfsSettingsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedNfsSettingsSession;
      final inventory = await api.loadNfsSettings();
      for (final threads in [4, 16, 256]) {
        final review = await api.reviewNfsSettings(
          NfsSettingsRequest(
            inventory: inventory,
            settings: NfsGlobalSettings(
              serverThreads: threads,
              protocols: const ['NFSV4'],
              bindAddresses: const ['192.0.2.11'],
              mountdLog: true,
              statdLockdLog: false,
            ),
          ),
        );
        expect(review.warnings.first, contains('SAMPLE ONLY'));
        for (final current in [false, true]) {
          expect(
            (await api.executeNfsSettings(
              review,
              review.target,
              isCurrent: () => current,
            )).outcome,
            NfsSettingsOutcome.rejected,
          );
        }
      }
      expect(identical(await api.loadNfsSettings(), inventory), isTrue);
      expect(inventory.serviceState, 'STOPPED');
      expect(inventory.config.settings.serverThreads, isNull);
      await expectLater(
        api.reviewNfsSettings(
          NfsSettingsRequest(
            inventory: inventory,
            settings: inventory.config.settings,
          ),
        ),
        throwsA(isA<NfsSettingsException>()),
      );
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'alert-policy preview rejects configure and class reset without support or transport',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialAlertPolicies: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AlertPoliciesPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedAlertPoliciesSession;
      final inventory = await api.loadAlertPolicies();
      for (final action in AlertPoliciesAction.values) {
        final review = await api.reviewAlertPolicies(
          AlertPoliciesRequest(
            inventory: inventory,
            classPolicy: inventory.classes.first,
            action: action,
            overrides: action == AlertPoliciesAction.configure
                ? const AlertClassOverrides(
                    level: AlertDeliveryLevel.error,
                    policy: AlertPolicyFrequency.daily,
                  )
                : null,
          ),
        );
        expect(review.warnings.first, contains('SAMPLE ONLY'));
        for (final current in [false, true]) {
          expect(
            (await api.executeAlertPolicies(
              review,
              review.target,
              isCurrent: () => current,
            )).outcome,
            AlertPoliciesOutcome.rejected,
          );
        }
      }
      expect(identical(await api.loadAlertPolicies(), inventory), isTrue);
      expect(
        inventory.classes.first.overrides.policy,
        AlertPolicyFrequency.hourly,
      );
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'notification-provider preview rejects every action and disposes entered secrets',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialNotificationProviders: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NotificationProvidersPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedNotificationProvidersSession;
      final inventory = await api.loadNotificationProviders();
      for (final action in NotificationProvidersAction.values) {
        final editing =
            action == NotificationProvidersAction.create ||
            action == NotificationProvidersAction.replace;
        final credentials = editing
            ? NotificationProviderCredentials(
                provider: NotificationProviderType.slack,
                values: {'url': 'https://hooks.example.com/synthetic-only'},
              )
            : null;
        final review = await api.reviewNotificationProviders(
          NotificationProvidersRequest(
            inventory: inventory,
            action: action,
            service: action == NotificationProvidersAction.create
                ? null
                : inventory.services.singleWhere(
                    (s) =>
                        s.id ==
                        (action == NotificationProvidersAction.disable
                            ? 22
                            : 21),
                  ),
            settings: editing
                ? NotificationProviderSettings(
                    provider: NotificationProviderType.slack,
                    name: 'Reviewed sample channel',
                    fields: const {},
                  )
                : null,
            credentials: credentials,
          ),
        );
        expect(review.warnings.first, contains('SAMPLE ONLY'));
        expect(review.destinationSummary, isNot(contains('synthetic-only')));
        for (final current in [false, true]) {
          expect(
            (await api.executeNotificationProviders(
              review,
              review.target,
              isCurrent: () => current,
            )).outcome,
            NotificationProvidersOutcome.rejected,
          );
        }
        if (credentials != null) expect(credentials.isDisposed, isTrue);
      }
      expect(
        identical(await api.loadNotificationProviders(), inventory),
        isTrue,
      );
      expect(inventory.services.first.enabled, isFalse);
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'notification service sample rejects every lifecycle action without a provider or send',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialAlertSettings: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AlertSettingsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedAlertSettingsSession;
      final inventory = await api.loadAlertSettings();
      final disabled = inventory.services.singleWhere((row) => row.id == 11);
      final enabled = inventory.services.singleWhere((row) => row.id == 12);
      for (final action in AlertSettingsAction.values) {
        final review = await api.reviewAlertSettings(
          AlertSettingsRequest(
            inventory: inventory,
            action: action,
            service: switch (action) {
              AlertSettingsAction.createEmail => null,
              AlertSettingsAction.disableEmail => enabled,
              _ => disabled,
            },
            settings:
                action == AlertSettingsAction.createEmail ||
                    action == AlertSettingsAction.editEmail
                ? const EmailAlertServiceSettings(
                    name: 'Reviewed example',
                    recipient: 'reviewed@example.com',
                  )
                : null,
          ),
        );
        expect(review.warnings.first, contains('SAMPLE ONLY'));
        for (final current in [false, true]) {
          expect(
            (await api.executeAlertSettings(
              review,
              review.target,
              isCurrent: () => current,
            )).outcome,
            AlertSettingsOutcome.rejected,
          );
        }
      }
      expect(identical(await api.loadAlertSettings(), inventory), isTrue);
      expect(
        inventory.services.where((row) => !row.isEmail).single.recipient,
        isNull,
      );
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'email sample rejects settings, password changes and test sends without transport',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialEmailSettings: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EmailSettingsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedEmailSettingsSession;
      final inventory = await api.loadEmailSettings();
      for (final password in [
        const EmailPasswordChange.keep(),
        EmailPasswordChange.replace('SYNTHETIC_PREVIEW_PASSWORD'),
        const EmailPasswordChange.clear(),
      ]) {
        final review = await api.reviewEmailSettings(
          EmailSettingsRequest(
            inventory: inventory,
            action: EmailSettingsAction.configure,
            password: password,
            settings: EmailSmtpSettings(
              fromEmail: 'alerts@example.com',
              fromName: 'Reviewed sample sender',
              outgoingServer: 'smtp.example.com',
              username: 'alerts@example.com',
              smtpAuth: password.action != EmailPasswordAction.clear,
            ),
          ),
        );
        expect(review.warnings.first, contains('SAMPLE ONLY'));
        for (final current in [false, true]) {
          final result = await api.executeEmailSettings(
            review,
            review.target,
            isCurrent: () => current,
          );
          expect(result.outcome, EmailSettingsOutcome.rejected);
          expect(result.jobId, isNull);
        }
        if (password.action == EmailPasswordAction.replace) {
          expect(password.isDisposed, isTrue);
        }
      }
      final review = await api.reviewEmailSettings(
        EmailSettingsRequest(
          inventory: inventory,
          action: EmailSettingsAction.test,
          recipient: 'recipient@example.com',
        ),
      );
      expect(review.target, contains('recipient@example.com'));
      for (final current in [false, true]) {
        final result = await api.executeEmailSettings(
          review,
          review.target,
          isCurrent: () => current,
        );
        expect(result.outcome, EmailSettingsOutcome.rejected);
        expect(result.jobId, isNull);
        expect(
          (await api.checkEmailSettingsJob(
            123,
            isCurrent: () => current,
          )).outcome,
          EmailSettingsOutcome.rejected,
        );
      }
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'time settings sample rejects every action without probes or transport',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialTimeSettings: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TimeSettingsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedTimeSettingsSession;
      final inventory = await api.loadTimeSettings();
      expect(inventory.servers, hasLength(3));
      for (final request in [
        TimeSettingsRequest(
          inventory: inventory,
          action: TimeSettingsAction.timezone,
          timezone: 'UTC',
        ),
        TimeSettingsRequest(
          inventory: inventory,
          action: TimeSettingsAction.createNtp,
          settings: const NtpServerSettings(address: 'time-new.example'),
        ),
        TimeSettingsRequest(
          inventory: inventory,
          action: TimeSettingsAction.updateNtp,
          server: inventory.servers.first,
          settings: const NtpServerSettings(
            address: 'time-a.example',
            prefer: false,
          ),
        ),
        TimeSettingsRequest(
          inventory: inventory,
          action: TimeSettingsAction.deleteNtp,
          server: inventory.servers.last,
        ),
      ]) {
        final review = await api.reviewTimeSettings(request);
        expect(review.warnings.first, contains('SAMPLE ONLY'));
        for (final current in [false, true]) {
          final result = await api.executeTimeSettings(
            review,
            review.target,
            isCurrent: () => current,
          );
          expect(result.outcome, TimeSettingsOutcome.rejected);
        }
      }
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('factory reset sample always rejects without transport', (
    tester,
  ) async {
    await tester.pumpWidget(
      const DashboardPreviewApp(initialConfigurationReset: true),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ConfigurationResetPage)),
    );
    final repository = container
        .read(dashboardActiveSessionProvider)!
        .repository;
    final api = repository as AuthenticatedConfigurationResetSession;
    final inventory = await api.loadConfigurationReset();
    final review = await api.reviewConfigurationReset(
      ConfigurationResetRequest(inventory: inventory),
    );
    expect(review.target, 'RESET ${inventory.hostId}');
    expect(
      review.warnings.any((warning) => warning.contains('SAMPLE ONLY')),
      isTrue,
    );
    for (final current in [false, true]) {
      final result = await api.executeConfigurationReset(
        review,
        review.target,
        isCurrent: () => current,
      );
      expect(result.outcome, ConfigurationResetOutcome.rejected);
      expect(result.jobId, isNull);
    }
    await _expectNoPreviewTransport(container, repository);
    expect(tester.takeException(), isNull);
  });
  testWidgets('configuration restore sample cannot pick files or upload', (
    tester,
  ) async {
    await tester.pumpWidget(
      const DashboardPreviewApp(initialConfigurationRestore: true),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ConfigurationRestorePage)),
    );
    final repository = container
        .read(dashboardActiveSessionProvider)!
        .repository;
    final api = repository as AuthenticatedConfigurationRestoreSession;
    final picker = container.read(configurationRestoreFilePickerProvider);
    expect(await picker.pick(isCurrent: () => false), isNull);
    var started = false;
    final bytes = (await picker.pick(
      isCurrent: () => true,
      onReadStarted: () => started = true,
    ))!;
    expect(started, isTrue);
    expect(bytes, hasLength(512));
    final file = await api.prepareConfigurationRestore(bytes);
    expect(bytes, everyElement(0));
    expect(file.hasSecretSeed, isFalse);
    expect(file.authorizedKeyMembers, isEmpty);
    final review = await api.reviewConfigurationRestore(
      ConfigurationRestoreRequest(
        inventory: await api.loadConfigurationRestore(),
        file: file,
      ),
    );
    final result = await api.executeConfigurationRestore(
      review,
      review.target,
      isCurrent: () => true,
    );
    expect(result.outcome, ConfigurationRestoreOutcome.rejected);
    expect(result.jobId, isNull);
    expect(file.isDisposed, isTrue);
    await _expectNoPreviewTransport(container, repository);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'configuration backup sample rejects all contents without files or transport',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialConfigurationBackup: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ConfigurationBackupPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedConfigurationBackupSession;
      final inventory = await api.loadConfigurationBackup();
      for (final seed in [false, true]) {
        for (final keys in [false, true]) {
          final review = await api.reviewConfigurationBackup(
            ConfigurationBackupRequest(
              inventory: inventory,
              includeSecretSeed: seed,
              includeAuthorizedKeys: keys,
            ),
          );
          final result = await api.executeConfigurationBackup(
            review,
            review.target,
          );
          expect(result.outcome, ConfigurationBackupOutcome.rejected);
          expect(result.artifact, isNull);
          expect(result.jobId, isNull);
        }
      }
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(
        await container
            .read(configurationBackupFileSaverProvider)
            .save(
              bytes: bytes,
              filename: 'truenas-configuration.db',
              isCurrent: () => true,
            ),
        ConfigurationBackupSaveOutcome.cancelled,
      );
      expect(bytes, everyElement(0));
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('system power sample rejects both actions without transport', (
    tester,
  ) async {
    await tester.pumpWidget(
      const DashboardPreviewApp(initialSystemPower: true),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SystemPowerPage)),
    );
    final repository = container
        .read(dashboardActiveSessionProvider)!
        .repository;
    final api = repository as AuthenticatedSystemPowerSession;
    final inventory = await api.loadSystemPower();
    expect(inventory.endpoint, 'wss://nas-demo.example/api/current');
    for (final action in SystemPowerAction.values) {
      final review = await api.reviewSystemPower(
        SystemPowerRequest(
          inventory: inventory,
          action: action,
          reason: 'Sample inspection only',
        ),
      );
      expect(
        (await api.executeSystemPower(review, review.target)).outcome,
        SystemPowerOutcome.rejected,
      );
    }
    await _expectNoPreviewTransport(container, repository);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Rsync sample rejects every action and explicit check without transport',
    (tester) async {
      await tester.pumpWidget(const DashboardPreviewApp(initialRsync: true));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(RsyncPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedRsyncSession;
      final inventory = await api.loadRsync();
      expect(inventory.tasks, hasLength(3));
      for (final action in RsyncAction.values) {
        final review = RsyncReview(
          request: RsyncRequest(
            inventory: inventory,
            action: action,
            task: inventory.tasks.first,
          ),
          endpoint: inventory.endpoint,
          warnings: const [],
        );
        expect(
          (await api.executeRsync(review, review.target)).outcome,
          RsyncOutcome.rejected,
        );
      }
      expect(
        (await api.checkRsyncJob(
          RsyncJob(
            id: 1,
            taskId: inventory.tasks.first.id,
            endpoint: inventory.endpoint,
            path: '/mnt/tank/media',
            connectionId: 21,
            remotePath: '/srv/backup',
          ),
        )).outcome,
        RsyncOutcome.rejected,
      );
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'disk sample exposes passive type inventory and rejects edits without transport',
    (tester) async {
      await tester.pumpWidget(const DashboardPreviewApp(initialDisks: true));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DisksPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedDisksSession;
      final inventory = await api.loadDisks(),
          disk = (await api.loadDisks()).disks.first;
      expect(inventory.disks, hasLength(5));
      expect(
        inventory.disks.every((d) => d.temperatureCelsius == null),
        isTrue,
      );
      final review = await api.reviewDisk(
        DiskRequest(
          inventory: inventory,
          disk: disk,
          settings: DiskSettings(
            description: 'Sample edit',
            hddStandby: disk.hddStandby,
            advancedPowerManagement: disk.advancedPowerManagement,
          ),
        ),
      );
      expect(
        (await api.executeDisk(review, review.target)).outcome,
        DiskOutcome.rejected,
      );
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'pool maintenance sample rejects every change and job check without transport',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialPoolMaintenance: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PoolMaintenancePage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedPoolMaintenanceSession;
      final inventory = await api.loadPoolMaintenance(),
          pool = (await api.loadPoolMaintenance()).pools.first;
      expect(inventory.pools, hasLength(3));
      for (final action in PoolMaintenanceAction.values) {
        final review = PoolMaintenanceReview(
          request: PoolMaintenanceRequest(
            inventory: inventory,
            pool: pool,
            action: action,
          ),
          endpoint: inventory.endpoint,
          warnings: const [],
        );
        expect(
          (await api.executePoolMaintenance(review, review.target)).outcome,
          PoolMaintenanceOutcome.rejected,
        );
      }
      expect(
        (await api.checkPoolMaintenanceJob(
          PoolMaintenanceJob(
            id: 1,
            poolId: pool.id,
            endpoint: inventory.endpoint,
            poolName: pool.name,
            poolGuid: pool.guid,
            action: PoolMaintenanceAction.startScrub,
          ),
        )).outcome,
        PoolMaintenanceOutcome.rejected,
      );
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'shares sample aggregates only typed local inventories without transport',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialSharesOverview: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SharesPage)),
      );
      final overview = await container.read(sharesOverviewProvider.future);
      expect(overview.loadedSources, 2);
      expect(overview.shares.length, 7);
      expect(overview.paths['/mnt/tank/archive']!.length, 2);
      await _expectNoPreviewTransport(
        container,
        container.read(dashboardActiveSessionProvider)!.repository,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'SSH sample rejects every effect and disposes import input without transport',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialSshCredentials: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SshCredentialsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedSshCredentialsSession;
      final inventory = await api.loadSshCredentials();
      expect(inventory.keyPairs.length, 2);
      expect(inventory.connections.length, 1);
      for (final action in SshCredentialAction.values) {
        final review = SshCredentialReview(
          request: SshCredentialRequest(
            inventory: inventory,
            action: action,
            name: 'Sample only',
          ),
          endpoint: inventory.endpoint,
          warnings: const [],
        );
        final input = SshCredentialWriteOnlyInput.keyPair(
          privateKey: 'not-a-real-private-key',
        );
        final result = await api.executeSshCredential(
          review,
          review.target,
          input: input,
        );
        expect(result.outcome, SshCredentialOutcome.rejected);
        expect(result.publicKey, isNull);
        expect(input.disposed, isTrue);
      }
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'alert sample includes inspect-only one-shots and rejects all actions without transport',
    (tester) async {
      await tester.pumpWidget(const DashboardPreviewApp(initialAlerts: true));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AlertsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedAlertsSession;
      final inventory = await api.loadAlerts();
      expect(inventory.alerts.any((a) => a.oneShot), isTrue);
      for (final action in AlertAction.values) {
        final review = AlertReview(
          request: AlertRequest(
            inventory: inventory,
            action: action,
            alert: inventory.alerts.first,
          ),
          endpoint: inventory.endpoint,
          warnings: const [],
        );
        expect(
          (await api.executeAlert(review, review.target)).outcome,
          AlertOutcome.rejected,
        );
      }
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'primary alerts destination uses typed alert center when available',
    (tester) async {
      await tester.pumpWidget(const DashboardPreviewApp(initialAlerts: true));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AlertsPage)),
      );
      final session = container.read(dashboardActiveSessionProvider)!;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardActiveSessionProvider.overrideWith((ref) => session),
          ],
          child: MaterialApp(
            theme: TrueNavoTheme.dark(),
            home: const DashboardPage(destination: AppDestination.alerts),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'protection overview sample reads four typed sources without transport',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialDataProtection: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DataProtectionPage)),
      );
      final overview = await container.read(
        dataProtectionOverviewProvider.future,
      );
      expect(overview.loadedSources, 4);
      expect(overview.tasks, hasLength(11));
      expect(overview.enabled, 5);
      expect(overview.disabled, 6);
      expect(
        overview.tasks.where((task) => task.family == ProtectionFamily.rsync),
        hasLength(3),
      );
      expect(
        find.byKey(const Key('protection-enablement-chart')),
        findsOneWidget,
      );
      await _expectNoPreviewTransport(
        container,
        container.read(dashboardActiveSessionProvider)!.repository,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'API key sample rejects every action without returning a secret or transport',
    (tester) async {
      await tester.pumpWidget(const DashboardPreviewApp(initialApiKeys: true));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ApiKeysPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedApiKeysSession;
      final inventory = await api.loadApiKeys();
      expect(inventory.keys.length, 4);
      expect(inventory.currentKeyId, 1);
      for (final action in ApiKeyAction.values) {
        final review = ApiKeyReview(
          request: ApiKeyRequest(
            inventory: inventory,
            action: action,
            key: inventory.keys[1],
            name: 'Sample only',
          ),
          endpoint: inventory.endpoint,
          warnings: const [],
        );
        final result = await api.executeApiKey(review, review.target);
        expect(result.outcome, ApiKeyOutcome.rejected);
        expect(result.secret, isNull);
      }
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cloud credential sample rejects every action and disposes write-only input without transport',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialCloudCredentials: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CloudCredentialsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedCloudCredentialsSession;
      final inventory = await api.loadCloudCredentials();
      expect(
        inventory.credentials.map((e) => e.provider),
        containsAll(['S3', 'DROPBOX', 'ONEDRIVE']),
      );
      expect(inventory.references.any((r) => r.kind == 'cloud_backup'), isTrue);
      for (final action in CloudCredentialAction.values) {
        final review = CloudCredentialReview(
          request: CloudCredentialRequest(
            inventory: inventory,
            action: action,
            credential: inventory.credentials.last,
            name: 'Sample only',
            provider: 'S3',
          ),
          endpoint: inventory.endpoint,
          warnings: const [],
        );
        final input = CloudCredentialWriteOnlyInput.s3(
          accessKeyId: 'synthetic-placeholder',
          secretAccessKey: 'synthetic-placeholder',
          endpoint: '',
          region: '',
          skipRegion: false,
          signaturesV2: false,
          maxUploadParts: 10000,
        );
        expect(
          (await api.executeCloudCredential(
            review,
            review.target,
            input: input,
          )).outcome,
          CloudCredentialOutcome.rejected,
        );
        expect(input.validationError, isNotNull);
      }
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'replication sample shows unsupported tasks and rejects all mutation actions',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialReplication: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReplicationPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedReplicationSession;
      final inventory = await api.loadReplication();
      expect(inventory.tasks.any((task) => !task.available), isTrue);
      for (final action in ReplicationAction.values) {
        final review = ReplicationReview(
          request: ReplicationRequest(
            inventory: inventory,
            action: action,
            task: inventory.tasks.first,
            settings: inventory.tasks.first.settings,
          ),
          endpoint: inventory.endpoint,
          warnings: const [],
          sourceSnapshots: 12,
          destinationSnapshots: 8,
          createsDestination: false,
        );
        expect(
          (await api.executeReplication(review, review.target)).outcome,
          ReplicationOutcome.rejected,
        );
      }
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cloud sync sample retains secret-free references and rejects every action',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialCloudSync: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CloudSyncPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedCloudSyncSession;
      final inventory = await api.loadCloudSync();
      expect(inventory.tasks, isNotEmpty);
      expect(
        inventory.credentials.map((item) => item.provider),
        containsAll(['S3', 'DROPBOX']),
      );
      for (final action in CloudSyncAction.values) {
        final review = CloudSyncReview(
          request: CloudSyncRequest(
            inventory: inventory,
            action: action,
            task: inventory.tasks.first,
            settings: inventory.tasks.first.settings,
          ),
          endpoint: inventory.endpoint,
          warnings: const [],
        );
        expect(
          (await api.executeCloudSync(review, review.target)).outcome,
          CloudSyncOutcome.rejected,
        );
      }
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'system update sample never contacts release source or executes any action',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialSystemUpdates: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SystemUpdatesPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedSystemUpdatesSession;
      final inventory = await api.loadSystemUpdates();
      expect(inventory.versions, isNotEmpty);
      for (final action in SystemUpdateAction.values) {
        final request = SystemUpdateRequest(
          inventory: inventory,
          action: action,
          version: action == SystemUpdateAction.check
              ? null
              : inventory.versions.first,
        );
        final review = await api.reviewSystemUpdate(request);
        expect(
          (await api.executeSystemUpdate(review, review.target)).outcome,
          SystemUpdateOutcome.rejected,
        );
      }
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('SMB sample stays connector-free and rejects every write', (
    tester,
  ) async {
    await tester.pumpWidget(const DashboardPreviewApp(initialSmbShares: true));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SmbSharesPage)),
    );
    final repository = container
        .read(dashboardActiveSessionProvider)!
        .repository;
    final api = repository as AuthenticatedSmbSharesSession;
    final inventory = await api.loadSmbShares();
    expect(inventory.shares, isNotEmpty);
    expect(
      inventory.enabledCount + inventory.disabledCount,
      inventory.shares.length,
    );
    for (final action in SmbShareAction.values) {
      final review = SmbShareReview(
        action: action,
        target: 'Sample only',
        identity: 'Synthetic identity',
        changes: const [],
        warnings: const [],
      );
      expect(
        (await api.executeSmbShare(review, review.confirmation)).outcome,
        SmbShareOutcome.rejected,
      );
    }
    final after = await api.loadSmbShares();
    expect(
      after.shares.map(
        (share) =>
            (share.id, share.name, share.path, share.readonly, share.enabled),
      ),
      inventory.shares.map(
        (share) =>
            (share.id, share.name, share.path, share.readonly, share.enabled),
      ),
    );
    await _expectNoPreviewTransport(container, repository);
    expect(tester.takeException(), isNull);
  });
  testWidgets('NFS sample stays connector-free and rejects every write', (
    tester,
  ) async {
    await tester.pumpWidget(const DashboardPreviewApp(initialNfsShares: true));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NfsSharesPage)),
    );
    final repository = container
        .read(dashboardActiveSessionProvider)!
        .repository;
    final api = repository as AuthenticatedNfsSharesSession;
    final inventory = await api.loadNfsShares();
    expect(inventory.shares, isNotEmpty);
    expect(inventory.protocols, isNotEmpty);
    for (final action in NfsShareAction.values) {
      final review = NfsShareReview(
        action: action,
        target: 'Sample only',
        identity: 'Synthetic identity',
        changes: const [],
        warnings: const [],
      );
      expect(
        (await api.executeNfsShare(review, review.target)).outcome,
        NfsShareOutcome.rejected,
      );
    }
    final after = await api.loadNfsShares();
    expect(
      after.shares.map(
        (share) => (
          share.id,
          share.settings.path,
          share.settings.readOnly,
          share.settings.enabled,
        ),
      ),
      inventory.shares.map(
        (share) => (
          share.id,
          share.settings.path,
          share.settings.readOnly,
          share.settings.enabled,
        ),
      ),
    );
    await _expectNoPreviewTransport(container, repository);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'snapshot schedule preview supplies truthful task states and rejects every action without transport',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialSnapshotSchedules: true),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SnapshotSchedulesPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedSnapshotSchedulesSession;
      final inventory = await api.loadSnapshotSchedules();
      expect(inventory.timezone, 'Asia/Seoul');
      expect(
        inventory.tasks.map((t) => t.state),
        containsAll(['FINISHED', 'ERROR', 'PENDING']),
      );
      expect(inventory.tasks.any((t) => !t.settings.enabled), isTrue);
      final task = inventory.tasks.first;
      for (final action in SnapshotScheduleAction.values) {
        final request = SnapshotScheduleRequest(
          inventory: inventory,
          action: action,
          task: action == SnapshotScheduleAction.create ? null : task,
          settings:
              action == SnapshotScheduleAction.create ||
                  action == SnapshotScheduleAction.update
              ? SnapshotScheduleSettings(
                  dataset: task.settings.dataset,
                  lifetimeValue: 3,
                )
              : null,
        );
        final review = await api.reviewSnapshotSchedule(request);
        expect(review.action, action);
        expect(
          (await api.executeSnapshotSchedule(review, review.target)).outcome,
          SnapshotScheduleOutcome.rejected,
        );
      }
      expect(await api.loadSnapshotSchedules(), same(inventory));
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'quota preview resolves synthetic identity and cannot authorize a limit write',
    (tester) async {
      await tester.pumpWidget(const DashboardPreviewApp(initialQuotas: true));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(QuotasPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedQuotasSession;
      final datasets = await api.loadQuotaDatasets();
      final inventory = await api.loadQuotas(datasets.first);
      expect(inventory.entries.any((e) => e.usedBytes == null), isTrue);
      expect(inventory.entries.any((e) => e.byteLimit == 0), isTrue);
      expect(
        inventory.entries.any(
          (e) => e.byteLimit > 0 && (e.usedBytes ?? 0) > e.byteLimit,
        ),
        isTrue,
      );
      final entry = inventory.entries.first;
      final identity = await api.resolveQuotaIdentity(
        inventory,
        entry.kind,
        entry.id,
      );
      expect(identity.id, entry.id);
      await expectLater(
        api.reviewQuotaChange(
          QuotaChange(inventory: inventory, identity: identity, byteLimit: 1),
        ),
        throwsA(isA<QuotaException>()),
      );
      final review = QuotaReview(
        dataset: inventory.dataset,
        identity: identity,
        confirmation: 'sample',
        changes: const [],
        warnings: const [],
      );
      expect(
        (await api.executeQuotaReview(review, 'sample')).outcome,
        QuotaOutcome.rejected,
      );
      final after = await api.loadQuotas(datasets.first);
      expect(
        after.entries.map((e) => (e.kind, e.id, e.byteLimit, e.objectLimit)),
        inventory.entries.map(
          (e) => (e.kind, e.id, e.byteLimit, e.objectLimit),
        ),
      );
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'compile-time native preview flags select the isolated entrypoint',
    (tester) async {
      final pageType = const bool.fromEnvironment('PREVIEW_CRON_TASKS')
          ? CronTasksPage
          : const bool.fromEnvironment('PREVIEW_INIT_SHUTDOWN_TASKS')
          ? InitShutdownTasksPage
          : const bool.fromEnvironment('PREVIEW_SMB_SETTINGS')
          ? SmbSettingsPage
          : const bool.fromEnvironment('PREVIEW_NFS_SETTINGS')
          ? NfsSettingsPage
          : const bool.fromEnvironment('PREVIEW_ALERT_POLICIES')
          ? AlertPoliciesPage
          : const bool.fromEnvironment('PREVIEW_NOTIFICATION_PROVIDERS')
          ? NotificationProvidersPage
          : const bool.fromEnvironment('PREVIEW_ALERT_SETTINGS')
          ? AlertSettingsPage
          : const bool.fromEnvironment('PREVIEW_EMAIL_SETTINGS')
          ? EmailSettingsPage
          : const bool.fromEnvironment('PREVIEW_TIME_SETTINGS')
          ? TimeSettingsPage
          : const bool.fromEnvironment('PREVIEW_CONFIGURATION_RESET')
          ? ConfigurationResetPage
          : const bool.fromEnvironment('PREVIEW_CONFIGURATION_RESTORE')
          ? ConfigurationRestorePage
          : const bool.fromEnvironment('PREVIEW_CONFIGURATION_BACKUP')
          ? ConfigurationBackupPage
          : const bool.fromEnvironment('PREVIEW_SYSTEM_POWER')
          ? SystemPowerPage
          : const bool.fromEnvironment('PREVIEW_RSYNC')
          ? RsyncPage
          : const bool.fromEnvironment('PREVIEW_DISKS')
          ? DisksPage
          : const bool.fromEnvironment('PREVIEW_POOL_MAINTENANCE')
          ? PoolMaintenancePage
          : const bool.fromEnvironment('PREVIEW_SSH_CREDENTIALS')
          ? SshCredentialsPage
          : const bool.fromEnvironment('PREVIEW_ALERTS')
          ? AlertsPage
          : const bool.fromEnvironment('PREVIEW_SHARES_OVERVIEW')
          ? SharesPage
          : const bool.fromEnvironment('PREVIEW_API_KEYS')
          ? ApiKeysPage
          : const bool.fromEnvironment('PREVIEW_CLOUD_CREDENTIALS')
          ? CloudCredentialsPage
          : const bool.fromEnvironment('PREVIEW_DATA_PROTECTION')
          ? DataProtectionPage
          : const bool.fromEnvironment('PREVIEW_REPLICATION')
          ? ReplicationPage
          : const bool.fromEnvironment('PREVIEW_CLOUD_SYNC')
          ? CloudSyncPage
          : const bool.fromEnvironment('PREVIEW_SYSTEM_UPDATES')
          ? SystemUpdatesPage
          : const bool.fromEnvironment('PREVIEW_SMB_SHARES')
          ? SmbSharesPage
          : const bool.fromEnvironment('PREVIEW_NFS_SHARES')
          ? NfsSharesPage
          : const bool.fromEnvironment('PREVIEW_QUOTAS')
          ? QuotasPage
          : const bool.fromEnvironment('PREVIEW_SNAPSHOT_SCHEDULES')
          ? SnapshotSchedulesPage
          : const bool.fromEnvironment('PREVIEW_ZVOLS')
          ? ZvolsPage
          : const bool.fromEnvironment('PREVIEW_PERMISSIONS')
          ? PermissionsPage
          : const bool.fromEnvironment('PREVIEW_BOOT_ENVIRONMENTS')
          ? BootEnvironmentsPage
          : null;
      await tester.pumpWidget(const DashboardPreviewApp());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      if (pageType == null) {
        expect(find.text('atlas'), findsOneWidget);
      } else {
        expect(find.byType(pageType), findsOneWidget);
      }
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('preview-banner'))),
      );
      await _expectNoPreviewTransport(
        container,
        container.read(dashboardActiveSessionProvider)!.repository,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'permissions preview initial flag binds all ACL fixture types and rejects writes without transport',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialPermissions: true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PermissionsPage), findsOneWidget);
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PermissionsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedPermissionsSession;
      final datasets = await api.loadPermissionDatasets();
      final types = <PermissionAclType>{};
      expect(datasets.any((dataset) => !dataset.editable), isTrue);
      for (final dataset in datasets) {
        final review = await api.loadPermissionReview(dataset);
        types.add(review.aclType);
        final request = PermissionApplyRequest(
          review: review,
          acl: review.canEditAcl ? review.acl : null,
          mode: review.canEditAcl ? null : '700',
        );
        await expectLater(
          api.applyPermissions(request),
          throwsA(isA<PermissionsException>()),
        );
      }
      expect(types, containsAll(PermissionAclType.values));
      expect(await api.loadPermissionDatasets(), same(datasets));
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Zvol preview initial flag preserves provisioning fixtures and rejects create update delete',
    (tester) async {
      await tester.pumpWidget(const DashboardPreviewApp(initialZvols: true));
      await tester.pumpAndSettle();
      expect(find.byType(ZvolsPage), findsOneWidget);
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ZvolsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedZvolsSession;
      final inventory = await api.loadZvols();
      expect(
        inventory.volumes.map((volume) => volume.provisioning),
        containsAll(['Thin', 'Reserved']),
      );
      expect(inventory.volumes.any((volume) => volume.readonly), isTrue);
      expect(
        await api.loadZvolRecommendedBlockSize(inventory.parents.first),
        '16K',
      );
      final reviews = [
        await api.reviewZvolCreate(
          ZvolCreate(
            parent: inventory.parents.first,
            name: 'sample-new',
            sizeBytes: 1073741824,
          ),
        ),
        await api.reviewZvolUpdate(
          ZvolUpdate(volume: inventory.volumes.first, readonly: true),
        ),
        await api.reviewZvolDelete(inventory.volumes.first),
      ];
      expect(
        reviews.map((review) => review.action),
        containsAll(ZvolAction.values),
      );
      for (final review in reviews) {
        expect(
          (await api.executeZvolReview(review, review.target)).outcome,
          ZvolOutcome.rejected,
        );
      }
      expect(await api.loadZvols(), same(inventory));
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'boot preview initial flag preserves running next-boot and keep safety cases; no review can authorize changes',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialBootEnvironments: true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BootEnvironmentsPage), findsOneWidget);
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BootEnvironmentsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedBootEnvironmentsSession;
      final inventory = await api.loadBootEnvironments();
      expect(inventory.environments.where((item) => item.active), hasLength(1));
      expect(
        inventory.environments.where((item) => item.activated),
        hasLength(1),
      );
      expect(
        inventory.environments.singleWhere((item) => item.active).canDelete,
        isFalse,
      );
      expect(
        inventory.environments
            .where((item) => item.keep)
            .every((item) => !item.canDelete),
        isTrue,
      );
      final eligible = inventory.environments.singleWhere(
        (item) => item.canDelete,
      );
      for (final action in BootEnvironmentAction.values) {
        await expectLater(
          api.reviewBootEnvironment(
            BootEnvironmentRequest(
              inventory: inventory,
              snapshot: eligible,
              action: action,
              targetName: action == BootEnvironmentAction.clone
                  ? 'sample-recovery'
                  : null,
              keep: action == BootEnvironmentAction.keep ? true : null,
            ),
          ),
          throwsA(isA<StateError>()),
        );
      }
      final after = await api.loadBootEnvironments();
      expect(
        after.environments.map(
          (item) => (item.id, item.active, item.activated, item.keep),
        ),
        inventory.environments.map(
          (item) => (item.id, item.active, item.activated, item.keep),
        ),
      );
      await _expectNoPreviewTransport(container, repository);
      expect(tester.takeException(), isNull);
    },
  );
  for (final (label, app, pageType) in [
    (
      'SMB shares',
      const DashboardPreviewApp(initialSmbShares: true),
      SmbSharesPage,
    ),
    (
      'NFS shares',
      const DashboardPreviewApp(initialNfsShares: true),
      NfsSharesPage,
    ),
    ('Quotas', const DashboardPreviewApp(initialQuotas: true), QuotasPage),
    (
      'Snapshot schedules',
      const DashboardPreviewApp(initialSnapshotSchedules: true),
      SnapshotSchedulesPage,
    ),
    (
      'Permissions',
      const DashboardPreviewApp(initialPermissions: true),
      PermissionsPage,
    ),
    ('Zvols', const DashboardPreviewApp(initialZvols: true), ZvolsPage),
    (
      'Boot environments',
      const DashboardPreviewApp(initialBootEnvironments: true),
      BootEnvironmentsPage,
    ),
  ]) {
    testWidgets('$label sample entrypoint is clearly labeled at 430px', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(430, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      expect(find.byType(pageType), findsOneWidget);
      expect(find.text('PREVIEW · SAMPLE DATA · NO SERVER'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'accounts preview supplies protected synthetic identities and rejects mutations',
    (tester) async {
      await tester.pumpWidget(const DashboardPreviewApp(initialAccounts: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AccountsPage)),
      );
      final repository = container
          .read(dashboardActiveSessionProvider)!
          .repository;
      final api = repository as AuthenticatedAccountsSession;
      final inventory = await api.loadAccounts();
      expect(inventory.users.any((user) => user.builtin), isTrue);
      final user = inventory.users.first;
      await expectLater(
        api.updateAccountUser(
          user,
          AccountUserUpdate(fullName: 'Preview only'),
        ),
        throwsA(isA<AccountsException>()),
      );
      await expectLater(
        api.deleteAccountUser(user, user.username),
        throwsA(isA<AccountsException>()),
      );
      await expectLater(
        api.createAccountGroup(
          AccountGroupCreate(inventory: inventory, name: 'sample_new'),
        ),
        throwsA(isA<AccountsException>()),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('activity preview stays synthetic and rejects cancellation', (
    tester,
  ) async {
    await tester.pumpWidget(const DashboardPreviewApp(initialActivity: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preview-banner')), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ActivityPage)),
    );
    final repository = container
        .read(dashboardActiveSessionProvider)!
        .repository;
    final api = repository as AuthenticatedActivitySession;
    final job = (await api.loadActivityJobs(const JobQuery())).entries.first;
    expect(
      (await api.cancelActivityJob(job, job.confirmation)).outcome,
      JobCancelOutcome.rejected,
    );
    expect(
      (await api.checkActivityCancellation(job)).outcome,
      JobCancelOutcome.rejected,
    );
    await expectLater(
      repository.connect(
        serverInput: 'https://fixture.invalid',
        apiKey: null,
        username: null,
      ),
      throwsA(anything),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'VM preview is routed to synthetic adapter and never sends a lifecycle change',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialVirtualMachines: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(VirtualMachinesPage)),
      );
      final api =
          container.read(dashboardActiveSessionProvider)!.repository
              as AuthenticatedVirtualMachinesSession;
      final vm = (await api.loadVirtualMachines()).machines.first;
      final review = await api.reviewVmAction(vm, VmAction.stop);
      expect(
        (await api.executeVmReview(
          review,
          confirmation: review.targetName,
        )).outcome,
        VmOperationOutcome.rejected,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'configuration preview preserves sample warning and rejects reviewed edits',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialAppSettings: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      expect(find.text('Current · "Family media library"'), findsOneWidget);
      expect(
        find.textContaining('synthetic-preview-protected-value'),
        findsNothing,
      );
      await _previewTap(
        tester,
        find.byKey(const ValueKey('app-config-select-/display_name')),
      );
      final input = find.byKey(const ValueKey('admin-value-new_value'));
      await tester.ensureVisible(input);
      await tester.enterText(input, 'Preview edit only');
      await _previewTap(tester, find.byKey(const Key('app-config-review')));
      await tester.enterText(
        find.byKey(const Key('app-confirm-name')),
        'sample-media',
      );
      await _previewTap(tester, find.byKey(const Key('app-confirm-submit')));
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      expect(find.text('This review has been used'), findsOneWidget);
      expect(
        find.textContaining(
          'The application, catalogue, form or application pool changed.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'apps preview has synthetic inventory and rejects every mutation without connections',
    (tester) async {
      await tester.pumpWidget(const DashboardPreviewApp(initialApps: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      expect(find.text('sample-media'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AppsPage)),
      );
      final session = container.read(dashboardActiveSessionProvider)!;
      final repository = session.repository;
      final api = repository as AuthenticatedAppsSession;
      final inventory = await api.loadAppsInventory();
      final catalog = await api.loadAppsCatalog();
      final app = inventory.apps.first;
      final details = await api.loadAppVersionDetails(catalog.first, '1.1.0');
      final review = await api.loadAppUpgradeReview(app, details);
      final config = await api.loadAppConfigReview(app);
      expect(config.schema.supported, isTrue);
      expect(
        (await api.updateApp(
          AppConfigUpdateRequest(
            review: config,
            patches: const [
              AppConfigPatch(
                fieldId: '/display_name',
                value: 'Rejected preview update',
              ),
            ],
          ),
        )).outcome,
        AppOperationOutcome.rejected,
      );
      expect(details.formSchema.supported, isTrue);
      expect(
        details.formSchema.validate(details.formSchema.initialValues),
        isNull,
      );
      expect(catalog.every((item) => item.title.startsWith('Sample')), isTrue);
      expect(review.changelog, contains('SAMPLE RELEASE NOTES'));
      expect(
        session.availableMethodNames,
        containsAll([
          'app.create',
          'app.start',
          'app.stop',
          'app.redeploy',
          'app.delete',
          'app.upgrade',
          'app.upgrade_summary',
        ]),
      );
      expect(
        (await api.installApp(
          AppInstallRequest(
            details: details,
            appName: 'sample-new',
            values: details.formSchema.initialValues,
          ),
        )).outcome,
        AppOperationOutcome.rejected,
      );
      for (final action in AppLifecycleAction.values) {
        expect(
          (await api.changeAppState(app, action)).outcome,
          AppOperationOutcome.rejected,
        );
      }
      expect(
        (await api.upgradeApp(
          AppUpgradeRequest(
            app: app,
            details: details,
            review: review,
            values: {},
          ),
        )).outcome,
        AppOperationOutcome.rejected,
      );
      expect(
        (await api.uninstallApp(
          AppUninstallRequest(app: app, confirmedName: app.name),
        )).outcome,
        AppOperationOutcome.rejected,
      );
      expect(
        (await api.pollAppJob(
          const AppJob(id: 1, appName: 'sample-media', operation: 'app.stop'),
        )).outcome,
        AppOperationOutcome.rejected,
      );
      expect((await api.loadAppsInventory()).apps, inventory.apps);
      await expectLater(
        repository.connect(
          serverInput: 'https://example.invalid',
          apiKey: null,
          username: null,
        ),
        throwsUnsupportedError,
      );
      await expectLater(
        container
            .read(rpcConnectorProvider)
            .connect(Uri.parse('wss://example.invalid/api/current')),
        throwsUnsupportedError,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'apps preview keeps sample banner through rejected lifecycle review',
    (tester) async {
      await tester.pumpWidget(const DashboardPreviewApp(initialApps: true));
      await tester.pumpAndSettle();
      await _previewTap(tester, find.byKey(const Key('app-stop-sample-media')));
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('app-confirm-name')),
        'sample-media',
      );
      await tester.pump();
      await _previewTap(tester, find.byKey(const Key('app-confirm-submit')));
      await _previewVisible(tester, find.text('Application operation result'));
      expect(
        find.text(
          const AppOperationResult(outcome: AppOperationOutcome.rejected)
              .userMessage,
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      expect(find.text('RUNNING'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sample app catalog opens version-specific settings', (
    tester,
  ) async {
    await tester.pumpWidget(const DashboardPreviewApp(initialApps: true));
    await tester.pumpAndSettle();
    await _previewTap(tester, find.byKey(const Key('apps-catalog-tab')));
    expect(find.text('Sample Media Library'), findsOneWidget);
    await _previewTap(
      tester,
      find.byKey(const Key('catalog-open-stable-sample-media')),
    );
    await _previewTap(tester, find.byKey(const Key('app-version')));
    await _previewTap(tester, find.text('1.1.0').last);
    await _previewVisible(tester, find.text('Application settings').first);
    expect(find.text('Application settings'), findsWidgets);
    expect(find.byKey(const Key('preview-banner')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'snapshot preview exposes filtered safety cases and rejects create and delete',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialSnapshots: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SnapshotsPage)),
      );
      final api =
          container.read(dashboardActiveSessionProvider)!.repository
              as AuthenticatedSnapshotsSession;
      final datasets = await api.loadSnapshotDatasets();
      final all = await api.loadSnapshots(
        SnapshotQuery(dataset: datasets.first.id),
      );
      final manual = await api.loadSnapshots(
        SnapshotQuery(dataset: datasets.first.id, namePrefix: 'sample-manual'),
      );
      expect(all.entries.length, 4);
      expect(all.entries.where((entry) => !entry.canDelete).length, 3);
      expect(manual.entries.single.canDelete, isTrue);
      expect(
        (await api.createSnapshot(
          SnapshotCreateRequest(dataset: datasets.first, name: 'sample-new'),
        )).outcome,
        SnapshotOperationOutcome.rejected,
      );
      expect(
        (await api.deleteSnapshot(
          SnapshotDeleteRequest(
            snapshot: manual.entries.single,
            confirmation: manual.entries.single.id,
          ),
        )).outcome,
        SnapshotOperationOutcome.rejected,
      );
      final unchanged = await api.loadSnapshots(
        SnapshotQuery(dataset: datasets.first.id),
      );
      expect(unchanged.entries, all.entries);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'snapshot preview rejects a reviewed creation and preserves its banner',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialSnapshots: true),
      );
      await tester.pumpAndSettle();
      await _previewTap(tester, find.text('Create snapshot'));
      await tester.enterText(find.byType(TextField), 'sample-new');
      await _previewTap(tester, find.text('Review creation'));
      await _previewTap(tester, find.text('Create this snapshot'));
      await _previewVisible(
        tester,
        find.text('Preview only. No snapshot was created.'),
      );
      expect(
        find.text('Preview only. No snapshot was created.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final apps in [true, false]) {
    testWidgets(
      '${apps ? 'apps' : 'snapshots'} preview stays labeled at 430px',
      (tester) async {
        tester.view.physicalSize = const Size(430, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          DashboardPreviewApp(initialApps: apps, initialSnapshots: !apps),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('preview-banner')), findsOneWidget);
        expect(find.byType(apps ? AppsPage : SnapshotsPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'dataset property preview is isolated and exposes native editor',
    (tester) async {
      await tester.pumpWidget(const DashboardPreviewApp(initialDatasets: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      expect(find.text('tank/media'), findsOneWidget);
      await tester.ensureVisible(find.text('Edit properties').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit properties').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dataset-quota')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('dataset-compression')),
        300,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dataset-compression')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('native network preview remains isolated and labeled', (
    tester,
  ) async {
    await tester.pumpWidget(const DashboardPreviewApp(initialNetwork: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preview-banner')), findsOneWidget);
    expect(find.text('Network interfaces'), findsOneWidget);
    expect(find.text('enp1s0'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reporting preview offers sample graphs with persistent warning',
    (tester) async {
      await tester.pumpWidget(
        const DashboardPreviewApp(initialReporting: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      expect(find.textContaining('CPU'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sample preview shows dashboard and persistent warning at 430px',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const DashboardPreviewApp());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      expect(find.text('atlas'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('open-management')));
      await tester.pumpAndSettle();
      expect(find.text('Administration'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('admin-quick-controls')));
      await tester.tap(find.byKey(const Key('admin-quick-controls')));
      await tester.pumpAndSettle();
      expect(find.text('Manage server'), findsOneWidget);
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      expect(tester.takeException(), isNull);
      final restart = find.byKey(const Key('service-cifs-restart'));
      await tester.ensureVisible(restart);
      await tester.tap(restart);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview-banner')), findsOneWidget);
      expect(find.text('EXACT TARGET'), findsOneWidget);
      await tester.tap(find.byKey(const Key('management-confirm')));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).last, const Offset(0, 1000));
      await tester.pumpAndSettle();
      expect(find.text('Change not completed'), findsOneWidget);
      expect(find.text('Change completed'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('storage preview stays clearly labeled at 430px', (tester) async {
    tester.view.physicalSize = const Size(430, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const DashboardPreviewApp(initialStorage: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preview-banner')), findsOneWidget);
    expect(find.text('Manage server'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final properties = find.byKey(const Key('management-dataset-properties'));
    await tester.ensureVisible(properties);
    await tester.tap(properties);
    await tester.pumpAndSettle();
    expect(find.text('Dataset properties'), findsOneWidget);
    expect(find.text('tank/media'), findsOneWidget);
    expect(find.byKey(const Key('preview-banner')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _previewVisible(WidgetTester tester, Finder target) async {
  await tester.pumpAndSettle();
  if (target.evaluate().isEmpty) {
    final scrollable = find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .last;
    final state = tester.state<ScrollableState>(scrollable);
    state.position.jumpTo(state.position.minScrollExtent);
    await tester.pumpAndSettle();
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        300,
        maxScrolls: 40,
        scrollable: scrollable,
      );
    }
    await tester.ensureVisible(target);
  } else {
    await tester.ensureVisible(target);
  }
  await tester.pumpAndSettle();
}

Future<void> _expectNoPreviewTransport(
  ProviderContainer container,
  SessionRepository repository,
) async {
  await expectLater(
    repository.connect(
      serverInput: 'https://fixture.invalid',
      apiKey: null,
      username: null,
    ),
    throwsUnsupportedError,
  );
  await expectLater(
    container
        .read(rpcConnectorProvider)
        .connect(Uri.parse('wss://fixture.invalid/api/current')),
    throwsUnsupportedError,
  );
}

Future<void> _previewTap(WidgetTester tester, Finder target) async {
  await _previewVisible(tester, target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}
