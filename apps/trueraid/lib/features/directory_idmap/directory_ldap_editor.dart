import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import 'directory_ldap_controller.dart';

class DirectoryLdapEditor extends ConsumerStatefulWidget {
  const DirectoryLdapEditor({required this.inventory, super.key});
  final DirectoryIdmapInventory inventory;

  @override
  ConsumerState<DirectoryLdapEditor> createState() =>
      _DirectoryLdapEditorState();
}

class _DirectoryLdapEditorState extends ConsumerState<DirectoryLdapEditor> {
  late final TextEditingController _servers;
  late final TextEditingController _baseDn;
  late final TextEditingController _userSearchBase;
  late final TextEditingController _groupSearchBase;
  late final TextEditingController _netgroupSearchBase;
  late final Map<String, TextEditingController> _attributes;
  final _confirmation = TextEditingController();
  late String _schema;
  late bool _startTls;
  bool _acceptRisk = false;

  @override
  void initState() {
    super.initState();
    final ldap = widget.inventory.ldap!;
    _servers = TextEditingController(text: ldap.serverUrls.join('\n'));
    _baseDn = TextEditingController(text: ldap.baseDn);
    _userSearchBase = TextEditingController(text: ldap.userSearchBase);
    _groupSearchBase = TextEditingController(text: ldap.groupSearchBase);
    _netgroupSearchBase = TextEditingController(text: ldap.netgroupSearchBase);
    _attributes = {
      for (final category in directoryLdapAttributeFields.entries)
        for (final field in category.value)
          '${category.key}.$field': TextEditingController(
            text: ldap.attributeMaps?.value(category.key, field),
          ),
    };
    _schema = ldap.schema;
    _startTls = ldap.startTls;
  }

  @override
  void didUpdateWidget(covariant DirectoryLdapEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inventory.hostId != widget.inventory.hostId ||
        oldWidget.inventory.ldap != widget.inventory.ldap) {
      final ldap = widget.inventory.ldap!;
      _servers.text = ldap.serverUrls.join('\n');
      _baseDn.text = ldap.baseDn;
      _userSearchBase.text = ldap.userSearchBase ?? '';
      _groupSearchBase.text = ldap.groupSearchBase ?? '';
      _netgroupSearchBase.text = ldap.netgroupSearchBase ?? '';
      for (final category in directoryLdapAttributeFields.entries) {
        for (final field in category.value) {
          _attributes['${category.key}.$field']!.text =
              ldap.attributeMaps?.value(category.key, field) ?? '';
        }
      }
      _schema = ldap.schema;
      _startTls = ldap.startTls;
      _confirmation.clear();
      _acceptRisk = false;
    }
  }

  @override
  void dispose() {
    _servers.dispose();
    _baseDn.dispose();
    _userSearchBase.dispose();
    _groupSearchBase.dispose();
    _netgroupSearchBase.dispose();
    for (final controller in _attributes.values) {
      controller.dispose();
    }
    _confirmation.dispose();
    super.dispose();
  }

  void _changed() {
    ref.read(directoryLdapControllerProvider.notifier).clearReview();
    _confirmation.clear();
    _acceptRisk = false;
    setState(() {});
  }

  DirectoryLdapDraft get _draft => DirectoryLdapDraft(
    serverUrls: _servers.text
        .split('\n')
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty)
        .toList(),
    baseDn: _baseDn.text.trim(),
    schema: _schema,
    startTls: _startTls,
    validateCertificates: true,
    userSearchBase: _userSearchBase.text.trim().isEmpty
        ? null
        : _userSearchBase.text.trim(),
    groupSearchBase: _groupSearchBase.text.trim().isEmpty
        ? null
        : _groupSearchBase.text.trim(),
    netgroupSearchBase: _netgroupSearchBase.text.trim().isEmpty
        ? null
        : _netgroupSearchBase.text.trim(),
    attributeMaps: DirectoryLdapAttributeMaps.parse({
      for (final category in directoryLdapAttributeFields.entries)
        category.key: {
          for (final field in category.value)
            field: _attributes['${category.key}.$field']!.text.trim().isEmpty
                ? null
                : _attributes['${category.key}.$field']!.text.trim(),
        },
    }),
  );

  @override
  Widget build(BuildContext context) {
    final operation = ref.watch(directoryLdapControllerProvider);
    final controller = ref.read(directoryLdapControllerProvider.notifier);
    final error = _draft.validateAgainst(widget.inventory);
    final review = operation.review;
    final result = operation.result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit anonymous LDAP',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'Only an existing, disabled anonymous LDAP service with default advanced settings can be edited. Bind credentials, auxiliary parameters and enabling the service are not changed here. Attribute mapping edits can change user and group identity resolution. Optional search bases narrow which directory users, groups and netgroups TrueNAS can find. All server URLs must use LDAPS or all must use StartTLS; certificate validation stays on.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _servers,
              enabled: !operation.locked,
              maxLines: 3,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'LDAP server URLs (one per line)',
                hintText: 'ldaps://ldap.example.invalid',
              ),
              onChanged: (_) => _changed(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _baseDn,
              enabled: !operation.locked,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Base DN',
              ),
              onChanged: (_) => _changed(),
            ),
            const SizedBox(height: 8),
            const Text(
              'Optional search bases. Leave blank to use the Base DN. Changing these can hide directory accounts from TrueNAS.',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _userSearchBase,
              enabled: !operation.locked,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'User search base DN (optional)',
              ),
              onChanged: (_) => _changed(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _groupSearchBase,
              enabled: !operation.locked,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Group search base DN (optional)',
              ),
              onChanged: (_) => _changed(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _netgroupSearchBase,
              enabled: !operation.locked,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Netgroup search base DN (optional)',
              ),
              onChanged: (_) => _changed(),
            ),
            const SizedBox(height: 8),
            ExpansionTile(
              title: const Text('Advanced LDAP attribute mappings'),
              subtitle: Text(
                '${widget.inventory.ldap?.attributeMaps?.overrideCount ?? 0} custom values saved',
              ),
              children: [
                const Text(
                  'Use only attribute or object-class names verified on the LDAP server. Empty values restore TrueNAS defaults. Incorrect mappings may hide accounts or change UID/GID resolution.',
                ),
                for (final category in directoryLdapAttributeFields.entries)
                  ExpansionTile(
                    title: Text(category.key),
                    children: [
                      for (final field in category.value)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: TextField(
                            key: ValueKey('ldap-attr:${category.key}.$field'),
                            controller: _attributes['${category.key}.$field'],
                            enabled: !operation.locked,
                            decoration: InputDecoration(
                              border: const OutlineInputBorder(),
                              labelText: field,
                              hintText: 'TrueNAS default',
                            ),
                            onChanged: (_) => _changed(),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
            DropdownButtonFormField<String>(
              key: ValueKey(_schema),
              initialValue: _schema,
              decoration: const InputDecoration(labelText: 'Schema'),
              items: const [
                DropdownMenuItem(value: 'RFC2307', child: Text('RFC2307')),
                DropdownMenuItem(
                  value: 'RFC2307BIS',
                  child: Text('RFC2307BIS'),
                ),
              ],
              onChanged: operation.locked
                  ? null
                  : (value) {
                      if (value != null) {
                        _schema = value;
                        _changed();
                      }
                    },
            ),
            SwitchListTile(
              title: const Text('StartTLS (for ldap:// URLs)'),
              value: _startTls,
              onChanged: operation.locked
                  ? null
                  : (value) {
                      _startTls = value;
                      _changed();
                    },
            ),
            const ListTile(
              leading: Icon(Icons.verified_user_outlined),
              title: Text('Certificate validation'),
              subtitle: Text('Required and always enabled for edits'),
            ),
            if (error != null && review == null && result == null)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (operation.message case final message?)
              Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (operation.busy) const LinearProgressIndicator(),
            if (review == null && result == null)
              FilledButton.tonal(
                onPressed: operation.locked || error != null
                    ? null
                    : () => controller.review(_draft),
                child: const Text('Review LDAP change'),
              ),
            if (review != null) ...[
              const SizedBox(height: 12),
              Text(
                'Review changes on ${review.inventory.endpoint}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final change in review.changes) Text('• $change'),
              const Text(
                'LDAP lookup and account/group resolution may change after the service is enabled again. This app does not validate directory reachability or file ownership.',
              ),
              CheckboxListTile(
                title: const Text('I understand this directory-identity risk'),
                value: _acceptRisk,
                onChanged: (value) =>
                    setState(() => _acceptRisk = value ?? false),
              ),
              TextField(
                controller: _confirmation,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Type ${review.confirmation} to confirm',
                ),
                onChanged: (_) => setState(() {}),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: controller.clearReview,
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed:
                        operation.locked ||
                            !_acceptRisk ||
                            _confirmation.text != review.confirmation ||
                            DateTime.now().toUtc().isAfter(review.expiresAt)
                        ? null
                        : () => controller.execute(_confirmation.text),
                    child: const Text('Submit once'),
                  ),
                ],
              ),
            ],
            if (result != null) ...[
              Text(result.message),
              if (result.outcome == DirectoryIdmapOutcome.pending &&
                  result.job != null)
                FilledButton.tonal(
                  onPressed: operation.busy ? null : controller.poll,
                  child: const Text('Check owned job'),
                ),
              if (result.outcome == DirectoryIdmapOutcome.unknown)
                const Text(
                  'Outcome is uncertain. Do not resubmit. Inspect the original TrueNAS server.',
                ),
              if (controller.canAcknowledgeAfterReconnect)
                TextButton(
                  onPressed: controller.acknowledgeAfterReconnect,
                  child: const Text('Acknowledge after same-server reload'),
                ),
              if (!operation.locked)
                TextButton(
                  onPressed: controller.clearReview,
                  child: const Text('Dismiss'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
