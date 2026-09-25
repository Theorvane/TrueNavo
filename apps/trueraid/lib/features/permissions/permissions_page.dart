import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'permissions_acl_editor.dart';
import 'permissions_controller.dart';

class PermissionsPage extends ConsumerStatefulWidget {
  const PermissionsPage({super.key});
  @override
  ConsumerState<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends ConsumerState<PermissionsPage> {
  String _search = '';
  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final api = ref.watch(permissionsSessionProvider);
    final operation = ref.watch(permissionsControllerProvider);
    final available =
        session?.endpoint != null &&
        api?.permissionsCapabilities.supported == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dataset permissions'),
        actions: [
          IconButton(
            key: const Key('permissions-refresh'),
            tooltip: 'Refresh datasets',
            onPressed: available && !operation.locked
                ? () => ref.invalidate(permissionsDatasetsProvider)
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _Workspace(
        children: [
          const Text('ACCESS CONTROL', style: TdTypography.micro),
          const SizedBox(height: TdSpacing.related),
          const Text(
            'Who can access your data',
            style: TdTypography.titleLarge,
          ),
          const SizedBox(height: TdSpacing.related),
          Text(session?.endpoint ?? 'No authenticated server'),
          const SizedBox(height: TdSpacing.component),
          const PermissionsOperationBanner(),
          if (!available)
            TdPanel(
              title: 'Permissions unavailable',
              child: Text(
                api?.permissionsCapabilities.blockedReason ??
                    'Connect to a supported TrueNAS server.',
              ),
            )
          else if (operation.locked && !operation.connectionCurrent)
            const TdPanel(
              title: 'Previous operation needs attention',
              child: Text(
                'Reconnect to the original server and resolve the retained outcome before starting another permissions change.',
              ),
            )
          else
            ref
                .watch(permissionsDatasetsProvider)
                .when(
                  skipLoadingOnReload: false,
                  skipLoadingOnRefresh: false,
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => _ReadError(
                    error: error,
                    retry: () => ref.invalidate(permissionsDatasetsProvider),
                  ),
                  data: (datasets) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        key: const Key('permissions-search'),
                        decoration: const InputDecoration(
                          labelText: 'Find a dataset',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                        onChanged: (value) =>
                            setState(() => _search = value.toLowerCase()),
                      ),
                      const SizedBox(height: TdSpacing.component),
                      Text(
                        '${datasets.length} dataset roots · Non-recursive changes only',
                      ),
                      const SizedBox(height: TdSpacing.related),
                      if (datasets.isEmpty)
                        const Text(
                          'No accessible dataset roots were returned.',
                        ),
                      for (final dataset in datasets.where(
                        (item) => '${item.id} ${item.mountpoint}'
                            .toLowerCase()
                            .contains(_search),
                      ))
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(TdSpacing.component),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(Icons.folder_shared_outlined),
                                    const SizedBox(width: TdSpacing.related),
                                    Expanded(
                                      child: Text(
                                        dataset.id,
                                        style: TdTypography.titleSmall,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: TdSpacing.related),
                                Text(dataset.mountpoint),
                                if (dataset.blockedReason != null) ...[
                                  const SizedBox(height: TdSpacing.related),
                                  Text(dataset.blockedReason!),
                                ],
                                const SizedBox(height: TdSpacing.related),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: OutlinedButton.icon(
                                    key: ValueKey(
                                      'permissions-open-${dataset.id}',
                                    ),
                                    onPressed: operation.locked
                                        ? null
                                        : () => Navigator.of(context).push(
                                            MaterialPageRoute<void>(
                                              builder: (_) =>
                                                  PermissionsEditorPage(
                                                    dataset: dataset,
                                                    expectedSession: session!,
                                                  ),
                                            ),
                                          ),
                                    icon: const Icon(
                                      Icons.rule_folder_outlined,
                                    ),
                                    label: const Text('Inspect permissions'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
          const SizedBox(height: TdSpacing.component),
          const Text(
            'This workspace edits supported POSIX and NFSv4 ACLs on existing dataset roots. Arbitrary paths, recursive rewriting, ACL stripping, ownership changes, and directory-service identity creation are not available here.',
          ),
        ],
      ),
    );
  }
}

class PermissionsEditorPage extends ConsumerWidget {
  const PermissionsEditorPage({
    required this.dataset,
    required this.expectedSession,
    super.key,
  });
  final PermissionDataset dataset;
  final AuthenticatedSession expectedSession;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = identical(
      expectedSession,
      ref.watch(dashboardActiveSessionProvider),
    );
    final operation = ref.watch(permissionsControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Permission editor'),
        actions: [
          IconButton(
            key: const Key('permissions-reload-review'),
            tooltip: 'Reload current permissions',
            onPressed: current && !operation.locked
                ? () => ref.invalidate(permissionsReviewProvider(dataset))
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: !current
          ? const _Workspace(
              children: [
                PermissionsOperationBanner(),
                TdPanel(
                  title: 'Connection changed',
                  child: Text(
                    'The previous dataset and editor are hidden. Return to the dataset list to inspect the current connection. No draft was sent.',
                  ),
                ),
              ],
            )
          : ref
                .watch(permissionsReviewProvider(dataset))
                .when(
                  skipLoadingOnReload: false,
                  skipLoadingOnRefresh: false,
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => _Workspace(
                    children: [
                      const PermissionsOperationBanner(),
                      _ReadError(
                        error: error,
                        retry: () =>
                            ref.invalidate(permissionsReviewProvider(dataset)),
                      ),
                    ],
                  ),
                  data: (review) => _PermissionDraft(
                    key: ObjectKey(review),
                    review: review,
                    session: expectedSession,
                  ),
                ),
    );
  }
}

class _PermissionDraft extends ConsumerStatefulWidget {
  const _PermissionDraft({
    required this.review,
    required this.session,
    super.key,
  });
  final PermissionReview review;
  final AuthenticatedSession session;
  @override
  ConsumerState<_PermissionDraft> createState() => _PermissionDraftState();
}

class _PermissionDraftState extends ConsumerState<_PermissionDraft> {
  late List<PermissionAce> _entries = [...widget.review.acl];
  late final _mode = TextEditingController(text: widget.review.mode);
  late bool _editMode = !widget.review.canEditAcl;
  bool _reviewing = false;
  String? _error;
  @override
  void dispose() {
    _mode.dispose();
    super.dispose();
  }

  Future<void> _review() async {
    if (_reviewing ||
        !identical(widget.session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final request = PermissionApplyRequest(
      review: widget.review,
      acl: _editMode ? null : _entries,
      mode: _editMode ? _mode.text : null,
    );
    final error = request.validationError;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _error = null;
      _reviewing = true;
    });
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          PermissionsReviewDialog(request: request, session: widget.session),
    );
    if (!mounted) return;
    setState(() => _reviewing = false);
    if (confirmed == true &&
        identical(widget.session, ref.read(dashboardActiveSessionProvider))) {
      await ref
          .read(permissionsControllerProvider.notifier)
          .apply(
            expectedSession: widget.session,
            request: request,
            confirmation: request.review.dataset.mountpoint,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final review = widget.review;
    final operation = ref.watch(permissionsControllerProvider);
    final api = ref.watch(permissionsSessionProvider);
    final method = _editMode ? 'filesystem.setperm' : 'filesystem.setacl';
    final canWrite =
        api?.permissionsCapabilities.canCall(method) == true &&
        api?.permissionsCapabilities.canCall('core.get_jobs') == true;
    final enabled =
        review.editable && !operation.locked && !_reviewing && canWrite;
    return _Workspace(
      children: [
        Text(review.dataset.id, style: TdTypography.titleLarge),
        const SizedBox(height: TdSpacing.related),
        Text(widget.session.endpoint ?? 'Authenticated endpoint unavailable'),
        const SizedBox(height: TdSpacing.related),
        SelectableText(review.dataset.mountpoint),
        const SizedBox(height: TdSpacing.component),
        const PermissionsOperationBanner(),
        TdPanel(
          title: 'Current ownership & ACL',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${_aclLabel(review.aclType)} · Mode ${review.mode}'),
              const SizedBox(height: TdSpacing.related),
              Text(
                'Owner UID ${review.uid} · Group GID ${review.gid} — preserved',
              ),
              if (review.aclFlags.isNotEmpty)
                Text(
                  'Dataset ACL flags — preserved: ${_flags(review.aclFlags)}',
                ),
              if (review.blockedReason != null) Text(review.blockedReason!),
              if (review.dataset.blockedReason != null)
                Text(review.dataset.blockedReason!),
            ],
          ),
        ),
        const SizedBox(height: TdSpacing.component),
        if (!canWrite)
          const TdPanel(
            title: 'Read-only permissions',
            child: Text(
              'The required setter and job-inspection permissions are unavailable to this connection.',
            ),
          ),
        if (review.canEditAcl && review.canEditMode) ...[
          Wrap(
            spacing: TdSpacing.related,
            runSpacing: TdSpacing.related,
            children: [
              ChoiceChip(
                key: const Key('permissions-edit-acl'),
                label: const Text('ACL entries'),
                selected: !_editMode,
                onSelected: !operation.locked && !_reviewing
                    ? (_) => setState(() {
                        _editMode = false;
                        _error = null;
                      })
                    : null,
              ),
              ChoiceChip(
                key: const Key('permissions-edit-mode'),
                label: const Text('Unix mode'),
                selected: _editMode,
                onSelected: !operation.locked && !_reviewing
                    ? (_) => setState(() {
                        _editMode = true;
                        _error = null;
                      })
                    : null,
              ),
            ],
          ),
          const SizedBox(height: TdSpacing.component),
        ],
        if (_editMode)
          TdPanel(
            title: 'Unix permissions',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Three octal digits: owner, group, others. Read = 4, write = 2, execute = 1. Special mode bits and extended-ACL stripping are not supported.',
                ),
                if (review.aclType == PermissionAclType.posix1e)
                  const Text(
                    'Applying mode to a trivial POSIX ACL rebuilds its ordinary access entries from these mode bits. Extended ACLs cannot be replaced this way.',
                  ),
                const SizedBox(height: TdSpacing.component),
                TextField(
                  key: const Key('permissions-mode'),
                  controller: _mode,
                  enabled: enabled && review.canEditMode,
                  keyboardType: TextInputType.number,
                  maxLength: 3,
                  decoration: const InputDecoration(
                    labelText: 'Octal mode',
                    hintText: '750',
                  ),
                ),
                if (!review.canEditMode)
                  const Text(
                    'Mode editing requires a trivial POSIX or disabled ACL. It cannot replace an extended ACL.',
                  ),
              ],
            ),
          )
        else
          TdPanel(
            child: PermissionsAclEditor(
              entries: _entries,
              aclType: review.aclType,
              session: widget.session,
              enabled: enabled,
              onChanged: (entries) => setState(() {
                _entries = entries;
                _error = null;
              }),
            ),
          ),
        const SizedBox(height: TdSpacing.component),
        const TdPanel(
          title: 'Scope limits',
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                CheckboxListTile(
                  value: false,
                  onChanged: null,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text('Apply recursively'),
                  subtitle: Text(
                    'Unavailable: a recursive child-impact review and recovery workflow has not been implemented.',
                  ),
                ),
                CheckboxListTile(
                  value: false,
                  onChanged: null,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text('Strip ACL'),
                  subtitle: Text(
                    'Unavailable for extended ACLs: no destructive ACL stripping or ACL-type conversion is offered.',
                  ),
                ),
                Text(
                  'Only this dataset root is rewritten, but root traversal permissions can change access to existing descendants. Inheritance and POSIX default entries can affect newly created children. Owner, group and dataset ACL flags remain unchanged.',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: TdSpacing.component),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: TdSpacing.related),
            child: Text(
              _error!,
              key: const Key('permissions-validation-error'),
              style: TextStyle(color: context.tdTheme.statusCritical),
            ),
          ),
        FilledButton.icon(
          key: const Key('permissions-review'),
          onPressed: enabled ? _review : null,
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('Review permission change'),
        ),
      ],
    );
  }
}

class PermissionsReviewDialog extends ConsumerStatefulWidget {
  const PermissionsReviewDialog({
    required this.request,
    required this.session,
    super.key,
  });
  final PermissionApplyRequest request;
  final AuthenticatedSession session;
  @override
  ConsumerState<PermissionsReviewDialog> createState() =>
      _PermissionsReviewDialogState();
}

class _PermissionsReviewDialogState
    extends ConsumerState<PermissionsReviewDialog> {
  final _confirmation = TextEditingController();
  bool _acknowledged = false;
  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = identical(
      ref.watch(dashboardActiveSessionProvider),
      widget.session,
    );
    final request = widget.request;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.all(TdSpacing.component),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current ? 'Review permission change' : 'Connection changed',
                style: TdTypography.titleSmall,
              ),
              const SizedBox(height: TdSpacing.component),
              Flexible(
                child: SingleChildScrollView(
                  child: !current
                      ? const Text(
                          'The previous target and ACL are hidden. Close this review and reload the current connection. Nothing was sent.',
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Authenticated server',
                              style: TdTypography.label,
                            ),
                            SelectableText(
                              widget.session.endpoint ?? 'Unavailable',
                            ),
                            const SizedBox(height: TdSpacing.related),
                            const Text(
                              'Exact dataset root',
                              style: TdTypography.label,
                            ),
                            SelectableText(request.review.dataset.mountpoint),
                            Text('Dataset: ${request.review.dataset.id}'),
                            const SizedBox(height: TdSpacing.component),
                            Text(
                              'Owner UID ${request.review.uid} and group GID ${request.review.gid} stay unchanged.',
                            ),
                            Text(
                              'Dataset ACL flags stay unchanged: ${_flags(request.review.aclFlags)}',
                            ),
                            const SizedBox(height: TdSpacing.component),
                            _AclComparison(
                              title: 'Before',
                              mode: request.review.mode,
                              entries: request.acl == null
                                  ? null
                                  : request.review.acl,
                            ),
                            const SizedBox(height: TdSpacing.component),
                            _AclComparison(
                              title: 'After',
                              mode: request.expectedMode,
                              entries: request.acl,
                            ),
                            const SizedBox(height: TdSpacing.component),
                            const Text(
                              'Non-recursive. No extended-ACL stripping, ownership changes, traversal into other mounts, or automatic NFSv4 reordering. Root traversal permissions can change access to existing descendants; inheritance/default entries may affect future children. You can revoke your own access.',
                            ),
                            if (request.mode != null &&
                                request.review.aclType ==
                                    PermissionAclType.posix1e)
                              const Text(
                                'This mode change rebuilds the trivial POSIX access ACL as ordinary owner/group/other permissions. It does not preserve a separate extended ACL.',
                              ),
                            const SizedBox(height: TdSpacing.component),
                            TextField(
                              key: const Key('permissions-confirm-path'),
                              controller: _confirmation,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: const InputDecoration(
                                labelText: 'Type the exact dataset mountpoint',
                                helperText: 'Case-sensitive, including the leading /mnt/.',
                                helperMaxLines: 3,
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                            Material(
                              type: MaterialType.transparency,
                              child: CheckboxListTile(
                                key: const Key('permissions-confirm-risk'),
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: _acknowledged,
                                onChanged: (value) => setState(
                                  () => _acknowledged = value ?? false,
                                ),
                                title: const Text(
                                  'I reviewed every entry and have another way to recover access.',
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: TdSpacing.component),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: TdSpacing.related,
                runSpacing: TdSpacing.related,
                children: [
                  TextButton(
                    key: const Key('permissions-cancel-confirm'),
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(current ? 'Cancel' : 'Close'),
                  ),
                  if (current)
                    FilledButton(
                      key: const Key('permissions-apply-confirm'),
                      onPressed:
                          _acknowledged &&
                              widget.session.endpoint != null &&
                              _confirmation.text ==
                                  request.review.dataset.mountpoint &&
                              !ref.watch(permissionsControllerProvider).locked
                          ? () => Navigator.pop(context, true)
                          : null,
                      child: const Text('Apply once'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AclComparison extends StatelessWidget {
  const _AclComparison({
    required this.title,
    required this.mode,
    required this.entries,
  });
  final String title;
  final String? mode;
  final List<PermissionAce>? entries;
  @override
  Widget build(BuildContext context) => TdPanel(
    title: title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (mode != null) Text('Mode $mode'),
        if (entries != null) ...[
          const Text('All enabled bits are listed; other bits remain false.'),
          for (var index = 0; index < entries!.length; index++)
            Padding(
              padding: const EdgeInsets.only(top: TdSpacing.related),
              child: Text(
                '${index + 1}. ${permissionPrincipal(entries![index])}\n${permissionAceSummary(entries![index])}',
              ),
            ),
        ],
      ],
    ),
  );
}

class PermissionsOperationBanner extends ConsumerStatefulWidget {
  const PermissionsOperationBanner({super.key});
  @override
  ConsumerState<PermissionsOperationBanner> createState() =>
      _PermissionsOperationBannerState();
}

class _PermissionsOperationBannerState
    extends ConsumerState<PermissionsOperationBanner> {
  bool _acknowledged = false;
  @override
  Widget build(BuildContext context) {
    final operation = ref.watch(permissionsControllerProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    if (operation.phase == PermissionsPhase.idle && operation.message == null) {
      return const SizedBox.shrink();
    }
    final reconnect =
        operation.unknown &&
        !operation.connectionCurrent &&
        session?.endpoint != null &&
        session!.endpoint == operation.server;
    return Padding(
      padding: const EdgeInsets.only(bottom: TdSpacing.component),
      child: TdPanel(
        title: switch (operation.phase) {
          PermissionsPhase.submitting => 'Submitting once',
          PermissionsPhase.checking => 'Checking the existing job',
          PermissionsPhase.pending => 'Permission job pending',
          PermissionsPhase.verified => 'Permissions verified',
          PermissionsPhase.failed => 'Change not completed',
          PermissionsPhase.unknown => 'Outcome needs verification',
          PermissionsPhase.idle => 'Prior outcome remains unverified',
        },
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (operation.server != null)
                Text('Original server: ${operation.server}'),
              if (operation.path != null)
                Text('Original target: ${operation.path}'),
              if (operation.jobId != null) Text('Job ${operation.jobId}'),
              if (operation.message != null) Text(operation.message!),
              if (operation.busy)
                const Padding(
                  padding: EdgeInsets.only(top: TdSpacing.related),
                  child: LinearProgressIndicator(),
                ),
              if (operation.canCheck)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('permissions-check-job'),
                    onPressed: () => ref
                        .read(permissionsControllerProvider.notifier)
                        .checkProgress(),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Check job'),
                  ),
                ),
              if (reconnect) ...[
                CheckboxListTile(
                  key: const Key('permissions-reconnect-ack'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _acknowledged,
                  onChanged: (value) =>
                      setState(() => _acknowledged = value ?? false),
                  title: const Text(
                    'I independently checked the original server and job, and understand that this app has not verified the prior outcome.',
                  ),
                ),
                OutlinedButton(
                  key: const Key('permissions-reconnect-release'),
                  onPressed: _acknowledged
                      ? () {
                          ref
                              .read(permissionsControllerProvider.notifier)
                              .acknowledgeAfterReconnect();
                          setState(() => _acknowledged = false);
                        }
                      : null,
                  child: const Text('Reload after reconnect'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadError extends StatelessWidget {
  const _ReadError({required this.error, required this.retry});
  final Object error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => TdPanel(
    title: 'Could not load permissions',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          error is PermissionsException
              ? (error as PermissionsException).userMessage
              : 'Server details were withheld. Try the read-only request again.',
        ),
        const SizedBox(height: TdSpacing.related),
        OutlinedButton(onPressed: retry, child: const Text('Try again')),
      ],
    ),
  );
}

class _Workspace extends StatelessWidget {
  const _Workspace({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: ListView(
          padding: const EdgeInsets.all(TdSpacing.component),
          children: children,
        ),
      ),
    ),
  );
}

String _aclLabel(PermissionAclType type) => switch (type) {
  PermissionAclType.nfs4 => 'NFSv4 ACL',
  PermissionAclType.posix1e => 'POSIX ACL',
  PermissionAclType.disabled => 'ACL disabled',
};
String _flags(Map<String, bool> flags) => flags.isEmpty
    ? 'None'
    : flags.entries.map((entry) => '${entry.key}=${entry.value}').join(', ');
