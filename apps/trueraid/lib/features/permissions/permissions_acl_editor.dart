import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'permissions_controller.dart';

/// An ordered native ACE editor. It never submits a setter or strips an ACL.
class PermissionsAclEditor extends StatefulWidget {
  const PermissionsAclEditor({
    required this.entries,
    required this.aclType,
    required this.session,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });
  final List<PermissionAce> entries;
  final PermissionAclType aclType;
  final AuthenticatedSession session;
  final ValueChanged<List<PermissionAce>> onChanged;
  final bool enabled;
  @override
  State<PermissionsAclEditor> createState() => _PermissionsAclEditorState();
}

class _PermissionsAclEditorState extends State<PermissionsAclEditor> {
  int _selected = 0;
  bool get _nfs => widget.aclType == PermissionAclType.nfs4;
  void _replace(PermissionAce entry) {
    final entries = [...widget.entries];
    entries[_selected] = entry;
    widget.onChanged(entries);
  }

  void _move(int direction) {
    final entries = [...widget.entries];
    final entry = entries.removeAt(_selected);
    _selected += direction;
    entries.insert(_selected, entry);
    widget.onChanged(entries);
  }

  @override
  Widget build(BuildContext context) {
    if (_selected >= widget.entries.length) {
      _selected = widget.entries.length - 1;
    }
    final entry = _selected >= 0 ? widget.entries[_selected] : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Access entries · ${widget.entries.length}',
          style: TdTypography.titleSmall,
        ),
        const SizedBox(height: TdSpacing.related),
        Text(
          _nfs
              ? 'NFSv4 entries are evaluated in order. No automatic reordering or canonicalization is requested.'
              : 'POSIX access and default entries are distinct. Required entries and masks are checked before submission.',
        ),
        const SizedBox(height: TdSpacing.component),
        if (widget.entries.isEmpty)
          const Text(
            'No access entries. Add the entries required by this ACL type.',
          ),
        for (var index = 0; index < widget.entries.length; index++) ...[
          Material(
            color: index == _selected
                ? context.tdTheme.actionPrimary.withValues(alpha: .10)
                : context.tdTheme.surfaceRaised,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(TdRadius.control),
              side: BorderSide(
                color: index == _selected
                    ? context.tdTheme.actionPrimary
                    : context.tdTheme.borderSubtle,
              ),
            ),
            child: InkWell(
              key: ValueKey('permissions-select-ace-$index'),
              borderRadius: BorderRadius.circular(TdRadius.control),
              onTap: widget.enabled
                  ? () => setState(() => _selected = index)
                  : null,
              child: Padding(
                padding: const EdgeInsets.all(TdSpacing.related),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${index + 1}. ${permissionPrincipal(widget.entries[index])}',
                      style: TdTypography.label,
                    ),
                    const SizedBox(height: TdSpacing.inline),
                    Text(permissionAceSummary(widget.entries[index])),
                    if (index == _selected) const Text('Selected for editing'),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: TdSpacing.related),
        ],
        Wrap(
          spacing: TdSpacing.related,
          runSpacing: TdSpacing.related,
          children: [
            OutlinedButton.icon(
              key: const Key('permissions-add-ace'),
              onPressed: widget.enabled && widget.entries.length < 128
                  ? () {
                      final newEntry = PermissionAce(
                        tag: 'USER',
                        id: null,
                        type: _nfs ? 'ALLOW' : null,
                        permissions: {
                          for (final name
                              in _nfs
                                  ? PermissionAce.nfs4PermissionNames
                                  : PermissionAce.posixPermissionNames)
                            name: false,
                        },
                        flags: {
                          if (_nfs)
                            for (final name in PermissionAce.nfs4FlagNames)
                              name: false,
                        },
                        isDefault: false,
                      );
                      _selected = widget.entries.length;
                      widget.onChanged([...widget.entries, newEntry]);
                    }
                  : null,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add entry'),
            ),
            OutlinedButton.icon(
              key: const Key('permissions-ace-up'),
              onPressed: widget.enabled && _selected > 0
                  ? () => _move(-1)
                  : null,
              icon: const Icon(Icons.arrow_upward_rounded),
              label: const Text('Move up'),
            ),
            OutlinedButton.icon(
              key: const Key('permissions-ace-down'),
              onPressed:
                  widget.enabled &&
                      _selected >= 0 &&
                      _selected < widget.entries.length - 1
                  ? () => _move(1)
                  : null,
              icon: const Icon(Icons.arrow_downward_rounded),
              label: const Text('Move down'),
            ),
            TextButton.icon(
              key: const Key('permissions-remove-ace'),
              onPressed: widget.enabled && entry != null
                  ? () {
                      final entries = [...widget.entries]..removeAt(_selected);
                      widget.onChanged(entries);
                    }
                  : null,
              icon: const Icon(Icons.remove_circle_outline),
              label: const Text('Remove selected'),
            ),
          ],
        ),
        if (entry != null) ...[
          const SizedBox(height: TdSpacing.group),
          Text('Edit entry ${_selected + 1}', style: TdTypography.titleSmall),
          const SizedBox(height: TdSpacing.component),
          _AceEditor(
            key: ValueKey('permissions-ace-editor-$_selected'),
            entry: entry,
            nfs: _nfs,
            session: widget.session,
            enabled: widget.enabled,
            onChanged: _replace,
          ),
        ],
      ],
    );
  }
}

class _AceEditor extends ConsumerStatefulWidget {
  const _AceEditor({
    required this.entry,
    required this.nfs,
    required this.session,
    required this.enabled,
    required this.onChanged,
    super.key,
  });
  final PermissionAce entry;
  final bool nfs, enabled;
  final AuthenticatedSession session;
  final ValueChanged<PermissionAce> onChanged;
  @override
  ConsumerState<_AceEditor> createState() => _AceEditorState();
}

class _AceEditorState extends ConsumerState<_AceEditor> {
  late final _identityId = TextEditingController(
    text: widget.entry.id?.toString() ?? '',
  );
  PermissionIdentity? _identity;
  String? _error;
  bool _resolving = false;
  @override
  void didUpdateWidget(covariant _AceEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.tag != widget.entry.tag ||
        oldWidget.entry.id != widget.entry.id) {
      _identityId.text = widget.entry.id?.toString() ?? '';
      if (_identity?.id != widget.entry.id) _identity = null;
      _error = null;
    }
  }

  @override
  void dispose() {
    _identityId.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    final id = int.tryParse(_identityId.text);
    if (id == null || id < 0) {
      setState(() => _error = 'Enter a non-negative numeric UID or GID.');
      return;
    }
    final session = ref.read(dashboardActiveSessionProvider);
    final api = ref.read(permissionsSessionProvider);
    if (!identical(session, widget.session) || api == null || _resolving) {
      return;
    }
    final tag = widget.entry.tag;
    final kind = tag == 'USER'
        ? PermissionIdentityKind.user
        : PermissionIdentityKind.group;
    setState(() {
      _resolving = true;
      _error = null;
    });
    try {
      final identity = await api.lookupPermissionIdentity(kind, id);
      if (!mounted ||
          !widget.enabled ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          widget.entry.tag != tag) {
        return;
      }
      if (identity == null ||
          !identity.local ||
          identity.kind != kind ||
          identity.id != id) {
        setState(
          () => _error = 'This identity could not be verified as a local principal. Existing unresolved entries are preserved; no new identity was selected.',
        );
      } else {
        setState(() => _identity = identity);
        widget.onChanged(_copyAce(widget.entry, id: identity.id));
      }
    } on Object {
      if (mounted &&
          identical(session, ref.read(dashboardActiveSessionProvider))) {
        setState(
          () => _error = 'Identity lookup failed. No principal was changed.',
        );
      }
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!identical(ref.watch(dashboardActiveSessionProvider), widget.session)) {
      return const Text('The connection changed. This entry editor is hidden.');
    }
    final entry = widget.entry;
    final tags = widget.nfs
        ? const ['owner@', 'group@', 'everyone@', 'USER', 'GROUP']
        : const ['USER_OBJ', 'USER', 'GROUP_OBJ', 'GROUP', 'MASK', 'OTHER'];
    final named = entry.tag == 'USER' || entry.tag == 'GROUP';
    final names = widget.nfs
        ? PermissionAce.nfs4PermissionNames
        : PermissionAce.posixPermissionNames;
    final enabled = widget.enabled && !_resolving;
    final lookupAvailable =
        ref
            .watch(permissionsSessionProvider)
            ?.permissionsCapabilities
            .canCall(entry.tag == 'USER' ? 'user.query' : 'group.query') ==
        true;
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: const Key('permissions-principal-tag'),
            initialValue: tags.contains(entry.tag) ? entry.tag : null,
            decoration: const InputDecoration(labelText: 'Principal'),
            isExpanded: true,
            items: [
              for (final tag in tags)
                DropdownMenuItem(value: tag, child: Text(_principalLabel(tag))),
            ],
            onChanged: enabled
                ? (tag) {
                    if (tag == null) return;
                    _identity = null;
                    widget.onChanged(_copyAce(entry, tag: tag, id: null));
                  }
                : null,
          ),
          if (named) ...[
            const SizedBox(height: TdSpacing.component),
            TextFormField(
              key: const Key('permissions-identity-id'),
              controller: _identityId,
              enabled: enabled && lookupAvailable,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: entry.tag == 'USER' ? 'User UID' : 'Group GID',
                helperText: 'Typed IDs are not applied until Resolve & select identity succeeds.',
                helperMaxLines: 4,
              ),
            ),
            const SizedBox(height: TdSpacing.related),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('permissions-resolve-identity'),
                onPressed: enabled && lookupAvailable ? _resolve : null,
                icon: _resolving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.person_search_outlined),
                label: const Text('Resolve & select identity'),
              ),
            ),
            if (!lookupAvailable)
              const Text(
                'Identity lookup is unavailable to this connection. The current numeric principal is preserved.',
              ),
            if (_identity != null)
              Text(
                'Selected: ${_identity!.name} · ${entry.tag == 'USER' ? 'UID' : 'GID'} ${_identity!.id}',
              )
            else if (entry.id != null)
              Text(
                'Current ${entry.tag == 'USER' ? 'UID' : 'GID'} ${entry.id} is preserved unless a new identity is resolved.',
              ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: context.tdTheme.statusCritical),
              ),
          ],
          if (widget.nfs) ...[
            const SizedBox(height: TdSpacing.component),
            DropdownButtonFormField<String>(
              key: const Key('permissions-ace-type'),
              initialValue: entry.type,
              decoration: const InputDecoration(labelText: 'Access type'),
              items: [
                const DropdownMenuItem(
                  value: 'ALLOW',
                  child: Text('Allow selected permissions'),
                ),
                DropdownMenuItem(
                  value: 'DENY',
                  enabled: named,
                  child: const Text('Deny selected permissions'),
                ),
              ],
              isExpanded: true,
              onChanged: enabled
                  ? (value) {
                      if (value != null) {
                        widget.onChanged(_copyAce(entry, type: value));
                      }
                    }
                  : null,
            ),
            if (!named)
              const Text(
                'Deny entries require a named user or group in this supported workflow.',
              ),
          ] else ...[
            const SizedBox(height: TdSpacing.component),
            CheckboxListTile(
              key: const Key('permissions-default-ace'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Default entry for newly created children'),
              subtitle: const Text('Existing descendants are not rewritten.'),
              value: entry.isDefault,
              onChanged: enabled
                  ? (value) => widget.onChanged(
                      _copyAce(entry, isDefault: value ?? false),
                    )
                  : null,
            ),
          ],
          const SizedBox(height: TdSpacing.component),
          const Text('Permission bits', style: TdTypography.titleSmall),
          for (final name in names)
            CheckboxListTile(
              key: ValueKey('permissions-bit-$name'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(_label(name)),
              value: entry.permissions[name] == true,
              onChanged: enabled
                  ? (value) => widget.onChanged(
                      _copyAce(
                        entry,
                        permissions: {
                          ...entry.permissions,
                          name: value ?? false,
                        },
                      ),
                    )
                  : null,
            ),
          if (widget.nfs) ...[
            const SizedBox(height: TdSpacing.component),
            const Text('Inheritance flags', style: TdTypography.titleSmall),
            const Text(
              'These flags can affect newly created children. Existing descendants are not rewritten.',
            ),
            for (final name in PermissionAce.nfs4FlagNames)
              CheckboxListTile(
                key: ValueKey('permissions-flag-$name'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(_label(name)),
                subtitle: name == 'INHERITED'
                    ? const Text(
                        'Server-provided inherited marker is preserved.',
                      )
                    : null,
                value: entry.flags[name] == true,
                onChanged: enabled && name != 'INHERITED'
                    ? (value) => widget.onChanged(
                        _copyAce(
                          entry,
                          flags: {...entry.flags, name: value ?? false},
                        ),
                      )
                    : null,
              ),
          ],
        ],
      ),
    );
  }
}

enum _Keep { id }

PermissionAce _copyAce(
  PermissionAce entry, {
  String? tag,
  Object? id = _Keep.id,
  String? type,
  Map<String, bool>? permissions,
  Map<String, bool>? flags,
  bool? isDefault,
}) => PermissionAce(
  tag: tag ?? entry.tag,
  id: id == _Keep.id ? entry.id : id as int?,
  type: type ?? entry.type,
  permissions: permissions ?? entry.permissions,
  flags: flags ?? entry.flags,
  isDefault: isDefault ?? entry.isDefault,
);

String permissionPrincipal(PermissionAce entry) =>
    '${_principalLabel(entry.tag)}${entry.id == null ? '' : ' #${entry.id}'}';
String permissionAceSummary(PermissionAce entry) {
  final permissions = entry.permissions.entries
      .where((item) => item.value)
      .map((item) => item.key)
      .join(', ');
  final flags = entry.flags.entries
      .where((item) => item.value)
      .map((item) => item.key)
      .join(', ');
  return '${entry.type ?? (entry.isDefault ? 'DEFAULT' : 'ACCESS')} · ${permissions.isEmpty ? 'No permission bits' : permissions}'
      '${flags.isEmpty ? '' : '\nFlags: $flags'}';
}

String _principalLabel(String tag) => switch (tag) {
  'owner@' || 'USER_OBJ' => 'Owner',
  'group@' || 'GROUP_OBJ' => 'Owning group',
  'everyone@' => 'Everyone',
  'USER' => 'Named user',
  'GROUP' => 'Named group',
  'MASK' => 'POSIX mask',
  'OTHER' => 'Other users',
  _ => tag,
};
String _label(String name) => name
    .toLowerCase()
    .split('_')
    .map(
      (word) =>
          word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}',
    )
    .join(' ');
