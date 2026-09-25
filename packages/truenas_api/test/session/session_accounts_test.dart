import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const methods = {
  'auth.me',
  'user.query',
  'group.query',
  'privilege.query',
  'user.shell_choices',
  'group.has_password_enabled_user',
  'filesystem.stat',
  'filesystem.listdir',
  'user.create',
  'user.update',
  'user.delete',
  'group.create',
  'group.update',
  'group.delete',
};
Map<String, Object?> user(
  int id,
  String name, {
  int primary = 10,
  bool builtin = false,
  bool locked = false,
  bool disabled = false,
}) => {
  'id': id,
  'uid': id + 3000,
  'username': name,
  'full_name': '$name account',
  'email': null,
  'home': '/mnt/tank/$name',
  'shell': '/usr/sbin/nologin',
  'group': {'id': primary},
  'groups': <int>[],
  'roles': <String>[],
  'local': true,
  'builtin': builtin,
  'immutable': builtin,
  'smb': false,
  'locked': locked,
  'password_disabled': disabled,
  'ssh_password_enabled': false,
  'sshpubkey': 'protected-existing-key',
  'twofactor_auth_configured': false,
  'api_keys': <int>[],
  'last_password_change': '2026-01-01T00:00:00Z',
  'sudo_commands': <String>[],
  'sudo_commands_nopasswd': <String>[],
};
Map<String, Object?> group(
  int id,
  String name, {
  bool builtin = false,
  List<String> roles = const [],
}) => {
  'id': id,
  'gid': id + 3000,
  'name': name,
  'local': true,
  'builtin': builtin,
  'immutable': builtin,
  'smb': false,
  'users': <int>[],
  'roles': roles,
  'sudo_commands': <String>[],
  'sudo_commands_nopasswd': <String>[],
};
Matcher reason(AccountsExceptionReason reason) =>
    isA<AccountsException>().having((error) => error.reason, 'reason', reason);

String fixturePublicKey() {
  final type = utf8.encode('ssh-ed25519');
  return 'ssh-ed25519 ${base64Encode([0, 0, 0, type.length, ...type, 0, 0, 0, 32, ...List.filled(32, 1)])} fixture';
}

Future<AccountsTestHarness> connect({
  Set<String> available = methods,
  String version = '25.10.1',
}) async {
  final h = AccountsTestHarness(available, version);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'fake-account-key',
    username: 'admin',
  );
  return h;
}

void main() {
  test('inventory uses bounded projections without password hashes and only exposes SSH presence', () async {
    final h = await connect();
    final inventory = await h.repo.loadAccounts();
    expect(inventory.currentUsername, 'admin');
    expect(
      inventory.users
          .firstWhere((user) => user.username == 'demo')
          .sshKeyPresent,
      isTrue,
    );
    expect(inventory.privileges.single.localGids, [3001]);
    final query = h.transport.requests.lastWhere(
      (request) => request['method'] == 'user.query',
    );
    final options = (query['params'] as List)[1] as Map;
    expect(options['limit'], 513);
    final selected = options['select'] as List;
    for (final key in ['unixhash', 'smbhash', 'password', 'password_history']) {
      expect(selected, isNot(contains(key)));
    }
    expect(h.transport.writes, isEmpty);
    expect(() => inventory.users.clear(), throwsUnsupportedError);
    expect(() => inventory.shells.clear(), throwsUnsupportedError);
  });

  for (final version in ['25.04.2', '25.10-BETA.1', '26.0.1']) {
    test(
      'unsupported version $version sends no account inventory query',
      () async {
        final h = await connect(version: version);
        await expectLater(
          h.repo.loadAccounts(),
          throwsA(reason(AccountsExceptionReason.unsupportedVersion)),
        );
        expect(
          h.transport.requests.where(
            (request) => request['method'] == 'user.query',
          ),
          isEmpty,
        );
      },
    );
  }
  test('read-only account can inspect but cannot mutate', () async {
    final h = await connect(available: methods.difference({'user.update'}));
    final target = (await h.repo.loadAccounts()).users.firstWhere(
      (user) => user.username == 'demo',
    );
    await expectLater(
      h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New name')),
      throwsA(reason(AccountsExceptionReason.unavailableMethod)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test('profile update preserves keys, groups, unknown protected account settings and ignores secret response fields', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.firstWhere(
      (user) => user.username == 'demo',
    );
    final result = await h.repo.updateAccountUser(
      target,
      AccountUserUpdate(fullName: 'New name', email: 'demo@example.test'),
    );
    expect(
      result.outcome,
      AccountsOperationOutcome.verified,
      reason: h.transport.requests
          .map((request) => request['method'])
          .join(', '),
    );
    expect(result.userMessage, isNot(contains('returned-secret')));
    expect(h.transport.writes.single['params'], [
      102,
      {'full_name': 'New name', 'email': 'demo@example.test'},
    ]);
    expect(
      h.transport.users.firstWhere((row) => row['id'] == 102)['sshpubkey'],
      'protected-existing-key',
    );
  });
  test('user creation explicitly avoids home and group deletion/creation side effects', () async {
    final h = await connect();
    final inventory = await h.repo.loadAccounts();
    final result = await h.repo.createAccountUser(
      AccountUserCreate(
        inventory: inventory,
        username: 'new-user',
        fullName: 'New User',
        primaryGroupId: 10,
        password: 'fixture-password',
      ),
    );
    expect(result.outcome, AccountsOperationOutcome.verified);
    final values = (h.transport.writes.single['params'] as List).single as Map;
    expect(values['home'], '/var/empty');
    expect(values['home_create'], isFalse);
    expect(values['group_create'], isFalse);
    expect(values['random_password'], isFalse);
    expect(values['sudo_commands'], isEmpty);
    expect(values['ssh_password_enabled'], isFalse);
  });
  test(
    'SMB user creation verifies the automatic builtin_users membership',
    () async {
      final h = await connect();
      final inventory = await h.repo.loadAccounts();
      final result = await h.repo.createAccountUser(
        AccountUserCreate(
          inventory: inventory,
          username: 'smb-user',
          fullName: 'SMB User',
          primaryGroupId: 10,
          password: 'fixture-password',
          smb: true,
        ),
      );
      expect(result.outcome, AccountsOperationOutcome.verified);
      expect(h.transport.users.last['groups'], [2]);
    },
  );
  test('SMB enabling requires an explicit password and preserves update memberships', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.firstWhere(
      (user) => user.username == 'demo',
    );
    await expectLater(
      h.repo.updateAccountUser(target, AccountUserUpdate(smb: true)),
      throwsA(reason(AccountsExceptionReason.invalidInput)),
    );
    expect(h.transport.writes, isEmpty);
    expect(
      (await h.repo.updateAccountUser(
        target,
        AccountUserUpdate(smb: true, password: 'fixture-password'),
      )).outcome,
      AccountsOperationOutcome.verified,
    );
    expect(
      h.transport.users.firstWhere((row) => row['id'] == 102)['groups'],
      isEmpty,
    );
  });
  test('password updates need changed safe timestamp readback without returning the password', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.firstWhere(
      (user) => user.username == 'demo',
    );
    final request = AccountUserUpdate(password: 'replacement-password');
    expect(request.toString(), isNot(contains('replacement-password')));
    expect(
      (await h.repo.updateAccountUser(target, request)).outcome,
      AccountsOperationOutcome.verified,
    );
    expect(h.transport.writes.length, 1);
  });
  test(
    'unchanged password timestamp cannot falsely verify a password reset',
    () async {
      final h = await connect();
      final target = (await h.repo.loadAccounts()).users.firstWhere(
        (user) => user.username == 'demo',
      );
      h.transport.preservePasswordTimestamp = true;
      expect(
        (await h.repo.updateAccountUser(
          target,
          AccountUserUpdate(password: 'replacement-password'),
        )).outcome,
        AccountsOperationOutcome.unknown,
      );
    },
  );
  test('SSH replacement accepts a structured public key, never existing key content', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.firstWhere(
      (user) => user.username == 'demo',
    );
    final type = utf8.encode('ssh-ed25519');
    final blob = [
      0,
      0,
      0,
      type.length,
      ...type,
      0,
      0,
      0,
      32,
      ...List.filled(32, 1),
    ];
    final key = 'ssh-ed25519 ${base64Encode(blob)} fixture';
    expect(
      (await h.repo.updateAccountUser(
        target,
        AccountUserUpdate(sshPublicKey: key),
      )).outcome,
      AccountsOperationOutcome.verified,
    );
    expect(
      h.transport.users.firstWhere((row) => row['id'] == 102)['sshpubkey'],
      key,
    );
  });
  for (final key in [
    '-----BEGIN PRIVATE KEY-----',
    'command="do something" ssh-ed25519 AAAA',
    'ssh-ed25519 AAAA',
    'ssh-rsa AAAA\nssh-rsa AAAA',
  ]) {
    test(
      'malformed or unsafe SSH input is rejected before dispatch: ${key.length} chars',
      () async {
        final h = await connect();
        final target = (await h.repo.loadAccounts()).users.firstWhere(
          (user) => user.username == 'demo',
        );
        await expectLater(
          h.repo.updateAccountUser(
            target,
            AccountUserUpdate(sshPublicKey: key),
          ),
          throwsA(reason(AccountsExceptionReason.invalidInput)),
        );
        expect(h.transport.writes, isEmpty);
      },
    );
  }
  test(
    'SSH clear is explicit and verified separately from absence of a change',
    () async {
      final h = await connect();
      final target = (await h.repo.loadAccounts()).users.firstWhere(
        (user) => user.username == 'demo',
      );
      expect(
        (await h.repo.updateAccountUser(
          target,
          AccountUserUpdate(sshPublicKey: ''),
        )).outcome,
        AccountsOperationOutcome.verified,
      );
      expect((h.transport.writes.single['params'] as List)[1], {
        'sshpubkey': '',
      });
    },
  );
  test('builtin, immutable, and directory users cannot be changed', () async {
    final h = await connect();
    h.transport.users.add({...user(104, 'directory'), 'local': false});
    h.transport.users.add({...user(105, 'immutable'), 'immutable': true});
    final inventory = await h.repo.loadAccounts();
    for (final name in ['root', 'directory', 'immutable']) {
      final target = inventory.users.firstWhere(
        (user) => user.username == name,
      );
      await expectLater(
        h.repo.updateAccountUser(
          target,
          AccountUserUpdate(fullName: 'Changed'),
        ),
        throwsA(reason(AccountsExceptionReason.protectedAccount)),
      );
      await expectLater(
        h.repo.deleteAccountUser(target, name),
        throwsA(reason(AccountsExceptionReason.protectedAccount)),
      );
    }
    expect(h.transport.writes, isEmpty);
  });
  test('active identity cannot be deleted locked or have membership access changed', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.firstWhere(
      (user) => user.username == 'admin',
    );
    await expectLater(
      h.repo.deleteAccountUser(target, 'admin'),
      throwsA(reason(AccountsExceptionReason.protectedAccount)),
    );
    await expectLater(
      h.repo.updateAccountUser(target, AccountUserUpdate(locked: true)),
      throwsA(reason(AccountsExceptionReason.protectedAccount)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test('last administrator and false password-enabled proof reject before dispatch', () async {
    final h = await connect();
    h.transport.users.add(user(103, 'backup', primary: 1));
    final inventory = await h.repo.loadAccounts();
    final backup = inventory.users.firstWhere(
      (user) => user.username == 'backup',
    );
    h.transport.adminProof = false;
    await expectLater(
      h.repo.updateAccountUser(backup, AccountUserUpdate(locked: true)),
      throwsA(reason(AccountsExceptionReason.lastAdministrator)),
    );
    expect(h.transport.writes, isEmpty);
    h.transport.adminProof = true;
    expect(
      (await h.repo.updateAccountUser(
        backup,
        AccountUserUpdate(locked: true),
      )).outcome,
      AccountsOperationOutcome.verified,
    );
    final proof = h.transport.requests.lastWhere(
      (request) => request['method'] == 'group.has_password_enabled_user',
    );
    expect((proof['params'] as List).first, [3001]);
    expect((proof['params'] as List)[1], contains(103));
  });
  test('administrator membership removal cannot rely on locked or password-disabled alternatives', () async {
    final h = await connect();
    h.transport.identity = 'reader';
    final target = (await h.repo.loadAccounts()).users.firstWhere(
      (user) => user.username == 'admin',
    );
    await expectLater(
      h.repo.updateAccountUser(target, AccountUserUpdate(primaryGroupId: 10)),
      throwsA(reason(AccountsExceptionReason.lastAdministrator)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'user deletion preserves primary group and blocks API-key dependencies',
    () async {
      final h = await connect();
      h.transport.users.firstWhere((row) => row['id'] == 102)['api_keys'] = [7];
      var target = (await h.repo.loadAccounts()).users.firstWhere(
        (user) => user.username == 'demo',
      );
      await expectLater(
        h.repo.deleteAccountUser(target, 'demo'),
        throwsA(reason(AccountsExceptionReason.dependency)),
      );
      h.transport.users.firstWhere((row) => row['id'] == 102)['api_keys'] =
          <int>[];
      target = (await h.repo.loadAccounts()).users.firstWhere(
        (user) => user.username == 'demo',
      );
      expect(
        (await h.repo.deleteAccountUser(target, 'demo')).outcome,
        AccountsOperationOutcome.verified,
      );
      expect(h.transport.writes.single['params'], [
        102,
        {'delete_group': false},
      ]);
    },
  );
  test(
    'group create and membership update use API user IDs not UIDs',
    () async {
      final h = await connect();
      var inventory = await h.repo.loadAccounts();
      expect(
        (await h.repo.createAccountGroup(
          AccountGroupCreate(
            inventory: inventory,
            name: 'new-group',
            userIds: [102],
          ),
        )).outcome,
        AccountsOperationOutcome.verified,
      );
      inventory = await h.repo.loadAccounts();
      final target = inventory.groups.firstWhere(
        (group) => group.name == 'new-group',
      );
      expect(
        (await h.repo.updateAccountGroup(
          target,
          AccountGroupUpdate(name: 'renamed', smb: true, userIds: []),
        )).outcome,
        AccountsOperationOutcome.verified,
      );
      expect((h.transport.writes.first['params'] as List).single, {
        'name': 'new-group',
        'smb': false,
        'users': [102],
        'sudo_commands': [],
        'sudo_commands_nopasswd': [],
      });
    },
  );
  test(
    'group removal blocks primary members and privilege dependencies',
    () async {
      final h = await connect();
      var inventory = await h.repo.loadAccounts();
      final staff = inventory.groups.firstWhere(
        (group) => group.name == 'staff',
      );
      await expectLater(
        h.repo.deleteAccountGroup(staff, 'staff'),
        throwsA(reason(AccountsExceptionReason.dependency)),
      );
      await expectLater(
        h.repo.updateAccountGroup(staff, AccountGroupUpdate(userIds: [])),
        throwsA(reason(AccountsExceptionReason.dependency)),
      );
      h.transport.groups.add(group(20, 'privileged'));
      h.transport.privileges.add({
        'id': 2,
        'name': 'Custom',
        'builtin_name': null,
        'local_groups': [
          {'gid': 3020},
        ],
        'ds_groups': [],
        'roles': ['SHARING_ADMIN'],
        'web_shell': false,
      });
      inventory = await h.repo.loadAccounts();
      await expectLater(
        h.repo.deleteAccountGroup(
          inventory.groups.firstWhere((group) => group.id == 20),
          'privileged',
        ),
        throwsA(reason(AccountsExceptionReason.dependency)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('empty group deletion explicitly retains all user accounts', () async {
    final h = await connect();
    h.transport.groups.add(group(20, 'empty'));
    final target = (await h.repo.loadAccounts()).groups.firstWhere(
      (group) => group.id == 20,
    );
    expect(
      (await h.repo.deleteAccountGroup(target, 'empty')).outcome,
      AccountsOperationOutcome.verified,
    );
    expect(h.transport.writes.single['params'], [
      20,
      {'delete_users': false},
    ]);
    expect(h.transport.users.length, 3);
  });
  test(
    'stale field or private key drift rejects the reviewed handle',
    () async {
      final h = await connect();
      final target = (await h.repo.loadAccounts()).users.firstWhere(
        (user) => user.username == 'demo',
      );
      h.transport.users.firstWhere((row) => row['id'] == 102)['sshpubkey'] =
          'changed-outside-review';
      await expectLater(
        h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
        throwsA(reason(AccountsExceptionReason.staleSnapshot)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('handles from another connection cannot authorize a mutation', () async {
    final first = await connect(), second = await connect();
    final target = (await first.repo.loadAccounts()).users.firstWhere(
      (user) => user.username == 'demo',
    );
    await expectLater(
      second.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
      throwsA(reason(AccountsExceptionReason.staleSnapshot)),
    );
    expect(second.transport.writes, isEmpty);
  });
  for (final mode in ['timeout', 'error', 'wrong-id', 'readback']) {
    test('$mode after dispatch is unknown and never retries', () async {
      final h = await connect();
      final target = (await h.repo.loadAccounts()).users.firstWhere(
        (user) => user.username == 'demo',
      );
      h.transport.failure = mode;
      final result = await h.repo.updateAccountUser(
        target,
        AccountUserUpdate(fullName: 'New'),
      );
      expect(result.outcome, AccountsOperationOutcome.unknown);
      expect(result.userMessage, isNot(contains('private-server-error')));
      h.transport.failure = null;
      final current = (await h.repo.loadAccounts()).users.firstWhere(
        (user) => user.username == 'demo',
      );
      await expectLater(
        h.repo.updateAccountUser(
          current,
          AccountUserUpdate(fullName: 'Another'),
        ),
        throwsA(reason(AccountsExceptionReason.busy)),
      );
      expect(h.transport.writes.length, 1);
    });
  }
  test('success invalidates issued handles and duplicate requests', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.firstWhere(
      (user) => user.username == 'demo',
    );
    await h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New'));
    await expectLater(
      h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'Another')),
      throwsA(reason(AccountsExceptionReason.staleSnapshot)),
    );
    expect(h.transport.writes.length, 1);
  });
  for (final number in [-9223372036854775808, 9007199254740992]) {
    test('unsafe JSON identity $number is rejected', () async {
      final h = await connect();
      h.transport.users.first['uid'] = number;
      await expectLater(
        h.repo.loadAccounts(),
        throwsA(reason(AccountsExceptionReason.invalidResponse)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test('oversized inventory is blocked instead of presenting incomplete dependency proof', () async {
    final h = await connect();
    h.transport.users.addAll(
      List.generate(511, (index) => user(1000 + index, 'fixture$index')),
    );
    await expectLater(
      h.repo.loadAccounts(),
      throwsA(reason(AccountsExceptionReason.invalidResponse)),
    );
  });
  for (final method in ['filesystem.stat', 'filesystem.listdir']) {
    test(
      'missing $method permission rejects home update before dispatch',
      () async {
        final h = await connect(available: methods.difference({method}));
        final target = (await h.repo.loadAccounts()).users.last;
        await expectLater(
          h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
          throwsA(reason(AccountsExceptionReason.unavailableMethod)),
        );
        expect(h.transport.writes, isEmpty);
      },
    );
  }
  test(
    'missing home cannot cause implicit recreation on a profile edit',
    () async {
      final h = await connect();
      final target = (await h.repo.loadAccounts()).users.last;
      h.transport.absentPaths.add(target.home);
      await expectLater(
        h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
        throwsA(reason(AccountsExceptionReason.unavailable)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  for (final scenario in <String, (String, Map<String, Object?>)>{
    'symlink home': ('', {'realpath': '/mnt/tank/someone-else'}),
    'wrong home owner': ('', {'uid': 1}),
    'home ACL': ('', {'acl': true}),
    'world writable home': ('', {'mode': 16895}),
    'symlink SSH directory': ('/.ssh', {'type': 'SYMLINK'}),
    'SSH mountpoint': ('/.ssh', {'is_mountpoint': true}),
    'nested SSH mount': ('/.ssh', {'mount_id': 2}),
    'SSH ACL': ('/.ssh', {'acl': true}),
    'writable SSH directory': ('/.ssh', {'mode': 16850}),
    'symlink key': ('/.ssh/authorized_keys', {'type': 'SYMLINK'}),
    'hardlinked key': ('/.ssh/authorized_keys', {'nlink': 2}),
    'key wrong owner': ('/.ssh/authorized_keys', {'uid': 1}),
    'key ACL': ('/.ssh/authorized_keys', {'acl': true}),
  }.entries) {
    test(
      '${scenario.key} blocks even ordinary profile edits before dispatch',
      () async {
        final h = await connect();
        final target = (await h.repo.loadAccounts()).users.last;
        h.transport.pathOverrides['${target.home}${scenario.value.$1}'] =
            scenario.value.$2;
        await expectLater(
          h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
          throwsA(reason(AccountsExceptionReason.dependency)),
        );
        expect(h.transport.writes, isEmpty);
      },
    );
  }
  test(
    'extra SSH files block replacement and deletion before dispatch',
    () async {
      final h = await connect();
      final target = (await h.repo.loadAccounts()).users.last;
      h.transport.extraSshFile = true;
      await expectLater(
        h.repo.updateAccountUser(
          target,
          AccountUserUpdate(sshPublicKey: fixturePublicKey()),
        ),
        throwsA(reason(AccountsExceptionReason.dependency)),
      );
      await expectLater(
        h.repo.deleteAccountUser(target, target.username),
        throwsA(reason(AccountsExceptionReason.dependency)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('no-key edits require source-normalized current permissions', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.last;
    h.transport.pathOverrides['${target.home}/.ssh/authorized_keys'] = {
      'mode': 33188,
    };
    await expectLater(
      h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
      throwsA(reason(AccountsExceptionReason.dependency)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test('absent SSH directory cannot authorize first-key creation', () async {
    final h = await connect();
    h.transport.users.last['sshpubkey'] = null;
    final target = (await h.repo.loadAccounts()).users.last;
    h.transport.absentPaths.addAll([
      '${target.home}/.ssh',
      '${target.home}/.ssh/authorized_keys',
    ]);
    await expectLater(
      h.repo.updateAccountUser(
        target,
        AccountUserUpdate(sshPublicKey: fixturePublicKey()),
      ),
      throwsA(reason(AccountsExceptionReason.dependency)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'empty current key cannot silently unlink an existing file on profile edit',
    () async {
      final h = await connect();
      h.transport.users.last['sshpubkey'] = null;
      final target = (await h.repo.loadAccounts()).users.last;
      await expectLater(
        h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
        throwsA(reason(AccountsExceptionReason.dependency)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('home identity is reread immediately before dispatch', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.last;
    h.transport.driftHome = true;
    await expectLater(
      h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
      throwsA(reason(AccountsExceptionReason.staleSnapshot)),
    );
    expect(h.transport.writes, isEmpty);
  });
  for (final suffix in ['', '/.ssh', '/.ssh/authorized_keys']) {
    test('post-write replaced path identity $suffix remains unknown', () async {
      final h = await connect();
      final target = (await h.repo.loadAccounts()).users.last;
      h.transport.replaceAfterWrite = '${target.home}$suffix';
      expect(
        (await h.repo.updateAccountUser(
          target,
          AccountUserUpdate(sshPublicKey: fixturePublicKey()),
        )).outcome,
        AccountsOperationOutcome.unknown,
      );
      expect(h.transport.writes.length, 1);
    });
  }
  test('failed server SSH cleanup on deletion remains unknown', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.last;
    h.transport.preserveDeletedSsh = true;
    expect(
      (await h.repo.deleteAccountUser(target, target.username)).outcome,
      AccountsOperationOutcome.unknown,
    );
    expect(h.transport.writes.length, 1);
  });
  test('shared home blocks ordinary updates', () async {
    final h = await connect();
    h.transport.users[1]['home'] = h.transport.users.last['home'];
    final target = (await h.repo.loadAccounts()).users.last;
    await expectLater(
      h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
      throwsA(reason(AccountsExceptionReason.dependency)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'safe default home profile update verifies absent shared SSH path',
    () async {
      final h = await connect();
      h.transport.users.last['home'] = '/var/empty';
      h.transport.users.last['sshpubkey'] = null;
      final target = (await h.repo.loadAccounts()).users.last;
      expect(
        (await h.repo.updateAccountUser(
          target,
          AccountUserUpdate(fullName: 'New'),
        )).outcome,
        AccountsOperationOutcome.verified,
      );
    },
  );
  test('default home shared SSH path blocks implicit update cleanup', () async {
    final h = await connect();
    h.transport.users.last['home'] = '/var/empty';
    h.transport.users.last['sshpubkey'] = null;
    h.transport.defaultHomeSsh = true;
    final target = (await h.repo.loadAccounts()).users.last;
    await expectLater(
      h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
      throwsA(reason(AccountsExceptionReason.dependency)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'default home deletion needs no filesystem permission or cleanup',
    () async {
      final h = await connect(
        available: methods.difference({
          'filesystem.stat',
          'filesystem.listdir',
        }),
      );
      h.transport.users.last['home'] = '/var/empty';
      h.transport.users.last['sshpubkey'] = null;
      final target = (await h.repo.loadAccounts()).users.last;
      expect(
        (await h.repo.deleteAccountUser(target, target.username)).outcome,
        AccountsOperationOutcome.verified,
      );
      expect(
        h.transport.requests.where(
          (request) => (request['method'] as String).startsWith('filesystem.'),
        ),
        isEmpty,
      );
    },
  );
  test(
    'group update cannot verify changed protected sudo command contents',
    () async {
      final h = await connect();
      h.transport.groups.last['sudo_commands'] = ['old-private-command'];
      final target = (await h.repo.loadAccounts()).groups.last;
      h.transport.groupReadbackOverrides = {
        'sudo_commands': ['new-private-command'],
      };
      expect(
        (await h.repo.updateAccountGroup(
          target,
          AccountGroupUpdate(name: 'renamed'),
        )).outcome,
        AccountsOperationOutcome.unknown,
      );
      expect(h.transport.writes.length, 1);
    },
  );
  for (final override in [
    {
      'roles': ['FULL_ADMIN'],
    },
    {
      'sudo_commands': ['unexpected'],
    },
    {'builtin': true},
  ]) {
    test(
      'group creation cannot verify unexpected elevated or protected identity $override',
      () async {
        final h = await connect();
        final inventory = await h.repo.loadAccounts();
        h.transport.groupReadbackOverrides = override;
        expect(
          (await h.repo.createAccountGroup(
            AccountGroupCreate(
              inventory: inventory,
              name: 'newgroup',
              userIds: const [],
            ),
          )).outcome,
          AccountsOperationOutcome.unknown,
        );
        expect(h.transport.writes.length, 1);
      },
    );
  }
  for (final replacement in [false, true]) {
    test(
      'server-omitted dangling authorized_keys blocks ${replacement ? 'replacement' : 'implicit cleanup'}',
      () async {
        final h = await connect();
        h.transport.users.last['sshpubkey'] = null;
        final target = (await h.repo.loadAccounts()).users.last;
        h.transport.danglingPaths.add('${target.home}/.ssh/authorized_keys');
        await expectLater(
          h.repo.updateAccountUser(
            target,
            replacement
                ? AccountUserUpdate(sshPublicKey: fixturePublicKey())
                : AccountUserUpdate(fullName: 'New'),
          ),
          throwsA(reason(AccountsExceptionReason.dependency)),
        );
        expect(h.transport.writes, isEmpty);
        for (final request in h.transport.requests.where(
          (request) => request['method'] == 'filesystem.listdir',
        )) {
          expect(((request['params'] as List)[2] as Map)['select'], [
            'name',
            'path',
            'type',
          ]);
        }
      },
    );
  }
  test(
    'explicit clear authorizes only exact dangling authorized_keys unlink',
    () async {
      final h = await connect();
      h.transport.users.last['sshpubkey'] = null;
      final target = (await h.repo.loadAccounts()).users.last;
      final keyPath = '${target.home}/.ssh/authorized_keys';
      h.transport.danglingPaths.add(keyPath);
      expect(
        (await h.repo.updateAccountUser(
          target,
          AccountUserUpdate(sshPublicKey: ''),
        )).outcome,
        AccountsOperationOutcome.verified,
      );
      expect(h.transport.danglingPaths, isNot(contains(keyPath)));
      expect((h.transport.writes.single['params'] as List)[1], {
        'sshpubkey': '',
      });
    },
  );
  test('ordinary update below unresolved dangling SSH directory performs no key cleanup', () async {
    final h = await connect();
    h.transport.users.last['sshpubkey'] = null;
    final target = (await h.repo.loadAccounts()).users.last;
    final ssh = '${target.home}/.ssh';
    h.transport.danglingPaths.add(ssh);
    expect(
      (await h.repo.updateAccountUser(
        target,
        AccountUserUpdate(fullName: 'New'),
      )).outcome,
      AccountsOperationOutcome.verified,
    );
    expect(h.transport.danglingPaths, contains(ssh));
  });
  test(
    'default-home unresolved dangling SSH path cannot resolve a cleanup target',
    () async {
      final h = await connect();
      h.transport.users.last['home'] = '/var/empty';
      h.transport.users.last['sshpubkey'] = null;
      h.transport.defaultHomeSsh = true;
      h.transport.danglingPaths.add('/var/empty/.ssh');
      final target = (await h.repo.loadAccounts()).users.last;
      expect(
        (await h.repo.updateAccountUser(
          target,
          AccountUserUpdate(fullName: 'New'),
        )).outcome,
        AccountsOperationOutcome.verified,
      );
      expect(h.transport.danglingPaths, contains('/var/empty/.ssh'));
    },
  );
  test('existing regular-key replacement leaves server-omitted dangling siblings alone', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.last;
    final sibling = '${target.home}/.ssh/private_key';
    h.transport.extraSshFile = true;
    h.transport.danglingPaths.add(sibling);
    expect(
      (await h.repo.updateAccountUser(
        target,
        AccountUserUpdate(sshPublicKey: fixturePublicKey()),
      )).outcome,
      AccountsOperationOutcome.verified,
    );
    expect(h.transport.danglingPaths, contains(sibling));
  });
  for (final path in ['/', '/mnt', '/mnt/tank']) {
    test(
      'each ancestor $path rejects live symlink even when home realpath is lexical',
      () async {
        final h = await connect();
        final target = (await h.repo.loadAccounts()).users.last;
        h.transport.pathOverrides[path] = {
          'type': 'SYMLINK',
          'realpath': '/different',
        };
        await expectLater(
          h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
          throwsA(reason(AccountsExceptionReason.dependency)),
        );
        expect(h.transport.writes, isEmpty);
      },
    );
  }
  test('server-omitted dangling ancestor blocks before dispatch', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.last;
    h.transport.danglingPaths.add('/mnt/tank');
    await expectLater(
      h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
      throwsA(reason(AccountsExceptionReason.unavailable)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test('ancestor identities are reread after a key change', () async {
    final h = await connect();
    final target = (await h.repo.loadAccounts()).users.last;
    h.transport.replaceAfterWrite = '/mnt/tank';
    expect(
      (await h.repo.updateAccountUser(
        target,
        AccountUserUpdate(sshPublicKey: fixturePublicKey()),
      )).outcome,
      AccountsOperationOutcome.unknown,
    );
    expect(h.transport.writes.length, 1);
  });
  test(
    'ancestor proof is depth bounded before any filesystem access',
    () async {
      final h = await connect();
      h.transport.users.last['home'] =
          '/mnt/tank/${List.filled(16, 'nested').join('/')}';
      final target = (await h.repo.loadAccounts()).users.last;
      await expectLater(
        h.repo.updateAccountUser(target, AccountUserUpdate(fullName: 'New')),
        throwsA(reason(AccountsExceptionReason.dependency)),
      );
      expect(h.transport.writes, isEmpty);
      expect(
        h.transport.requests.where(
          (request) => (request['method'] as String).startsWith('filesystem.'),
        ),
        isEmpty,
      );
    },
  );
}

class AccountsTestHarness {
  AccountsTestHarness(Set<String> methods, String version) {
    transport = AccountsTestTransport(methods, version);
    repo = TrueNasSessionRepository(
      connector: _Connector(transport),
      managementRequestTimeout: const Duration(milliseconds: 100),
    );
  }
  late final AccountsTestTransport transport;
  late final TrueNasSessionRepository repo;
}

class _Connector implements RpcConnector {
  const _Connector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

class AccountsTestTransport implements RpcTransport {
  AccountsTestTransport(this.methods, this.version);
  final Set<String> methods;
  final String version;
  final inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  final users = [
    user(1, 'root', primary: 1, builtin: true, locked: true, disabled: true),
    user(101, 'admin', primary: 1),
    user(102, 'demo'),
  ];
  final groups = [
    group(1, 'builtin_administrators', builtin: true, roles: ['FULL_ADMIN']),
    group(2, 'builtin_users', builtin: true),
    group(10, 'staff'),
  ];
  final privileges = <Map<String, Object?>>[
    {
      'id': 1,
      'name': 'Local Administrator',
      'builtin_name': 'LOCAL_ADMINISTRATOR',
      'local_groups': [
        {'gid': 3001},
      ],
      'ds_groups': [],
      'roles': ['FULL_ADMIN'],
      'web_shell': true,
    },
  ];
  String identity = 'admin';
  String? failure;
  bool adminProof = true, preservePasswordTimestamp = false;
  int nextUser = 200, nextGroup = 30, tick = 1;
  final historicalHomes = <String, Map<String, Object?>>{};
  final pathOverrides = <String, Map<String, Object?>>{};
  final absentPaths = <String>{};
  final danglingPaths = <String>{};
  bool extraSshFile = false, driftHome = false, preserveDeletedSsh = false;
  bool defaultHomeSsh = false;
  Map<String, Object?> groupReadbackOverrides = {};
  String? replaceAfterWrite;
  int homeStats = 0;

  Map<String, Object?> stat(String path) {
    final homePath = path.split('/.ssh').first;
    final owner =
        historicalHomes[homePath] ??
        {
          'uid': 0,
          'group': {'id': -3000},
        };
    final directory = !path.endsWith('/authorized_keys');
    final home = path == homePath && historicalHomes.containsKey(path);
    if (home) homeStats++;
    return {
      'realpath': path,
      'type': directory ? 'DIRECTORY' : 'FILE',
      'uid': path == '/var/empty' ? 0 : owner['uid'],
      'gid': ((owner['group'] as Map)['id'] as int) + 3000,
      'mode': directory ? 16832 : 33152,
      'mount_id': 1,
      'dev': 1,
      'inode': home && driftHome && homeStats > 1 ? 999 : path.length,
      'nlink': directory ? 2 : 1,
      'acl': false,
      'is_mountpoint': false,
      'is_ctldir': false,
      ...?pathOverrides[path],
      if (path == replaceAfterWrite && writes.isNotEmpty) 'inode': 10000,
    };
  }

  List<Map<String, Object?>> listDirectory(String path) {
    if (path == '/var/empty' && !defaultHomeSsh) return [];
    final ssh = path.endsWith('/.ssh');
    final child = '$path/${ssh ? 'authorized_keys' : '.ssh'}';
    Map<String, Object?> entry(String target, String type) => {
      'name': target.split('/').last,
      'path': target,
      'realpath': pathOverrides[target]?['realpath'] ?? target,
      'type': pathOverrides[target]?['type'] ?? type,
    };
    return [
      if (!absentPaths.contains(child) && !danglingPaths.contains(child))
        entry(child, ssh ? 'FILE' : 'DIRECTORY'),
      if (ssh && extraSshFile && !danglingPaths.contains('$path/private_key'))
        entry('$path/private_key', 'FILE'),
    ];
  }

  Iterable<Map<String, Object?>> get writes => requests.where(
    (request) => {
      'user.create',
      'user.update',
      'user.delete',
      'group.create',
      'group.update',
      'group.delete',
    }.contains(request['method']),
  );
  @override
  Stream<String> get inboundFrames => inbound.stream;
  void syncMemberships() {
    for (final group in groups) {
      group['users'] = users
          .where(
            (user) =>
                (user['group'] as Map)['id'] == group['id'] ||
                (user['groups'] as List).contains(group['id']),
          )
          .map((user) => user['id'])
          .toList();
    }
    for (final user in users) {
      user['roles'] =
          groups
              .where(
                (group) =>
                    (user['group'] as Map)['id'] == group['id'] ||
                    (user['groups'] as List).contains(group['id']),
              )
              .expand((group) => (group['roles'] as List).cast<String>())
              .toSet()
              .toList()
            ..sort();
    }
  }

  @override
  Future<void> send(String frame) async {
    final request = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(request);
    final method = request['method'] as String;
    final args = request['params'] as List? ?? [];
    Object? result;
    if (writes.contains(request)) {
      if (failure == 'timeout') return;
      if (failure == 'error') {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': request['id'],
            'error': {'code': -32603, 'message': 'private-server-error'},
          }),
        );
        return;
      }
    }
    syncMemberships();
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'pw_name': identity, 'username': identity};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final method in methods)
            method: {
              'accepts': [],
              'returns': [],
              'job': false,
              'no_auth_required': false,
            },
        };
      case 'user.query':
        for (final row in users) {
          historicalHomes[row['home'] as String] = Map.of(row);
        }
        result = users;
      case 'group.query':
        result = groups;
      case 'privilege.query':
        result = privileges;
      case 'user.shell_choices':
        result = {
          '/usr/sbin/nologin': 'nologin',
          '/usr/bin/bash': 'bash',
          '/usr/bin/zsh': 'zsh',
        };
      case 'group.has_password_enabled_user':
        result = adminProof;
      case 'filesystem.stat':
        final path = args.single as String;
        if (absentPaths.contains(path) || danglingPaths.contains(path)) {
          inbound.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': request['id'],
              'error': {'code': -32603, 'message': 'private-path-error'},
            }),
          );
          return;
        }
        result = stat(path);
      case 'filesystem.listdir':
        result = listDirectory(args.first as String);
      case 'user.create':
        final values = args.single as Map;
        final id = nextUser++;
        final row = user(
          id,
          values['username'] as String,
          primary: values['group'] as int,
        );
        for (final key in [
          'full_name',
          'email',
          'home',
          'shell',
          'smb',
          'password_disabled',
          'ssh_password_enabled',
          'locked',
        ]) {
          if (values.containsKey(key)) row[key] = values[key];
        }
        row['groups'] = <Object?>[
          ...values['groups'] as List,
          if (values['smb'] == true) 2,
        ];
        row['sshpubkey'] = null;
        row['last_password_change'] = values['password'] == null
            ? null
            : '2026-01-02T00:00:00Z';
        users.add(row);
        result = {'id': id, 'password': values['password']};
      case 'user.update':
        final row = users.firstWhere((row) => row['id'] == args[0]);
        final values = args[1] as Map;
        for (final entry in values.entries) {
          if (entry.key == 'password') {
            if (!preservePasswordTimestamp) {
              row['last_password_change'] = '2026-01-02T00:00:${tick++}Z';
            }
          } else {
            row[entry.key as String] = entry.key == 'group'
                ? {'id': entry.value}
                : entry.value;
          }
        }
        if (values.containsKey('sshpubkey')) {
          final ssh = '${row['home']}/.ssh';
          final key = '$ssh/authorized_keys';
          if ((values['sshpubkey'] as String).isEmpty) {
            absentPaths.add(key);
            danglingPaths.remove(key);
          } else {
            absentPaths.removeAll([ssh, key]);
            pathOverrides[ssh] = {
              'mode': 16832,
              'gid': ((row['group'] as Map)['id'] as int) + 3000,
            };
            pathOverrides[key] = {
              'mode': 33152,
              'gid': ((row['group'] as Map)['id'] as int) + 3000,
            };
          }
        }
        if (failure == 'readback') row['full_name'] = 'unexpected';
        result = {
          'id': failure == 'wrong-id' ? 9999 : args[0],
          'password': 'returned-secret',
        };
      case 'user.delete':
        if (!preserveDeletedSsh) {
          absentPaths.add(
            '${users.firstWhere((row) => row['id'] == args[0])['home']}/.ssh',
          );
        }
        users.removeWhere((row) => row['id'] == args[0]);
        result = args[0];
      case 'group.create':
        final values = args.single as Map;
        final id = nextGroup++;
        final row = group(id, values['name'] as String);
        row['smb'] = values['smb'];
        row.addAll(groupReadbackOverrides);
        groups.add(row);
        for (final user in users.where(
          (row) => (values['users'] as List).contains(row['id']),
        )) {
          user['groups'] = [...user['groups'] as List, id];
        }
        result = id;
      case 'group.update':
        final row = groups.firstWhere((row) => row['id'] == args[0]);
        final values = args[1] as Map;
        for (final key in ['name', 'smb']) {
          if (values.containsKey(key)) row[key] = values[key];
        }
        if (values.containsKey('users')) {
          for (final user in users) {
            final ids = (user['groups'] as List)
                .where((id) => id != args[0])
                .toList();
            if ((values['users'] as List).contains(user['id']) &&
                (user['group'] as Map)['id'] != args[0]) {
              ids.add(args[0]);
            }
            user['groups'] = ids;
          }
        }
        row.addAll(groupReadbackOverrides);
        result = args[0];
      case 'group.delete':
        groups.removeWhere((row) => row['id'] == args[0]);
        result = args[0];
      default:
        throw StateError('Unexpected fixture method.');
    }
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    await inbound.close();
  }
}
