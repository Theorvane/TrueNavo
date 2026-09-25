import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'smb_settings_controller.dart';

String _encryptionName(SmbTransportEncryption v) => switch (v) {
  SmbTransportEncryption.defaultMode => 'Default (negotiate)',
  SmbTransportEncryption.negotiate => 'Negotiate',
  SmbTransportEncryption.desired => 'Desired',
  SmbTransportEncryption.required => 'Required',
};
const _impact =
    'I accept Samba configuration regeneration and possible interruption of running clients, transfers and share availability. A later error is not rollback.';
const _identity =
    'I coordinated the server name/workgroup change and accept password-database synchronization, identity-cache flushing and network announcement changes for a renamed server. Client mappings may need repair.';
const _compatibility =
    'I verified client compatibility independently. Stronger encryption may exclude clients; multichannel changes network paths and resource use. No throughput or active encryption is verified here.';

class SmbSettingsPage extends ConsumerStatefulWidget {
  const SmbSettingsPage({super.key});
  @override
  ConsumerState<SmbSettingsPage> createState() => _SmbSettingsPageState();
}

class _SmbSettingsPageState extends ConsumerState<SmbSettingsPage> {
  bool _working = false, _ownModal = false, _abandoned = false;
  late final SmbSettingsController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(smbSettingsControllerProvider.notifier);
  }

  @override
  void dispose() {
    _controller.abandonRoute();
    super.dispose();
  }

  bool get _routeCurrent =>
      mounted && ModalRoute.of(context)?.isCurrent == true;
  Future<T?> _modal<T>(WidgetBuilder builder) async {
    setState(() => _ownModal = true);
    final route = DialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: false,
    );
    try {
      final value = await Navigator.of(context).push(route);
      await route.completed;
      return value;
    } finally {
      if (mounted) setState(() => _ownModal = false);
    }
  }

  Future<void> _change(
    AuthenticatedSession session,
    SmbSettingsInventory inventory,
  ) async {
    if (_working) return;
    setState(() => _working = true);
    var expired = false;
    final lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        if (s != AppLifecycleState.resumed) expired = true;
      },
    );
    final sessions = ref.listenManual(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) expired = true;
    });
    final inventories = ref.listenManual(smbSettingsInventoryProvider, (_, b) {
      if (b.isLoading || !identical(inventory, b.asData?.value)) expired = true;
    });
    bool current() =>
        _routeCurrent &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(smbSettingsInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(smbSettingsInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      final request = await _modal<SmbSettingsRequest>(
        (_) => _SmbEditor(session: session, inventory: inventory),
      );
      if (request == null || !current()) {
        _controller.expireContext();
        return;
      }
      final review = await _controller.review(
        expectedSession: session,
        request: request,
        isRouteCurrent: () => _routeCurrent,
      );
      if (!current()) {
        _controller.expireContext();
        return;
      }
      if (review == null) return;
      final confirmed = await _modal<bool>(
        (_) => _SmbReview(session: session, review: review),
      );
      if (confirmed != true || !current()) {
        _controller.expireContext();
        return;
      }
      await _controller.execute(
        expectedSession: session,
        review: review,
        confirmation: review.target,
        configurationImpactAccepted: true,
        identityImpactAccepted: true,
        compatibilityImpactAccepted: true,
        isRouteCurrent: () => _routeCurrent,
      );
    } finally {
      lifecycle.dispose();
      sessions.close();
      inventories.close();
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false && !_ownModal && !_abandoned) {
      _abandoned = true;
      _controller.abandonRoute();
    } else if (ModalRoute.isCurrentOf(context) == true) {
      _abandoned = false;
    }
    final session = ref.watch(dashboardActiveSessionProvider),
        api = ref.watch(smbSettingsSessionProvider),
        state = ref.watch(smbSettingsControllerProvider),
        value = ref.watch(smbSettingsInventoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Global SMB settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Server identity and client compatibility',
              style: TdTypography.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Saved configuration only, not active connections, bandwidth, runtime encryption or share health. This page does not start a service or probe clients. Individual SMB shares are managed separately.',
            ),
            const SizedBox(height: 16),
            if (state.message != null)
              TdPanel(
                title: state.unresolved
                    ? 'Inspect the original server'
                    : state.status == SmbSettingsStatus.completed
                    ? 'Configuration verified'
                    : 'SMB status',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(state.message!),
                    if (state.server != null)
                      Text('Original server: ${state.server}'),
                    if (state.unresolved) ...[
                      const Text(
                        'Writes remain locked across navigation. Reconnect manually to the original endpoint, verify the same host, then independently inspect SMB settings, generated configuration and client access. No automatic retry.',
                      ),
                      OutlinedButton(
                        key: const Key('smb-verify'),
                        onPressed: _controller.canVerifyReconnectedServer
                            ? _controller.verifyReconnectedServer
                            : null,
                        child: const Text(
                          'Verify reconnected original host once',
                        ),
                      ),
                      if (state.verificationMessage != null)
                        Text(state.verificationMessage!),
                      OutlinedButton(
                        key: const Key('smb-acknowledge'),
                        onPressed: _controller.canAcknowledge
                            ? _controller.acknowledgeAfterReconnect
                            : null,
                        child: const Text(
                          'I independently inspected SMB and clients; release app lock',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            if (!state.locked) ...[
              if (api == null || !api.smbSettingsCapabilities.supported)
                Text(
                  api?.smbSettingsCapabilities.blockedReason ??
                      'Connect to inspect global SMB settings.',
                ),
              value.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => const TdPanel(
                  title: 'SMB settings unavailable',
                  child: Text(
                    'Safe configuration and dependencies could not be verified. No change was submitted. Reload explicitly; remote details are withheld.',
                  ),
                ),
                data: (i) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SmbOverview(inventory: i),
                    const SizedBox(height: 12),
                    TdPanel(
                      title: 'Saved server configuration',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Server: ${i.config.settings.netbiosName}'),
                          Text('Workgroup: ${i.config.settings.workgroup}'),
                          Text(
                            'Description: ${i.config.settings.description.isEmpty ? '(empty)' : i.config.settings.description}',
                          ),
                          Text(
                            'Transport encryption: ${_encryptionName(i.config.settings.encryption)}',
                          ),
                          Text(
                            'Multichannel: ${i.config.settings.multichannel ? 'enabled' : 'disabled'}',
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Protected settings are never included in the update payload.',
                          ),
                          Text(
                            'Aliases: ${i.config.aliases.isEmpty ? 'none' : i.config.aliases.join(', ')}',
                          ),
                          Text(
                            'Apple extensions: ${i.config.appleExtensions ? 'enabled' : 'disabled'}',
                          ),
                          Text(
                            'SMB1: ${i.config.smb1Enabled ? 'enabled (protected)' : 'disabled'} · NTLMv1: ${i.config.ntlmv1Enabled ? 'enabled (protected)' : 'disabled'}',
                          ),
                          Text(
                            'Auxiliary parameters: ${i.config.auxiliaryParametersPresent ? 'present; contents withheld' : 'none'}',
                          ),
                          Text(
                            'Directory profile: ${i.directoryConfigured == false
                                ? 'unconfigured'
                                : i.directoryConfigured == true
                                ? 'configured (protected)'
                                : 'unknown'}',
                          ),
                          Text(
                            'FIPS/STIG configuration: ${i.securityManaged == false
                                ? 'not enabled'
                                : i.securityManaged == true
                                ? 'managed (protected)'
                                : 'unknown'}',
                          ),
                          if (i.blockedReason != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(i.blockedReason!),
                            ),
                          FilledButton(
                            key: const Key('smb-edit'),
                            onPressed:
                                session != null &&
                                    api?.smbSettingsCapabilities.canConfigure ==
                                        true &&
                                    i.blockedReason == null &&
                                    !_working &&
                                    !state.busy
                                ? () => _change(session, i)
                                : null,
                            child: const Text('Edit global SMB settings'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TdPanel(
                      title: 'Configured share headers',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'IDs and enabled flags only; paths, names, options and account details are not fetched.',
                          ),
                          if (i.shares.isEmpty)
                            const Text(
                              'No configured SMB shares. This does not establish runtime access or service status.',
                            ),
                          for (final share in i.shares.take(30))
                            Text(
                              'Share #${share.id}: ${share.enabled ? 'enabled' : 'disabled'}',
                            ),
                          if (i.shares.length > 30)
                            Text(
                              '${i.shares.length - 30} additional configured rows included in counts.',
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                key: const Key('smb-reload'),
                onPressed: !_working && !state.busy
                    ? _controller.refreshConfiguration
                    : null,
                child: const Text('Read fresh SMB configuration'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SmbOverview extends StatelessWidget {
  const _SmbOverview({required this.inventory});
  final SmbSettingsInventory inventory;
  @override
  Widget build(BuildContext context) {
    final total = inventory.shares.length,
        enabled = inventory.shares.where((s) => s.enabled).length,
        colors = Theme.of(context).colorScheme;
    return TdPanel(
      title: 'Configured shares, not live traffic',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 20,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                label: '$enabled enabled of $total configured SMB shares',
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: 110,
                    height: 110,
                    child: CustomPaint(
                      key: const Key('smb-share-ring'),
                      painter: _SmbRing(
                        enabled,
                        total,
                        colors.primary,
                        colors.outlineVariant,
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: FittedBox(
                            child: Text(
                              '$total',
                              style: TdTypography.metricMedium,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Text('$enabled enabled\n${total - enabled} disabled'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Apple-dependent configured shares: ${inventory.appleDependentShareCount ?? 'unknown'}',
          ),
          if (total > 0 && inventory.appleDependentShareCount != null)
            ExcludeSemantics(
              child: LinearProgressIndicator(
                value: inventory.appleDependentShareCount! / total,
                minHeight: 8,
              ),
            ),
          const Text(
            'Includes disabled rows. Counts do not measure mounted clients, effective generated shares or successful access.',
          ),
        ],
      ),
    );
  }
}

class _SmbRing extends CustomPainter {
  const _SmbRing(this.enabled, this.total, this.color, this.track);
  final int enabled, total;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero),
        radius = math.min(size.width, size.height) / 2 - 7;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..color = track;
    canvas.drawCircle(center, radius, p);
    if (total > 0 && enabled > 0) {
      p.color = color;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        math.pi * 2 * enabled / total,
        false,
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_SmbRing old) =>
      old.enabled != enabled ||
      old.total != total ||
      old.color != color ||
      old.track != track;
}

class _SmbEditor extends ConsumerStatefulWidget {
  const _SmbEditor({required this.session, required this.inventory});
  final AuthenticatedSession session;
  final SmbSettingsInventory inventory;
  @override
  ConsumerState<_SmbEditor> createState() => _SmbEditorState();
}

class _SmbEditorState extends ConsumerState<_SmbEditor> {
  late final TextEditingController _name, _workgroup, _description;
  late bool _multichannel;
  late SmbTransportEncryption _encryption;
  bool _expired = false, _closing = false;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    final s = widget.inventory.config.settings;
    _name = TextEditingController(text: s.netbiosName);
    _workgroup = TextEditingController(text: s.workgroup);
    _description = TextEditingController(text: s.description);
    _multichannel = s.multichannel;
    _encryption = s.encryption;
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        if (s != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _clear() {
    _name.clear();
    _workgroup.clear();
    _description.clear();
  }

  void _expire() {
    if (!mounted || _closing || _expired) return;
    setState(() {
      _expired = true;
      _clear();
    });
    ref.read(smbSettingsControllerProvider.notifier).expireContext();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _clear();
    _name.dispose();
    _workgroup.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(smbSettingsInventoryProvider, (_, n) {
      if (n.isLoading || !identical(widget.inventory, n.asData?.value)) {
        _expire();
      }
    });
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      _clear();
      ref.read(smbSettingsControllerProvider.notifier).abandonRoute();
    }
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        identical(
          widget.inventory,
          ref.watch(smbSettingsInventoryProvider).asData?.value,
        );
    final request = SmbSettingsRequest(
      inventory: widget.inventory,
      settings: SmbGlobalSettings(
        netbiosName: _name.text,
        workgroup: _workgroup.text,
        description: _description.text,
        multichannel: _multichannel,
        encryption: _encryption,
      ),
    );
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('smb-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current ? 'Edit global SMB settings' : 'SMB draft expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'The route, connection or foreground context changed. Draft buffers were cleared; close and reload.',
                )
              else ...[
                const Text(
                  'Only changed fields are submitted. Name/workgroup changes affect identity and clients; all edits regenerate configuration and can restart SMB.',
                ),
                TextField(
                  key: const Key('smb-name'),
                  controller: _name,
                  maxLength: 15,
                  decoration: const InputDecoration(
                    labelText: 'Server NetBIOS name',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  key: const Key('smb-workgroup'),
                  controller: _workgroup,
                  maxLength: 15,
                  decoration: const InputDecoration(labelText: 'Workgroup'),
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  key: const Key('smb-description'),
                  controller: _description,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'Description'),
                  onChanged: (_) => setState(() {}),
                ),
                CheckboxListTile(
                  key: const Key('smb-multichannel'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('SMB multichannel'),
                  subtitle: const Text(
                    'Configured capability, not measured bandwidth or active paths.',
                  ),
                  value: _multichannel,
                  onChanged: (v) => setState(() => _multichannel = v == true),
                ),
                const Text('Transport encryption (unchanged or stronger only)'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final v in SmbTransportEncryption.values)
                      ChoiceChip(
                        key: Key('smb-encryption-${v.name}'),
                        label: Text(_encryptionName(v)),
                        selected: _encryption == v,
                        onSelected:
                            SmbSettingsRequest(
                                  inventory: widget.inventory,
                                  settings: SmbGlobalSettings(
                                    netbiosName: _name.text,
                                    workgroup: _workgroup.text,
                                    description: 'Changed for validation',
                                    multichannel: _multichannel,
                                    encryption: v,
                                  ),
                                ).validationError?.contains(
                                  'Encryption may only',
                                ) ==
                                true
                            ? null
                            : (_) => setState(() => _encryption = v),
                      ),
                  ],
                ),
                const Text(
                  'Default currently negotiates like Negotiate; neither guarantees encrypted client sessions. Desired uses encryption when supported. Required rejects incompatible clients.',
                ),
                if (request.validationError != null)
                  Text(request.validationError!),
              ],
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('smb-editor-next'),
                onPressed: current && request.validationError == null
                    ? () {
                        _closing = true;
                        _clear();
                        Navigator.of(context).pop(request);
                      }
                    : null,
                child: const Text('Review exact change'),
              ),
              TextButton(
                key: const Key('smb-editor-cancel'),
                onPressed: () {
                  _closing = true;
                  _clear();
                  Navigator.of(context).pop();
                },
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmbReview extends ConsumerStatefulWidget {
  const _SmbReview({required this.session, required this.review});
  final AuthenticatedSession session;
  final SmbSettingsReview review;
  @override
  ConsumerState<_SmbReview> createState() => _SmbReviewState();
}

class _SmbReviewState extends ConsumerState<_SmbReview> {
  final _confirmation = TextEditingController();
  bool _impactAccepted = false,
      _identityAccepted = false,
      _compatAccepted = false,
      _expired = false,
      _closing = false;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        if (s != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _expire() {
    if (!mounted || _expired || _closing) return;
    setState(() {
      _expired = true;
      _confirmation.clear();
      _impactAccepted = false;
      _identityAccepted = false;
      _compatAccepted = false;
    });
    ref.read(smbSettingsControllerProvider.notifier).expireContext();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _confirmation.clear();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.review, request = r.request;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(smbSettingsInventoryProvider, (_, n) {
      if (n.isLoading || !identical(request.inventory, n.asData?.value)) {
        _expire();
      }
    });
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      _confirmation.clear();
      _impactAccepted = false;
      _identityAccepted = false;
      _compatAccepted = false;
      ref.read(smbSettingsControllerProvider.notifier).abandonRoute();
    }
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        identical(
          request.inventory,
          ref.watch(smbSettingsInventoryProvider).asData?.value,
        ) &&
        ref.read(smbSettingsControllerProvider.notifier).isReviewCurrent(r);
    final old = request.inventory.config.settings,
        newSettings = request.settings,
        compat =
            request.strengthensEncryption ||
            old.multichannel != newSettings.multichannel;
    final confirmed =
        current &&
        _impactAccepted &&
        (!request.changesIdentity || _identityAccepted) &&
        (!compat || _compatAccepted) &&
        _confirmation.text == r.target;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('smb-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current ? 'Review SMB change' : 'SMB review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text('Server: ${r.endpoint}'),
              Text('Host: ${request.inventory.hostId}'),
              if (old.netbiosName != newSettings.netbiosName)
                Text(
                  'Server name: ${old.netbiosName} → ${newSettings.netbiosName}',
                ),
              if (old.workgroup != newSettings.workgroup)
                Text('Workgroup: ${old.workgroup} → ${newSettings.workgroup}'),
              if (old.description != newSettings.description)
                Text(
                  'Description: ${old.description} → ${newSettings.description}',
                ),
              if (old.multichannel != newSettings.multichannel)
                Text(
                  'Multichannel: ${old.multichannel} → ${newSettings.multichannel}',
                ),
              if (old.encryption != newSettings.encryption)
                Text(
                  'Encryption: ${_encryptionName(old.encryption)} → ${_encryptionName(newSettings.encryption)}',
                ),
              for (final warning in r.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(warning),
                ),
              CheckboxListTile(
                key: const Key('smb-consent-impact'),
                contentPadding: EdgeInsets.zero,
                title: const Text(_impact),
                value: _impactAccepted,
                onChanged: current
                    ? (v) => setState(() => _impactAccepted = v == true)
                    : null,
              ),
              if (request.changesIdentity)
                CheckboxListTile(
                  key: const Key('smb-consent-identity'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text(_identity),
                  value: _identityAccepted,
                  onChanged: current
                      ? (v) => setState(() => _identityAccepted = v == true)
                      : null,
                ),
              if (compat)
                CheckboxListTile(
                  key: const Key('smb-consent-compatibility'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text(_compatibility),
                  value: _compatAccepted,
                  onChanged: current
                      ? (v) => setState(() => _compatAccepted = v == true)
                      : null,
                ),
              Text('Type exactly: ${r.target}'),
              TextField(
                key: const Key('smb-confirmation'),
                controller: _confirmation,
                enabled: current,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Exact target confirmation',
                ),
                onChanged: (_) => setState(() {}),
              ),
              FilledButton(
                key: const Key('smb-submit'),
                onPressed: confirmed
                    ? () {
                        _closing = true;
                        _confirmation.clear();
                        Navigator.of(context).pop(true);
                      }
                    : null,
                child: const Text('Apply reviewed SMB change once'),
              ),
              TextButton(
                key: const Key('smb-review-cancel'),
                onPressed: () {
                  _closing = true;
                  _confirmation.clear();
                  Navigator.of(context).pop(false);
                },
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
