import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

import 'server_profiles_controller.dart';

const _serverMenuMinimumWidth = 220.0;
const _focusRingThickness = 2.0;

class ServerSwitcher extends ConsumerStatefulWidget {
  const ServerSwitcher({super.key});

  @override
  ConsumerState<ServerSwitcher> createState() => _ServerSwitcherState();
}

class _ServerSwitcherState extends ConsumerState<ServerSwitcher> {
  final _triggerKey = GlobalKey(debugLabel: 'server-catalog-trigger-anchor');
  var _triggerFocused = false;
  var _focusResolutionScheduled = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_scheduleFocusResolution);
    _scheduleFocusResolution();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_scheduleFocusResolution);
    super.dispose();
  }

  void _scheduleFocusResolution() {
    if (_focusResolutionScheduled) return;
    _focusResolutionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusResolutionScheduled = false;
      if (mounted) _resolveTriggerFocus();
    });
  }

  void _resolveTriggerFocus() {
    final focused = FocusManager.instance.primaryFocus?.context
        ?.findRenderObject();
    final trigger = _triggerKey.currentContext?.findRenderObject();
    final focusedRect = _globalRect(focused);
    final triggerRect = _globalRect(trigger);
    _setTriggerFocused(
      focusedRect != null &&
          triggerRect != null &&
          (focusedRect.overlaps(triggerRect) ||
              triggerRect.contains(focusedRect.topLeft) ||
              triggerRect.contains(focusedRect.bottomRight)),
    );
  }

  Rect? _globalRect(RenderObject? renderObject) {
    if (renderObject is! RenderBox || !renderObject.attached) return null;
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  void _setTriggerFocused(bool focused) {
    if (!mounted || _triggerFocused == focused) return;
    setState(() => _triggerFocused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(serverProfilesControllerProvider);
    final empty = state.profiles.isEmpty;
    final label = empty ? 'Server catalog: empty' : 'Choose server';
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: label,
      button: true,
      child: DecoratedBox(
        key: const ValueKey('server-catalog-focus-ring'),
        decoration: BoxDecoration(
          border: _triggerFocused
              ? Border.all(
                  color: context.tdTheme.actionFocusOnSurface,
                  width: _focusRingThickness,
                )
              : null,
        ),
        child: PopupMenuButton<String>(
          tooltip: label,
          requestFocus: false,
          constraints: const BoxConstraints(minWidth: _serverMenuMinimumWidth),
          // PopupMenuButton restores focus to its InkWell trigger when
          // the route closes. Keeping that one native focus target avoids
          // a second, wrapper-only stop in the Tab order.
          onCanceled: () {},
          onSelected: (id) {
            // The controller contains storage failures so this callback never
            // leaves an unhandled Future behind.
            unawaited(
              ref.read(serverProfilesControllerProvider.notifier).select(id),
            );
          },
          itemBuilder: (context) => empty
              ? const [
                  PopupMenuItem<String>(
                    enabled: false,
                    height: TdSizing.minimumTouchTarget,
                    child: Text('No servers in this session catalog.'),
                  ),
                ]
              : [
                  for (final profile in state.profiles)
                    PopupMenuItem(
                      value: profile.id,
                      height: TdSizing.minimumTouchTarget,
                      child: Semantics(
                        selected: profile.id == state.selectedProfileId,
                        child: Text(profile.displayName),
                      ),
                    ),
                ],
          child: ConstrainedBox(
            key: _triggerKey,
            constraints: const BoxConstraints(
              minWidth: TdSizing.minimumTouchTarget,
              minHeight: TdSizing.minimumTouchTarget,
            ),
            child: DecoratedBox(
              key: const ValueKey('server-catalog-trigger'),
              decoration: const BoxDecoration(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.storage_outlined),
                  const SizedBox(width: TdSpacing.inline),
                  Flexible(
                    child: Text(
                      state.selectedProfile?.displayName ??
                          'No server selected',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
