part of 'true_nas_session_repository.dart';

/// Dedicated local identity workflows. No arbitrary account RPC or existing
/// passwords, hashes, SSH keys, or sudo command contents reach the app layer.
abstract interface class AuthenticatedAccountsSession {
  AccountsCapabilities get accountsCapabilities;
  Future<AccountsInventory> loadAccounts();
  Future<AccountsOperationResult> createAccountUser(AccountUserCreate request);
  Future<AccountsOperationResult> updateAccountUser(
    AccountUser user,
    AccountUserUpdate request,
  );
  Future<AccountsOperationResult> deleteAccountUser(
    AccountUser user,
    String confirmedName,
  );
  Future<AccountsOperationResult> createAccountGroup(
    AccountGroupCreate request,
  );
  Future<AccountsOperationResult> updateAccountGroup(
    AccountGroup group,
    AccountGroupUpdate request,
  );
  Future<AccountsOperationResult> deleteAccountGroup(
    AccountGroup group,
    String confirmedName,
  );
}

final class AccountsCapabilities {
  AccountsCapabilities({
    required this.connected,
    required this.versionSupported,
    required Set<String> methods,
  }) : methods = Set.unmodifiable(methods);
  const AccountsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      methods = const {};
  final bool connected, versionSupported;
  final Set<String> methods;
  bool get supported =>
      connected &&
      versionSupported &&
      methods.containsAll({'user.query', 'group.query', 'auth.me'});
  bool canCall(String method) => supported && methods.contains(method);
  String? get blockedReason => !connected
      ? 'Connect to manage local accounts.'
      : !versionSupported
      ? 'Native accounts require a stable TrueNAS 25.10 release.'
      : !supported
      ? 'Account discovery is unavailable to this connection.'
      : null;
}

final class AccountsInventory {
  AccountsInventory({
    required List<AccountUser> users,
    required List<AccountGroup> groups,
    required List<AccountPrivilege> privileges,
    required Map<String, String> shells,
    required this.currentUsername,
    required this.privilegesAvailable,
  }) : users = List.unmodifiable(users),
       groups = List.unmodifiable(groups),
       privileges = List.unmodifiable(privileges),
       shells = Map.unmodifiable(shells);
  final List<AccountUser> users;
  final List<AccountGroup> groups;
  final List<AccountPrivilege> privileges;
  final Map<String, String> shells;
  final String currentUsername;
  final bool privilegesAvailable;
}

final class AccountUser {
  AccountUser({
    required this.id,
    required this.uid,
    required this.username,
    required this.fullName,
    required this.email,
    required this.home,
    required this.shell,
    required this.groupId,
    required List<int> groupIds,
    required List<String> roles,
    required this.local,
    required this.builtin,
    required this.immutable,
    required this.smb,
    required this.locked,
    required this.passwordDisabled,
    required this.sshPasswordEnabled,
    required this.sshKeyPresent,
    required this.twoFactorConfigured,
    required this.apiKeyCount,
    required this.hasSudo,
  }) : groupIds = List.unmodifiable(groupIds),
       roles = List.unmodifiable(roles);
  final int id, uid, groupId, apiKeyCount;
  final String username, fullName, home, shell;
  final String? email;
  final List<int> groupIds;
  final List<String> roles;
  final bool local,
      builtin,
      immutable,
      smb,
      locked,
      passwordDisabled,
      sshPasswordEnabled,
      sshKeyPresent,
      twoFactorConfigured,
      hasSudo;
  bool get editable => local && !builtin && !immutable;
  bool get administrator => roles.contains('FULL_ADMIN');
}

final class AccountGroup {
  AccountGroup({
    required this.id,
    required this.gid,
    required this.name,
    required this.local,
    required this.builtin,
    required this.immutable,
    required this.smb,
    required List<int> userIds,
    required List<String> roles,
    required this.hasSudo,
  }) : userIds = List.unmodifiable(userIds),
       roles = List.unmodifiable(roles);
  final int id, gid;
  final String name;
  final bool local, builtin, immutable, smb, hasSudo;
  final List<int> userIds;
  final List<String> roles;
  bool get editable => local && !builtin && !immutable;
}

final class AccountPrivilege {
  AccountPrivilege({
    required this.id,
    required this.name,
    required this.builtinName,
    required List<int> localGids,
    required List<String> roles,
    required this.directoryGroupCount,
    required this.webShell,
  }) : localGids = List.unmodifiable(localGids),
       roles = List.unmodifiable(roles);
  final int id, directoryGroupCount;
  final String name;
  final String? builtinName;
  final List<int> localGids;
  final List<String> roles;
  final bool webShell;
}

final class AccountUserCreate {
  AccountUserCreate({
    required this.inventory,
    required this.username,
    required this.fullName,
    required this.primaryGroupId,
    List<int> groupIds = const [],
    this.email,
    this.password,
    this.passwordDisabled = false,
    this.smb = false,
    this.shell = '/usr/sbin/nologin',
  }) : groupIds = List.unmodifiable(groupIds);
  final AccountsInventory inventory;
  final String username, fullName, shell;
  final String? email, password;
  final int primaryGroupId;
  final List<int> groupIds;
  final bool passwordDisabled, smb;
  @override
  String toString() => 'AccountUserCreate([redacted])';
}

final class AccountUserUpdate {
  AccountUserUpdate({
    this.fullName,
    this.email,
    this.shell,
    this.smb,
    this.locked,
    this.passwordDisabled,
    this.sshPasswordEnabled,
    this.password,
    this.sshPublicKey,
    this.primaryGroupId,
    List<int>? groupIds,
  }) : groupIds = groupIds == null ? null : List.unmodifiable(groupIds);
  final String? fullName, email, shell, password, sshPublicKey;
  final bool? smb, locked, passwordDisabled, sshPasswordEnabled;
  final int? primaryGroupId;
  final List<int>? groupIds;
  @override
  String toString() => 'AccountUserUpdate([redacted])';
}

final class AccountGroupCreate {
  AccountGroupCreate({
    required this.inventory,
    required this.name,
    this.smb = false,
    List<int> userIds = const [],
  }) : userIds = List.unmodifiable(userIds);
  final AccountsInventory inventory;
  final String name;
  final bool smb;
  final List<int> userIds;
}

final class AccountGroupUpdate {
  AccountGroupUpdate({this.name, this.smb, List<int>? userIds})
    : userIds = userIds == null ? null : List.unmodifiable(userIds);
  final String? name;
  final bool? smb;
  final List<int>? userIds;
}

enum AccountsOperationOutcome { verified, unknown }

final class AccountsOperationResult {
  const AccountsOperationResult(this.outcome);
  final AccountsOperationOutcome outcome;
  String get userMessage => outcome == AccountsOperationOutcome.verified
      ? 'The account change was confirmed by fresh server data.'
      : 'The account change may have been applied. Do not repeat it. Reconnect and inspect the account before continuing.';
}

enum AccountsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  invalidInput,
  invalidResponse,
  staleSnapshot,
  protectedAccount,
  lastAdministrator,
  dependency,
  busy,
  unavailable,
}

final class AccountsException implements Exception {
  const AccountsException(this.reason);
  final AccountsExceptionReason reason;
  String get userMessage => switch (reason) {
    AccountsExceptionReason.notAuthenticated =>
      'Reconnect before managing accounts.',
    AccountsExceptionReason.unsupportedVersion =>
      'Native accounts require TrueNAS 25.10.',
    AccountsExceptionReason.unavailableMethod =>
      'The required account permission is unavailable.',
    AccountsExceptionReason.invalidInput =>
      'Review the selected account fields and their limits.',
    AccountsExceptionReason.invalidResponse =>
      'The account response could not be verified safely.',
    AccountsExceptionReason.staleSnapshot =>
      'The accounts or connection changed. Reload and review again.',
    AccountsExceptionReason.protectedAccount => 'Built-in, immutable, directory-service, and active-session identities are protected.',
    AccountsExceptionReason.lastAdministrator => 'Keep another unlocked, password-enabled local administrator before removing access.',
    AccountsExceptionReason.dependency => 'Verify a unique owned canonical home and simple SSH directory, or resolve API-key, membership and privilege dependencies first.',
    AccountsExceptionReason.busy =>
      'Another server operation or uncertain account change is in progress.',
    AccountsExceptionReason.unavailable =>
      'Accounts could not be loaded. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

final class _SessionAccounts {
  _SessionAccounts({
    required this.client,
    required ServerSummary summary,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherBusy,
    required this.requestTimeout,
  }) : versionSupported =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       methods = Set.unmodifiable(summary.availableMethodNames);
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherBusy;
  final Duration requestTimeout;
  final bool versionSupported;
  final Set<String> methods;
  bool _reading = false, _writing = false, _uncertain = false;
  Future<void> Function()? _beforeAccountWrite, _afterAccountWrite;
  bool get isBusy => _writing || _uncertain;
  final _inventories = <AccountsInventory, String>{};
  final _users = <AccountUser, String>{};
  final _groups = <AccountGroup, String>{};
  AccountsCapabilities get capabilities => AccountsCapabilities(
    connected: isCurrent(),
    versionSupported: versionSupported,
    methods: methods,
  );

  void _guard([String? method]) {
    if (!isCurrent()) {
      throw const AccountsException(AccountsExceptionReason.notAuthenticated);
    }
    if (!versionSupported) {
      throw const AccountsException(AccountsExceptionReason.unsupportedVersion);
    }
    if (!capabilities.supported ||
        method != null && !methods.contains(method)) {
      throw const AccountsException(AccountsExceptionReason.unavailableMethod);
    }
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    _guard(method);
    final result = await client
        .call(method, id: nextId(), params: args)
        .timeout(requestTimeout);
    _guard();
    return result;
  }

  Future<AccountsInventory> load() async {
    _guard();
    if (_reading || _writing) {
      throw const AccountsException(AccountsExceptionReason.busy);
    }
    _reading = true;
    try {
      final snapshot = await _snapshot();
      _invalidate();
      _inventories[snapshot.inventory] = snapshot.fingerprint;
      for (final user in snapshot.inventory.users) {
        _users[user] = snapshot.fingerprint;
      }
      for (final group in snapshot.inventory.groups) {
        _groups[group] = snapshot.fingerprint;
      }
      return snapshot.inventory;
    } on AccountsException {
      rethrow;
    } on Object {
      throw const AccountsException(AccountsExceptionReason.unavailable);
    } finally {
      _reading = false;
    }
  }

  Future<_AccountsSnapshot> _snapshot() async {
    final me = await _call('auth.me', []);
    final username = me is Map ? me['pw_name'] ?? me['username'] : null;
    if (!_accountsText(username, 128, empty: false)) {
      throw const AccountsException(AccountsExceptionReason.invalidResponse);
    }
    final rawUsers = _accountsRows(
      await _call('user.query', [
        [],
        {
          'select': _accountsUserFields,
          'order_by': ['id'],
          'limit': 513,
        },
      ]),
    );
    final rawGroups = _accountsRows(
      await _call('group.query', [
        [],
        {
          'select': _accountsGroupFields,
          'order_by': ['id'],
          'limit': 513,
        },
      ]),
    );
    final rawPrivileges = methods.contains('privilege.query')
        ? _accountsRows(
            await _call('privilege.query', [
              [],
              {
                'select': [
                  'id',
                  'name',
                  'builtin_name',
                  'local_groups',
                  'ds_groups',
                  'roles',
                  'web_shell',
                ],
                'order_by': ['id'],
                'limit': 513,
              },
            ]),
          )
        : <Map<String, Object?>>[];
    final rawShells = methods.contains('user.shell_choices')
        ? await _call('user.shell_choices', [<int>[]])
        : <String, Object?>{};
    if (rawShells is! Map ||
        rawShells.length > 128 ||
        rawShells.entries.any(
          (entry) =>
              !_accountsText(entry.key, 256, empty: false) ||
              !_accountsText(entry.value, 128, empty: false),
        )) {
      throw const AccountsException(AccountsExceptionReason.invalidResponse);
    }
    final users = rawUsers.map(_accountsUser).toList();
    final groups = rawGroups.map(_accountsGroup).toList();
    if (users.map((user) => user.id).toSet().length != users.length ||
        groups.map((group) => group.id).toSet().length != groups.length) {
      throw const AccountsException(AccountsExceptionReason.invalidResponse);
    }
    final privileges = rawPrivileges.map(_accountsPrivilege).toList();
    return _AccountsSnapshot(
      AccountsInventory(
        users: users,
        groups: groups,
        privileges: privileges,
        shells: {
          for (final entry in rawShells.entries)
            entry.key as String: entry.value as String,
        },
        currentUsername: username as String,
        privilegesAvailable: methods.contains('privilege.query'),
      ),
      rawUsers,
      rawGroups,
      _accountsFingerprint([
        username,
        rawUsers,
        rawGroups,
        rawPrivileges,
        rawShells,
      ]),
    );
  }

  Future<AccountsOperationResult> _mutate(
    String method,
    String? observation,
    Future<
      ({List<Object?> args, bool Function(Object?, _AccountsSnapshot) verify})
    >
    Function(_AccountsSnapshot fresh)
    prepare,
  ) async {
    _guard(method);
    if (_reading || isBusy || isOtherBusy()) {
      throw const AccountsException(AccountsExceptionReason.busy);
    }
    if (observation == null) {
      throw const AccountsException(AccountsExceptionReason.staleSnapshot);
    }
    _writing = true;
    _beforeAccountWrite = null;
    _afterAccountWrite = null;
    var dispatched = false;
    try {
      final fresh = await _snapshot();
      if (fresh.fingerprint != observation) {
        throw const AccountsException(AccountsExceptionReason.staleSnapshot);
      }
      final operation = await prepare(fresh);
      await _beforeAccountWrite?.call();
      _guard(method);
      if (isOtherBusy()) {
        throw const AccountsException(AccountsExceptionReason.busy);
      }
      dispatched = true;
      final result = await _call(method, operation.args);
      final after = await _snapshot();
      if (!operation.verify(result, after)) {
        throw const AccountsException(AccountsExceptionReason.invalidResponse);
      }
      await _afterAccountWrite?.call();
      _invalidate();
      return const AccountsOperationResult(AccountsOperationOutcome.verified);
    } on Object catch (error) {
      if (dispatched) {
        _uncertain = true;
        _invalidate();
        return const AccountsOperationResult(AccountsOperationOutcome.unknown);
      }
      if (error is AccountsException) rethrow;
      throw const AccountsException(AccountsExceptionReason.unavailable);
    } finally {
      _beforeAccountWrite = null;
      _afterAccountWrite = null;
      _writing = false;
    }
  }

  Future<AccountsOperationResult> createUser(
    AccountUserCreate request,
  ) => _mutate('user.create', _inventories[request.inventory], (fresh) async {
    _accountsRequireName(request.username);
    _accountsRequireText(request.fullName, 256, empty: false);
    _accountsEmail(request.email);
    if (fresh.inventory.users.any(
      (user) => user.username == request.username,
    )) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
    _validateGroups(fresh.inventory, request.primaryGroupId, request.groupIds);
    _validatePassword(request.password, request.passwordDisabled, request.smb);
    final expectedGroups = request.groupIds.toSet();
    if (request.smb) {
      final builtinUsers = fresh.inventory.groups
          .where((group) => group.local && group.name == 'builtin_users')
          .firstOrNull;
      if (builtinUsers == null) {
        throw const AccountsException(AccountsExceptionReason.invalidResponse);
      }
      expectedGroups.add(builtinUsers.id);
    }
    await _validateShell(request.shell, [
      request.primaryGroupId,
      ...request.groupIds,
    ]);
    final values = <String, Object?>{
      'username': request.username,
      'full_name': request.fullName,
      'group': request.primaryGroupId,
      'group_create': false,
      'groups': request.groupIds,
      'home': '/var/empty',
      'home_create': false,
      'shell': request.shell,
      'smb': request.smb,
      'password_disabled': request.passwordDisabled,
      'ssh_password_enabled': false,
      'locked': false,
      'sudo_commands': <String>[],
      'sudo_commands_nopasswd': <String>[],
      'random_password': false,
      if (request.email != null)
        'email': request.email!.isEmpty ? null : request.email,
      if (request.password != null) 'password': request.password,
    };
    return (
      args: [values],
      verify: (Object? result, _AccountsSnapshot after) {
        if (result is! Map || !_accountsId(result['id'])) return false;
        final row = after.rawUsers
            .where((row) => row['id'] == result['id'])
            .firstOrNull;
        return row != null &&
            row['username'] == request.username &&
            row['local'] == true &&
            row['builtin'] == false &&
            row['immutable'] == false &&
            (row['sshpubkey'] == null || row['sshpubkey'] == '') &&
            _verifyUser(row, {...values, 'groups': expectedGroups.toList()}) &&
            (request.password == null || row['last_password_change'] != null);
      },
    );
  });

  Future<AccountsOperationResult> updateUser(
    AccountUser user,
    AccountUserUpdate request,
  ) => _mutate('user.update', _users[user], (fresh) async {
    _requireUser(user);
    final values = <String, Object?>{
      if (request.fullName != null) 'full_name': request.fullName,
      if (request.email != null)
        'email': request.email!.isEmpty ? null : request.email,
      if (request.shell != null) 'shell': request.shell,
      if (request.smb != null) 'smb': request.smb,
      if (request.locked != null) 'locked': request.locked,
      if (request.passwordDisabled != null)
        'password_disabled': request.passwordDisabled,
      if (request.sshPasswordEnabled != null)
        'ssh_password_enabled': request.sshPasswordEnabled,
      if (request.password != null) 'password': request.password,
      if (request.sshPublicKey != null)
        'sshpubkey': request.sshPublicKey!.trim(),
      if (request.primaryGroupId != null) 'group': request.primaryGroupId,
      if (request.groupIds != null) 'groups': request.groupIds,
    };
    if (values.isEmpty) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
    if (request.fullName != null) {
      _accountsRequireText(request.fullName, 256, empty: false);
    }
    _accountsEmail(request.email);
    final disabled = request.passwordDisabled ?? user.passwordDisabled;
    final smb = request.smb ?? user.smb;
    if (disabled && smb || !user.smb && smb && request.password == null) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
    if (request.password != null) {
      _validatePassword(request.password, disabled, smb);
    }
    final primary = request.primaryGroupId ?? user.groupId;
    final groups = request.groupIds ?? user.groupIds;
    _validateGroups(fresh.inventory, primary, groups);
    if (request.shell != null ||
        request.primaryGroupId != null ||
        request.groupIds != null) {
      await _validateShell(request.shell ?? user.shell, [primary, ...groups]);
    }
    if (request.sshPublicKey != null) {
      _accountsSshKey(request.sshPublicKey!);
      if (!_accountsSafeHome(user.home) ||
          user.home == '/var/empty' ||
          fresh.inventory.users.any(
            (other) => other.id != user.id && other.home == user.home,
          )) {
        throw const AccountsException(AccountsExceptionReason.invalidInput);
      }
      if (user.administrator) {
        await _remainingAdministrator(fresh.inventory, {user.id});
      }
    }
    if (request.sshPasswordEnabled == true &&
        (disabled ||
            !_accountsSafeHome(user.home) ||
            user.home == '/var/empty' ||
            (request.shell ?? user.shell) == '/usr/sbin/nologin')) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
    final reducing =
        request.locked == true ||
        request.passwordDisabled == true ||
        request.primaryGroupId != null ||
        request.groupIds != null;
    if (user.username == fresh.inventory.currentUsername && reducing) {
      throw const AccountsException(AccountsExceptionReason.protectedAccount);
    }
    if (reducing && user.administrator) {
      await _remainingAdministrator(fresh.inventory, {user.id});
    }
    if (user.home != '/var/empty' &&
        fresh.inventory.users.any(
          (other) => other.id != user.id && other.home == user.home,
        )) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    await _prepareHomeChecks(
      user,
      ssh: true,
      preserveSsh: request.sshPublicKey == null,
      clear: request.sshPublicKey?.trim().isEmpty == true,
      targetGid: fresh.inventory.groups
          .firstWhere((group) => group.id == primary)
          .gid,
    );
    final previous = fresh.rawUsers.firstWhere((row) => row['id'] == user.id);
    return (
      args: [user.id, values],
      verify: (Object? result, _AccountsSnapshot after) {
        if (result is! Map || result['id'] != user.id) return false;
        final row = after.rawUsers
            .where((row) => row['id'] == user.id)
            .firstOrNull;
        if (row == null ||
            row['username'] != user.username ||
            row['uid'] != user.uid ||
            !_verifyUser(row, values)) {
          return false;
        }
        if (request.password != null &&
            (row['last_password_change'] == null ||
                row['last_password_change'] ==
                    previous['last_password_change'])) {
          return false;
        }
        if (request.sshPublicKey == null &&
            row['sshpubkey'] != previous['sshpubkey']) {
          return false;
        }
        for (final key in [
          'full_name',
          'email',
          'shell',
          'smb',
          'locked',
          'password_disabled',
          'ssh_password_enabled',
          'home',
          'group',
          'groups',
          'sudo_commands',
          'sudo_commands_nopasswd',
          'local',
          'builtin',
          'immutable',
        ]) {
          if (!values.containsKey(key) &&
              !_adminEqual(row[key], previous[key])) {
            return false;
          }
        }
        return true;
      },
    );
  });

  Future<AccountsOperationResult> deleteUser(
    AccountUser user,
    String confirmedName,
  ) => _mutate('user.delete', _users[user], (fresh) async {
    _requireUser(user);
    if (confirmedName != user.username) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
    if (fresh.inventory.currentUsername == user.username) {
      throw const AccountsException(AccountsExceptionReason.protectedAccount);
    }
    if (user.apiKeyCount != 0) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    if (!_accountsSafeHome(user.home) ||
        user.home != '/var/empty' &&
            fresh.inventory.users.any(
              (other) => other.id != user.id && other.home == user.home,
            )) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    if (user.administrator) {
      await _remainingAdministrator(fresh.inventory, {user.id});
    }
    await _prepareHomeChecks(user, ssh: true, deleting: true);
    return (
      args: [
        user.id,
        {'delete_group': false},
      ],
      verify: (Object? result, _AccountsSnapshot after) =>
          result == user.id &&
          !after.inventory.users.any(
            (entry) => entry.id == user.id || entry.username == user.username,
          ) &&
          after.inventory.groups.any((group) => group.id == user.groupId),
    );
  });

  Future<AccountsOperationResult> createGroup(AccountGroupCreate request) =>
      _mutate('group.create', _inventories[request.inventory], (fresh) async {
        _accountsRequireName(request.name);
        if (fresh.inventory.groups.any((group) => group.name == request.name)) {
          throw const AccountsException(AccountsExceptionReason.invalidInput);
        }
        _validateUsers(fresh.inventory, request.userIds);
        final values = <String, Object?>{
          'name': request.name,
          'smb': request.smb,
          'users': request.userIds,
          'sudo_commands': <String>[],
          'sudo_commands_nopasswd': <String>[],
        };
        return (
          args: [values],
          verify: (Object? result, _AccountsSnapshot after) =>
              _accountsId(result) &&
              after.inventory.groups.any(
                (group) =>
                    group.id == result &&
                    group.name == request.name &&
                    group.editable &&
                    group.roles.isEmpty &&
                    !group.hasSudo &&
                    group.smb == request.smb &&
                    _accountsSetEqual(group.userIds, request.userIds),
              ),
        );
      });

  Future<AccountsOperationResult> updateGroup(
    AccountGroup group,
    AccountGroupUpdate request,
  ) => _mutate('group.update', _groups[group], (fresh) async {
    _requireGroup(group);
    if (request.name == null &&
        request.smb == null &&
        request.userIds == null) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
    if (request.name != null) {
      _accountsRequireName(request.name!);
      if (fresh.inventory.groups.any(
        (entry) => entry.id != group.id && entry.name == request.name,
      )) {
        throw const AccountsException(AccountsExceptionReason.invalidInput);
      }
    }
    if (request.userIds != null) {
      _validateUsers(
        fresh.inventory,
        request.userIds!,
        retained: group.userIds,
      );
      final primary = fresh.inventory.users
          .where((user) => user.groupId == group.id)
          .map((user) => user.id)
          .toSet();
      if (!request.userIds!.toSet().containsAll(primary)) {
        throw const AccountsException(AccountsExceptionReason.dependency);
      }
      final removed = group.userIds.toSet().difference(
        request.userIds!.toSet(),
      );
      if (fresh.inventory.users.any(
        (user) =>
            removed.contains(user.id) &&
            user.username == fresh.inventory.currentUsername,
      )) {
        throw const AccountsException(AccountsExceptionReason.protectedAccount);
      }
      if (removed.isNotEmpty && group.roles.contains('FULL_ADMIN')) {
        await _remainingAdministrator(fresh.inventory, removed);
      }
    }
    final values = <String, Object?>{
      if (request.name != null) 'name': request.name,
      if (request.smb != null) 'smb': request.smb,
      if (request.userIds != null) 'users': request.userIds,
    };
    return (
      args: [group.id, values],
      verify: (Object? result, _AccountsSnapshot after) {
        final row = after.inventory.groups
            .where((entry) => entry.id == group.id)
            .firstOrNull;
        final priorRaw = fresh.rawGroups.firstWhere(
          (entry) => entry['id'] == group.id,
        );
        final afterRaw = after.rawGroups
            .where((entry) => entry['id'] == group.id)
            .firstOrNull;
        return result == group.id &&
            row != null &&
            afterRaw != null &&
            [
              'sudo_commands',
              'sudo_commands_nopasswd',
              'local',
              'builtin',
              'immutable',
            ].every((field) => _adminEqual(priorRaw[field], afterRaw[field])) &&
            row.gid == group.gid &&
            row.name == (request.name ?? group.name) &&
            row.smb == (request.smb ?? group.smb) &&
            _accountsSetEqual(row.userIds, request.userIds ?? group.userIds) &&
            _accountsSetEqual(row.roles, group.roles);
      },
    );
  });

  Future<AccountsOperationResult> deleteGroup(
    AccountGroup group,
    String confirmedName,
  ) => _mutate('group.delete', _groups[group], (fresh) async {
    _requireGroup(group);
    if (confirmedName != group.name) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
    if (!fresh.inventory.privilegesAvailable) {
      throw const AccountsException(AccountsExceptionReason.unavailableMethod);
    }
    if (group.userIds.isNotEmpty ||
        group.roles.isNotEmpty ||
        fresh.inventory.users.any(
          (user) =>
              user.groupId == group.id || user.groupIds.contains(group.id),
        ) ||
        fresh.inventory.privileges.any(
          (privilege) => privilege.localGids.contains(group.gid),
        )) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    return (
      args: [
        group.id,
        {'delete_users': false},
      ],
      verify: (Object? result, _AccountsSnapshot after) =>
          result == group.id &&
          !after.inventory.groups.any(
            (entry) => entry.id == group.id || entry.name == group.name,
          ) &&
          _accountsSetEqual(
            after.inventory.users.map((user) => user.id).toList(),
            fresh.inventory.users.map((user) => user.id).toList(),
          ),
    );
  });

  void _requireUser(AccountUser user) {
    if (!user.editable) {
      throw const AccountsException(AccountsExceptionReason.protectedAccount);
    }
  }

  void _requireGroup(AccountGroup group) {
    if (!group.editable) {
      throw const AccountsException(AccountsExceptionReason.protectedAccount);
    }
  }

  void _validateGroups(
    AccountsInventory inventory,
    int primary,
    List<int> groups,
  ) {
    if (!_accountsId(primary) ||
        groups.length > 64 ||
        groups.toSet().length != groups.length ||
        groups.contains(primary) ||
        [primary, ...groups].any(
          (id) =>
              !_accountsId(id) ||
              !inventory.groups.any((group) => group.id == id && group.local),
        )) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
  }

  void _validateUsers(
    AccountsInventory inventory,
    List<int> users, {
    List<int> retained = const [],
  }) {
    if (users.length > 512 ||
        users.toSet().length != users.length ||
        users.any(
          (id) =>
              !_accountsId(id) ||
              !inventory.users.any(
                (user) =>
                    user.id == id &&
                    user.local &&
                    (user.editable || retained.contains(id)),
              ),
        )) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
    if (inventory.users.any(
      (user) =>
          !user.editable &&
          retained.contains(user.id) &&
          !users.contains(user.id),
    )) {
      throw const AccountsException(AccountsExceptionReason.protectedAccount);
    }
  }

  void _validatePassword(String? password, bool disabled, bool smb) {
    if (disabled && (smb || password != null) ||
        !disabled &&
            (password == null ||
                password.length < 8 ||
                !_accountsText(password, 128, empty: false))) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
  }

  Future<void> _validateShell(String shell, List<int> groups) async {
    final choices = await _call('user.shell_choices', [groups]);
    if (choices is! Map || !choices.containsKey(shell)) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
  }

  Future<void> _remainingAdministrator(
    AccountsInventory inventory,
    Set<int> excluded,
  ) async {
    final remaining = inventory.users
        .where(
          (user) =>
              user.local &&
              user.administrator &&
              !user.locked &&
              !user.passwordDisabled &&
              !excluded.contains(user.id),
        )
        .toList();
    if (remaining.isEmpty) {
      throw const AccountsException(AccountsExceptionReason.lastAdministrator);
    }
    final gids = inventory.groups
        .where((group) => group.local && group.roles.contains('FULL_ADMIN'))
        .map((group) => group.gid)
        .toSet();
    for (final privilege in inventory.privileges.where(
      (privilege) => privilege.builtinName == 'LOCAL_ADMINISTRATOR',
    )) {
      gids.addAll(privilege.localGids);
    }
    final exclude = inventory.users
        .where((user) => !remaining.any((entry) => entry.id == user.id))
        .map((user) => user.id)
        .toList();
    if (gids.isEmpty ||
        await _call('group.has_password_enabled_user', [
              gids.toList()..sort(),
              exclude,
            ]) !=
            true) {
      throw const AccountsException(AccountsExceptionReason.lastAdministrator);
    }
  }

  Future<void> _prepareHomeChecks(
    AccountUser user, {
    required bool ssh,
    bool preserveSsh = false,
    bool deleting = false,
    bool clear = false,
    int? targetGid,
  }) async {
    if (user.home == '/var/empty') {
      if (deleting) return;
      if (user.sshKeyPresent) {
        throw const AccountsException(AccountsExceptionReason.dependency);
      }
      Future<Object?> proof() async {
        final ancestors = await _accountAncestors('/var/empty');
        final home = await _statAccountPath(
          '/var/empty',
          0,
          directory: true,
          ssh: false,
        );
        final entries = _accountsRows(
          await _call('filesystem.listdir', [
            '/var/empty',
            [
              ['name', '=', '.ssh'],
            ],
            {
              'select': ['name', 'path', 'type'],
              'limit': 1,
            },
          ]),
        );
        if (home['acl'] != false ||
            ((home['mode'] as int) & 18) != 0 ||
            entries.isNotEmpty) {
          throw const AccountsException(AccountsExceptionReason.dependency);
        }
        return {'ancestors': ancestors, 'home': home};
      }

      final before = _accountsFingerprint(await proof());
      _beforeAccountWrite = () async {
        if (_accountsFingerprint(await proof()) != before) {
          throw const AccountsException(AccountsExceptionReason.staleSnapshot);
        }
      };
      _afterAccountWrite = () async {
        if (_accountsFingerprint(await proof()) != before) {
          throw const AccountsException(
            AccountsExceptionReason.invalidResponse,
          );
        }
      };
      return;
    }
    if (!_accountsSafeHome(user.home)) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    final before = await _homeProof(user, ssh: ssh);
    // Pinned stat/listdir omit dangling links. An absent leaf is not proof
    // that open(..., 'w') cannot follow a pre-existing dangling symlink.
    if (ssh && !preserveSsh && !deleting && !clear && before['key'] == null) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    if (preserveSsh && before['ssh'] != null && before['key'] == null) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    if (preserveSsh && user.sshKeyPresent != (before['key'] != null)) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    if (preserveSsh && before['key'] is Map) {
      final directory = before['ssh'] as Map, key = before['key'] as Map;
      if (directory['mode'] != 448 ||
          key['mode'] != 384 ||
          directory['gid'] != targetGid ||
          key['gid'] != targetGid) {
        throw const AccountsException(AccountsExceptionReason.dependency);
      }
    }
    final fingerprint = _accountsFingerprint(before);
    _beforeAccountWrite = () async {
      if (_accountsFingerprint(await _homeProof(user, ssh: ssh)) !=
          fingerprint) {
        throw const AccountsException(AccountsExceptionReason.staleSnapshot);
      }
    };
    _afterAccountWrite = () async {
      final after = await _homeProof(user, ssh: ssh);
      if (!_adminEqual(before['home'], after['home']) ||
          !_adminEqual(before['ancestors'], after['ancestors'])) {
        throw const AccountsException(AccountsExceptionReason.invalidResponse);
      }
      if (!ssh || preserveSsh) {
        if (_accountsFingerprint(after) != fingerprint) {
          throw const AccountsException(
            AccountsExceptionReason.invalidResponse,
          );
        }
      } else if (deleting) {
        if (after['ssh'] != null) {
          throw const AccountsException(
            AccountsExceptionReason.invalidResponse,
          );
        }
      } else if (clear) {
        if (after['key'] != null || !_adminEqual(before['ssh'], after['ssh'])) {
          throw const AccountsException(
            AccountsExceptionReason.invalidResponse,
          );
        }
      } else {
        final directory = after['ssh'], key = after['key'];
        if (directory is! Map ||
            key is! Map ||
            directory['mode'] != 448 ||
            key['mode'] != 384 ||
            directory['gid'] != targetGid ||
            key['gid'] != targetGid) {
          throw const AccountsException(
            AccountsExceptionReason.invalidResponse,
          );
        }
        for (final name in ['ssh', 'key']) {
          final prior = before[name], next = after[name];
          if (prior is Map &&
              next is Map &&
              [
                'realpath',
                'type',
                'uid',
                'mount_id',
                'dev',
                'inode',
                'acl',
                'is_mountpoint',
              ].any((field) => prior[field] != next[field])) {
            throw const AccountsException(
              AccountsExceptionReason.invalidResponse,
            );
          }
        }
      }
    };
  }

  Future<Map<String, Object?>> _homeProof(
    AccountUser user, {
    required bool ssh,
  }) async {
    final ancestors = await _accountAncestors(user.home);
    final home = await _statAccountPath(
      user.home,
      user.uid,
      directory: true,
      ssh: false,
    );
    if (!ssh) return {'ancestors': ancestors, 'home': home};
    if (home['acl'] != false ||
        ((home['mode'] as int) & 18) != 0 ||
        ((home['mode'] as int) & 3584) != 0) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    final directoryPath = '${user.home}/.ssh';
    final entries = _accountsRows(
      await _call('filesystem.listdir', [
        user.home,
        [
          ['name', '=', '.ssh'],
        ],
        {
          'select': ['name', 'path', 'type'],
          'limit': 2,
        },
      ]),
    );
    if (entries.isEmpty) {
      return {'ancestors': ancestors, 'home': home, 'ssh': null, 'key': null};
    }
    if (entries.length != 1 ||
        entries.single['name'] != '.ssh' ||
        entries.single['path'] != directoryPath ||
        entries.single['type'] != 'DIRECTORY') {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    final directory = await _statAccountPath(
      directoryPath,
      user.uid,
      directory: true,
      ssh: true,
    );
    if (directory['mount_id'] != home['mount_id']) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    final children = _accountsRows(
      await _call('filesystem.listdir', [
        directoryPath,
        [],
        {
          'select': ['name', 'path', 'type'],
          'limit': 2,
        },
      ]),
    );
    if (children.isEmpty) {
      return {
        'ancestors': ancestors,
        'home': home,
        'ssh': directory,
        'key': null,
      };
    }
    final keyPath = '$directoryPath/authorized_keys';
    if (children.length != 1 ||
        children.single['name'] != 'authorized_keys' ||
        children.single['path'] != keyPath ||
        children.single['type'] != 'FILE') {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    final key = await _statAccountPath(
      keyPath,
      user.uid,
      directory: false,
      ssh: true,
    );
    if (key['mount_id'] != home['mount_id']) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    return {'ancestors': ancestors, 'home': home, 'ssh': directory, 'key': key};
  }

  Future<List<Map<String, Object?>>> _accountAncestors(String path) async {
    final components = path
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (components.length > 16) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    // filesystem.stat canonicalizes only a symlink leaf. Checking each
    // component rejects a symlink ancestor hidden by a lexical leaf realpath.
    final result = [
      await _statAccountPath('/', null, directory: true, ssh: false),
    ];
    var current = '';
    for (final component in components.take(components.length - 1)) {
      current = '$current/$component';
      result.add(
        await _statAccountPath(current, null, directory: true, ssh: false),
      );
    }
    return result;
  }

  Future<Map<String, Object?>> _statAccountPath(
    String path,
    int? uid, {
    required bool directory,
    required bool ssh,
  }) async {
    final stat = await _call('filesystem.stat', [path]);
    if (stat is! Map ||
        stat['realpath'] != path ||
        stat['type'] != (directory ? 'DIRECTORY' : 'FILE') ||
        !_accountsId(stat['uid']) ||
        uid != null && stat['uid'] != uid ||
        stat['is_ctldir'] != false ||
        stat['is_mountpoint'] is! bool ||
        stat['acl'] is! bool ||
        [
          'mode',
          'gid',
          'mount_id',
          'dev',
          'inode',
          'nlink',
        ].any((key) => !_accountsId(stat[key]))) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    final mode = (stat['mode'] as int) & 4095;
    if (ssh &&
        (stat['is_mountpoint'] != false ||
            stat['acl'] != false ||
            (mode & 18) != 0 ||
            (mode & 3584) != 0 ||
            !directory && stat['nlink'] != 1)) {
      throw const AccountsException(AccountsExceptionReason.dependency);
    }
    return {
      'realpath': path,
      'type': stat['type'],
      'uid': stat['uid'],
      'gid': stat['gid'],
      'mode': mode,
      'mount_id': stat['mount_id'],
      'dev': stat['dev'],
      'inode': stat['inode'],
      'acl': stat['acl'],
      'is_mountpoint': stat['is_mountpoint'],
    };
  }

  bool _verifyUser(Map row, Map<String, Object?> values) {
    for (final entry in values.entries) {
      if ({
        'password',
        'group_create',
        'home_create',
        'random_password',
      }.contains(entry.key)) {
        continue;
      }
      if (entry.key == 'group') {
        if (row['group'] is! Map ||
            (row['group'] as Map)['id'] != entry.value) {
          return false;
        }
      } else if (entry.key == 'groups') {
        if (row['groups'] is! List ||
            !_accountsSetEqual(row['groups'] as List, entry.value as List)) {
          return false;
        }
      } else if (entry.key == 'sshpubkey') {
        if ((row['sshpubkey'] ?? '').toString().trim() != entry.value) {
          return false;
        }
      } else if (!_adminEqual(row[entry.key], entry.value)) {
        return false;
      }
    }
    return true;
  }

  void _invalidate() {
    _inventories.clear();
    _users.clear();
    _groups.clear();
  }
}

final class _AccountsSnapshot {
  const _AccountsSnapshot(
    this.inventory,
    this.rawUsers,
    this.rawGroups,
    this.fingerprint,
  );
  final AccountsInventory inventory;
  final List<Map<String, Object?>> rawUsers, rawGroups;
  final String fingerprint;
}

const _accountsUserFields = [
  'id',
  'uid',
  'username',
  'full_name',
  'email',
  'home',
  'shell',
  'group',
  'groups',
  'roles',
  'local',
  'builtin',
  'immutable',
  'smb',
  'locked',
  'password_disabled',
  'ssh_password_enabled',
  'sshpubkey',
  'twofactor_auth_configured',
  'api_keys',
  'last_password_change',
  'sudo_commands',
  'sudo_commands_nopasswd',
];
const _accountsGroupFields = [
  'id',
  'gid',
  'name',
  'local',
  'builtin',
  'immutable',
  'smb',
  'users',
  'roles',
  'sudo_commands',
  'sudo_commands_nopasswd',
];

bool _accountsId(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991;
bool _accountsSafeHome(String path) =>
    path == '/var/empty' ||
    path.startsWith('/mnt/') &&
        path.split('/').length >= 4 &&
        !path
            .split('/')
            .skip(1)
            .any((part) => part.isEmpty || part == '.' || part == '..');
bool _accountsText(Object? value, int max, {bool empty = true}) =>
    value is String &&
    value.length <= max &&
    (empty || value.isNotEmpty) &&
    !RegExp(r'[\x00-\x1f\x7f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]')
        .hasMatch(value);
void _accountsRequireText(Object? value, int max, {bool empty = true}) {
  if (!_accountsText(value, max, empty: empty)) {
    throw const AccountsException(AccountsExceptionReason.invalidInput);
  }
}

void _accountsRequireName(String value) {
  if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$').hasMatch(value)) {
    throw const AccountsException(AccountsExceptionReason.invalidInput);
  }
}

void _accountsEmail(String? value) {
  if (value != null &&
      value.isNotEmpty &&
      (!_accountsText(value, 254) ||
          !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value))) {
    throw const AccountsException(AccountsExceptionReason.invalidInput);
  }
}

void _accountsSshKey(String value) {
  if (value.isEmpty) return;
  if (!_accountsText(value, 16384, empty: false) ||
      !RegExp(
        r'^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)) [A-Za-z0-9+/]+={0,2}(?: [^\r\n]+)?$',
      ).hasMatch(value.trim())) {
    throw const AccountsException(AccountsExceptionReason.invalidInput);
  }
  final parts = value.trim().split(' ');
  final encoded = parts[1].replaceAll('=', '');
  if (encoded.length % 4 == 1) {
    throw const AccountsException(AccountsExceptionReason.invalidInput);
  }
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final bytes = <int>[];
  var accumulator = 0, bits = 0;
  for (final unit in encoded.codeUnits) {
    final index = alphabet.indexOf(String.fromCharCode(unit));
    if (index < 0) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
    accumulator = (accumulator << 6) | index;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.add((accumulator >> bits) & 255);
      accumulator &= (1 << bits) - 1;
    }
  }
  if (accumulator != 0) {
    throw const AccountsException(AccountsExceptionReason.invalidInput);
  }
  var offset = 0;
  List<int> field() {
    if (offset + 4 > bytes.length) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
    final size =
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    offset += 4;
    if (size <= 0 || offset + size > bytes.length) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
    final result = bytes.sublist(offset, offset + size);
    offset += size;
    return result;
  }

  if (String.fromCharCodes(field()) != parts[0]) {
    throw const AccountsException(AccountsExceptionReason.invalidInput);
  }
  if (parts[0] == 'ssh-ed25519') {
    if (field().length != 32) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
  } else if (parts[0] == 'ssh-rsa') {
    final exponent = field(), modulus = field();
    if (exponent.length > 8 || modulus.length < 256 || modulus.length > 1025) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
  } else {
    final curve = parts[0].substring('ecdsa-sha2-'.length);
    if (String.fromCharCodes(field()) != curve ||
        field().length !=
            {'nistp256': 65, 'nistp384': 97, 'nistp521': 133}[curve]) {
      throw const AccountsException(AccountsExceptionReason.invalidInput);
    }
  }
  if (offset != bytes.length) {
    throw const AccountsException(AccountsExceptionReason.invalidInput);
  }
}

bool _accountsSetEqual(List a, List b) =>
    a.length == b.length && a.toSet().containsAll(b);
List<Map<String, Object?>> _accountsRows(Object? raw) {
  if (raw is! List ||
      raw.length > 512 ||
      raw.any((row) => row is! Map || row.keys.any((key) => key is! String))) {
    throw const AccountsException(AccountsExceptionReason.invalidResponse);
  }
  return raw.map((row) => Map<String, Object?>.from(row as Map)).toList();
}

List<int> _accountsIds(Object? raw) {
  if (raw is! List ||
      raw.length > 512 ||
      raw.any((value) => !_accountsId(value)) ||
      raw.toSet().length != raw.length) {
    throw const AccountsException(AccountsExceptionReason.invalidResponse);
  }
  return raw.cast<int>().toList()..sort();
}

List<String> _accountsStrings(Object? raw) {
  if (raw is! List ||
      raw.length > 512 ||
      raw.any((value) => !_accountsText(value, 1024, empty: false))) {
    throw const AccountsException(AccountsExceptionReason.invalidResponse);
  }
  return raw.cast<String>().toList()..sort();
}

AccountUser _accountsUser(Map<String, Object?> row) {
  if (!_accountsId(row['id']) ||
      !_accountsId(row['uid']) ||
      row['group'] is! Map ||
      !_accountsId((row['group'] as Map)['id']) ||
      [
        'username',
        'home',
        'shell',
      ].any((key) => !_accountsText(row[key], 4096, empty: false)) ||
      !_accountsText(row['full_name'], 1024) ||
      row['email'] != null && !_accountsText(row['email'], 254) ||
      [
        'local',
        'builtin',
        'immutable',
        'smb',
        'locked',
        'password_disabled',
        'ssh_password_enabled',
        'twofactor_auth_configured',
      ].any((key) => row[key] is! bool) ||
      row['sshpubkey'] != null &&
          (row['sshpubkey'] is! String ||
              (row['sshpubkey'] as String).length > 65536)) {
    throw const AccountsException(AccountsExceptionReason.invalidResponse);
  }
  return AccountUser(
    id: row['id'] as int,
    uid: row['uid'] as int,
    username: row['username'] as String,
    fullName: row['full_name'] as String,
    email: row['email'] as String?,
    home: row['home'] as String,
    shell: row['shell'] as String,
    groupId: (row['group'] as Map)['id'] as int,
    groupIds: _accountsIds(row['groups']),
    roles: _accountsStrings(row['roles']),
    local: row['local'] as bool,
    builtin: row['builtin'] as bool,
    immutable: row['immutable'] as bool,
    smb: row['smb'] as bool,
    locked: row['locked'] as bool,
    passwordDisabled: row['password_disabled'] as bool,
    sshPasswordEnabled: row['ssh_password_enabled'] as bool,
    sshKeyPresent:
        row['sshpubkey'] is String &&
        (row['sshpubkey'] as String).trim().isNotEmpty,
    twoFactorConfigured: row['twofactor_auth_configured'] as bool,
    apiKeyCount: _accountsIds(row['api_keys']).length,
    hasSudo:
        _accountsStrings(row['sudo_commands']).isNotEmpty ||
        _accountsStrings(row['sudo_commands_nopasswd']).isNotEmpty,
  );
}

AccountGroup _accountsGroup(Map<String, Object?> row) {
  if (!_accountsId(row['id']) ||
      !_accountsId(row['gid']) ||
      !_accountsText(row['name'], 256, empty: false) ||
      [
        'local',
        'builtin',
        'immutable',
        'smb',
      ].any((key) => row[key] is! bool)) {
    throw const AccountsException(AccountsExceptionReason.invalidResponse);
  }
  return AccountGroup(
    id: row['id'] as int,
    gid: row['gid'] as int,
    name: row['name'] as String,
    local: row['local'] as bool,
    builtin: row['builtin'] as bool,
    immutable: row['immutable'] as bool,
    smb: row['smb'] as bool,
    userIds: _accountsIds(row['users']),
    roles: _accountsStrings(row['roles']),
    hasSudo:
        _accountsStrings(row['sudo_commands']).isNotEmpty ||
        _accountsStrings(row['sudo_commands_nopasswd']).isNotEmpty,
  );
}

AccountPrivilege _accountsPrivilege(Map<String, Object?> row) {
  if (!_accountsId(row['id']) ||
      !_accountsText(row['name'], 256, empty: false) ||
      row['builtin_name'] != null &&
          !_accountsText(row['builtin_name'], 128, empty: false) ||
      row['web_shell'] is! bool ||
      row['local_groups'] is! List ||
      row['ds_groups'] is! List) {
    throw const AccountsException(AccountsExceptionReason.invalidResponse);
  }
  final gids = <int>[];
  for (final group in row['local_groups'] as List) {
    if (group is! Map || !_accountsId(group['gid'])) {
      throw const AccountsException(AccountsExceptionReason.invalidResponse);
    }
    gids.add(group['gid'] as int);
  }
  return AccountPrivilege(
    id: row['id'] as int,
    name: row['name'] as String,
    builtinName: row['builtin_name'] as String?,
    localGids: gids,
    roles: _accountsStrings(row['roles']),
    directoryGroupCount: (row['ds_groups'] as List).length,
    webShell: row['web_shell'] as bool,
  );
}

String _accountsFingerprint(Object? value) {
  var a = 2166136261, b = 5381, nodes = 0, characters = 0;
  void feed(String text) {
    if ((characters += text.length) > 1048576) {
      throw const AccountsException(AccountsExceptionReason.invalidResponse);
    }
    for (final unit in text.codeUnits) {
      a = ((a ^ unit) * 16777619) & 0xffffffff;
      b = ((b * 33) ^ unit) & 0xffffffff;
    }
  }

  void visit(Object? item, int depth) {
    if (++nodes > 100000 || depth > 24) {
      throw const AccountsException(AccountsExceptionReason.invalidResponse);
    }
    if (item is Map) {
      if (item.keys.any((key) => key is! String)) {
        throw const AccountsException(AccountsExceptionReason.invalidResponse);
      }
      feed('{');
      for (final key in item.keys.cast<String>().toList()..sort()) {
        feed('${key.length}:$key');
        visit(item[key], depth + 1);
      }
      feed('}');
    } else if (item is List) {
      feed('[');
      for (final child in item) {
        visit(child, depth + 1);
      }
      feed(']');
    } else if (item == null ||
        item is String ||
        item is bool ||
        item is num &&
            item.isFinite &&
            item >= -9007199254740991 &&
            item <= 9007199254740991) {
      feed('${item.runtimeType}:${item.toString().length}:$item;');
    } else {
      throw const AccountsException(AccountsExceptionReason.invalidResponse);
    }
  }

  visit(value, 0);
  return '$a:$b:$nodes:$characters';
}
