import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import 'directory_idmap_controller.dart';
import 'directory_ldap_activation_panel.dart';
import 'directory_ldap_editor.dart';
import 'directory_maintenance_controller.dart';
import '../dashboard/dashboard_controller.dart';

final directoryIdmapInventoryProvider =
    FutureProvider.autoDispose<DirectoryIdmapInventory>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      final api = repository is AuthenticatedDirectoryIdmapSession
          ? repository as AuthenticatedDirectoryIdmapSession
          : null;
      if (api?.directoryIdmapCapabilities.canRead != true) {
        throw const DirectoryIdmapException();
      }
      return api!.loadDirectoryIdmap();
    });

class DirectoryIdmapPage extends ConsumerWidget {
  const DirectoryIdmapPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final repository = session?.repository;
    final api = repository is AuthenticatedDirectoryIdmapSession
        ? repository as AuthenticatedDirectoryIdmapSession
        : null;
    final canRead = api?.directoryIdmapCapabilities.canRead == true;
    final inventory = canRead
        ? ref.watch(directoryIdmapInventoryProvider)
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Directory services')),
      body: !canRead
          ? const Center(
              child: Text(
                'Connect to a supported TrueNAS 25.10 server to inspect ID mapping.',
              ),
            )
          : inventory!.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Directory ID mapping could not be loaded safely.',
                    ),
                    TextButton(
                      onPressed: () =>
                          ref.invalidate(directoryIdmapInventoryProvider),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              data: (data) => RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(directoryIdmapInventoryProvider);
                  await ref.read(directoryIdmapInventoryProvider.future);
                },
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      'Server: ${data.endpoint}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      data.isActiveDirectory
                          ? 'Active Directory ID mapping'
                          : data.ldap != null
                          ? 'LDAP configuration'
                          : 'Current service: ${data.serviceType ?? 'none'}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      'Directory service: ${data.enabled ? 'enabled' : 'disabled'} · last status: ${data.status ?? 'unknown'}',
                    ),
                    const SizedBox(height: 12),
                    if ((api!.directoryIdmapCapabilities.canRefreshCache ||
                            api.directoryIdmapCapabilities.canSyncKeytab &&
                                data.isActiveDirectory) &&
                        data.serviceType != null)
                      DirectoryMaintenancePanel(
                        key: ValueKey('cache:${data.hostId}'),
                        inventory: data,
                        canRefreshCache:
                            api.directoryIdmapCapabilities.canRefreshCache,
                        canSyncKeytab:
                            api.directoryIdmapCapabilities.canSyncKeytab,
                      ),
                    if (data.ldap case final ldap?) ...[
                      const Text(
                        'LDAP overview. Bind credentials and advanced attribute maps are never shown here.',
                      ),
                      const SizedBox(height: 8),
                      for (final url in ldap.serverUrls)
                        Card(
                          child: ListTile(
                            leading: Icon(
                              url.startsWith('ldaps://')
                                  ? Icons.lock_outline
                                  : Icons.dns_outlined,
                            ),
                            title: Text(url),
                            subtitle: Text(
                              url.startsWith('ldaps://')
                                  ? 'LDAP over TLS'
                                  : ldap.startTls
                                  ? 'LDAP with StartTLS'
                                  : 'Unencrypted LDAP transport',
                            ),
                          ),
                        ),
                      Card(
                        child: Column(
                          children: [
                            ListTile(
                              title: const Text('Authentication'),
                              subtitle: Text(ldap.credentialType ?? 'Unknown'),
                            ),
                            ListTile(
                              title: const Text(
                                'Custom LDAP attribute mappings',
                              ),
                              subtitle: Text(
                                '${ldap.attributeMaps?.overrideCount ?? 0} of 19 overridden',
                              ),
                            ),
                            ListTile(
                              title: const Text('Base DN'),
                              subtitle: Text(ldap.baseDn),
                            ),
                            for (final entry in [
                              ('User search base', ldap.userSearchBase),
                              ('Group search base', ldap.groupSearchBase),
                              ('Netgroup search base', ldap.netgroupSearchBase),
                            ])
                              ListTile(
                                title: Text(entry.$1),
                                subtitle: Text(entry.$2 ?? 'Base DN (default)'),
                              ),
                            ListTile(
                              title: const Text('Schema'),
                              subtitle: Text(ldap.schema),
                            ),
                            ListTile(
                              title: const Text('Certificate validation'),
                              subtitle: Text(
                                ldap.validateCertificates
                                    ? 'Enabled'
                                    : 'Disabled',
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!ldap.encryptedTransport ||
                          !ldap.validateCertificates)
                        Text(
                          'LDAP transport or certificate validation is not fully protected. Review this server configuration in TrueNAS.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      const Text(
                        'Directory account-resolution effects cannot be verified in this view.',
                      ),
                      if (ldap.credentialType != 'LDAP_ANONYMOUS')
                        const Text(
                          'Editing this authentication type is not supported; credentials remain hidden.',
                        ),
                      if (ldap.hasAuxiliaryParameters)
                        const Text(
                          'LDAP auxiliary parameters are configured. This bounded editor cannot safely echo or change them.',
                        ),
                      if (api.directoryIdmapCapabilities.canEdit &&
                          ldap.credentialType == 'LDAP_ANONYMOUS' &&
                          !ldap.hasAuxiliaryParameters)
                        DirectoryLdapActivationPanel(
                          key: ValueKey('ldap-state:${data.hostId}'),
                          inventory: data,
                        ),
                      if (api.directoryIdmapCapabilities.canEdit &&
                          ldap.credentialType == 'LDAP_ANONYMOUS' &&
                          !ldap.hasAuxiliaryParameters &&
                          !data.enabled &&
                          (data.status == null || data.status == 'DISABLED'))
                        DirectoryLdapEditor(
                          key: ValueKey('ldap:${data.hostId}'),
                          inventory: data,
                        ),
                    ],
                    if (data.isActiveDirectory) ...[
                      const Text(
                        'Changing ID mapping can change how users and groups resolve to files. TrueNAS requires directory services to be disabled before changing this configuration.',
                      ),
                      const SizedBox(height: 12),
                      for (final domain in data.domains)
                        Card(
                          child: ListTile(
                            title: Text(domain.label),
                            subtitle: Text(
                              '${domain.backend} · UID/GID ${domain.range.low}–${domain.range.high}',
                            ),
                            trailing: Icon(
                              domain.range.valid
                                  ? Icons.check_circle_outline
                                  : Icons.error_outline,
                              semanticLabel: domain.range.valid
                                  ? 'Valid range'
                                  : 'Invalid range',
                            ),
                          ),
                        ),
                      if (data.domains.isNotEmpty)
                        DirectoryIdmapRangeChart(domains: data.domains),
                      const SizedBox(height: 12),
                      Text(
                        data.warnings.isEmpty
                            ? 'No range overlap or bound issue detected in the displayed mapping.'
                            : 'Range issues',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      for (final issue in data.warnings)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(issue),
                        ),
                      const SizedBox(height: 12),
                      if (api.directoryIdmapCapabilities.canEdit &&
                          data.isActiveDirectory)
                        DirectoryIdmapEditor(
                          key: ValueKey(
                            '${data.hostId}:${data.trusted.length}',
                          ),
                          inventory: data,
                        ),
                      const Text(
                        'This inventory does not inspect directory account resolution or prove that existing file ownership remains usable.',
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

/// Shared numeric axis makes gaps and overlaps visible without exposing
/// anything from the secret-bearing directory configuration.
class DirectoryIdmapRangeChart extends StatelessWidget {
  const DirectoryIdmapRangeChart({required this.domains, super.key});

  final List<DirectoryIdmapDomain> domains;

  @override
  Widget build(BuildContext context) {
    if (domains.isEmpty) return const SizedBox.shrink();
    final low = domains.map((d) => d.range.low).reduce((a, b) => a < b ? a : b);
    final high = domains
        .map((d) => d.range.high)
        .reduce((a, b) => a > b ? a : b);
    final span = (high - low).toDouble();
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Directory ID range chart, from $low to $high',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'UID/GID range map',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                '$low – $high',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < domains.length; i++) ...[
                Text(
                  '${domains[i].label} · ${domains[i].range.low}–${domains[i].range.high}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    if (width < 2) return const SizedBox(height: 16);
                    final start = span <= 0
                        ? 0.0
                        : ((domains[i].range.low - low) / span * width)
                              .clamp(0.0, width)
                              .toDouble();
                    final end = span <= 0
                        ? width
                        : ((domains[i].range.high - low) / span * width)
                              .clamp(0.0, width)
                              .toDouble();
                    final barWidth = (end - start).clamp(2.0, width).toDouble();
                    final barStart = start
                        .clamp(0.0, width - barWidth)
                        .toDouble();
                    final problem =
                        !domains[i].range.valid ||
                        domains.asMap().entries.any(
                          (other) =>
                              other.key != i &&
                              domains[i].range.overlaps(other.value.range),
                        );
                    return SizedBox(
                      height: 16,
                      child: Stack(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          Positioned(
                            left: barStart,
                            width: barWidth,
                            top: 0,
                            bottom: 0,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: problem ? colors.error : colors.primary,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DirectoryIdmapEditor extends ConsumerStatefulWidget {
  const DirectoryIdmapEditor({required this.inventory, super.key});
  final DirectoryIdmapInventory inventory;

  @override
  ConsumerState<DirectoryIdmapEditor> createState() =>
      _DirectoryIdmapEditorState();
}

class _DirectoryIdmapEditorState extends ConsumerState<DirectoryIdmapEditor> {
  late final List<TextEditingController> _ranges;
  late List<DirectoryIdmapBackendOptions?> _options;
  final _confirmation = TextEditingController();
  bool _identityRisk = false, _ownershipRisk = false, _recoveryAccepted = false;
  final _addName = TextEditingController();
  final _addLow = TextEditingController();
  final _addHigh = TextEditingController();
  bool _addTrusted = false, _trustRisk = false;
  String? _removal;
  bool _removalRisk = false;
  String? _transitionTarget;
  bool _transitionRisk = false;
  String _transitionSchema = 'RFC2307';
  bool _transitionSssd = false;
  bool _transitionUnixPrimary = false, _transitionUnixNss = false;
  String _addBackend = 'RID', _addSchema = 'RFC2307';
  bool _addSssd = false, _addUnixPrimary = false, _addUnixNss = false;

  @override
  void initState() {
    super.initState();
    final builtin = widget.inventory.builtin?.range;
    final primary = widget.inventory.primary?.range;
    final values = [
      builtin?.low,
      builtin?.high,
      primary?.low,
      primary?.high,
      for (final domain in widget.inventory.trusted) ...[
        domain.range.low,
        domain.range.high,
      ],
    ];
    _ranges = [
      for (final value in values)
        TextEditingController(text: value?.toString() ?? ''),
    ];
    _options = [
      widget.inventory.primary?.options,
      ...widget.inventory.trusted.map((domain) => domain.options),
    ];
  }

  @override
  void didUpdateWidget(covariant DirectoryIdmapEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.inventory, widget.inventory)) return;
    final current = ref.read(directoryIdmapControllerProvider);
    if (current.locked) return;
    final builtin = widget.inventory.builtin?.range;
    final primary = widget.inventory.primary?.range;
    final values = [
      builtin?.low,
      builtin?.high,
      primary?.low,
      primary?.high,
      for (final domain in widget.inventory.trusted) ...[
        domain.range.low,
        domain.range.high,
      ],
    ];
    for (var i = 0; i < _ranges.length; i++) {
      _ranges[i].text = values[i]?.toString() ?? '';
    }
    _options = [
      widget.inventory.primary?.options,
      ...widget.inventory.trusted.map((domain) => domain.options),
    ];
    _confirmation.clear();
    _identityRisk = false;
    _ownershipRisk = false;
    _addTrusted = false;
    _trustRisk = false;
    _removal = null;
    _removalRisk = false;
    _transitionTarget = null;
    _transitionRisk = false;
    _transitionSchema = 'RFC2307';
    _transitionSssd = false;
    _transitionUnixPrimary = false;
    _transitionUnixNss = false;
    _addName.clear();
    _addLow.clear();
    _addHigh.clear();
    _addBackend = 'RID';
    _addSchema = 'RFC2307';
    _addSssd = false;
    _addUnixPrimary = false;
    _addUnixNss = false;
    if (current.review == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(directoryIdmapControllerProvider.notifier).clearReview();
      }
    });
  }

  @override
  void dispose() {
    for (final controller in _ranges) {
      controller.dispose();
    }
    _confirmation.dispose();
    _addName.dispose();
    _addLow.dispose();
    _addHigh.dispose();
    super.dispose();
  }

  DirectoryIdmapRangeDraft? get _draft {
    final values = _ranges.map((c) => int.tryParse(c.text.trim())).toList();
    if (values.any((value) => value == null)) return null;
    final addedLow = _addTrusted ? int.tryParse(_addLow.text.trim()) : null;
    final addedHigh = _addTrusted ? int.tryParse(_addHigh.text.trim()) : null;
    if (_addTrusted && (addedLow == null || addedHigh == null)) return null;
    return DirectoryIdmapRangeDraft(
      builtin: DirectoryIdmapRange(low: values[0]!, high: values[1]!),
      trusted: [
        for (var i = 4; i < values.length; i += 2)
          DirectoryIdmapRange(low: values[i]!, high: values[i + 1]!),
      ],
      primary: DirectoryIdmapRange(low: values[2]!, high: values[3]!),
      options: _options,
      addition: !_addTrusted
          ? null
          : DirectoryIdmapTrustedAddition(
              name: _addName.text.trim(),
              range: DirectoryIdmapRange(low: addedLow!, high: addedHigh!),
              options: _addBackend == 'RID'
                  ? DirectoryIdmapBackendOptions.rid(sssdCompat: _addSssd)
                  : DirectoryIdmapBackendOptions.ad(
                      schemaMode: _addSchema,
                      unixPrimaryGroup: _addUnixPrimary,
                      unixNssInfo: _addUnixNss,
                    ),
            ),
      removal: _removal,
      transition: _transitionTarget == null
          ? null
          : _transitionTarget == '@primary'
          ? DirectoryIdmapBackendTransition.primary(
              _transitionOptions(widget.inventory.primary!),
            )
          : DirectoryIdmapBackendTransition.trusted(
              _transitionTarget,
              _transitionOptions(
                widget.inventory.trusted.singleWhere(
                  (domain) => domain.label == _transitionTarget,
                ),
              ),
            ),
    );
  }

  DirectoryIdmapBackendOptions _transitionOptions(
    DirectoryIdmapDomain domain,
  ) => domain.backend == 'RID'
      ? DirectoryIdmapBackendOptions.ad(
          schemaMode: _transitionSchema,
          unixPrimaryGroup: _transitionUnixPrimary,
          unixNssInfo: _transitionUnixNss,
        )
      : DirectoryIdmapBackendOptions.rid(sssdCompat: _transitionSssd);

  void _selectTransition(String? target) {
    _selectRemoval(null);
    setState(() {
      _transitionTarget = target;
      _transitionRisk = false;
    });
  }

  void _selectRemoval(String? name) {
    ref.read(directoryIdmapControllerProvider.notifier).clearReview();
    final builtin = widget.inventory.builtin?.range;
    final primary = widget.inventory.primary?.range;
    final values = [
      builtin?.low,
      builtin?.high,
      primary?.low,
      primary?.high,
      for (final domain in widget.inventory.trusted) ...[
        domain.range.low,
        domain.range.high,
      ],
    ];
    setState(() {
      _removal = name;
      _transitionTarget = null;
      _transitionRisk = false;
      _removalRisk = false;
      _addTrusted = false;
      _trustRisk = false;
      _confirmation.clear();
      _identityRisk = false;
      _ownershipRisk = false;
      for (var i = 0; i < _ranges.length; i++) {
        _ranges[i].text = values[i]?.toString() ?? '';
      }
      _options = [
        widget.inventory.primary?.options,
        ...widget.inventory.trusted.map((domain) => domain.options),
      ];
    });
  }

  void _changeAddition(VoidCallback update) {
    ref.read(directoryIdmapControllerProvider.notifier).clearReview();
    setState(() {
      update();
      _trustRisk = false;
    });
  }

  void _setOption(int index, DirectoryIdmapBackendOptions next) {
    ref.read(directoryIdmapControllerProvider.notifier).clearReview();
    setState(() => _options[index] = next);
  }

  Widget _backendOptionsEditor(
    int index,
    DirectoryIdmapDomain domain,
    bool locked,
  ) {
    final current = _options[index];
    if (current == null) return const SizedBox.shrink();
    final label = domain.label;
    if (current.backend == 'RID') {
      return SwitchListTile(
        title: Text('$label SSSD compatibility'),
        value: current.sssdCompat!,
        onChanged: locked
            ? null
            : (value) => _setOption(
                index,
                DirectoryIdmapBackendOptions.rid(sssdCompat: value),
              ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: current.schemaMode,
          decoration: InputDecoration(labelText: '$label schema mode'),
          items: const [
            DropdownMenuItem(value: 'RFC2307', child: Text('RFC2307')),
            DropdownMenuItem(value: 'SFU', child: Text('SFU')),
            DropdownMenuItem(value: 'SFU20', child: Text('SFU20')),
          ],
          onChanged: locked
              ? null
              : (value) {
                  if (value == null) return;
                  _setOption(
                    index,
                    DirectoryIdmapBackendOptions.ad(
                      schemaMode: value,
                      unixPrimaryGroup: current.unixPrimaryGroup!,
                      unixNssInfo: current.unixNssInfo!,
                    ),
                  );
                },
        ),
        SwitchListTile(
          title: Text('$label Unix primary group'),
          value: current.unixPrimaryGroup!,
          onChanged: locked
              ? null
              : (value) => _setOption(
                  index,
                  DirectoryIdmapBackendOptions.ad(
                    schemaMode: current.schemaMode!,
                    unixPrimaryGroup: value,
                    unixNssInfo: current.unixNssInfo!,
                  ),
                ),
        ),
        SwitchListTile(
          title: Text('$label Unix NSS info'),
          value: current.unixNssInfo!,
          onChanged: locked
              ? null
              : (value) => _setOption(
                  index,
                  DirectoryIdmapBackendOptions.ad(
                    schemaMode: current.schemaMode!,
                    unixPrimaryGroup: current.unixPrimaryGroup!,
                    unixNssInfo: value,
                  ),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final operation = ref.watch(directoryIdmapControllerProvider);
    final draft = _draft;
    final error =
        draft?.validateAgainst(widget.inventory) ??
        (draft == null
            ? 'Enter whole-number boundaries for every range.'
            : null);
    final review = operation.review;
    final result = operation.result;
    final canRecover = ref
        .read(directoryIdmapControllerProvider.notifier)
        .canAcknowledgeAfterReconnect;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit RID or AD ID mapping',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'Available only for disabled Active Directory with a Kerberos principal, a RID or AD primary domain, and up to eight existing RID or AD trusted domains. Range, option, add, remove and backend migrations are separately reviewed. Any change may alter account IDs, groups, or directory-provided home and shell values.',
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < _ranges.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: _ranges[i],
                  enabled:
                      !operation.locked &&
                      _removal == null &&
                      _transitionTarget == null,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: switch (i) {
                      0 => 'BUILTIN low',
                      1 => 'BUILTIN high',
                      2 => 'Primary domain low',
                      3 => 'Primary domain high',
                      _ =>
                        '${widget.inventory.trusted[(i - 4) ~/ 2].label} ${i.isEven ? 'low' : 'high'}',
                    },
                  ),
                  onChanged: (_) {
                    ref
                        .read(directoryIdmapControllerProvider.notifier)
                        .clearReview();
                    setState(() {});
                  },
                ),
              ),
            if (widget.inventory.primary != null)
              _backendOptionsEditor(
                0,
                widget.inventory.primary!,
                operation.locked ||
                    _removal != null ||
                    _transitionTarget != null,
              ),
            for (var i = 0; i < widget.inventory.trusted.length; i++)
              _backendOptionsEditor(
                i + 1,
                widget.inventory.trusted[i],
                operation.locked ||
                    _removal != null ||
                    _transitionTarget != null,
              ),
            if (widget.inventory.trusted.isNotEmpty)
              DropdownButtonFormField<String>(
                key: ValueKey(
                  'remove:${_removal ?? ''}:${widget.inventory.trusted.length}',
                ),
                initialValue: _removal ?? '',
                decoration: const InputDecoration(
                  labelText: 'Remove existing trusted domain',
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('Keep all trusted domains'),
                  ),
                  for (final domain in widget.inventory.trusted)
                    DropdownMenuItem(
                      value: domain.label,
                      child: Text(domain.label),
                    ),
                ],
                onChanged: operation.locked || _transitionTarget != null
                    ? null
                    : (value) => _selectRemoval(value == '' ? null : value),
              ),
            if (_removal != null)
              Text(
                'Removing $_removal deletes its saved TrueNAS ID mapping. Directory accounts may stop resolving and existing file ownership may no longer be usable. This does not verify or remove the remote trust relationship.',
              ),
            if (widget.inventory.trusted.length < 8)
              SwitchListTile(
                title: const Text('Add one trusted domain'),
                value: _addTrusted,
                onChanged:
                    operation.locked ||
                        _removal != null ||
                        _transitionTarget != null
                    ? null
                    : (value) => _changeAddition(() => _addTrusted = value),
              ),
            if (_addTrusted) ...[
              const Text(
                'Only add a domain whose trust relationship and NetBIOS name you verified independently. TrueNAS requires separate configuration for every trusted domain; this app cannot discover or validate that topology.',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _addName,
                enabled: !operation.locked,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'New trusted domain NetBIOS name',
                ),
                onChanged: (_) => _changeAddition(() {}),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _addLow,
                enabled: !operation.locked,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'New trusted domain low',
                ),
                onChanged: (_) => _changeAddition(() {}),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _addHigh,
                enabled: !operation.locked,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'New trusted domain high',
                ),
                onChanged: (_) => _changeAddition(() {}),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _addBackend,
                decoration: const InputDecoration(
                  labelText: 'New trusted domain backend',
                ),
                items: const [
                  DropdownMenuItem(value: 'RID', child: Text('RID')),
                  DropdownMenuItem(value: 'AD', child: Text('AD')),
                ],
                onChanged: operation.locked
                    ? null
                    : (value) {
                        if (value != null) {
                          _changeAddition(() => _addBackend = value);
                        }
                      },
              ),
              if (_addBackend == 'RID')
                SwitchListTile(
                  title: const Text('New domain SSSD compatibility'),
                  value: _addSssd,
                  onChanged: operation.locked
                      ? null
                      : (value) => _changeAddition(() => _addSssd = value),
                )
              else ...[
                DropdownButtonFormField<String>(
                  initialValue: _addSchema,
                  decoration: const InputDecoration(
                    labelText: 'New domain schema mode',
                  ),
                  items: const [
                    DropdownMenuItem(value: 'RFC2307', child: Text('RFC2307')),
                    DropdownMenuItem(value: 'SFU', child: Text('SFU')),
                    DropdownMenuItem(value: 'SFU20', child: Text('SFU20')),
                  ],
                  onChanged: operation.locked
                      ? null
                      : (value) {
                          if (value != null) {
                            _changeAddition(() => _addSchema = value);
                          }
                        },
                ),
                SwitchListTile(
                  title: const Text('New domain Unix primary group'),
                  value: _addUnixPrimary,
                  onChanged: operation.locked
                      ? null
                      : (value) =>
                            _changeAddition(() => _addUnixPrimary = value),
                ),
                SwitchListTile(
                  title: const Text('New domain Unix NSS info'),
                  value: _addUnixNss,
                  onChanged: operation.locked
                      ? null
                      : (value) => _changeAddition(() => _addUnixNss = value),
                ),
              ],
            ],
            const SizedBox(height: 12),
            if (widget.inventory.primary?.options != null ||
                widget.inventory.trusted.any(
                  (domain) => domain.options != null,
                ))
              DropdownButtonFormField<String>(
                key: ValueKey('migrate:${_transitionTarget ?? ''}'),
                initialValue: _transitionTarget ?? '',
                decoration: const InputDecoration(
                  labelText: 'Migrate one existing domain backend',
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('No migration'),
                  ),
                  if (widget.inventory.primary?.options != null)
                    const DropdownMenuItem(
                      value: '@primary',
                      child: Text('Primary domain'),
                    ),
                  for (final domain in widget.inventory.trusted)
                    if (domain.options != null)
                      DropdownMenuItem(
                        value: domain.label,
                        child: Text(domain.label),
                      ),
                ],
                onChanged: operation.locked
                    ? null
                    : (value) => _selectTransition(value == '' ? null : value),
              ),
            if (_transitionTarget != null) ...[
              Text(
                'Changing the backend may remap every account in this domain. AD requires pre-provisioned Unix IDs in the selected directory schema; this app cannot verify account attributes. RID derives IDs algorithmically. Confirm file ownership and recovery before submitting.',
              ),
              if ((draft?.transition?.options.backend ?? '') == 'RID')
                SwitchListTile(
                  title: const Text('Migrated domain SSSD compatibility'),
                  value: _transitionSssd,
                  onChanged: operation.locked
                      ? null
                      : (value) => setState(() {
                          _transitionSssd = value;
                          _transitionRisk = false;
                          ref
                              .read(directoryIdmapControllerProvider.notifier)
                              .clearReview();
                        }),
                )
              else ...[
                DropdownButtonFormField<String>(
                  key: ValueKey('migration-schema:$_transitionSchema'),
                  initialValue: _transitionSchema,
                  decoration: const InputDecoration(
                    labelText: 'Migrated domain schema mode',
                  ),
                  items: const [
                    DropdownMenuItem(value: 'RFC2307', child: Text('RFC2307')),
                    DropdownMenuItem(value: 'SFU', child: Text('SFU')),
                    DropdownMenuItem(value: 'SFU20', child: Text('SFU20')),
                  ],
                  onChanged: operation.locked
                      ? null
                      : (value) => setState(() {
                          _transitionSchema = value ?? 'RFC2307';
                          _transitionRisk = false;
                          ref
                              .read(directoryIdmapControllerProvider.notifier)
                              .clearReview();
                        }),
                ),
                SwitchListTile(
                  title: const Text('Migrated domain Unix primary group'),
                  value: _transitionUnixPrimary,
                  onChanged: operation.locked
                      ? null
                      : (value) => setState(() {
                          _transitionUnixPrimary = value;
                          _transitionRisk = false;
                          ref
                              .read(directoryIdmapControllerProvider.notifier)
                              .clearReview();
                        }),
                ),
                SwitchListTile(
                  title: const Text('Migrated domain Unix NSS info'),
                  value: _transitionUnixNss,
                  onChanged: operation.locked
                      ? null
                      : (value) => setState(() {
                          _transitionUnixNss = value;
                          _transitionRisk = false;
                          ref
                              .read(directoryIdmapControllerProvider.notifier)
                              .clearReview();
                        }),
                ),
              ],
            ],
            const SizedBox(height: 8),
            if (error != null)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (operation.message != null) Text(operation.message!),
            if (result != null) ...[
              Text(result.message),
              if (result.job != null)
                OutlinedButton(
                  onPressed: operation.busy
                      ? null
                      : () => ref
                            .read(directoryIdmapControllerProvider.notifier)
                            .poll(),
                  child: const Text('Check owned job'),
                ),
              if (result.outcome == DirectoryIdmapOutcome.unknown &&
                  canRecover) ...[
                CheckboxListTile(
                  value: _recoveryAccepted,
                  onChanged: (value) =>
                      setState(() => _recoveryAccepted = value == true),
                  title: const Text(
                    'I independently inspected the original server job and current UID/GID mapping. The prior result remains unverified.',
                  ),
                ),
                OutlinedButton(
                  onPressed: _recoveryAccepted
                      ? () {
                          ref
                              .read(directoryIdmapControllerProvider.notifier)
                              .acknowledgeAfterReconnect();
                          setState(() => _recoveryAccepted = false);
                        }
                      : null,
                  child: const Text('Acknowledge after reconnect'),
                ),
              ],
            ],
            if (review == null && !operation.locked)
              FilledButton(
                onPressed: error == null && !operation.busy
                    ? () => ref
                          .read(directoryIdmapControllerProvider.notifier)
                          .review(draft!)
                    : null,
                child: const Text('Review ID mapping change'),
              ),
            if (review != null && !operation.locked) ...[
              const SizedBox(height: 12),
              Text(
                'Review changes',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final change in review.changes) Text(change),
              Text('Server: ${review.inventory.endpoint}'),
              Text('Host: ${review.inventory.hostId}'),
              Text('Review expires: ${review.expiresAt.toLocal()}'),
              CheckboxListTile(
                value: _identityRisk,
                onChanged: (value) =>
                    setState(() => _identityRisk = value == true),
                title: const Text(
                  'I understand UID/GID mappings may change for directory accounts.',
                ),
              ),
              CheckboxListTile(
                value: _ownershipRisk,
                onChanged: (value) =>
                    setState(() => _ownershipRisk = value == true),
                title: const Text(
                  'I have checked file ownership and have a recovery plan.',
                ),
              ),
              if (review.draft.addition != null)
                CheckboxListTile(
                  value: _trustRisk,
                  onChanged: (value) =>
                      setState(() => _trustRisk = value == true),
                  title: Text(
                    'I verified ${review.draft.addition!.name} is a real trusted domain and that all trusted domains are configured. I accept that incorrect mapping may deny account access.',
                  ),
                ),
              if (review.draft.removal != null)
                CheckboxListTile(
                  value: _removalRisk,
                  onChanged: (value) =>
                      setState(() => _removalRisk = value == true),
                  title: Text(
                    'I verified ${review.draft.removal} should lose its TrueNAS ID mapping, checked affected accounts and file ownership, and have a recovery plan.',
                  ),
                ),
              if (review.draft.transition != null)
                CheckboxListTile(
                  value: _transitionRisk,
                  onChanged: (value) =>
                      setState(() => _transitionRisk = value == true),
                  title: Text(
                    'I verified ${review.draft.transition!.label} account mappings for the new backend, checked affected file ownership, and have a recovery plan.',
                  ),
                ),
              TextField(
                controller: _confirmation,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Type ${review.confirmation} to confirm',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed:
                    _identityRisk &&
                        _ownershipRisk &&
                        (review.draft.addition == null || _trustRisk) &&
                        (review.draft.removal == null || _removalRisk) &&
                        (review.draft.transition == null || _transitionRisk) &&
                        _confirmation.text == review.confirmation
                    ? () => ref
                          .read(directoryIdmapControllerProvider.notifier)
                          .execute(_confirmation.text)
                    : null,
                child: const Text('Submit ID mapping update once'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A separately reviewed directory cache refresh. It does not fix share login.
class DirectoryMaintenancePanel extends ConsumerStatefulWidget {
  const DirectoryMaintenancePanel({
    required this.inventory,
    this.canRefreshCache = true,
    this.canSyncKeytab = false,
    super.key,
  });
  final DirectoryIdmapInventory inventory;
  final bool canRefreshCache, canSyncKeytab;

  @override
  ConsumerState<DirectoryMaintenancePanel> createState() =>
      _DirectoryMaintenancePanelState();
}

class _DirectoryMaintenancePanelState
    extends ConsumerState<DirectoryMaintenancePanel> {
  final _confirmation = TextEditingController();
  bool _impactAccepted = false, _recoveryAccepted = false;

  void _beginReview(DirectoryMaintenanceAction action) {
    _confirmation.clear();
    setState(() => _impactAccepted = false);
    ref.read(directoryMaintenanceControllerProvider.notifier).review(action);
  }

  @override
  void didUpdateWidget(covariant DirectoryMaintenancePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.inventory, widget.inventory)) return;
    _confirmation.clear();
    _impactAccepted = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(directoryMaintenanceControllerProvider.notifier).clearReview();
      }
    });
  }

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(directoryMaintenanceControllerProvider);
    final controller = ref.read(
      directoryMaintenanceControllerProvider.notifier,
    );
    final review = state.review, result = state.result;
    final available =
        widget.inventory.enabled && widget.inventory.status == 'HEALTHY';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Directory maintenance',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'Refreshes cached users and groups used by account lists. It may take a while and does not repair share authentication or change ACL identity mappings.',
            ),
            if (widget.canSyncKeytab && widget.inventory.isActiveDirectory)
              const Text(
                'Syncing the local keytab reads updated Kerberos service principal names from the AD domain controller. Use it only after those SPNs were added remotely.',
              ),
            if (!available)
              const Text(
                'Available only while the directory service is healthy.',
              ),
            if (state.message != null) Text(state.message!),
            if (result != null) ...[
              Text(result.message),
              if (result.job != null)
                OutlinedButton(
                  onPressed: state.busy ? null : controller.poll,
                  child: const Text('Check directory job'),
                ),
              if (result.outcome == DirectoryIdmapOutcome.unknown &&
                  controller.canAcknowledgeAfterReconnect) ...[
                CheckboxListTile(
                  value: _recoveryAccepted,
                  onChanged: (value) =>
                      setState(() => _recoveryAccepted = value == true),
                  title: const Text(
                    'I independently inspected the original server job. Its prior outcome remains unverified.',
                  ),
                ),
                OutlinedButton(
                  onPressed: _recoveryAccepted
                      ? () {
                          controller.acknowledgeAfterReconnect();
                          setState(() => _recoveryAccepted = false);
                        }
                      : null,
                  child: const Text('Acknowledge after reconnect'),
                ),
              ],
            ],
            if (review == null && !state.locked) ...[
              if (widget.canRefreshCache)
                FilledButton.tonal(
                  onPressed: available
                      ? () => _beginReview(
                          DirectoryMaintenanceAction.refreshCache,
                        )
                      : null,
                  child: const Text('Review cache refresh'),
                ),
              if (widget.canSyncKeytab && widget.inventory.isActiveDirectory)
                FilledButton.tonal(
                  onPressed: available
                      ? () =>
                            _beginReview(DirectoryMaintenanceAction.syncKeytab)
                      : null,
                  child: const Text('Review AD keytab sync'),
                ),
            ],
            if (review != null && !state.locked) ...[
              Text('Server: ${review.inventory.endpoint}'),
              Text('Service: ${review.inventory.serviceType}'),
              Text('Host: ${review.inventory.hostId}'),
              Text('Review expires: ${review.expiresAt.toLocal()}'),
              TextButton(
                onPressed: () {
                  _confirmation.clear();
                  setState(() => _impactAccepted = false);
                  controller.clearReview();
                },
                child: const Text('Cancel review'),
              ),
              CheckboxListTile(
                value: _impactAccepted,
                onChanged: (value) =>
                    setState(() => _impactAccepted = value == true),
                title: Text(
                  review.action == DirectoryMaintenanceAction.refreshCache
                      ? 'I understand refreshing account lists may be slow and will not resolve share authentication problems.'
                      : 'I verified the AD computer account SPNs changed and understand keytab sync may affect Kerberos-backed access.',
                ),
              ),
              TextField(
                controller: _confirmation,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Type ${review.confirmation} to confirm',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed:
                    _impactAccepted && _confirmation.text == review.confirmation
                    ? () => controller.execute(_confirmation.text)
                    : null,
                child: Text(
                  review.action == DirectoryMaintenanceAction.refreshCache
                      ? 'Refresh directory cache once'
                      : 'Sync AD keytab once',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
