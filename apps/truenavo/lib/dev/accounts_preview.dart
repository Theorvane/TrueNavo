import 'package:truenas_api/truenas_api.dart';

/// Synthetic presentation-only data. No transport is used and every mutation
/// rejects, even when reached through a completed native confirmation dialog.
mixin AccountsPreviewAdapter implements AuthenticatedAccountsSession {
  static const _methods = {
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
  static final _inventory = AccountsInventory(
    users: [
      _previewUser(
        1,
        'truenavo_admin',
        'Server administrator',
        primary: 1,
        roles: ['FULL_ADMIN'],
        twoFactor: true,
      ),
      _previewUser(2, 'media', 'Media library service'),
      _previewUser(
        3,
        'backup',
        'Nightly backup service',
        groups: [20],
        keyPresent: true,
      ),
      _previewUser(4, 'photography', 'Shared photography archive', smb: true),
      _previewUser(5, 'guest_archive', 'Archived guest identity', locked: true),
      _previewUser(
        6,
        'root',
        'Built-in system identity',
        primary: 1,
        builtin: true,
        locked: true,
        roles: ['FULL_ADMIN'],
      ),
    ],
    groups: [
      _previewGroup(
        1,
        'builtin_administrators',
        builtin: true,
        users: [1, 6],
        roles: ['FULL_ADMIN'],
      ),
      _previewGroup(10, 'media_services', users: [2, 3, 4, 5]),
      _previewGroup(
        20,
        'backup_operators',
        users: [3],
        roles: ['READONLY_ADMIN'],
      ),
      _previewGroup(30, 'archive_readers', smb: true),
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
      AccountPrivilege(
        id: 2,
        name: 'Backup observers',
        builtinName: null,
        localGids: [3020],
        roles: ['READONLY_ADMIN'],
        directoryGroupCount: 0,
        webShell: false,
      ),
    ],
    shells: {
      '/usr/sbin/nologin': 'No interactive login',
      '/usr/bin/bash': 'Bash',
      '/usr/bin/zsh': 'Zsh',
    },
    currentUsername: 'truenavo_admin',
    privilegesAvailable: true,
  );
  @override
  AccountsCapabilities get accountsCapabilities => AccountsCapabilities(
    connected: true,
    versionSupported: true,
    methods: _methods,
  );
  @override
  Future<AccountsInventory> loadAccounts() async => _inventory;
  Future<AccountsOperationResult> _reject() => Future.error(
    const AccountsException(AccountsExceptionReason.unavailableMethod),
  );
  @override
  Future<AccountsOperationResult> createAccountUser(
    AccountUserCreate request,
  ) => _reject();
  @override
  Future<AccountsOperationResult> updateAccountUser(
    AccountUser user,
    AccountUserUpdate request,
  ) => _reject();
  @override
  Future<AccountsOperationResult> deleteAccountUser(
    AccountUser user,
    String confirmedName,
  ) => _reject();
  @override
  Future<AccountsOperationResult> createAccountGroup(
    AccountGroupCreate request,
  ) => _reject();
  @override
  Future<AccountsOperationResult> updateAccountGroup(
    AccountGroup group,
    AccountGroupUpdate request,
  ) => _reject();
  @override
  Future<AccountsOperationResult> deleteAccountGroup(
    AccountGroup group,
    String confirmedName,
  ) => _reject();
}

AccountUser _previewUser(
  int id,
  String name,
  String fullName, {
  int primary = 10,
  List<int> groups = const [],
  List<String> roles = const [],
  bool builtin = false,
  bool locked = false,
  bool smb = false,
  bool keyPresent = false,
  bool twoFactor = false,
}) => AccountUser(
  id: id,
  uid: id + 3000,
  username: name,
  fullName: fullName,
  email: null,
  home: '/mnt/tank/homes/$name',
  shell: '/usr/sbin/nologin',
  groupId: primary,
  groupIds: groups,
  roles: roles,
  local: true,
  builtin: builtin,
  immutable: builtin,
  smb: smb,
  locked: locked,
  passwordDisabled: false,
  sshPasswordEnabled: false,
  sshKeyPresent: keyPresent,
  twoFactorConfigured: twoFactor,
  apiKeyCount: 0,
  hasSudo: false,
);
AccountGroup _previewGroup(
  int id,
  String name, {
  bool builtin = false,
  bool smb = false,
  List<int> users = const [],
  List<String> roles = const [],
}) => AccountGroup(
  id: id,
  gid: id + 3000,
  name: name,
  local: true,
  builtin: builtin,
  immutable: builtin,
  smb: smb,
  userIds: users,
  roles: roles,
  hasSudo: false,
);
