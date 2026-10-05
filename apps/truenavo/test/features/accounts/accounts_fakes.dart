import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const accountMethods = {
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
AccountUser accountUser(
  int id,
  String name, {
  bool builtin = false,
  bool administrator = false,
  bool sshKeyPresent = true,
}) => AccountUser(
  id: id,
  uid: id + 3000,
  username: name,
  fullName: '$name account',
  email: '$name@example.test',
  home: '/mnt/tank/$name',
  shell: '/usr/sbin/nologin',
  groupId: administrator ? 1 : 10,
  groupIds: const [],
  roles: administrator ? ['FULL_ADMIN'] : [],
  local: true,
  builtin: builtin,
  immutable: builtin,
  smb: false,
  locked: false,
  passwordDisabled: false,
  sshPasswordEnabled: false,
  sshKeyPresent: sshKeyPresent,
  twoFactorConfigured: false,
  apiKeyCount: 0,
  hasSudo: false,
);
AccountGroup accountGroup(
  int id,
  String name, {
  bool builtin = false,
  List<int> users = const [],
  List<String> roles = const [],
}) => AccountGroup(
  id: id,
  gid: id + 3000,
  name: name,
  local: true,
  builtin: builtin,
  immutable: builtin,
  smb: false,
  userIds: users,
  roles: roles,
  hasSudo: false,
);

class AccountsFake implements SessionRepository, AuthenticatedAccountsSession {
  AccountsFake({this.methods = accountMethods, bool demoHasKey = true}) {
    inventory = AccountsInventory(
      users: [
        accountUser(1, 'admin', administrator: true),
        accountUser(2, 'demo', sshKeyPresent: demoHasKey),
        accountUser(3, 'root', builtin: true),
      ],
      groups: [
        accountGroup(
          1,
          'builtin_administrators',
          builtin: true,
          users: [1],
          roles: ['FULL_ADMIN'],
        ),
        accountGroup(10, 'staff', users: [2, 3]),
        accountGroup(20, 'auditors', roles: ['READONLY_ADMIN']),
      ],
      privileges: [
        AccountPrivilege(
          id: 1,
          name: 'Local Administrator',
          builtinName: 'LOCAL_ADMINISTRATOR',
          localGids: [3001],
          roles: ['FULL_ADMIN'],
          directoryGroupCount: 0,
          webShell: true,
        ),
      ],
      shells: {'/usr/sbin/nologin': 'nologin', '/usr/bin/bash': 'bash'},
      currentUsername: 'admin',
      privilegesAvailable: true,
    );
  }
  final Set<String> methods;
  late final AccountsInventory inventory;
  int reads = 0;
  final writes = <String>[];
  Object? lastRequest;
  Future<AccountsOperationResult> Function()? onWrite;
  Future<AccountsOperationResult> _write(
    String method, [
    Object? request,
  ]) async {
    writes.add(method);
    lastRequest = request;
    return onWrite?.call() ??
        const AccountsOperationResult(AccountsOperationOutcome.verified);
  }

  @override
  AccountsCapabilities get accountsCapabilities => AccountsCapabilities(
    connected: true,
    versionSupported: true,
    methods: methods,
  );
  @override
  Future<AccountsInventory> loadAccounts() async {
    reads++;
    return inventory;
  }

  @override
  Future<AccountsOperationResult> createAccountUser(
    AccountUserCreate request,
  ) => _write('user.create', request);
  @override
  Future<AccountsOperationResult> updateAccountUser(
    AccountUser user,
    AccountUserUpdate request,
  ) => _write('user.update', request);
  @override
  Future<AccountsOperationResult> deleteAccountUser(
    AccountUser user,
    String confirmedName,
  ) => _write('user.delete', confirmedName);
  @override
  Future<AccountsOperationResult> createAccountGroup(
    AccountGroupCreate request,
  ) => _write('group.create', request);
  @override
  Future<AccountsOperationResult> updateAccountGroup(
    AccountGroup group,
    AccountGroupUpdate request,
  ) => _write('group.update', request);
  @override
  Future<AccountsOperationResult> deleteAccountGroup(
    AccountGroup group,
    String confirmedName,
  ) => _write('group.delete', confirmedName);
  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnimplementedError();
}

class AccountsHarness {
  AccountsHarness({
    Set<String> methods = accountMethods,
    bool demoHasKey = true,
  }) {
    api = AccountsFake(methods: methods, demoHasKey: demoHasKey);
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  late final AccountsFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({
    String? endpoint = 'wss://sample.example/api/current',
  }) => AuthenticatedSession(
    profileId: 'test',
    repository: api,
    availableMethodNames: api.methods,
    version: '25.10.1',
    endpoint: endpoint,
  );
  void select(AuthenticatedSession? session) {
    active = session;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  void dispose() => container.dispose();
}
