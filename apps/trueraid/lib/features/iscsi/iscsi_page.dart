import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_access_audit.dart';
import 'iscsi_extent_chart.dart';
import 'iscsi_extent_comment_editor.dart';
import 'iscsi_overview.dart';
import 'iscsi_listener_choices_panel.dart';
import 'iscsi_auth_panel.dart';
import 'iscsi_global_panel.dart';
import 'iscsi_initiator_comment_editor.dart';
import 'iscsi_mapping_chart.dart';
import 'iscsi_portal_comment_editor.dart';
import 'iscsi_sessions_panel.dart';
import 'iscsi_target_name_check.dart';
import 'iscsi_target_create_editor.dart';
import 'iscsi_target_delete_editor.dart';
import 'iscsi_target_rename_editor.dart';
import 'iscsi_threshold_editor.dart';

final iscsiOverviewProvider = FutureProvider<IscsiOverview>((ref) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null || repository is! AuthenticatedAdminSession) {
    throw StateError('Connect to a server to view iSCSI.');
  }
  final api = repository as AuthenticatedAdminSession;
  const names = [
    'iscsi.portal.query',
    'iscsi.initiator.query',
    'iscsi.target.query',
    'iscsi.extent.query',
    'iscsi.targetextent.query',
  ];
  final methods = [for (final name in names) api.adminCatalog.method(name)];
  if (!api.adminCatalog.versionSupported ||
      methods.any((method) => method == null || !method.supported)) {
    throw StateError('This server does not support the iSCSI overview.');
  }
  final values = <Object?>[];
  // The administration gateway accepts one request at a time. These reads
  // are sequential and must not be mistaken for an atomic server snapshot.
  for (final method in methods) {
    final result = await api.invokeAdmin(
      AdminRequest(method: method!, arguments: const []),
    );
    if (!ref.mounted ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      throw StateError('The server connection changed.');
    }
    if (result is! AdminCompleted) {
      throw StateError('iSCSI inventory is unavailable for this account.');
    }
    values.add(result.value);
  }
  return IscsiOverview.parse(
    portals: values[0],
    initiators: values[1],
    targets: values[2],
    extents: values[3],
    mappings: values[4],
  );
}, retry: (_, _) => null);

class IscsiPage extends ConsumerWidget {
  const IscsiPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(iscsiOverviewProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('iSCSI topology'),
        actions: [
          IconButton(
            key: const Key('iscsi-refresh'),
            tooltip: 'Reload iSCSI inventory',
            onPressed: state.isLoading
                ? null
                : () {
                    ref.invalidate(iscsiOverviewProvider);
                    ref.invalidate(iscsiGlobalProvider);
                  },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ListView(
              padding: const EdgeInsets.all(TdSpacing.pageMobile),
              children: [
                const Text('SHARES · BLOCK STORAGE', style: TdTypography.micro),
                const SizedBox(height: 8),
                const Text('Targets & extents', style: TdTypography.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'Configuration overview with reviewed threshold, portal-description, initiator-description and extent-description edits. Five inventories are read sequentially, so server changes during loading may temporarily appear unmatched. Active sessions and CHAP references load separately on request. CHAP secrets, extent paths and serials are not shown.',
                ),
                const SizedBox(height: 20),
                switch (state) {
                  AsyncData(:final value) => _IscsiContent(value: value),
                  AsyncError(:final error) => TdPanel(
                    title: 'iSCSI overview unavailable',
                    child: Text(
                      error is StateError ? error.message.toString() : 'The server did not return a complete iSCSI inventory. Reload to try again.',
                    ),
                  ),
                  _ => const Center(child: CircularProgressIndicator()),
                },
                const SizedBox(height: 16),
                const IscsiSessionsPanel(),
                const SizedBox(height: 16),
                const IscsiAuthPanel(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IscsiContent extends StatefulWidget {
  const _IscsiContent({required this.value});
  final IscsiOverview value;

  @override
  State<_IscsiContent> createState() => _IscsiContentState();
}

class _IscsiContentState extends State<_IscsiContent> {
  String _targetFilter = '';
  String _extentFilter = '';

  @override
  void didUpdateWidget(covariant _IscsiContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.value, widget.value)) {
      _targetFilter = '';
      _extentFilter = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final query = _targetFilter.trim().toLowerCase();
    final visibleTargets = query.isEmpty
        ? value.targets
        : value.targets.where((target) {
            if (target.name.toLowerCase().contains(query) ||
                target.id.toString() == query) {
              return true;
            }
            return value.mappings.any(
              (mapping) =>
                  mapping.targetId == target.id &&
                  (value
                          .extentById(mapping.extentId)
                          ?.name
                          .toLowerCase()
                          .contains(query) ??
                      false),
            );
          }).toList();
    final mappedExtentIds = value.mappings.map((m) => m.extentId).toSet();
    final extentQuery = _extentFilter.trim().toLowerCase();
    final visibleExtents = extentQuery.isEmpty
        ? value.extents
        : value.extents.where((extent) {
            if (extent.name.toLowerCase().contains(extentQuery) ||
                extent.id.toString() == extentQuery) {
              return true;
            }
            return value.mappings.any(
              (mapping) =>
                  mapping.extentId == extent.id &&
                  (value
                          .targetById(mapping.targetId)
                          ?.name
                          .toLowerCase()
                          .contains(extentQuery) ??
                      false),
            );
          }).toList();
    final unresolved = value.mappings
        .where(
          (mapping) =>
              value.targetById(mapping.targetId) == null ||
              value.extentById(mapping.extentId) == null,
        )
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TdPanel(
          title: 'Configuration summary',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${value.portals.length} portals · ${value.initiators.length} initiator groups · ${value.targets.length} targets · ${value.extents.length} extents · ${value.mappings.length} LUN mappings',
              ),
              if (value.extents.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '${value.extents.where((e) => mappedExtentIds.contains(e.id)).length} of ${value.extents.length} extents mapped',
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  key: const Key('iscsi-mapped-ratio'),
                  value:
                      value.extents
                          .where((e) => mappedExtentIds.contains(e.id))
                          .length /
                      value.extents.length,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
              if (unresolved > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '$unresolved mappings reference a target or extent missing from this read.',
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        IscsiMappingChart(overview: value),
        const SizedBox(height: 16),
        IscsiExtentChart(overview: value),
        const SizedBox(height: 16),
        IscsiAccessAudit(overview: value),
        const SizedBox(height: 16),
        IscsiListenerChoicesPanel(overview: value),
        const SizedBox(height: 16),
        const IscsiGlobalPanel(),
        const SizedBox(height: 16),
        const IscsiThresholdEditor(),
        const SizedBox(height: 16),
        IscsiPortalCommentEditor(overview: value),
        const SizedBox(height: 16),
        IscsiInitiatorCommentEditor(overview: value),
        const SizedBox(height: 16),
        IscsiExtentCommentEditor(overview: value),
        const SizedBox(height: 16),
        const IscsiTargetNameCheck(),
        const SizedBox(height: 16),
        const IscsiTargetCreateEditor(),
        const SizedBox(height: 16),
        IscsiTargetDeleteEditor(overview: value),
        const SizedBox(height: 16),
        IscsiTargetRenameEditor(overview: value),
        const SizedBox(height: 16),
        if (value.targets.isNotEmpty) ...[
          KeyedSubtree(
            key: ValueKey(('target-filter', value)),
            child: TextField(
              key: const Key('iscsi-target-filter'),
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Find targets',
                hintText: 'Target name, ID or mapped extent name',
                border: OutlineInputBorder(),
              ),
              onChanged: (text) => setState(() => _targetFilter = text),
            ),
          ),
          Text(
            'Showing ${visibleTargets.length} of ${value.targets.length} targets. '
            'Local filter only; charts and other inventory remain unfiltered.',
          ),
          const SizedBox(height: 16),
        ],
        if (value.targets.isEmpty)
          const TdPanel(
            title: 'No targets configured',
            child: Text('No iSCSI targets were returned.'),
          ),
        if (value.targets.isNotEmpty && visibleTargets.isEmpty)
          const TdPanel(
            title: 'No matching targets',
            child: Text('No targets match this local filter.'),
          ),
        for (final target in visibleTargets) ...[
          TdPanel(
            key: Key('iscsi-target-${target.id}'),
            title: target.name,
            description: 'Target #${target.id} · ${target.mode}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!value.mappings.any((m) => m.targetId == target.id))
                  const Text('No extents mapped to this target.'),
                for (final mapping in value.mappings.where(
                  (m) => m.targetId == target.id,
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'LUN ${mapping.lun} → ${value.extentById(mapping.extentId)?.name ?? 'Unresolved extent #${mapping.extentId}'}',
                    ),
                  ),
                const SizedBox(height: 8),
                Text('Access groups', style: TdTypography.titleSmall),
                if (target.groups.isEmpty)
                  const Text('No portal and initiator associations returned.'),
                for (final group in target.groups)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_groupSummary(value, group)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        TdPanel(
          title: 'Extents',
          child: value.extents.isEmpty
              ? const Text('No extents configured.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    KeyedSubtree(
                      key: ValueKey(('extent-filter', value)),
                      child: TextField(
                        key: const Key('iscsi-extent-filter'),
                        maxLength: 120,
                        decoration: const InputDecoration(
                          labelText: 'Find extents',
                          hintText: 'Extent name, ID or mapped target name',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (text) =>
                            setState(() => _extentFilter = text),
                      ),
                    ),
                    Text(
                      'Showing ${visibleExtents.length} of ${value.extents.length} extents. '
                      'Local filter only; charts and summary remain unfiltered.',
                    ),
                    const SizedBox(height: 12),
                    if (visibleExtents.isEmpty)
                      const Text('No extents match this local filter.'),
                    for (final extent in visibleExtents)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          '${extent.name} · ${extent.type} · ${_state(extent.enabled)} · ${mappedExtentIds.contains(extent.id) ? 'Mapped' : 'Unmapped'}${extent.locked == true ? ' · Locked' : ''}${extent.readOnly == true ? ' · Read only' : ''}',
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        TdPanel(
          title: 'Portals & initiator groups',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (value.portals.isEmpty && value.initiators.isEmpty)
                const Text('No access groups configured.'),
              for (final portal in value.portals)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('Portal #${portal.id} · ${_listeners(portal)}'),
                ),
              for (final initiator in value.initiators)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Initiator group #${initiator.id} · ${_initiatorNames(initiator)}',
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

String _state(bool? enabled) => switch (enabled) {
  true => 'Enabled',
  false => 'Disabled',
  null => 'Status unknown',
};

String _groupSummary(IscsiOverview overview, IscsiTargetGroup group) {
  final portal = overview.portalById(group.portalId);
  final portalText = portal == null
      ? 'Unresolved portal #${group.portalId}'
      : 'Portal #${portal.id} (${_listeners(portal)})';
  final initiatorText = group.initiatorId == null
      ? 'Any initiator'
      : switch (overview.initiatorById(group.initiatorId!)) {
          final IscsiInitiator initiator =>
            'Initiator group #${initiator.id} (${_initiatorNames(initiator)})',
          null => 'Unresolved initiator group #${group.initiatorId}',
        };
  return '$portalText · $initiatorText · ${group.authMethod}';
}

String _listeners(IscsiPortal portal) {
  if (portal.listeners.isEmpty) return 'No listeners listed';
  final shown = portal.listeners
      .take(8)
      .map((listener) {
        final address =
            listener.ip.contains(':') && !listener.ip.startsWith('[')
            ? '[${listener.ip}]'
            : listener.ip;
        return '$address:${listener.port}';
      })
      .join(', ');
  final extra = portal.listeners.length - 8;
  return extra > 0 ? '$shown · $extra more listeners' : shown;
}

String _initiatorNames(IscsiInitiator initiator) {
  if (initiator.names.isEmpty) return 'No names listed';
  final shown = initiator.names.take(8).join(', ');
  final extra = initiator.names.length - 8;
  return extra > 0 ? '$shown · $extra more names' : shown;
}
