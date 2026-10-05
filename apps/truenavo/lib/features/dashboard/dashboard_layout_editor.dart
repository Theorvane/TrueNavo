import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import 'dashboard_layout.dart';
import 'dashboard_layout_controller.dart';

class DashboardLayoutEditor extends ConsumerStatefulWidget {
  const DashboardLayoutEditor({
    required this.identity,
    required this.serverName,
    required this.initial,
    super.key,
  });
  final DashboardLayoutIdentity identity;
  final String serverName;
  final DashboardLayout initial;

  @override
  ConsumerState<DashboardLayoutEditor> createState() =>
      _DashboardLayoutEditorState();
}

class _DashboardLayoutEditorState extends ConsumerState<DashboardLayoutEditor> {
  late DashboardLayout _draft = widget.initial;
  bool _restored = false;

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(dashboardLayoutControllerProvider(widget.identity));
    final current =
        ref.watch(dashboardLayoutIdentityProvider) == widget.identity;
    final enabled = current && !saved.loading && !saved.saving;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 600,
          maxHeight: MediaQuery.sizeOf(context).height * .9,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TdSpacing.component),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: const Text(
                  'Customize dashboard',
                  style: TdTypography.titleMedium,
                ),
              ),
              const SizedBox(height: TdSpacing.inline),
              Text(widget.serverName, style: TdTypography.body),
              const SizedBox(height: TdSpacing.inline),
              const Text(
                'Choose sections and their order. Changes are saved only on this device for this server. Server health stays visible.',
              ),
              const SizedBox(height: TdSpacing.related),
              if (!current)
                const Text(
                  'The selected server changed. Close this editor and customize the current server.',
                  key: Key('dashboard-layout-stale'),
                ),
              if (saved.message != null)
                Semantics(liveRegion: true, child: Text(saved.message!)),
              if (_restored)
                const Text('Default layout selected. Save layout to apply.'),
              for (var index = 0; index < _draft.order.length; index++)
                _section(_draft.order[index], index, enabled),
              const SizedBox(height: TdSpacing.related),
              Wrap(
                spacing: TdSpacing.inline,
                runSpacing: TdSpacing.inline,
                children: [
                  TextButton.icon(
                    key: const Key('dashboard-layout-reset'),
                    onPressed: enabled
                        ? () => setState(() {
                            _draft = DashboardLayout.defaults();
                            _restored = true;
                          })
                        : null,
                    icon: const Icon(Icons.restore_rounded),
                    label: const Text('Use defaults'),
                  ),
                  TextButton(
                    onPressed: saved.saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton.icon(
                    key: const Key('dashboard-layout-save'),
                    onPressed: enabled ? _save : null,
                    icon: saved.saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(saved.saving ? 'Saving…' : 'Save layout'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(DashboardSection section, int index, bool enabled) => Padding(
    key: ValueKey('dashboard-layout-row-${section.name}'),
    padding: const EdgeInsets.symmetric(vertical: TdSpacing.inline),
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: context.tdTheme.borderSubtle),
        borderRadius: BorderRadius.circular(TdRadius.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(TdSpacing.inline),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CheckboxListTile(
              key: ValueKey('dashboard-layout-visible-${section.name}'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: !_draft.hidden.contains(section),
              onChanged: enabled
                  ? (value) => setState(() {
                      _draft = _draft.toggle(section, value ?? true);
                      _restored = false;
                    })
                  : null,
              title: Text(section.label),
              subtitle: Text(section.description),
            ),
            Wrap(
              spacing: TdSpacing.inline,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${index + 1} of ${_draft.order.length}',
                  style: TdTypography.metadata,
                ),
                IconButton(
                  key: ValueKey('dashboard-layout-up-${section.name}'),
                  tooltip: 'Move ${section.label} up',
                  onPressed: enabled && index > 0
                      ? () => setState(() {
                          _draft = _draft.move(section, -1);
                          _restored = false;
                        })
                      : null,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
                IconButton(
                  key: ValueKey('dashboard-layout-down-${section.name}'),
                  tooltip: 'Move ${section.label} down',
                  onPressed: enabled && index < _draft.order.length - 1
                      ? () => setState(() {
                          _draft = _draft.move(section, 1);
                          _restored = false;
                        })
                      : null,
                  icon: const Icon(Icons.arrow_downward_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _save() async {
    final succeeded = await ref
        .read(dashboardLayoutControllerProvider(widget.identity).notifier)
        .save(_draft);
    if (succeeded && mounted) Navigator.of(context).pop();
  }
}
