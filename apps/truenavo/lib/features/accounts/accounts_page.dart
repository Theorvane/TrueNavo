import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'accounts_controller.dart';

class AccountsPage extends ConsumerStatefulWidget {
  const AccountsPage({super.key});
  @override
  ConsumerState<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends ConsumerState<AccountsPage> {
  int _tab = 0;
  String _search = '';
  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final api = ref.watch(accountsSessionProvider);
    final state = ref.watch(accountsControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Accounts'),
        actions: [
          IconButton(
            key: const Key('accounts-refresh'),
            tooltip: 'Refresh accounts',
            onPressed: state.locked
                ? null
                : () => ref.invalidate(accountsInventoryProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'LOCAL IDENTITY WORKSPACE',
                  style: TdTypography.micro,
                ),
                const SizedBox(height: 8),
                const Text(
                  'People, access, and groups',
                  style: TdTypography.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(session?.endpoint ?? 'No authenticated server'),
                const SizedBox(height: 16),
                const AccountsOperationBanner(),
                if (session?.endpoint == null ||
                    api?.accountsCapabilities.supported != true)
                  TdPanel(
                    title: 'Accounts unavailable',
                    child: Text(
                      api?.accountsCapabilities.blockedReason ??
                          'Connect to a supported TrueNAS server.',
                    ),
                  )
                else
                  ref
                      .watch(accountsInventoryProvider)
                      .when(
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (error, _) => TdPanel(
                          title: 'Could not load accounts',
                          child: Text(
                            error is AccountsException ? error.userMessage : 'Server details were withheld. Refresh to try again.',
                          ),
                        ),
                        data: (inventory) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final entry in [
                                  (0, 'Users'),
                                  (1, 'Groups'),
                                  (2, 'Privileges'),
                                ])
                                  ChoiceChip(
                                    key: Key('accounts-tab-${entry.$1}'),
                                    label: Text(entry.$2),
                                    selected: _tab == entry.$1,
                                    onSelected: (_) => setState(() {
                                      _tab = entry.$1;
                                      _search = '';
                                    }),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              key: ValueKey('accounts-search-$_tab'),
                              decoration: const InputDecoration(
                                labelText: 'Search accounts',
                                prefixIcon: Icon(Icons.search),
                              ),
                              onChanged: (value) =>
                                  setState(() => _search = value.toLowerCase()),
                            ),
                            const SizedBox(height: 16),
                            if (_tab < 2)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: FilledButton.icon(
                                  key: Key('accounts-create-$_tab'),
                                  onPressed:
                                      state.locked ||
                                          !api!.accountsCapabilities.canCall(
                                            _tab == 0
                                                ? 'user.create'
                                                : 'group.create',
                                          )
                                      ? null
                                      : () => Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            builder: (_) => _tab == 0
                                                ? _UserEditor(
                                                    session: session!,
                                                    inventory: inventory,
                                                  )
                                                : _GroupEditor(
                                                    session: session!,
                                                    inventory: inventory,
                                                  ),
                                          ),
                                        ),
                                  icon: const Icon(Icons.add),
                                  label: Text(
                                    _tab == 0 ? 'Create user' : 'Create group',
                                  ),
                                ),
                              ),
                            const SizedBox(height: 12),
                            if (_tab == 0) ...[
                              Text(
                                '${inventory.users.length} users · Existing credentials stay private',
                              ),
                              for (final user in inventory.users.where(
                                (user) => '${user.username} ${user.fullName}'
                                    .toLowerCase()
                                    .contains(_search),
                              ))
                                Card(
                                  child: ListTile(
                                    key: Key('account-user-${user.id}'),
                                    leading: Icon(
                                      user.administrator
                                          ? Icons.admin_panel_settings_outlined
                                          : Icons.person_outline,
                                    ),
                                    title: Text(user.username),
                                    subtitle: Text(
                                      '${user.fullName}\nUID ${user.uid} · ${user.locked ? 'Locked' : 'Unlocked'}${user.editable ? '' : ' · Protected'}',
                                    ),
                                    isThreeLine: true,
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => _UserEditor(
                                          session: session!,
                                          inventory: inventory,
                                          user: user,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ] else if (_tab == 1) ...[
                              Text(
                                '${inventory.groups.length} groups · API IDs and Unix GIDs are distinct',
                              ),
                              for (final group in inventory.groups.where(
                                (group) =>
                                    group.name.toLowerCase().contains(_search),
                              ))
                                Card(
                                  child: ListTile(
                                    key: Key('account-group-${group.id}'),
                                    leading: const Icon(Icons.groups_outlined),
                                    title: Text(group.name),
                                    subtitle: Text(
                                      'GID ${group.gid} · ${group.userIds.length} members${group.editable ? '' : ' · Protected'}',
                                    ),
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => _GroupEditor(
                                          session: session!,
                                          inventory: inventory,
                                          group: group,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ] else ...[
                              const Text(
                                'Privilege mappings are reviewed here. Built-in mappings and role changes remain protected; group membership changes show the roles they grant.',
                              ),
                              if (!inventory.privilegesAvailable)
                                const Text(
                                  'Privilege discovery is unavailable to this account.',
                                ),
                              for (final privilege
                                  in inventory.privileges.where(
                                    (privilege) => privilege.name
                                        .toLowerCase()
                                        .contains(_search),
                                  ))
                                Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          privilege.name,
                                          style: TdTypography.titleMedium,
                                        ),
                                        Text(
                                          privilege.builtinName == null
                                              ? 'Custom privilege'
                                              : 'Built-in privilege · protected',
                                        ),
                                        Text(
                                          'Roles: ${privilege.roles.join(', ')}',
                                        ),
                                        Text(
                                          'Local groups: ${privilege.localGids.map((gid) => '${inventory.groups.where((group) => group.gid == gid).firstOrNull?.name ?? 'Unmapped'} (GID $gid)').join(', ')}',
                                        ),
                                        Text(
                                          'Directory groups: ${privilege.directoryGroupCount} · Web shell: ${privilege.webShell ? 'Allowed' : 'Not allowed'}',
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AccountsOperationBanner extends ConsumerWidget {
  const AccountsOperationBanner({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(accountsControllerProvider);
    if (!state.busy && state.result == null && state.message == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TdPanel(
        title: state.busy
            ? 'Applying account change'
            : state.unknown
            ? 'Outcome needs verification'
            : 'Account operation',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.target != null) Text('Operation target: ${state.target}'),
            if (state.server != null) Text('Original server: ${state.server}'),
            if (state.busy)
              const LinearProgressIndicator()
            else
              Text(state.message ?? state.result!.userMessage),
            if (state.unknown && !state.connectionCurrent)
              TextButton(
                onPressed: () => ref
                    .read(accountsControllerProvider.notifier)
                    .acknowledgeAfterReconnect(),
                child: const Text('I reconnected and will inspect the account'),
              ),
          ],
        ),
      ),
    );
  }
}

class _UserEditor extends ConsumerStatefulWidget {
  const _UserEditor({
    required this.session,
    required this.inventory,
    this.user,
  });
  final AuthenticatedSession session;
  final AccountsInventory inventory;
  final AccountUser? user;
  @override
  ConsumerState<_UserEditor> createState() => _UserEditorState();
}

class _UserEditorState extends ConsumerState<_UserEditor> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController(),
      _fullName = TextEditingController(),
      _email = TextEditingController(),
      _password = TextEditingController(),
      _sshKey = TextEditingController();
  late String _shell;
  late bool _smb, _locked, _disabled, _sshPassword;
  bool _replaceKey = false, _clearKey = false;
  int? _primary;
  late Set<int> _groups;
  String? _error;
  @override
  void initState() {
    super.initState();
    final user = widget.user;
    _username.text = user?.username ?? '';
    _fullName.text = user?.fullName ?? '';
    _email.text = user?.email ?? '';
    _shell = user?.shell ?? '/usr/sbin/nologin';
    _smb = user?.smb ?? false;
    _locked = user?.locked ?? false;
    _disabled = user?.passwordDisabled ?? false;
    _sshPassword = user?.sshPasswordEnabled ?? false;
    _primary =
        user?.groupId ??
        widget.inventory.groups
            .where((group) => group.local && !group.builtin && !group.immutable)
            .firstOrNull
            ?.id;
    _groups = user?.groupIds.toSet() ?? {};
  }

  void _clearSecrets() {
    _password.clear();
    _sshKey.clear();
    _replaceKey = false;
    _clearKey = false;
  }

  @override
  void dispose() {
    for (final controller in [
      _username,
      _fullName,
      _email,
      _password,
      _sshKey,
    ]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (!identical(next, widget.session)) _clearSecrets();
    });
    final current = ref.watch(dashboardActiveSessionProvider);
    final state = ref.watch(accountsControllerProvider);
    final user = widget.user;
    final creating = user == null;
    final capabilities = ref
        .watch(accountsSessionProvider)
        ?.accountsCapabilities;
    final canStat =
        creating || capabilities?.canCall('filesystem.stat') == true;
    final canInspectSsh =
        creating || capabilities?.canCall('filesystem.listdir') == true;
    final permitted = creating
        ? ref
                  .watch(accountsSessionProvider)
                  ?.accountsCapabilities
                  .canCall('user.create') ==
              true
        : user.editable &&
              ref
                      .watch(accountsSessionProvider)
                      ?.accountsCapabilities
                      .canCall('user.update') ==
                  true;
    final enabled = permitted && canStat && canInspectSsh && !state.locked;
    return Scaffold(
      appBar: AppBar(
        title: Text(creating ? 'Create local user' : 'User details'),
      ),
      body: SafeArea(
        child: !identical(current, widget.session) || current?.endpoint == null
            ? const Center(
                child: Text(
                  'This account review expired. Reconnect and reopen it.',
                ),
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const AccountsOperationBanner(),
                          Text(
                            creating ? 'New local identity' : user.username,
                            style: TdTypography.titleLarge,
                          ),
                          Text(widget.session.endpoint ?? ''),
                          const SizedBox(height: 12),
                          if (!creating)
                            Text(
                              'UID ${user.uid} · ${user.local ? 'Local' : 'Directory service'}\nRoles: ${user.roles.isEmpty ? 'None' : user.roles.join(', ')}\nAPI keys: ${user.apiKeyCount} · Two-factor: ${user.twoFactorConfigured ? 'Configured' : 'Not configured'}\nSSH keys: ${user.sshKeyPresent ? 'Present, never displayed' : 'None'}\nHome: ${user.home}${user.hasSudo ? '\nElevated command access is configured.' : ''}',
                            ),
                          if (!creating && !user.editable)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                'This identity is protected. Its existing settings can be reviewed but not changed here.',
                              ),
                            ),
                          if (!creating && (!canStat || !canInspectSsh))
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                'Filesystem metadata read permission is required to verify this home before account edits or SSH-directory removal. No home is created by this client.',
                              ),
                            ),
                          if (creating)
                            TextFormField(
                              key: const Key('account-username'),
                              controller: _username,
                              enabled: enabled,
                              decoration: const InputDecoration(
                                labelText: 'Username',
                              ),
                              maxLength: 32,
                              validator: (value) =>
                                  value != null &&
                                      RegExp(
                                        r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$',
                                      ).hasMatch(value)
                                  ? null
                                  : 'Use a portable username, up to 32 characters.',
                            ),
                          TextFormField(
                            key: const Key('account-full-name'),
                            controller: _fullName,
                            enabled: enabled,
                            decoration: const InputDecoration(
                              labelText: 'Full name or description',
                            ),
                            maxLength: 256,
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                ? 'Enter a name or description.'
                                : null,
                          ),
                          TextFormField(
                            key: const Key('account-email'),
                            controller: _email,
                            enabled: enabled,
                            decoration: const InputDecoration(
                              labelText: 'Email (optional)',
                            ),
                            keyboardType: TextInputType.emailAddress,
                            maxLength: 254,
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<int>(
                            key: const Key('account-primary-group'),
                            initialValue: _primary,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Primary group',
                            ),
                            items: [
                              for (final group in widget.inventory.groups.where(
                                (group) => group.local,
                              ))
                                DropdownMenuItem(
                                  value: group.id,
                                  child: Text(
                                    '${group.name} · GID ${group.gid}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: enabled
                                ? (value) => setState(() {
                                    _primary = value;
                                    _groups.remove(value);
                                  })
                                : null,
                            validator: (value) => value == null
                                ? 'Select a primary group.'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            key: const Key('account-shell'),
                            initialValue:
                                widget.inventory.shells.containsKey(_shell)
                                ? _shell
                                : null,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Login shell',
                            ),
                            items: [
                              for (final entry
                                  in widget.inventory.shells.entries)
                                DropdownMenuItem(
                                  value: entry.key,
                                  child: Text(
                                    '${entry.value} · ${entry.key}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: enabled
                                ? (value) =>
                                      setState(() => _shell = value ?? _shell)
                                : null,
                          ),
                          if (creating)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                'Home remains /var/empty. No home directory or filesystem permissions are created or changed. SSH password access starts disabled.',
                              ),
                            ),
                          ExpansionTile(
                            title: Text(
                              'Supplementary groups (${_groups.length})',
                            ),
                            children: [
                              for (final group in widget.inventory.groups.where(
                                (group) => group.local && group.id != _primary,
                              ))
                                CheckboxListTile(
                                  value: _groups.contains(group.id),
                                  title: Text(group.name),
                                  subtitle: Text(
                                    'GID ${group.gid}${group.roles.isEmpty ? '' : ' · Roles: ${group.roles.join(', ')}'}${group.hasSudo ? ' · Elevated commands' : ''}',
                                  ),
                                  onChanged: enabled
                                      ? (value) => setState(() {
                                          if (value == true) {
                                            _groups.add(group.id);
                                          } else {
                                            _groups.remove(group.id);
                                          }
                                        })
                                      : null,
                                ),
                            ],
                          ),
                          SwitchListTile(
                            key: const Key('account-smb'),
                            title: const Text('SMB authentication'),
                            subtitle: const Text(
                              'Enabling SMB requires a password. New SMB users also join builtin_users.',
                            ),
                            value: _smb,
                            onChanged: enabled
                                ? (value) => setState(() {
                                    _smb = value;
                                    if (value) _disabled = false;
                                  })
                                : null,
                          ),
                          SwitchListTile(
                            key: const Key('account-password-disabled'),
                            title: const Text(
                              'Disable password authentication',
                            ),
                            subtitle: const Text(
                              'This does not revoke SSH keys or API keys.',
                            ),
                            value: _disabled,
                            onChanged: enabled
                                ? (value) => setState(() {
                                    _disabled = value;
                                    if (value) {
                                      _smb = false;
                                      _sshPassword = false;
                                      _password.clear();
                                    }
                                  })
                                : null,
                          ),
                          if (!_disabled)
                            TextFormField(
                              key: const Key('account-new-password'),
                              controller: _password,
                              enabled: enabled,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: InputDecoration(
                                labelText: creating
                                    ? 'New password'
                                    : 'New password (leave blank to keep)',
                              ),
                              maxLength: 128,
                              validator: (value) =>
                                  (creating ||
                                          (!user.smb && _smb) ||
                                          value?.isNotEmpty == true) &&
                                      (value?.length ?? 0) < 8
                                  ? 'Enter at least 8 characters.'
                                  : null,
                            ),
                          if (!creating) ...[
                            SwitchListTile(
                              key: const Key('account-locked'),
                              title: const Text('Lock account'),
                              subtitle: const Text(
                                'Blocks authentication. Active-session and last-administrator accounts are protected.',
                              ),
                              value: _locked,
                              onChanged:
                                  enabled &&
                                      user.username !=
                                          widget.inventory.currentUsername
                                  ? (value) => setState(() => _locked = value)
                                  : null,
                            ),
                            SwitchListTile(
                              key: const Key('account-ssh-password'),
                              title: const Text(
                                'Allow SSH password authentication',
                              ),
                              subtitle: const Text(
                                'Requires a usable home, login shell, and compatible server two-factor policy. Key-based access is preferred.',
                              ),
                              value: _sshPassword,
                              onChanged:
                                  enabled &&
                                      !_disabled &&
                                      user.home.startsWith('/mnt/') &&
                                      _shell != '/usr/sbin/nologin'
                                  ? (value) =>
                                        setState(() => _sshPassword = value)
                                  : null,
                            ),
                            SwitchListTile(
                              key: const Key('account-replace-ssh'),
                              title: const Text('Replace authorized SSH key'),
                              subtitle: const Text(
                                'Replaces existing keys only; first-key creation is not supported. Existing key contents are never loaded into this form.',
                              ),
                              value: _replaceKey,
                              onChanged:
                                  enabled &&
                                      user.sshKeyPresent &&
                                      user.home.startsWith('/mnt/')
                                  ? (value) => setState(() {
                                      _replaceKey = value;
                                      _clearKey = false;
                                      _sshKey.clear();
                                    })
                                  : null,
                            ),
                            if (_replaceKey)
                              TextFormField(
                                key: const Key('account-new-ssh-key'),
                                controller: _sshKey,
                                enabled: enabled,
                                obscureText: true,
                                autocorrect: false,
                                enableSuggestions: false,
                                decoration: const InputDecoration(
                                  labelText: 'New public key (one line)',
                                ),
                                maxLength: 16384,
                                validator: (value) =>
                                    value == null || value.isEmpty
                                    ? 'Paste one supported public key.'
                                    : null,
                              ),
                            if (user.sshKeyPresent)
                              CheckboxListTile(
                                key: const Key('account-clear-ssh'),
                                title: const Text(
                                  'Remove all authorized SSH keys',
                                ),
                                value: _clearKey,
                                onChanged: enabled
                                    ? (value) => setState(() {
                                        _clearKey = value == true;
                                        _replaceKey = false;
                                        _sshKey.clear();
                                      })
                                    : null,
                              ),
                          ],
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              FilledButton(
                                key: const Key('account-review-user'),
                                onPressed: enabled ? _review : null,
                                child: const Text('Review changes'),
                              ),
                              if (!creating)
                                OutlinedButton(
                                  key: const Key('account-delete-user'),
                                  onPressed:
                                      user.editable &&
                                          (user.home == '/var/empty' ||
                                              canStat && canInspectSsh) &&
                                          !state.locked &&
                                          user.username !=
                                              widget
                                                  .inventory
                                                  .currentUsername &&
                                          ref
                                                  .watch(
                                                    accountsSessionProvider,
                                                  )
                                                  ?.accountsCapabilities
                                                  .canCall('user.delete') ==
                                              true
                                      ? _delete
                                      : null,
                                  child: const Text('Delete user'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _review() async {
    if (_form.currentState?.validate() != true || _primary == null) return;
    final user = widget.user;
    final password = _password.text.isEmpty ? null : _password.text;
    final groups = _groups.toList()..sort();
    final lines = <String>[];
    String groupLabel(int id) {
      final group = widget.inventory.groups.firstWhere(
        (group) => group.id == id,
      );
      return '${group.name} (GID ${group.gid}${group.roles.isEmpty ? '' : ', roles ${group.roles.join(', ')}'}${group.hasSudo ? ', elevated commands' : ''})';
    }

    if (user == null || _fullName.text != user.fullName) {
      lines.add('Full name: ${_fullName.text}');
    }
    if (user == null || _email.text != (user.email ?? '')) {
      lines.add('Email: ${_email.text.isEmpty ? '(none)' : _email.text}');
    }
    if (user == null || _primary != user.groupId) {
      lines.add('Primary group: ${groupLabel(_primary!)}');
    }
    if (user == null || !_setEqual(groups, user.groupIds)) {
      lines.add(
        'Supplementary groups: ${groups.isEmpty ? '(none)' : groups.map(groupLabel).join(', ')}',
      );
    }
    if (user == null || _shell != user.shell) lines.add('Shell: $_shell');
    if (user == null || _smb != user.smb) {
      lines.add(
        'SMB authentication: $_smb${user == null && _smb ? ' · adds builtin_users membership' : ''}',
      );
    }
    if (user == null || _disabled != user.passwordDisabled) {
      lines.add('Password authentication disabled: $_disabled');
    }
    if (user != null && _locked != user.locked) {
      lines.add('Account locked: $_locked');
    }
    if (user != null && _sshPassword != user.sshPasswordEnabled) {
      lines.add('SSH password authentication: $_sshPassword');
    }
    if (password != null) {
      lines.add(
        'Password: new private value supplied; it will not be displayed.',
      );
    }
    if (_replaceKey) {
      lines.add(
        'Replace ALL authorized SSH keys with the private entry supplied.',
      );
    }
    if (_replaceKey) {
      lines.add(
        'The server recursively removes ACLs and changes ownership and permissions throughout ${user!.home}/.ssh to this user and selected primary group (directory mode 700; authorized_keys mode 600). Requires an existing verified regular authorized_keys file. Visible extra entries and links are rejected; creating the first key is not supported.',
      );
    }
    if (_clearKey) {
      lines.add(
        'Remove ALL authorized SSH keys by unlinking ${user!.home}/.ssh/authorized_keys, including a dangling link at that exact path.',
      );
    }
    if (lines.isEmpty) {
      setState(() => _error = 'Select at least one change.');
      return;
    }
    final target = user?.username ?? _username.text;
    final create = user == null
        ? AccountUserCreate(
            inventory: widget.inventory,
            username: target,
            fullName: _fullName.text,
            email: _email.text,
            primaryGroupId: _primary!,
            groupIds: groups,
            shell: _shell,
            password: password,
            passwordDisabled: _disabled,
            smb: _smb,
          )
        : null;
    final update = user == null
        ? null
        : AccountUserUpdate(
            fullName: _fullName.text == user.fullName ? null : _fullName.text,
            email: _email.text == (user.email ?? '') ? null : _email.text,
            primaryGroupId: _primary == user.groupId ? null : _primary,
            groupIds: _setEqual(groups, user.groupIds) ? null : groups,
            shell: _shell == user.shell ? null : _shell,
            smb: _smb == user.smb ? null : _smb,
            passwordDisabled: _disabled == user.passwordDisabled
                ? null
                : _disabled,
            locked: _locked == user.locked ? null : _locked,
            sshPasswordEnabled: _sshPassword == user.sshPasswordEnabled
                ? null
                : _sshPassword,
            password: password,
            sshPublicKey: _clearKey
                ? ''
                : _replaceKey
                ? _sshKey.text
                : null,
          );
    final confirmed = await _confirmAccount(
      context,
      widget.session,
      target,
      user == null ? 'Create local user' : 'Update local user',
      lines,
    );
    if (!mounted) return;
    setState(_clearSecrets);
    if (!confirmed ||
        !identical(widget.session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    await ref
        .read(accountsControllerProvider.notifier)
        .perform(
          widget.session,
          target,
          (api) => create != null
              ? api.createAccountUser(create)
              : api.updateAccountUser(user!, update!),
        );
    if (mounted &&
        ref.read(accountsControllerProvider).result?.outcome ==
            AccountsOperationOutcome.verified) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete() async {
    final user = widget.user!;
    final confirmed = await _confirmAccount(
      context,
      widget.session,
      user.username,
      'Delete local user',
      [
        'Deletes this account and SMB credentials.${user.home == '/var/empty' ? '' : ' Also removes the entire ${user.home}/.ssh subtree, including dangling links.'}',
        'Keeps the primary group and other home files. File ownership and filesystem ACL entries are not reassigned.',
        'If this is the configured SMB guest account, the server resets the SMB guest to nobody.',
        'API keys must be revoked first. Another working local administrator must remain.',
      ],
    );
    if (!mounted) return;
    setState(_clearSecrets);
    if (!confirmed) return;
    await ref
        .read(accountsControllerProvider.notifier)
        .perform(
          widget.session,
          user.username,
          (api) => api.deleteAccountUser(user, user.username),
        );
    if (mounted &&
        ref.read(accountsControllerProvider).result?.outcome ==
            AccountsOperationOutcome.verified) {
      Navigator.of(context).pop();
    }
  }
}

class _GroupEditor extends ConsumerStatefulWidget {
  const _GroupEditor({
    required this.session,
    required this.inventory,
    this.group,
  });
  final AuthenticatedSession session;
  final AccountsInventory inventory;
  final AccountGroup? group;
  @override
  ConsumerState<_GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends ConsumerState<_GroupEditor> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  late bool _smb;
  late Set<int> _users;
  String? _error;
  @override
  void initState() {
    super.initState();
    _name.text = widget.group?.name ?? '';
    _smb = widget.group?.smb ?? false;
    _users = widget.group?.userIds.toSet() ?? {};
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final state = ref.watch(accountsControllerProvider);
    final group = widget.group;
    final method = group == null ? 'group.create' : 'group.update';
    final enabled =
        !state.locked &&
        (group == null || group.editable) &&
        ref
                .watch(accountsSessionProvider)
                ?.accountsCapabilities
                .canCall(method) ==
            true;
    return Scaffold(
      appBar: AppBar(
        title: Text(group == null ? 'Create local group' : 'Group details'),
      ),
      body: SafeArea(
        child: !identical(session, widget.session) || session?.endpoint == null
            ? const Center(
                child: Text(
                  'This group review expired. Reopen it on the current connection.',
                ),
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const AccountsOperationBanner(),
                          Text(
                            group?.name ?? 'New local group',
                            style: TdTypography.titleLarge,
                          ),
                          Text(widget.session.endpoint ?? ''),
                          if (group != null)
                            Text(
                              'GID ${group.gid} · API ID ${group.id}\nRoles: ${group.roles.isEmpty ? 'None' : group.roles.join(', ')}${group.hasSudo ? '\nElevated command access is configured.' : ''}${group.editable ? '' : '\nProtected identity: changes are disabled.'}',
                            ),
                          const SizedBox(height: 12),
                          TextFormField(
                            key: const Key('account-group-name'),
                            controller: _name,
                            enabled: enabled,
                            maxLength: 32,
                            decoration: const InputDecoration(
                              labelText: 'Group name',
                            ),
                            validator: (value) =>
                                value != null &&
                                    RegExp(
                                      r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$',
                                    ).hasMatch(value)
                                ? null
                                : 'Use a portable group name, up to 32 characters.',
                          ),
                          SwitchListTile(
                            key: const Key('account-group-smb'),
                            title: const Text('SMB group mapping'),
                            subtitle: const Text(
                              'Maps this group for SMB share ACLs.',
                            ),
                            value: _smb,
                            onChanged: enabled
                                ? (value) => setState(() => _smb = value)
                                : null,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Members (${_users.length})',
                            style: TdTypography.titleMedium,
                          ),
                          const Text(
                            'Primary-group members and protected users cannot be removed here. Group roles and elevated access apply to selected members.',
                          ),
                          for (final user in widget.inventory.users.where(
                            (user) => user.local,
                          ))
                            CheckboxListTile(
                              key: Key('account-group-member-${user.id}'),
                              title: Text(user.username),
                              subtitle: Text(
                                '${user.fullName}${user.groupId == group?.id ? ' · Primary group member' : ''}${user.editable ? '' : ' · Protected'}',
                              ),
                              value: _users.contains(user.id),
                              onChanged:
                                  enabled &&
                                      user.editable &&
                                      user.groupId != group?.id
                                  ? (value) => setState(() {
                                      if (value == true) {
                                        _users.add(user.id);
                                      } else {
                                        _users.remove(user.id);
                                      }
                                    })
                                  : null,
                            ),
                          if (_error != null)
                            Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              FilledButton(
                                key: const Key('account-review-group'),
                                onPressed: enabled ? _review : null,
                                child: const Text('Review changes'),
                              ),
                              if (group != null)
                                OutlinedButton(
                                  key: const Key('account-delete-group'),
                                  onPressed:
                                      group.editable &&
                                          !state.locked &&
                                          ref
                                                  .watch(
                                                    accountsSessionProvider,
                                                  )
                                                  ?.accountsCapabilities
                                                  .canCall('group.delete') ==
                                              true
                                      ? _delete
                                      : null,
                                  child: const Text('Delete group'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _review() async {
    if (_form.currentState?.validate() != true) return;
    final group = widget.group;
    final users = _users.toList()..sort();
    final lines = <String>[
      if (group == null || _name.text != group.name)
        'Group name: ${_name.text}',
      if (group == null || _smb != group.smb) 'SMB group mapping: $_smb',
      if (group == null || !_setEqual(users, group.userIds))
        'Members: ${users.isEmpty ? '(none)' : users.map((id) => widget.inventory.users.firstWhere((user) => user.id == id).username).join(', ')}',
      if (group != null && group.roles.isNotEmpty)
        'Roles granted by membership: ${group.roles.join(', ')}',
      if (group?.hasSudo == true)
        'Members receive the existing elevated command access.',
    ];
    if (lines.isEmpty) {
      setState(() => _error = 'Select at least one change.');
      return;
    }
    final confirmed = await _confirmAccount(
      context,
      widget.session,
      group?.name ?? _name.text,
      group == null ? 'Create local group' : 'Update local group',
      lines,
    );
    if (!mounted || !confirmed) return;
    await ref
        .read(accountsControllerProvider.notifier)
        .perform(
          widget.session,
          group?.name ?? _name.text,
          (api) => group == null
              ? api.createAccountGroup(
                  AccountGroupCreate(
                    inventory: widget.inventory,
                    name: _name.text,
                    smb: _smb,
                    userIds: users,
                  ),
                )
              : api.updateAccountGroup(
                  group,
                  AccountGroupUpdate(
                    name: _name.text == group.name ? null : _name.text,
                    smb: _smb == group.smb ? null : _smb,
                    userIds: _setEqual(users, group.userIds) ? null : users,
                  ),
                ),
        );
    if (mounted &&
        ref.read(accountsControllerProvider).result?.outcome ==
            AccountsOperationOutcome.verified) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete() async {
    final group = widget.group!;
    final confirmed = await _confirmAccount(
      context,
      widget.session,
      group.name,
      'Delete local group',
      [
        'Requires no members, primary-group users, or privilege dependencies.',
        'Keeps all users. File ownership and filesystem ACL entries can retain the old numeric GID; they are not rewritten.',
      ],
    );
    if (!mounted || !confirmed) return;
    await ref
        .read(accountsControllerProvider.notifier)
        .perform(
          widget.session,
          group.name,
          (api) => api.deleteAccountGroup(group, group.name),
        );
    if (mounted &&
        ref.read(accountsControllerProvider).result?.outcome ==
            AccountsOperationOutcome.verified) {
      Navigator.of(context).pop();
    }
  }
}

bool _setEqual(List<int> a, List<int> b) =>
    a.length == b.length && a.toSet().containsAll(b);

Future<bool> _confirmAccount(
  BuildContext context,
  AuthenticatedSession session,
  String target,
  String title,
  List<String> lines,
) async {
  if (lines.length > 200 || lines.join('\n').length > 16384) return false;
  var entered = '';
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => Consumer(
          builder: (context, ref, _) {
            if (!identical(
                  session,
                  ref.watch(dashboardActiveSessionProvider),
                ) ||
                session.endpoint == null) {
              return AlertDialog(
                title: const Text('Review expired'),
                content: const Text(
                  'The connection changed. Old account values are hidden.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Close'),
                  ),
                ],
              );
            }
            return StatefulBuilder(
              builder: (context, setState) => AlertDialog(
                title: Text(title),
                content: SizedBox(
                  width: 560,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(session.endpoint!),
                        const SizedBox(height: 8),
                        Text('Exact target: $target'),
                        const SizedBox(height: 12),
                        for (final line in lines)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(line),
                          ),
                        const Text(
                          'The server can reload account and SSH services. No mutation is retried automatically.',
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('account-confirm-name'),
                          decoration: InputDecoration(
                            labelText: 'Type $target to confirm',
                          ),
                          onChanged: (value) => setState(() => entered = value),
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    key: const Key('account-confirm-cancel'),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('account-confirm-submit'),
                    onPressed: entered == target
                        ? () => Navigator.of(context).pop(true)
                        : null,
                    child: const Text('Confirm change'),
                  ),
                ],
              ),
            );
          },
        ),
      ) ??
      false;
}
