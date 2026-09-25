import 'dart:io';

import 'package:test/test.dart';
import 'package:truenas_api/src/session/admin_policy.dart';

void main() {
  AdminOperationDefinition operation(String method) =>
      adminOperationDefinitions.singleWhere((item) => item.method == method);

  test('notification lifecycle requires its projected native gateway', () {
    for (final method in ['alertservice.query', 'alertservice.create']) {
      expect(operation(method).blockedReason, contains('native'));
    }
    for (final method in [
      'alertservice.update',
      'alertservice.delete',
      'alertservice.test',
    ]) {
      expect(
        adminOperationDefinitions.any((entry) => entry.method == method),
        isFalse,
      );
    }
    expect(operation('alertclasses.update').warning, contains('entire'));
    expect(operation('alertclasses.update').warning, contains('proactive'));
  });

  test(
    'email credentials and external sends cannot bypass the native gateway',
    () {
      expect(operation('mail.config').blockedReason, contains('passwords'));
      expect(operation('mail.update').blockedReason, contains('write-only'));
      for (final method in [
        'mail.send',
        'mail.send_raw',
        'mail.send_mail_queue',
        'mail.gmail_send',
      ]) {
        expect(
          adminOperationDefinitions.any((entry) => entry.method == method),
          isFalse,
        );
      }
    },
  );

  test('reviewed operations have stable unique identities and full labels', () {
    expect(adminOperationDefinitions.length, greaterThan(100));
    expect(
      adminOperationDefinitions.map((item) => item.id).toSet(),
      hasLength(adminOperationDefinitions.length),
    );
    expect(
      adminOperationDefinitions.map((item) => item.method).toSet(),
      hasLength(adminOperationDefinitions.length),
    );
    for (final item in adminOperationDefinitions) {
      expect(item.id, item.method);
      expect(item.method, matches(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'));
      expect(item.title.trim(), isNotEmpty, reason: item.method);
      expect(item.description.trim(), isNotEmpty, reason: item.method);
      expect(item.domain.label.trim(), isNotEmpty, reason: item.method);
      if (item.blockedReason != null) {
        expect(
          item.blockedReason!.length,
          greaterThan(20),
          reason: item.method,
        );
      }
    }
  });

  test('all user-facing administration domains are represented', () {
    expect(
      adminOperationDefinitions.map((item) => item.domain).toSet(),
      containsAll(AdminDomain.values),
    );
    expect(
      AdminDomain.values.map((domain) => domain.label).toSet(),
      hasLength(AdminDomain.values.length),
    );
  });

  test('configuration transfers cannot use generic forms', () {
    for (final method in ['config.save', 'config.upload', 'config.reset']) {
      expect(operation(method).blockedReason, isNotNull, reason: method);
    }
    expect(
      operation('config.upload').warning,
      contains('automatically reboots'),
    );
    expect(
      adminOperationDefinitions.where(
        (entry) => entry.method == 'core.download',
      ),
      isEmpty,
    );
  });

  test(
    'time settings cannot bypass native review or reveal full configuration',
    () {
      for (final method in [
        'system.general.config',
        'system.general.update',
        'system.ntpserver.query',
        'system.ntpserver.create',
        'system.ntpserver.update',
        'system.ntpserver.delete',
      ]) {
        expect(operation(method).blockedReason, isNotNull, reason: method);
      }
      expect(
        operation('system.general.config').blockedReason,
        contains('secrets'),
      );
      expect(
        operation('system.general.update').blockedReason,
        contains('timezone'),
      );
      for (final method in [
        'system.ntpserver.peers',
        'system.ntpserver.test_ntp_server',
      ]) {
        expect(
          adminOperationDefinitions.any((entry) => entry.method == method),
          isFalse,
        );
      }
    },
  );

  test(
    'update reads with hidden effects and staging cannot bypass native review',
    () {
      for (final method in [
        'update.config',
        'update.status',
        'update.available_versions',
        'update.download',
        'update.run',
      ]) {
        expect(operation(method).blockedReason, isNotNull, reason: method);
      }
    },
  );

  test('every mutation carries an impact warning and confirmation policy', () {
    for (final item in adminOperationDefinitions) {
      expect(
        item.requiresConfirmation,
        item.risk != AdminRisk.read,
        reason: item.method,
      );
      if (item.requiresConfirmation) {
        expect(item.warning, isNotNull, reason: item.method);
        expect(item.warning!.length, greaterThan(20), reason: item.method);
      }
      expect(
        item.requiresTypedConfirmation,
        item.risk == AdminRisk.destructive || item.risk == AdminRisk.disruptive,
        reason: item.method,
      );
    }
  });

  test('deletion, rollback and force-off are never classified as reads', () {
    for (final item in adminOperationDefinitions.where(
      (item) =>
          RegExp(r'\.(delete|destroy|wipe|rollback|poweroff|reset)$')
              .hasMatch(item.method),
    )) {
      if (item.method == 'interface.rollback') {
        expect(item.blockedReason, isNotNull);
      } else {
        expect(item.risk, AdminRisk.destructive, reason: item.method);
      }
    }
    for (final method in [
      'system.reboot',
      'system.shutdown',
      'core.job_abort',
      'vm.stop',
      'vm.restart',
      'app.stop',
      'app.redeploy',
    ]) {
      expect(
        operation(method).requiresTypedConfirmation,
        isTrue,
        reason: method,
      );
    }
    for (final method in [
      'replication.run',
      'cloudsync.sync',
      'rsynctask.run',
      'cloud_backup.sync',
      'reporting.update',
      'audit.update',
    ]) {
      expect(operation(method).risk, AdminRisk.destructive, reason: method);
    }
  });

  test('generic forms cannot bypass existing typed management safeguards', () {
    for (final method in [
      'sharing.smb.create',
      'sharing.smb.update',
      'sharing.smb.delete',
      'sharing.nfs.create',
      'sharing.nfs.update',
      'sharing.nfs.delete',
      'boot.environment.clone',
      'pool.dataset.set_quota',
      'pool.snapshottask.create',
      'pool.snapshottask.update',
      'pool.snapshottask.delete',
      'pool.snapshottask.run',
      'boot.environment.keep',
      'boot.environment.activate',
      'boot.environment.destroy',
      'filesystem.setacl',
      'filesystem.setperm',
    ]) {
      expect(
        operation(method).blockedReason,
        isNotNull,
        reason: '$method must use its typed native workflow.',
      );
      expect(operation(method).requiresConfirmation, isTrue, reason: method);
    }
    for (final method in [
      'service.control',
      'pool.dataset.create',
      'pool.dataset.delete',
      'pool.snapshot.create',
    ]) {
      expect(operation(method).blockedReason, contains('Quick management'));
    }
    for (final method in [
      'service.start',
      'service.stop',
      'service.restart',
      'core.bulk',
      'core.download',
      'auth.generate_token',
      'auth.generate_onetime_password',
      'filesystem.put',
    ]) {
      expect(
        adminOperationDefinitions.any((item) => item.method == method),
        isFalse,
        reason: method,
      );
    }
  });

  test(
    'network transactions and topology mutations require dedicated flows',
    () {
      for (final item in adminOperationDefinitions.where(
        (item) =>
            (item.domain == AdminDomain.network ||
                item.method.startsWith('pool.') &&
                    !item.method.startsWith('pool.scrub.') &&
                    !item.method.startsWith('pool.snapshottask.')) &&
            item.risk != AdminRisk.read,
      )) {
        if ([
          'pool.dataset.set_quota',
          'pool.snapshot.hold',
          'pool.snapshot.release',
        ].contains(item.method)) {
          continue;
        }
        expect(item.blockedReason, isNotNull, reason: item.method);
      }
      expect(
        operation('system.general.update').blockedReason,
        contains('rollback'),
      );
    },
  );

  test(
    'secret material files terminals and dynamic installers fail closed',
    () {
      for (final method in [
        'pool.dataset.export_key',
        'pool.dataset.export_keys',
        'pool.dataset.change_key',
        'pool.dataset.unlock',
        'system.advanced.sed_global_password',
        'certificate.query',
        'api_key.create',
        'api_key.query',
        'api_key.update',
        'api_key.delete',
        'cloudsync.credentials.create',
        'cloudsync.credentials.update',
        'cloudsync.credentials.delete',
        'keychaincredential.query',
        'keychaincredential.create',
        'keychaincredential.update',
        'keychaincredential.delete',
        'keychaincredential.generate_ssh_key_pair',
        'alert.list',
        'alert.dismiss',
        'alert.restore',
        'kerberos.keytab.query',
        'iscsi.auth.query',
        'nvmet.host.query',
        'cloudsync.credentials.query',
        'config.save',
        'config.upload',
        'config.reset',
        'update.file',
        'core.job_download_logs',
        'audit.export',
        'system.debug',
        'vm.get_console',
        'vm.get_display_web_uri',
        'core.resize_shell',
        'app.container_console_choices',
        'app.create',
        'app.update',
        'app.delete',
        'app.upgrade',
        'app.rollback',
        'vm.create',
        'filesystem.setacl',
        'filesystem.setperm',
        'user.delete',
        'privilege.update',
        'failover.become_passive',
      ]) {
        expect(operation(method).blockedReason, isNotNull, reason: method);
      }
    },
  );

  test('unverified event names do not become executable public methods', () {
    for (final method in [
      'container.query',
      'container.device.query',
      'sharing.webshare.query',
    ]) {
      expect(operation(method).blockedReason, isNotNull, reason: method);
    }
  });

  test(
    'ordinary native configuration and lifecycle remains available by policy',
    () {
      for (final method in [
        'iscsi.portal.create',
        'iscsi.target.update',
        'iscsi.targetextent.delete',
        'nvmet.subsys.create',
        'nvmet.port.update',
        'nvmet.host_subsys.create',
        'group.create',
        'kerberos.realm.create',
        'service.update',
        'app.start',
        'app.stop',
        'app.redeploy',
      ]) {
        expect(operation(method).blockedReason, isNull, reason: method);
      }
    },
  );

  test('native cancellation and VM lifecycle cannot bypass typed gateways', () {
    for (final method in [
      'system.reboot',
      'system.shutdown',
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
      'core.job_abort',
      'vm.start',
      'vm.stop',
      'vm.restart',
      'vm.poweroff',
    ]) {
      expect(operation(method).blockedReason, isNotNull);
    }
  });

  test('parity ledger preserves all requirements and only documented read evidence', () {
    // Exact row mapping for READONLY_LIVE_VALIDATION.md, 2026-09-12.
    // These labels record limited reads on 25.10.1, never write acceptance.
    const observedReadIds = {
      'TD-001',
      'TD-005',
      'TD-008',
      'TD-010',
      'TD-011',
      'TD-014',
      'TD-015',
      'TD-016',
      'TD-017',
      'TD-019',
      'TD-026',
      'TD-028',
      'TD-069',
      'TD-073',
      'TD-076',
    };
    final requirements =
        File('../../docs/planning/TRUERAID_CAPABILITY_MATRIX.csv')
            .readAsLinesSync()
            .skip(1)
            .where((line) => line.isNotEmpty)
            .map((line) => line.split(',').first)
            .toSet();
    final statusLines = File('../../docs/planning/WEBUI_PARITY_STATUS.csv')
        .readAsLinesSync()
        .skip(1)
        .where((line) => line.isNotEmpty)
        .toList();
    final statusIds = statusLines.map((line) => line.split(',').first).toSet();
    expect(requirements, hasLength(88));
    expect(statusLines, hasLength(88));
    expect(statusIds, requirements);
    expect(observedReadIds, hasLength(15));
    expect(statusIds, containsAll(observedReadIds));
    for (final line in statusLines) {
      final fields = line.split(',');
      expect(fields, hasLength(5), reason: fields.first);
      expect(
        fields[1],
        isIn([
          'native_partial',
          'schema_partial',
          'blocked_specialized',
          'missing',
          'foundation_partial',
        ]),
      );
      expect(fields[2], isNotEmpty);
      expect(fields[3], isNotEmpty);
      expect(
        fields[4],
        observedReadIds.contains(fields[0])
            ? 'read_subset_observed_25.10.1'
            : 'not_run',
        reason: fields[0],
      );
    }
  });
}
