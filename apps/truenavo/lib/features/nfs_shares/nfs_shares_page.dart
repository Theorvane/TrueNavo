import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../nfs_settings/nfs_settings_page.dart';
import 'nfs_shares_controller.dart';

class NfsSharesPage extends ConsumerStatefulWidget {
  const NfsSharesPage({super.key});
  @override
  ConsumerState<NfsSharesPage> createState() => _NfsSharesPageState();
}

class _NfsSharesPageState extends ConsumerState<NfsSharesPage> {
  String _search = '';
  bool _reviewing = false, _ready = false;
  String? _error;
  Future<void> _delete(
    AuthenticatedSession session,
    NfsShareInventory inventory,
    NfsShare share,
  ) async {
    setState(() {
      _reviewing = true;
      _ready = false;
      _error = null;
    });
    try {
      await _review(
        context,
        ref,
        session,
        NfsShareRequest(
          inventory: inventory,
          action: NfsShareAction.delete,
          share: share,
        ),
        onReady: () {
          if (mounted) setState(() => _ready = true);
        },
      );
    } on Object {
      if (mounted &&
          identical(session, ref.read(dashboardActiveSessionProvider))) {
        setState(
          () => _error = 'The export could not be reviewed. Reload inventory; nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final caps = ref.watch(nfsSharesSessionProvider)?.nfsSharesCapabilities;
    final state = ref.watch(nfsSharesControllerProvider);
    final available = caps?.supported == true && session?.endpoint != null;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) {
        setState(() {
          _search = '';
          _error = null;
        });
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('NFS shares'),
        actions: [
          IconButton(
            key: const Key('nfs-server-settings'),
            tooltip: 'NFS server settings',
            onPressed: !state.locked && !_reviewing
                ? () => Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => const NfsSettingsPage()),
                  )
                : null,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            key: const Key('nfs-refresh'),
            tooltip: 'Reload NFS shares',
            onPressed: available && !state.locked && !_reviewing
                ? () => ref.invalidate(nfsSharesInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _Workspace(
        children: [
          const Text('FILE SHARING', style: TdTypography.micro),
          const SizedBox(height: 8),
          const Text('NFS exports', style: TdTypography.titleLarge),
          const SizedBox(height: 8),
          Text(session?.endpoint ?? 'No authenticated server'),
          const SizedBox(height: 20),
          const NfsSharesOperationBanner(),
          if (!available)
            TdPanel(
              title: 'NFS unavailable',
              child: Text(
                caps?.blockedReason ?? 'Connect to a supported TrueNAS server.',
              ),
            )
          else if (state.locked && !state.connectionCurrent)
            const TdPanel(
              title: 'Original operation needs attention',
              child: Text(
                'Previous inventory is hidden. Resolve the original outcome before another change.',
              ),
            )
          else
            ref
                .watch(nfsSharesInventoryProvider)
                .when(
                  skipLoadingOnReload: false,
                  skipLoadingOnRefresh: false,
                  loading: () => const LinearProgressIndicator(),
                  error: (_, _) => TdPanel(
                    title: 'NFS inventory unavailable',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'No current inventory could be verified. Remote details were withheld. Reads are not retried automatically.',
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: state.locked
                              ? null
                              : () =>
                                    ref.invalidate(nfsSharesInventoryProvider),
                          child: const Text('Retry inventory'),
                        ),
                      ],
                    ),
                  ),
                  data: (inventory) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NfsShareEnablementChart(shares: inventory.shares),
                      const SizedBox(height: 16),
                      TdPanel(
                        title: 'Service readiness',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'NFS ${inventory.serviceState}',
                              style: TdTypography.titleSmall,
                            ),
                            Text(
                              'Start at boot: ${inventory.serviceEnabled ? 'enabled' : 'disabled'} · ${inventory.protocols.join(', ')}',
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Configuration is not proof of client access. This workspace never starts or stops NFS.',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (inventory.blockedReason != null) ...[
                        TdPanel(
                          title: 'Changes unavailable',
                          child: Text(inventory.blockedReason!),
                        ),
                        const SizedBox(height: 16),
                      ],
                      FilledButton.icon(
                        key: const Key('nfs-create'),
                        onPressed:
                            caps!.canCreate &&
                                inventory.blockedReason == null &&
                                !state.locked &&
                                !_reviewing
                            ? () => Navigator.of(context).push<void>(
                                MaterialPageRoute(
                                  builder: (_) => NfsShareEditor(
                                    session: session!,
                                    inventory: inventory,
                                  ),
                                ),
                              )
                            : null,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Create NFS share'),
                      ),
                      if (!caps.canCreate && !caps.canUpdate && !caps.canDelete)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'This account has read-only access or required safety methods are unavailable.',
                          ),
                        ),
                      const SizedBox(height: 16),
                      TextField(
                        key: ValueKey(
                          'nfs-search-${identityHashCode(session)}',
                        ),
                        onChanged: (v) => setState(() => _search = v),
                        decoration: const InputDecoration(
                          labelText: 'Find an export',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (inventory.shares.isEmpty)
                        const TdPanel(
                          title: 'No exports configured',
                          child: Text(
                            'Create an export for an existing dataset root. No folders or permissions are changed.',
                          ),
                        ),
                      for (final share in inventory.shares.where(
                        (s) => '${s.settings.path} ${s.settings.comment}'
                            .toLowerCase()
                            .contains(_search.toLowerCase()),
                      ))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: TdPanel(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  share.settings.path,
                                  style: TdTypography.titleSmall,
                                ),
                                Text(
                                  'Export #${share.id} · ${share.settings.enabled ? 'Enabled' : 'Disabled'} · ${share.settings.readOnly ? 'Read only' : 'Read / write'}',
                                ),
                                if (share.settings.comment.isNotEmpty)
                                  Text(share.settings.comment),
                                const SizedBox(height: 12),
                                Text(_clients(share.settings)),
                                Text(_mapping(share.settings)),
                                if (share.blockedReason != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(share.blockedReason!),
                                  ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    OutlinedButton.icon(
                                      key: Key('nfs-edit-${share.id}'),
                                      onPressed:
                                          caps.canUpdate &&
                                              share.editable &&
                                              inventory.blockedReason == null &&
                                              !state.locked &&
                                              !_reviewing
                                          ? () => Navigator.of(context)
                                                .push<void>(
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        NfsShareEditor(
                                                          session: session!,
                                                          inventory: inventory,
                                                          share: share,
                                                        ),
                                                  ),
                                                )
                                          : null,
                                      icon: const Icon(Icons.tune_rounded),
                                      label: const Text('Edit export'),
                                    ),
                                    TextButton.icon(
                                      key: Key('nfs-delete-${share.id}'),
                                      onPressed:
                                          caps.canDelete &&
                                              share.editable &&
                                              inventory.blockedReason == null &&
                                              !state.locked &&
                                              !_reviewing
                                          ? () => _delete(
                                              session!,
                                              inventory,
                                              share,
                                            )
                                          : null,
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                      ),
                                      label: const Text('Delete export'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (_reviewing && !_ready)
                        const LinearProgressIndicator(),
                      if (_error != null) Text(_error!),
                      const SizedBox(height: 16),
                      const Text(
                        'Bounded native workflow: existing unencrypted unmanaged dataset roots, IPv4 clients, AUTH_SYS and verified local nonzero identity mappings. DNS/netgroups, IPv6, Kerberos, HA, RDMA, snapshot exposure and path moves remain unavailable. No ACL, ownership or directory creation controls are hidden here.',
                      ),
                    ],
                  ),
                ),
        ],
      ),
    );
  }
}

class NfsSharesOperationBanner extends ConsumerWidget {
  const NfsSharesOperationBanner({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(nfsSharesControllerProvider);
    if (state.result == null && !state.busy && state.recoveryMessage == null) {
      return const SizedBox.shrink();
    }
    final controller = ref.read(nfsSharesControllerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TdPanel(
        title: state.unknown
            ? 'NFS outcome unverified'
            : state.busy
            ? 'Applying NFS configuration'
            : state.result?.outcome == NfsShareOutcome.verified
            ? 'Configuration read back'
            : 'NFS operation',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.server != null) Text('Original server: ${state.server}'),
            if (state.target != null) Text('Target: ${state.target}'),
            if (state.busy) const LinearProgressIndicator(),
            if (state.result != null) Text(state.result!.message),
            if (state.recoveryMessage != null) Text(state.recoveryMessage!),
            if (state.unknown)
              const Text(
                'Inspect the original server and clients. Reconnect to that same endpoint only after checking the outcome; no prior request will be sent again.',
              ),
            if (controller.canAcknowledge)
              OutlinedButton(
                onPressed: controller.acknowledgeAfterReconnect,
                child: const Text('I inspected the original outcome'),
              ),
          ],
        ),
      ),
    );
  }
}

class NfsShareEditor extends ConsumerStatefulWidget {
  const NfsShareEditor({
    required this.session,
    required this.inventory,
    this.share,
    super.key,
  });
  final AuthenticatedSession session;
  final NfsShareInventory inventory;
  final NfsShare? share;
  @override
  ConsumerState<NfsShareEditor> createState() => _NfsShareEditorState();
}

class _NfsShareEditorState extends ConsumerState<NfsShareEditor> {
  late final TextEditingController _comment, _hosts, _networks, _user, _group;
  String? _path;
  String _mappingMode = 'none';
  bool _enabled = true, _readOnly = false, _busy = false, _ready = false;
  bool _expired = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final s = widget.share?.settings;
    _path = s?.path;
    _comment = TextEditingController(text: s?.comment ?? '');
    _hosts = TextEditingController(text: s?.hosts.join(', ') ?? '');
    _networks = TextEditingController(text: s?.networks.join(', ') ?? '');
    _enabled = s?.enabled ?? true;
    _readOnly = s?.readOnly ?? false;
    _mappingMode = s?.mapallUser?.isNotEmpty == true
        ? 'all'
        : s?.maprootUser?.isNotEmpty == true
        ? 'root'
        : 'none';
    _user = TextEditingController(
      text: _mappingMode == 'all' ? s?.mapallUser : s?.maprootUser,
    );
    _group = TextEditingController(
      text: _mappingMode == 'all' ? s?.mapallGroup : s?.maprootGroup,
    );
    ref.listenManual(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    ref.listenManual(nfsSharesInventoryProvider, (_, next) {
      if (next.isLoading || !identical(next.asData?.value, widget.inventory)) {
        _expire();
      }
    });
  }

  void _expire() {
    if (_expired || !mounted) return;
    setState(() {
      _expired = true;
      _error = null;
      _path = null;
      for (final controller in [_comment, _hosts, _networks, _user, _group]) {
        controller.clear();
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_comment, _hosts, _networks, _user, _group]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _tokens(String text) =>
      text.trim().isEmpty ? [] : text.split(',').map((s) => s.trim()).toList();
  Future<void> _submit() async {
    if (_busy || _expired) return;
    final old = widget.share?.settings;
    // Preserve original null-versus-empty map fields when mapping is unchanged.
    String? mapValue(String mode, bool group) {
      final text = (group ? _group : _user).text;
      final previous = mode == 'root'
          ? (group ? old?.maprootGroup : old?.maprootUser)
          : (group ? old?.mapallGroup : old?.mapallUser);
      if (_mappingMode != mode) return previous?.isEmpty == true ? '' : null;
      return text.isEmpty ? (previous?.isEmpty == true ? '' : null) : text;
    }

    final settings = NfsShareSettings(
      path: _path ?? '',
      comment: _comment.text,
      hosts: _tokens(_hosts.text),
      networks: _tokens(_networks.text),
      enabled: _enabled,
      readOnly: _readOnly,
      maprootUser: mapValue('root', false),
      maprootGroup: mapValue('root', true),
      mapallUser: mapValue('all', false),
      mapallGroup: mapValue('all', true),
    );
    final request = NfsShareRequest(
      inventory: widget.inventory,
      action: widget.share == null
          ? NfsShareAction.create
          : NfsShareAction.update,
      share: widget.share,
      settings: settings,
    );
    if (request.validationError != null) {
      setState(() => _error = request.validationError);
      return;
    }
    setState(() {
      _busy = true;
      _ready = false;
      _error = null;
    });
    try {
      final sent = await _review(
        context,
        ref,
        widget.session,
        request,
        onReady: () {
          if (mounted) setState(() => _ready = true);
        },
      );
      if (sent && mounted) Navigator.of(context).pop();
    } on NfsSharesException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } on Object {
      if (mounted) {
        setState(
          () => _error = 'This export could not be reviewed. Reload inventory; nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(nfsSharesInventoryProvider);
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.inventory, inventory.asData?.value);
    final locked = ref.watch(nfsSharesControllerProvider).locked;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.share == null ? 'Create NFS share' : 'Edit NFS export',
        ),
      ),
      body: !current
          ? const _Workspace(
              children: [
                TdPanel(
                  title: 'Editor is no longer current',
                  child: Text(
                    'Previous server and export details are hidden. Close this editor and reload the current connection. Nothing was sent.',
                  ),
                ),
              ],
            )
          : _Workspace(
              children: [
                Text(widget.session.endpoint!, style: TdTypography.label),
                const SizedBox(height: 16),
                TdPanel(
                  title: 'Export scope',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.share != null)
                        SelectableText(widget.share!.settings.path)
                      else
                        DropdownButtonFormField<String>(
                          key: const Key('nfs-dataset'),
                          isExpanded: true,
                          initialValue: _path,
                          decoration: const InputDecoration(
                            labelText: 'Existing dataset root',
                          ),
                          items: [
                            for (final d in widget.inventory.datasets.where(
                              (d) => d.available,
                            ))
                              DropdownMenuItem(
                                value: d.path,
                                child: Text(d.id),
                              ),
                          ],
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _path = v),
                        ),
                      const SizedBox(height: 12),
                      const Text(
                        'No path creation, ACL or owner changes. Existing export paths cannot be moved.',
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('nfs-comment'),
                        controller: _comment,
                        enabled: !_busy,
                        maxLength: 120,
                        decoration: const InputDecoration(labelText: 'Comment'),
                      ),
                      Material(
                        type: MaterialType.transparency,
                        child: Column(
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Export enabled'),
                              subtitle: const Text(
                                'Changing this reloads exports; it does not start NFS.',
                              ),
                              value: _enabled,
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() => _enabled = v),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Read only'),
                              subtitle: const Text(
                                'Reject client writes through this export.',
                              ),
                              value: _readOnly,
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() => _readOnly = v),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TdPanel(
                  title: 'Authorized clients',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Hosts and networks are alternatives (OR). Leaving both empty authorizes all clients. AUTH_SYS is not encrypted or strong client authentication.',
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('nfs-hosts'),
                        controller: _hosts,
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          labelText: 'IPv4 hosts',
                          hintText: '192.168.1.20, 192.168.1.21',
                          helperText:
                              'Comma-separated, up to 16 unique addresses',
                          helperMaxLines: 3,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('nfs-networks'),
                        controller: _networks,
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          labelText: 'IPv4 CIDR networks',
                          hintText: '192.168.10.0/24',
                          helperText: 'Canonical network addresses; no overlapping ranges',
                          helperMaxLines: 3,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'DNS names, IPv6, wildcard hosts and netgroups are unavailable in this editor.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TdPanel(
                  title: 'Client identity mapping',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<String>(
                        key: const Key('nfs-mapping'),
                        isExpanded: true,
                        initialValue: _mappingMode,
                        decoration: const InputDecoration(
                          labelText: 'Mapping mode',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'none',
                            child: Text('Default root squash'),
                          ),
                          DropdownMenuItem(
                            value: 'root',
                            child: Text('Map client root'),
                          ),
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('Map every client user'),
                          ),
                        ],
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _mappingMode = v!),
                      ),
                      if (_mappingMode != 'none') ...[
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('nfs-map-user'),
                          controller: _user,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'Local user name',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('nfs-map-group'),
                          controller: _group,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'Local group name (optional)',
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      const Text(
                        'Review resolves and binds the local account IDs again before saving. Root (ID 0), directory-service identities and no-root-squash are unavailable. Filesystem ownership is not changed.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, key: const Key('nfs-editor-error')),
                  ),
                if (_busy && !_ready) const LinearProgressIndicator(),
                FilledButton.icon(
                  key: const Key('nfs-review'),
                  onPressed: _busy || locked ? null : _submit,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Review export change'),
                ),
              ],
            ),
    );
  }
}

Future<bool> _review(
  BuildContext context,
  WidgetRef ref,
  AuthenticatedSession session,
  NfsShareRequest request, {
  VoidCallback? onReady,
}) async {
  var expired = false;
  bool current() =>
      !expired &&
      identical(session, ref.read(dashboardActiveSessionProvider)) &&
      identical(
        request.inventory,
        ref.read(nfsSharesInventoryProvider).asData?.value,
      ) &&
      !ref.read(nfsSharesInventoryProvider).isLoading;
  if (!current() || request.validationError != null) return false;
  final api = ref.read(nfsSharesSessionProvider);
  if (api == null) return false;
  final connection = ref.listenManual(dashboardActiveSessionProvider, (
    previous,
    next,
  ) {
    if (!identical(previous, next)) expired = true;
  });
  final data = ref.listenManual(nfsSharesInventoryProvider, (_, next) {
    if (next.isLoading || !identical(next.asData?.value, request.inventory)) {
      expired = true;
    }
  });
  try {
    final review = await api.reviewNfsShare(request);
    if (!context.mounted || !current()) return false;
    if (review.target != request.target || review.action != request.action) {
      throw StateError('Mismatched reviewed operation.');
    }
    onReady?.call();
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => NfsShareReviewDialog(
        session: session,
        request: request,
        review: review,
      ),
    );
    if (!context.mounted || confirmed != true || !current()) return false;
    await ref
        .read(nfsSharesControllerProvider.notifier)
        .execute(
          expectedSession: session,
          review: review,
          confirmation: review.target,
        );
    return true;
  } finally {
    connection.close();
    data.close();
  }
}

class NfsShareReviewDialog extends ConsumerStatefulWidget {
  const NfsShareReviewDialog({
    required this.session,
    required this.request,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final NfsShareRequest request;
  final NfsShareReview review;
  @override
  ConsumerState<NfsShareReviewDialog> createState() =>
      _NfsShareReviewDialogState();
}

class _NfsShareReviewDialogState extends ConsumerState<NfsShareReviewDialog> {
  final _confirmation = TextEditingController();
  bool _ack = false, _expired = false;
  @override
  void initState() {
    super.initState();
    ref.listenManual(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    ref.listenManual(nfsSharesInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(next.asData?.value, widget.request.inventory)) {
        _expire();
      }
    });
  }

  void _expire() {
    if (_expired || !mounted) return;
    setState(() {
      _expired = true;
      _confirmation.clear();
      _ack = false;
    });
  }

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(nfsSharesInventoryProvider);
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.request.inventory, inventory.asData?.value);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          key: const Key('nfs-review-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  current
                      ? 'Review NFS ${widget.review.action.name}'
                      : 'Review is no longer current',
                  style: TdTypography.titleSmall,
                ),
                const SizedBox(height: 16),
                current
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Authenticated server',
                            style: TdTypography.label,
                          ),
                          SelectableText(widget.session.endpoint!),
                          const SizedBox(height: 12),
                          const Text('Exact target', style: TdTypography.label),
                          SelectableText(widget.review.target),
                          Text(widget.review.identity),
                          const SizedBox(height: 16),
                          if (widget.request.share != null) ...[
                            const Text('Before', style: TdTypography.label),
                            Text(_summary(widget.request.share!.settings)),
                            const SizedBox(height: 12),
                          ],
                          if (widget.request.settings != null) ...[
                            const Text('After', style: TdTypography.label),
                            Text(_summary(widget.request.settings!)),
                            const SizedBox(height: 12),
                          ],
                          for (final change in widget.review.changes)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(change),
                            ),
                          const SizedBox(height: 12),
                          for (final warning in widget.review.warnings)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(warning),
                            ),
                          if (widget.review.action == NfsShareAction.delete)
                            const Text(
                              'Delete removes this export configuration, not the dataset or files. Existing client mounts and pending I/O can fail after reload.',
                            ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('nfs-confirmation'),
                            controller: _confirmation,
                            autocorrect: false,
                            enableSuggestions: false,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Type the exact target',
                              helperText: 'Case and spacing must match',
                              helperMaxLines: 2,
                            ),
                          ),
                          Material(
                            type: MaterialType.transparency,
                            child: CheckboxListTile(
                              key: const Key('nfs-impact-ack'),
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: const Text(
                                'I reviewed global export reload and client I/O impact, and other administrators are idle.',
                              ),
                              value: _ack,
                              onChanged: (v) =>
                                  setState(() => _ack = v ?? false),
                            ),
                          ),
                        ],
                      )
                    : const Text(
                        'Previous server and export details are hidden. Close this review and reload. Nothing was sent.',
                      ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      key: const Key('nfs-confirm'),
                      onPressed:
                          current &&
                              _ack &&
                              _confirmation.text == widget.review.target
                          ? () => Navigator.of(context).pop(true)
                          : null,
                      child: const Text('Confirm NFS change'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _clients(NfsShareSettings s) => s.hosts.isEmpty && s.networks.isEmpty
    ? 'Clients: all (both lists empty)'
    : 'Clients (OR): ${[...s.hosts, ...s.networks].join(', ')}';
String _mapping(NfsShareSettings s) => s.mapallUser?.isNotEmpty == true
    ? 'Map all → ${s.mapallUser}${s.mapallGroup?.isNotEmpty == true ? ' / ${s.mapallGroup}' : ''}'
    : s.maprootUser?.isNotEmpty == true
    ? 'Map root → ${s.maprootUser}${s.maprootGroup?.isNotEmpty == true ? ' / ${s.maprootGroup}' : ''}'
    : 'Default root squash';
String _summary(NfsShareSettings s) =>
    '${s.path}\n${s.enabled ? 'Enabled' : 'Disabled'} · ${s.readOnly ? 'Read only' : 'Read / write'}\n${_clients(s)}\n${_mapping(s)}\nComment: ${s.comment.isEmpty ? 'None' : s.comment}';

class _Workspace extends StatelessWidget {
  const _Workspace({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1060),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    ),
  );
}

class NfsShareEnablementChart extends StatelessWidget {
  const NfsShareEnablementChart({required this.shares, super.key});
  final List<NfsShare> shares;
  @override
  Widget build(BuildContext context) {
    final enabled = shares.where((s) => s.settings.enabled).length;
    final td = context.tdTheme;
    return TdPanel(
      title: 'Export enablement',
      description: 'Configuration counts for all returned exports, not connected clients or successful access.',
      child: LayoutBuilder(
        builder: (context, c) {
          final beside = c.maxWidth - 132;
          final minimum = 128 * MediaQuery.textScalerOf(context).scale(14) / 14;
          return Wrap(
            spacing: 20,
            runSpacing: 20,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                key: const Key('nfs-chart-semantics'),
                label:
                    'NFS configuration: $enabled enabled, ${shares.length - enabled} disabled, ${shares.length} total. Not service health or client access.',
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: 112,
                    height: 112,
                    child: CustomPaint(
                      painter: _NfsPainter(
                        enabled,
                        shares.length,
                        td.statusSuccess,
                        td.textMuted,
                        td.borderSubtle,
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: FittedBox(
                            child: Text(
                              '${shares.length}',
                              style: TdTypography.metricMedium,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: math.min(240, beside >= minimum ? beside : c.maxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _NfsLegend(
                      label: 'Enabled · $enabled',
                      color: td.statusSuccess,
                      dotKey: const Key('nfs-enabled-dot'),
                    ),
                    const SizedBox(height: 8),
                    _NfsLegend(
                      label: 'Disabled · ${shares.length - enabled}',
                      color: td.textMuted,
                      dotKey: const Key('nfs-disabled-dot'),
                    ),
                    if (shares.isEmpty)
                      const Text(
                        'No exports returned; no percentage inferred.',
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NfsLegend extends StatelessWidget {
  const _NfsLegend({
    required this.label,
    required this.color,
    required this.dotKey,
  });
  final String label;
  final Color color;
  final Key dotKey;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 7),
        child: DecoratedBox(
          key: dotKey,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(label)),
    ],
  );
}

class _NfsPainter extends CustomPainter {
  const _NfsPainter(
    this.enabled,
    this.total,
    this.active,
    this.disabled,
    this.track,
  );
  final int enabled, total;
  final Color active, disabled, track;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(5, 5, size.width - 10, size.height - 10);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..color = total == 0 ? track : disabled;
    canvas.drawOval(rect, paint);
    if (enabled > 0 && total > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * enabled / total,
        false,
        paint..color = active,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NfsPainter old) =>
      enabled != old.enabled ||
      total != old.total ||
      active != old.active ||
      disabled != old.disabled ||
      track != old.track;
}
