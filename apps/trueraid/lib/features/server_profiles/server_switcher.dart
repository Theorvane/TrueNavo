import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../credentials/credential_vault_provider.dart';
import 'server_profile_forget_coordinator.dart';
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
  String? _removingProfileId;
  String? _removalError;

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

  Future<void> _forget(String profileId) async {
    if (_removingProfileId != null || !mounted) return;
    setState(() {
      _removingProfileId = profileId;
      _removalError = null;
    });
    final outcome = await ServerProfileForgetCoordinator(
      vault: ref.read(credentialVaultProvider),
      removeSecretFirst: ref
          .read(serverProfilesControllerProvider.notifier)
          .removeSecretFirst,
    ).forget(profileId, isCurrent: () => mounted);
    if (!mounted) return;
    setState(() {
      _removingProfileId = null;
      _removalError = switch (outcome) {
        ForgetProfileOutcome.removed || ForgetProfileOutcome.cancelled => null,
        ForgetProfileOutcome.invalidProfile =>
          'This saved server cannot be forgotten safely. Try again.',
        ForgetProfileOutcome.credentialDeleteFailed =>
          'Could not forget the saved credential. Try again.',
        ForgetProfileOutcome.profileRemoveFailed =>
          'Credential forgotten, but the saved server remains. Try again.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(serverProfilesControllerProvider);
    final empty = state.profiles.isEmpty;
    final label = empty ? 'Server catalog: empty' : 'Choose server';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // This must remain a sibling of the excluding trigger semantics: an
        // announcement inside that node would be hidden from assistive tech.
        if (_removalError != null)
          Semantics(
            liveRegion: true,
            child: Text(
              _removalError!,
              style: TdTypography.bodyLarge.copyWith(
                color: context.tdTheme.textSecondary,
              ),
            ),
          ),
        Semantics(
          container: true,
          excludeSemantics: true,
          label: label,
          button: true,
          child: DecoratedBox(
            key: const ValueKey('server-catalog-focus-ring'),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(TdRadius.control),
              border: Border.all(
                color: _triggerFocused
                    ? context.tdTheme.actionFocusOnSurface
                    : Colors.transparent,
                width: _focusRingThickness,
              ),
            ),
            child: PopupMenuButton<_ServerMenuAction>(
              tooltip: label,
              enabled: _removingProfileId == null,
              requestFocus: false,
              constraints: const BoxConstraints(
                minWidth: _serverMenuMinimumWidth,
              ),
              // PopupMenuButton restores focus to its InkWell trigger when
              // the route closes. Keeping that one native focus target avoids
              // a second, wrapper-only stop in the Tab order.
              onCanceled: () {},
              onSelected: (action) {
                // The controller contains storage failures so this callback never
                // leaves an unhandled Future behind.
                switch (action) {
                  case _SelectProfileAction(:final profileId):
                    unawaited(
                      ref
                          .read(serverProfilesControllerProvider.notifier)
                          .select(profileId),
                    );
                  case _ForgetProfileAction(:final profileId):
                    unawaited(_forget(profileId));
                }
              },
              itemBuilder: (context) => empty
                  ? const [
                      PopupMenuItem<_ServerMenuAction>(
                        enabled: false,
                        height: TdSizing.minimumTouchTarget,
                        child: Text('No servers in this session catalog.'),
                      ),
                    ]
                  : [
                      for (final profile in state.profiles) ...[
                        PopupMenuItem<_ServerMenuAction>(
                          value: _SelectProfileAction(profile.id),
                          height: TdSizing.minimumTouchTarget,
                          child: Semantics(
                            selected: profile.id == state.selectedProfileId,
                            child: Text(profile.displayName),
                          ),
                        ),
                        PopupMenuItem<_ServerMenuAction>(
                          key: Key('forget-profile-${profile.id}'),
                          value: _ForgetProfileAction(profile.id),
                          enabled: _removingProfileId == null,
                          height: TdSizing.minimumTouchTarget,
                          child: Text('Forget ${profile.displayName}'),
                        ),
                      ],
                    ],
              child: ConstrainedBox(
                key: _triggerKey,
                constraints: const BoxConstraints(
                  minWidth: TdSizing.minimumTouchTarget,
                  minHeight: TdSizing.minimumTouchTarget,
                ),
                child: DecoratedBox(
                  key: const ValueKey('server-catalog-trigger'),
                  decoration: BoxDecoration(
                    color: context.tdTheme.surfaceRaised,
                    borderRadius: BorderRadius.circular(TdRadius.control),
                    border: Border.all(color: context.tdTheme.borderSubtle),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: TdSpacing.related,
                      vertical: TdSpacing.inline,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.dns_rounded,
                          size: 20,
                          color: context.tdTheme.actionPrimary,
                        ),
                        const SizedBox(width: TdSpacing.inline),
                        Flexible(
                          child: Text(
                            state.selectedProfile?.displayName ??
                                'No server selected',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TdTypography.label,
                          ),
                        ),
                        const SizedBox(width: TdSpacing.inlineTight),
                        const Icon(Icons.expand_more_rounded, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

sealed class _ServerMenuAction {
  const _ServerMenuAction();
}

final class _SelectProfileAction extends _ServerMenuAction {
  const _SelectProfileAction(this.profileId);
  final String profileId;
}

final class _ForgetProfileAction extends _ServerMenuAction {
  const _ForgetProfileAction(this.profileId);
  final String profileId;
}
