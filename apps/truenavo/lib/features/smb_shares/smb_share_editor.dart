import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'smb_share_review.dart';
import 'smb_shares_controller.dart';
import 'smb_shares_page.dart';

class SmbShareEditorPage extends ConsumerStatefulWidget {
  const SmbShareEditorPage({
    required this.session,
    required this.inventory,
    this.share,
    super.key,
  });
  final AuthenticatedSession session;
  final SmbShareInventory inventory;
  final SmbShareEntry? share;
  @override
  ConsumerState<SmbShareEditorPage> createState() => _SmbShareEditorPageState();
}

class _SmbShareEditorPageState extends ConsumerState<SmbShareEditorPage> {
  late final _name = TextEditingController(text: widget.share?.name ?? '');
  late final _comment = TextEditingController(
    text: widget.share?.comment ?? '',
  );
  late bool _readonly = widget.share?.readonly ?? false,
      _enabled = widget.share?.enabled ?? true;
  late SmbShareDataset? _dataset = smbCreationDatasets(widget.inventory)
      .firstOrNull;
  bool _expired = false, _reviewing = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _comment.dispose();
    super.dispose();
  }

  void _expire() {
    if (!_expired) {
      setState(() {
        _expired = true;
        _name.clear();
        _comment.clear();
        _dataset = null;
        _error = null;
      });
    }
  }

  Future<void> _review() async {
    if (_expired ||
        _reviewing ||
        !identical(widget.session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final request = SmbShareRequest(
      inventory: widget.inventory,
      action: widget.share == null
          ? SmbShareAction.create
          : SmbShareAction.update,
      share: widget.share,
      dataset: widget.share == null ? _dataset : null,
      settings: SmbShareSettings(
        name: widget.share?.name ?? _name.text,
        comment: _comment.text,
        readonly: _readonly,
        enabled: _enabled,
      ),
    );
    if (request.validationError case final error?) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _reviewing = true;
      _error = null;
    });
    final previousResult = ref.read(smbSharesControllerProvider).result;
    try {
      await reviewSmbShareChange(
        context: context,
        ref: ref,
        session: widget.session,
        request: request,
      );
      if (mounted &&
          ref.read(smbSharesControllerProvider).result != null &&
          !identical(
            previousResult,
            ref.read(smbSharesControllerProvider).result,
          ) &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } on Object {
      if (mounted &&
          !_expired &&
          identical(widget.session, ref.read(dashboardActiveSessionProvider))) {
        setState(
          () => _error = 'This change could not be reviewed safely. Nothing was sent. Reload the current inventory.',
        );
      }
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final inventory = ref.watch(smbSharesInventoryProvider);
    final caps = ref.watch(smbSharesSessionProvider)?.smbSharesCapabilities;
    final state = ref.watch(smbSharesControllerProvider);
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    ref.listen(smbSharesInventoryProvider, (_, next) {
      if (next.isLoading || !identical(next.asData?.value, widget.inventory)) {
        _expire();
      }
    });
    final current =
        !_expired &&
        identical(widget.session, session) &&
        !inventory.isLoading &&
        identical(inventory.asData?.value, widget.inventory);
    final creating = widget.share == null;
    final allowed =
        current &&
        !state.locked &&
        !_reviewing &&
        caps?.allows(
              creating ? SmbShareAction.create : SmbShareAction.update,
            ) ==
            true &&
        (creating ? _dataset?.editable == true : widget.share!.editable);
    return Scaffold(
      appBar: AppBar(
        title: Text(creating ? 'Create SMB share' : 'Inspect & edit SMB share'),
      ),
      body: SmbSharesWorkspace(
        children: [
          const SmbSharesOperationBanner(),
          if (!current)
            const TdPanel(
              title: 'Draft is no longer current',
              child: Text(
                'Previous connection and share details are hidden. Close this draft and reload. Nothing is replayed.',
              ),
            )
          else ...[
            Text(widget.session.endpoint ?? 'Unavailable'),
            const SizedBox(height: TdSpacing.component),
            if (creating) ...[
              const Text(
                'Existing dataset root',
                style: TdTypography.titleSmall,
              ),
              const Text(
                'Only an existing verified, unencrypted unmanaged filesystem is eligible. No directory or dataset is created.',
              ),
              const SizedBox(height: TdSpacing.related),
              DropdownButtonFormField<SmbShareDataset>(
                key: const Key('smb-dataset'),
                initialValue: _dataset,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Dataset'),
                items: [
                  for (final dataset in smbCreationDatasets(widget.inventory))
                    DropdownMenuItem(
                      value: dataset,
                      child: Text(dataset.id, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: state.locked || _reviewing
                    ? null
                    : (value) => setState(() => _dataset = value),
              ),
              if (_dataset != null) Text(_dataset!.mountpoint),
              if (_dataset == null)
                const Text('No eligible dataset roots were returned.'),
              const SizedBox(height: TdSpacing.component),
              TextField(
                key: const Key('smb-name'),
                controller: _name,
                enabled: !state.locked && !_reviewing,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Share name',
                  helperText: '1–80 characters; unique ignoring case.',
                  helperMaxLines: 3,
                ),
              ),
            ] else ...[
              Text(
                widget.share!.name,
                key: const Key('smb-immutable-name'),
                style: TdTypography.titleSmall,
              ),
              SelectableText(widget.share!.path),
              const Text(
                'Name and path are immutable here. Renaming needs a separate protocol-ACL migration and client-impact workflow.',
              ),
              if (widget.share!.blockedReason != null)
                Text(widget.share!.blockedReason!),
            ],
            const SizedBox(height: TdSpacing.component),
            TextField(
              key: const Key('smb-comment'),
              controller: _comment,
              enabled: allowed,
              decoration: const InputDecoration(
                labelText: 'Comment',
                helperText: 'Optional, single line, at most 512 characters.',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: TdSpacing.related),
            SwitchListTile(
              key: const Key('smb-readonly'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Read-only share'),
              subtitle: const Text(
                'Filesystem permissions still apply. Existing client writes may be rejected.',
              ),
              value: _readonly,
              onChanged: allowed ? (v) => setState(() => _readonly = v) : null,
            ),
            SwitchListTile(
              key: const Key('smb-enabled'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Enabled'),
              subtitle: const Text(
                'Enables this configuration, not the SMB service. It is not proof of access.',
              ),
              value: _enabled,
              onChanged: allowed ? (v) => setState(() => _enabled = v) : null,
            ),
            const SizedBox(height: TdSpacing.related),
            const Text(
              'Default-purpose settings only. No guest/home, Time Machine, host rules, audit, protocol ACL, ownership or filesystem-ACL edits.',
            ),
            if (caps?.allows(
                  creating ? SmbShareAction.create : SmbShareAction.update,
                ) !=
                true)
              const Text(
                'This mutation is unavailable to the current connection.',
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: TdSpacing.related),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.tdTheme.statusCritical),
                ),
              ),
            const SizedBox(height: TdSpacing.component),
            Wrap(
              spacing: TdSpacing.related,
              runSpacing: TdSpacing.related,
              children: [
                OutlinedButton(
                  key: const Key('smb-editor-cancel'),
                  onPressed: _reviewing
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('smb-review'),
                  onPressed: allowed ? _review : null,
                  child: Text(
                    _reviewing ? 'Preparing review…' : 'Review changes',
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
