import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'cloud_sync_controller.dart';

class CloudSyncEditor extends ConsumerStatefulWidget {
  const CloudSyncEditor({
    required this.inventory,
    required this.session,
    this.task,
    super.key,
  });
  final CloudSyncInventory inventory;
  final AuthenticatedSession session;
  final CloudSyncTask? task;
  @override
  ConsumerState<CloudSyncEditor> createState() => _CloudSyncEditorState();
}

class _CloudSyncEditorState extends ConsumerState<CloudSyncEditor> {
  bool _expired = false;
  final _fields = <String, TextEditingController>{};
  int? _credential;
  String? _path;
  String _direction = 'PUSH', _mode = 'COPY';
  bool _enabled = false, _sse = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final s = widget.task?.settings;
    _credential = s?.credentialId;
    _path = s?.path;
    _direction = s?.direction ?? 'PUSH';
    _mode = s?.transferMode ?? 'COPY';
    _enabled = s?.enabled ?? false;
    _sse = s?.serverSideEncryption ?? false;
    for (final entry in {
      'description': s?.description ?? '',
      'folder': s?.folder ?? '',
      'bucket': s?.bucket ?? '',
      'region': s?.region ?? '',
      'storage class': s?.storageClass ?? '',
      'chunk size': '${s?.dropboxChunkSize ?? 48}',
      'minute': s?.minute ?? '0',
      'hour': s?.hour ?? '2',
      'day': s?.dom ?? '*',
      'month': s?.month ?? '*',
      'weekday': s?.dow ?? '*',
      'exclusions': s?.exclude.join('\n') ?? '',
    }.entries) {
      _fields[entry.key] = TextEditingController(text: entry.value);
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  CloudSyncSettings _settings() => CloudSyncSettings(
    path: _path ?? '',
    credentialId: _credential ?? 0,
    description: _fields['description']!.text,
    direction: _direction,
    transferMode: _mode,
    enabled: _enabled,
    serverSideEncryption: _sse,
    folder: _fields['folder']!.text,
    bucket: _fields['bucket']!.text,
    region: _fields['region']!.text,
    storageClass: _fields['storage class']!.text,
    dropboxChunkSize: int.tryParse(_fields['chunk size']!.text) ?? 0,
    minute: _fields['minute']!.text,
    hour: _fields['hour']!.text,
    dom: _fields['day']!.text,
    month: _fields['month']!.text,
    dow: _fields['weekday']!.text,
    exclude: _fields['exclusions']!.text.isEmpty
        ? []
        : _fields['exclusions']!.text.split('\n'),
  );
  Widget _field(String name, {bool enabled = true, int lines = 1}) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      key: Key('cloud-sync-field-$name'),
      controller: _fields[name],
      enabled: enabled,
      maxLines: lines,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: name[0].toUpperCase() + name.substring(1),
        border: const OutlineInputBorder(),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final inventory = ref.watch(cloudSyncInventoryProvider);
    void expire() {
      if (_expired) return;
      setState(() {
        _expired = true;
        for (final field in _fields.values) {
          field.clear();
        }
      });
    }

    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) expire();
    });
    ref.listen(cloudSyncInventoryProvider, (_, b) {
      if (b.isLoading || !identical(widget.inventory, b.asData?.value)) {
        expire();
      }
    });
    if (_expired ||
        !identical(session, widget.session) ||
        inventory.isLoading ||
        !identical(widget.inventory, inventory.asData?.value)) {
      return AlertDialog(
        title: const Text('Editor expired'),
        content: const Text(
          'Previous server and destination details are hidden. Reload before editing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }
    final credentials = widget.inventory.credentials
            .where((c) => c.supported)
            .toList(),
        datasets = widget.inventory.datasets
            .where((d) => d.blockedReason == null)
            .toList();
    final provider = widget.inventory.credentials
        .where((c) => c.id == _credential)
        .singleOrNull
        ?.provider;
    final editing = widget.task != null;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: SingleChildScrollView(
          key: const Key('cloud-sync-editor-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  editing ? 'Edit cloud sync task' : 'Create cloud sync task',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Text(
                  'Existing S3 or Dropbox credentials only. Secrets are not read, entered or stored here. Local and remote endpoints cannot be changed on an existing task.',
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  key: const Key('cloud-sync-credential'),
                  initialValue: _credential,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Existing credential',
                  ),
                  items: [
                    for (final c in credentials)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text(
                          '${c.name} · ${c.provider}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: editing
                      ? null
                      : (v) => setState(() {
                          _credential = v;
                          _fields['bucket']!.clear();
                          _fields['region']!.clear();
                          _fields['storage class']!.clear();
                          _sse = false;
                        }),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: const Key('cloud-sync-dataset'),
                  initialValue: _path,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Exact leaf dataset',
                  ),
                  items: [
                    for (final d in datasets)
                      DropdownMenuItem(
                        value: d.path,
                        child: Text(d.id, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: editing ? null : (v) => setState(() => _path = v),
                ),
                _field('description'),
                _field('folder', enabled: !editing),
                if (provider == 'S3') ...[
                  _field('bucket', enabled: !editing),
                  _field('region'),
                  _field('storage class'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _sse,
                    onChanged: (v) => setState(() => _sse = v),
                    title: const Text('S3 server-side AES256'),
                  ),
                ],
                if (provider == 'DROPBOX') _field('chunk size'),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _direction,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Direction'),
                  items: const [
                    DropdownMenuItem(
                      value: 'PUSH',
                      child: Text('PUSH · local to cloud'),
                    ),
                    DropdownMenuItem(
                      value: 'PULL',
                      child: Text('PULL · cloud to local'),
                    ),
                  ],
                  onChanged: editing
                      ? null
                      : (v) => setState(() => _direction = v!),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _mode,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Transfer mode'),
                  items: const [
                    DropdownMenuItem(
                      value: 'COPY',
                      child: Text('COPY · may overwrite'),
                    ),
                    DropdownMenuItem(
                      value: 'SYNC',
                      child: Text('SYNC · deletes at destination'),
                    ),
                    DropdownMenuItem(
                      value: 'MOVE',
                      child: Text('MOVE · deletes at source'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _mode = v!),
                ),
                const SizedBox(height: 12),
                Text(
                  _mode == 'SYNC'
                      ? 'SYNC deletes destination files missing from the source.'
                      : _mode == 'MOVE'
                      ? 'MOVE deletes source files after transfer.'
                      : 'COPY may overwrite files. This is not append-only backup.',
                ),
                if (_direction == 'PULL')
                  const Text(
                    'PULL writes your NAS data. Verify a separate backup and quiesce clients.',
                  ),
                SwitchListTile(
                  key: const Key('cloud-sync-enabled'),
                  contentPadding: EdgeInsets.zero,
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                  title: const Text('Enable scheduled runs'),
                  subtitle: Text(
                    'Server timezone: ${widget.inventory.timezone}. New tasks start disabled.',
                  ),
                ),
                const Text(
                  'Cron: bounded numbers, lists, ranges and steps. Sunday is 0 or 7.',
                ),
                for (final name in [
                  'minute',
                  'hour',
                  'day',
                  'month',
                  'weekday',
                ])
                  _field(name),
                _field('exclusions', lines: 3),
                const Text(
                  'One rclone exclusion pattern per line. No scripts, custom flags, encryption secrets or symlink following.',
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      key: const Key('cloud-sync-editor-error'),
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      key: const Key('cloud-sync-editor-review'),
                      onPressed: () {
                        final desired = _settings();
                        final request = CloudSyncRequest(
                          inventory: widget.inventory,
                          action: editing
                              ? CloudSyncAction.update
                              : CloudSyncAction.create,
                          task: widget.task,
                          settings: desired,
                        );
                        final error = request.validationError;
                        if (error != null) {
                          setState(() => _error = error);
                          return;
                        }
                        Navigator.of(context).pop(desired);
                      },
                      child: const Text('Review changes'),
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
