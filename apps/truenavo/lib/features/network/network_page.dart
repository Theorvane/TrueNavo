import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'network_controller.dart';

/// Physical-interface administration with an explicit server rollback window.
class NetworkPage extends ConsumerStatefulWidget {
  const NetworkPage({super.key});
  @override
  ConsumerState<NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends ConsumerState<NetworkPage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _revealNetworkResult(ref, _scroll);
    final session = ref.watch(dashboardActiveSessionProvider);
    final network = ref.watch(networkSessionProvider);
    final capabilities = network?.networkCapabilities;
    final td = context.tdTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Network interfaces')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(TdSpacing.pageMobile),
              children: [
                Text(
                  'CONNECTIVITY',
                  style: TdTypography.micro.copyWith(
                    color: td.actionPrimary,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: TdSpacing.inline),
                const Text(
                  'Interface configuration',
                  style: TdTypography.titleLarge,
                ),
                const SizedBox(height: TdSpacing.related),
                Text(
                  session?.endpoint ?? 'No authenticated server endpoint',
                  style: TdTypography.metadata.copyWith(
                    color: td.textSecondary,
                  ),
                ),
                const SizedBox(height: TdSpacing.component),
                const Text(
                  'Review the current configuration, test a change temporarily, '
                  'then explicitly keep it after verifying connectivity.',
                ),
                const SizedBox(height: TdSpacing.group),
                const NetworkTransactionPanel(),
                if (session?.endpoint == null ||
                    capabilities?.connected != true)
                  const TdPanel(
                    title: 'A live connection is required',
                    child: Text(
                      'Connect to the selected server to inspect its interfaces. '
                      'No network settings have been changed.',
                    ),
                  )
                else if (capabilities?.supported != true)
                  TdPanel(
                    title: 'Network editing is unavailable',
                    child: Text(
                      capabilities?.blockedReason ?? 'This server has not advertised the required safe network workflow.',
                    ),
                  )
                else
                  const _InterfaceInventory(),
                const SizedBox(height: TdSpacing.group),
                const TdPanel(
                  title: 'Scope of this editor',
                  description: 'Physical interfaces · IPv4 · description · MTU',
                  child: Text(
                    'Gateway and DNS settings, VLANs, bonds, bridges, IPv6 and '
                    'HA require dedicated workflows. They are not changed here. '
                    'Interfaces involved in an unsupported configuration are read-only.',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InterfaceInventory extends ConsumerWidget {
  const _InterfaceInventory();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inventory = ref.watch(networkInventoryProvider);
    final operation = ref.watch(networkControllerProvider);
    return inventory.when(
      loading: () => const TdPanel(
        title: 'Reading current interfaces',
        child: LinearProgressIndicator(),
      ),
      error: (_, _) => TdPanel(
        title: 'Interfaces could not be loaded',
        description: 'The current configuration could not be verified. Editing is disabled.',
        child: OutlinedButton.icon(
          onPressed: operation.unresolved
              ? null
              : () => ref.invalidate(networkInventoryProvider),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try again'),
        ),
      ),
      data: (data) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Interface inventory',
                  style: TdTypography.titleSmall,
                ),
              ),
              IconButton(
                key: const Key('network-refresh-inventory'),
                tooltip: 'Refresh interfaces',
                onPressed: operation.unresolved
                    ? null
                    : () => ref.invalidate(networkInventoryProvider),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          Text('${data.interfaces.length} interfaces reported by this server'),
          const SizedBox(height: TdSpacing.component),
          if (data.blockedReason != null ||
              data.failoverLicensed ||
              data.hasPendingChanges ||
              data.checkinWaitingSeconds != null) ...[
            TdPanel(
              title: 'Changes are currently protected',
              child: Text(_inventoryReason(data)!),
            ),
            const SizedBox(height: TdSpacing.component),
          ],
          if (data.interfaces.isEmpty)
            const TdPanel(
              child: Text(
                'No interfaces were returned. Nothing can be edited.',
              ),
            ),
          for (final interface in data.interfaces) ...[
            _InterfaceCard(
              inventory: data,
              interface: interface,
              active: operation.unresolved,
            ),
            const SizedBox(height: TdSpacing.related),
          ],
        ],
      ),
    );
  }
}

String? _inventoryReason(NetworkInventory inventory) =>
    inventory.blockedReason ??
    (inventory.failoverLicensed
        ? 'HA systems require a node-aware network workflow.'
        : inventory.hasPendingChanges || inventory.checkinWaitingSeconds != null
        ? 'Another network transaction is pending. Resolve it before starting a new test.'
        : null);

class _InterfaceCard extends StatelessWidget {
  const _InterfaceCard({
    required this.inventory,
    required this.interface,
    required this.active,
  });
  final NetworkInventory inventory;
  final NetworkInterfaceSnapshot interface;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final reason = _inventoryReason(inventory) ?? interface.blockedReason;
    return TdPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: TdSpacing.related,
            runSpacing: TdSpacing.inline,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(
                Icons.settings_ethernet_rounded,
                color: context.tdTheme.actionPrimary,
              ),
              Text(interface.name, style: TdTypography.titleSmall),
              TdStatusBadge(
                status: reason == null ? TdStatus.info : TdStatus.neutral,
                label: reason == null ? 'Editable IPv4' : 'Read-only',
              ),
            ],
          ),
          const SizedBox(height: TdSpacing.related),
          Text('${interface.id} · ${interface.type}'),
          if (interface.description.isNotEmpty) ...[
            const SizedBox(height: TdSpacing.inline),
            Text(interface.description),
          ],
          const SizedBox(height: TdSpacing.component),
          _Detail(
            label: 'IPv4 configuration',
            value: _addressSummary(interface.dhcp, interface.aliases),
          ),
          _Detail(
            label: 'MTU',
            value: interface.mtu?.toString() ?? 'Interface default',
          ),
          if (reason != null) ...[
            const SizedBox(height: TdSpacing.related),
            Text(
              reason,
              style: TextStyle(color: context.tdTheme.textSecondary),
            ),
          ],
          if (active)
            const Text(
              'Finish or verify the current network transaction first.',
            ),
          const SizedBox(height: TdSpacing.component),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: ValueKey('network-edit-${interface.id}'),
              onPressed: reason == null && !active
                  ? () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NetworkInterfacePage(
                          inventory: inventory,
                          interface: interface,
                        ),
                      ),
                    )
                  : null,
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('Configure IPv4'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps transaction status visible on both the inventory and editor routes.
/// The controller owns the deadline; this widget never keeps changes for users.
class NetworkTransactionPanel extends ConsumerStatefulWidget {
  const NetworkTransactionPanel({super.key});
  @override
  ConsumerState<NetworkTransactionPanel> createState() =>
      _NetworkTransactionPanelState();
}

class _NetworkTransactionPanelState
    extends ConsumerState<NetworkTransactionPanel> {
  bool _connectivityVerified = false;
  NetworkTransaction? _seenTransaction;
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(networkControllerProvider);
    final controller = ref.read(networkControllerProvider.notifier);
    if (!identical(_seenTransaction, state.transaction)) {
      _seenTransaction = state.transaction;
      _connectivityVerified = false;
    }
    final session = ref.watch(dashboardActiveSessionProvider);
    final sameSession = identical(session, controller.operationSession);
    final reconciledHere =
        state.phase == NetworkPhase.reconciled &&
        session?.endpoint != null &&
        session?.endpoint == state.serverLabel;
    if (state.phase == NetworkPhase.idle ||
        (!state.unresolved && !sameSession && !reconciledHere)) {
      return const SizedBox.shrink();
    }
    final title = switch (state.phase) {
      NetworkPhase.starting => 'Starting a temporary network test',
      NetworkPhase.testing ||
      NetworkPhase.checking => 'Temporary settings · not yet kept',
      NetworkPhase.keeping => 'Confirming that the settings are kept',
      NetworkPhase.reverting => 'Requesting a rollback',
      NetworkPhase.kept => 'Changes kept',
      NetworkPhase.reverted => 'Previous configuration restored',
      NetworkPhase.reconciled => 'Current network state checked',
      NetworkPhase.rejected => 'Test not started',
      NetworkPhase.unknown => 'Network outcome needs verification',
      NetworkPhase.idle => '',
    };
    final remaining = state.secondsRemaining;
    return Padding(
      padding: const EdgeInsets.only(bottom: TdSpacing.component),
      child: Semantics(
        liveRegion: true,
        child: TdPanel(
          title: title,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(state.serverLabel ?? 'Original server'),
              if (state.request case final request?)
                Text('Interface: ${request.interfaceId}'),
              const SizedBox(height: TdSpacing.component),
              if (remaining != null &&
                  {
                    NetworkPhase.testing,
                    NetworkPhase.checking,
                    NetworkPhase.keeping,
                  }.contains(state.phase)) ...[
                Text(
                  '${remaining < 0 ? 0 : remaining} s',
                  key: const Key('network-countdown'),
                  style: TdTypography.display.copyWith(
                    color: context.tdTheme.statusWarning,
                  ),
                ),
                const Text(
                  'Local estimate · server rollback deadline is authoritative',
                ),
                const SizedBox(height: TdSpacing.related),
                LinearProgressIndicator(value: (remaining / 60).clamp(0, 1)),
                const SizedBox(height: TdSpacing.component),
              ] else if (state.busy) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: TdSpacing.component),
              ],
              Text(
                state.message ?? 'Verify the network state on the original server before continuing.',
              ),
              if (state.unresolved) ...[
                const SizedBox(height: TdSpacing.related),
                Text(
                  state.phase == NetworkPhase.unknown ||
                          state.phase == NetworkPhase.starting
                      ? 'A rollback timer has not been confirmed for this outcome. '
                            'Verify the original server or use the explicit Revert action '
                            'when available. Nothing is kept automatically.'
                      : 'Changes are never kept automatically. If connectivity is lost, '
                            'allow the server rollback window to expire and verify its state. '
                            'Leaving this page does not stop the server timer.',
                ),
                if (!sameSession) ...[
                  const SizedBox(height: TdSpacing.related),
                  const Text(
                    'This is a transaction on a previous connection. Controls are disabled here.',
                  ),
                ],
                const SizedBox(height: TdSpacing.component),
                if (state.phase == NetworkPhase.testing ||
                    state.phase == NetworkPhase.checking)
                  Material(
                    type: MaterialType.transparency,
                    child: CheckboxListTile(
                      key: const Key('network-connectivity-verified'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text(
                        'I verified connectivity using the proposed settings.',
                      ),
                      value: _connectivityVerified,
                      onChanged: sameSession && state.canKeep
                          ? (value) => setState(
                              () => _connectivityVerified = value ?? false,
                            )
                          : null,
                    ),
                  ),
                Wrap(
                  spacing: TdSpacing.related,
                  runSpacing: TdSpacing.related,
                  children: [
                    FilledButton.icon(
                      key: const Key('network-keep-changes'),
                      onPressed:
                          sameSession && state.canKeep && _connectivityVerified
                          ? controller.keep
                          : null,
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Keep changes'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('network-revert-changes'),
                      onPressed: sameSession && state.canRevert
                          ? controller.revert
                          : null,
                      icon: const Icon(Icons.undo_rounded),
                      label: const Text('Revert changes'),
                    ),
                    TextButton(
                      key: const Key('network-check-status'),
                      onPressed: sameSession && state.canRefresh
                          ? controller.refreshStatus
                          : null,
                      child: const Text('Check server status'),
                    ),
                    if (!state.connectionCurrent &&
                        session?.endpoint != null &&
                        session?.endpoint == state.serverLabel)
                      OutlinedButton.icon(
                        key: const Key('network-verify-reconnected'),
                        onPressed: state.busy
                            ? null
                            : controller.verifyAfterReconnect,
                        icon: const Icon(Icons.fact_check_outlined),
                        label: const Text('Verify after reconnect'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class NetworkInterfacePage extends ConsumerStatefulWidget {
  const NetworkInterfacePage({
    required this.inventory,
    required this.interface,
    super.key,
  });
  final NetworkInventory inventory;
  final NetworkInterfaceSnapshot interface;
  @override
  ConsumerState<NetworkInterfacePage> createState() =>
      _NetworkInterfacePageState();
}

class _NetworkInterfacePageState extends ConsumerState<NetworkInterfacePage> {
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  late final _description = TextEditingController(
    text: widget.interface.description,
  );
  late final _mtu = TextEditingController(
    text: widget.interface.mtu?.toString() ?? '1500',
  );
  late final AuthenticatedSession? _initialSession = ref.read(
    dashboardActiveSessionProvider,
  );
  late final String? _server = _initialSession?.endpoint;
  late bool _dhcp = widget.interface.dhcp;
  late bool _defaultMtu = widget.interface.mtu == null;
  late final List<_AddressInput> _aliases = [
    for (final address in widget.interface.aliases.where(
      (item) => item.type == 'INET',
    ))
      _AddressInput(
        address: address.address,
        prefix: address.netmask.toString(),
      ),
  ];
  bool _reviewing = false;
  String? _error;

  @override
  void dispose() {
    _scroll.dispose();
    _description.dispose();
    _mtu.dispose();
    for (final alias in _aliases) {
      alias.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _revealNetworkResult(ref, _scroll);
    final session = ref.watch(dashboardActiveSessionProvider);
    final state = ref.watch(networkControllerProvider);
    final reason =
        _inventoryReason(widget.inventory) ?? widget.interface.blockedReason;
    final sameSession =
        _initialSession != null && identical(_initialSession, session);
    final enabled =
        sameSession &&
        _server != null &&
        reason == null &&
        !state.unresolved &&
        !_reviewing;
    return Scaffold(
      appBar: AppBar(title: Text('Configure ${widget.interface.name}')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(TdSpacing.pageMobile),
              children: [
                Text(widget.interface.id, style: TdTypography.titleLarge),
                const SizedBox(height: TdSpacing.related),
                SelectableText(_server ?? 'No live server selected'),
                const SizedBox(height: TdSpacing.group),
                const NetworkTransactionPanel(),
                if (!sameSession || _server == null || reason != null) ...[
                  TdPanel(
                    title: 'Editing is unavailable',
                    child: Text(
                      reason ?? 'The connection changed. Reload the interfaces on the selected server.',
                    ),
                  ),
                  const SizedBox(height: TdSpacing.component),
                ],
                TdPanel(
                  title: 'Current configuration',
                  child: _ConfigurationSummary(
                    description: widget.interface.description,
                    dhcp: widget.interface.dhcp,
                    aliases: widget.interface.aliases,
                    mtu: widget.interface.mtu,
                  ),
                ),
                const SizedBox(height: TdSpacing.component),
                TdPanel(
                  title: 'Proposed configuration',
                  description: 'Nothing is sent until you review and start a temporary test.',
                  child: Material(
                    type: MaterialType.transparency,
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            key: const Key('network-description'),
                            controller: _description,
                            enabled: enabled,
                            maxLength: 64,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: const InputDecoration(
                              labelText: 'Description',
                            ),
                          ),
                          const SizedBox(height: TdSpacing.related),
                          SwitchListTile(
                            key: const Key('network-dhcp'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Obtain IPv4 using DHCP'),
                            subtitle: const Text(
                              'DHCP sends no static IPv4 aliases.',
                            ),
                            value: _dhcp,
                            onChanged: enabled
                                ? (value) => setState(() {
                                    _dhcp = value;
                                    _error = null;
                                  })
                                : null,
                          ),
                          if (!_dhcp) ...[
                            const SizedBox(height: TdSpacing.component),
                            const Text(
                              'Static IPv4 addresses',
                              style: TdTypography.titleSmall,
                            ),
                            const SizedBox(height: TdSpacing.related),
                            if (_aliases.isEmpty)
                              const Text(
                                'Add at least one address before starting a static IPv4 test.',
                              ),
                            for (
                              var index = 0;
                              index < _aliases.length;
                              index++
                            ) ...[
                              _AliasFields(
                                key: ObjectKey(_aliases[index]),
                                input: _aliases[index],
                                index: index,
                                enabled: enabled,
                                onRemove: () => setState(
                                  () => _aliases.removeAt(index).dispose(),
                                ),
                              ),
                              const SizedBox(height: TdSpacing.component),
                            ],
                            Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                key: const Key('network-add-address'),
                                onPressed: enabled && _aliases.length < 8
                                    ? () => setState(
                                        () => _aliases.add(_AddressInput()),
                                      )
                                    : null,
                                icon: const Icon(Icons.add_rounded),
                                label: const Text('Add IPv4 address'),
                              ),
                            ),
                          ],
                          const SizedBox(height: TdSpacing.component),
                          SwitchListTile(
                            key: const Key('network-default-mtu'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Use interface default MTU'),
                            value: _defaultMtu,
                            onChanged: enabled
                                ? (value) => setState(() => _defaultMtu = value)
                                : null,
                          ),
                          if (!_defaultMtu) ...[
                            const SizedBox(height: TdSpacing.related),
                            TextFormField(
                              key: const Key('network-mtu'),
                              controller: _mtu,
                              enabled: enabled,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'MTU',
                                helperText: '1280–9000 bytes',
                              ),
                              validator: (value) {
                                final parsed = int.tryParse(value ?? '');
                                return parsed == null ||
                                        parsed < 1280 ||
                                        parsed > 9000
                                    ? 'Enter a whole number from 1280 to 9000.'
                                    : null;
                              },
                            ),
                          ],
                          const SizedBox(height: TdSpacing.related),
                          const Text(
                            'IPv6, interface topology, gateway and DNS configuration are preserved.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: TdSpacing.component),
                if (_error != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(color: context.tdTheme.statusCritical),
                    ),
                  ),
                  const SizedBox(height: TdSpacing.related),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const Key('network-review-test'),
                    onPressed: enabled ? _review : null,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Review temporary test'),
                  ),
                ),
                const SizedBox(height: TdSpacing.component),
                const Text(
                  'Changing an address can disconnect this app and every client '
                  'using that interface. Have console or out-of-band access ready. '
                  'After successful temporary application, the server arms a '
                  '60-second test window. Staging alone does not confirm rollback protection.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _review() async {
    if (_reviewing || _initialSession == null || _server == null) return;
    if (_form.currentState?.validate() != true) return;
    final request = NetworkChangeRequest(
      inventory: widget.inventory,
      interfaceId: widget.interface.id,
      description: _description.text,
      dhcp: _dhcp,
      ipv4Aliases: _dhcp
          ? []
          : [
              for (final alias in _aliases)
                NetworkAddress(
                  address: alias.address.text,
                  netmask: int.parse(alias.prefix.text),
                ),
            ],
      mtu: _defaultMtu ? null : int.parse(_mtu.text),
    );
    if (request.validationError case final error?) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _reviewing = true;
      _error = null;
    });
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => NetworkReviewDialog(
        serverLabel: _server,
        original: widget.interface,
        request: request,
      ),
    );
    if (!mounted) return;
    setState(() => _reviewing = false);
    if (approved != true) return;
    if (!identical(ref.read(dashboardActiveSessionProvider), _initialSession)) {
      setState(
        () => _error = 'The connection changed during review. Nothing was sent. Reload the interfaces.',
      );
      return;
    }
    final submission = ref
        .read(networkControllerProvider.notifier)
        .begin(
          expectedSession: _initialSession,
          request: request,
          serverLabel: _server,
        );
    if (_scroll.hasClients) {
      await _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
    await submission;
  }
}

void _revealNetworkResult(WidgetRef ref, ScrollController scroll) {
  ref.listen(networkControllerProvider, (previous, next) {
    if (previous?.phase == next.phase ||
        !{
          NetworkPhase.kept,
          NetworkPhase.reverted,
          NetworkPhase.rejected,
          NetworkPhase.reconciled,
          NetworkPhase.unknown,
        }.contains(next.phase)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  });
}

class _AddressInput {
  _AddressInput({String address = '', String prefix = '24'})
    : address = TextEditingController(text: address),
      prefix = TextEditingController(text: prefix);
  final TextEditingController address;
  final TextEditingController prefix;
  void dispose() {
    address.dispose();
    prefix.dispose();
  }
}

class _AliasFields extends StatelessWidget {
  const _AliasFields({
    required this.input,
    required this.index,
    required this.enabled,
    required this.onRemove,
    super.key,
  });
  final _AddressInput input;
  final int index;
  final bool enabled;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    final address = TextFormField(
      key: ValueKey('network-address-$index'),
      controller: input.address,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(
        labelText: 'IPv4 address',
        hintText: '192.168.1.20',
      ),
      validator: (value) {
        final parts = (value ?? '').split('.');
        if (parts.length != 4 ||
            parts.any(
              (part) =>
                  !RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part) ||
                  int.parse(part) > 255,
            )) {
          return 'Enter an IPv4 address in dotted notation.';
        }
        return null;
      },
    );
    final prefix = TextFormField(
      key: ValueKey('network-prefix-$index'),
      controller: input.prefix,
      enabled: enabled,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: 'Prefix length',
        helperText: '1–32',
      ),
      validator: (value) {
        final parsed = int.tryParse(value ?? '');
        return parsed == null || parsed < 1 || parsed > 32 ? 'Use 1–32.' : null;
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Address ${index + 1}', style: TdTypography.label),
            ),
            IconButton(
              key: ValueKey('network-remove-address-$index'),
              tooltip: 'Remove address ${index + 1}',
              onPressed: enabled ? onRemove : null,
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
            return constraints.maxWidth >= 440 * scale
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: address),
                      const SizedBox(width: TdSpacing.related),
                      Expanded(child: prefix),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      address,
                      const SizedBox(height: TdSpacing.related),
                      prefix,
                    ],
                  );
          },
        ),
      ],
    );
  }
}

class NetworkReviewDialog extends StatefulWidget {
  const NetworkReviewDialog({
    required this.serverLabel,
    required this.original,
    required this.request,
    super.key,
  });
  final String serverLabel;
  final NetworkInterfaceSnapshot original;
  final NetworkChangeRequest request;
  @override
  State<NetworkReviewDialog> createState() => _NetworkReviewDialogState();
}

class _NetworkReviewDialogState extends State<NetworkReviewDialog> {
  String _target = '';
  bool _acknowledged = false;
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 760,
        maxHeight: MediaQuery.sizeOf(context).height * .9,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(TdSpacing.component),
            child: Text(
              'Review temporary network test',
              style: TdTypography.titleSmall,
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(TdSpacing.component),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('EXACT SERVER', style: TdTypography.micro),
                  SelectableText(widget.serverLabel),
                  const SizedBox(height: TdSpacing.related),
                  const Text('INTERFACE', style: TdTypography.micro),
                  SelectableText(
                    widget.request.interfaceId,
                    style: TdTypography.titleSmall,
                  ),
                  const SizedBox(height: TdSpacing.component),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final before = TdPanel(
                        title: 'Before',
                        child: _ConfigurationSummary(
                          description: widget.original.description,
                          dhcp: widget.original.dhcp,
                          aliases: widget.original.aliases,
                          mtu: widget.original.mtu,
                        ),
                      );
                      final after = TdPanel(
                        title: 'After · temporary',
                        child: _ConfigurationSummary(
                          description: widget.request.description,
                          dhcp: widget.request.dhcp,
                          aliases: widget.request.ipv4Aliases,
                          mtu: widget.request.mtu,
                        ),
                      );
                      final scale =
                          MediaQuery.textScalerOf(context).scale(16) / 16;
                      return constraints.maxWidth >= 620 * scale
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: before),
                                const SizedBox(width: TdSpacing.related),
                                Expanded(child: after),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                before,
                                const SizedBox(height: TdSpacing.related),
                                after,
                              ],
                            );
                    },
                  ),
                  const SizedBox(height: TdSpacing.component),
                  const Text(
                    'This can disconnect your management session and clients. After successful '
                    'temporary application, the server arms a 60-second rollback window. '
                    'Staging alone does not confirm rollback protection. Only choose Keep changes after '
                    'you verify connectivity. No settings are kept automatically. '
                    'Do not edit networking concurrently in the WebUI or another API client.',
                  ),
                  const SizedBox(height: TdSpacing.related),
                  CheckboxListTile(
                    key: const Key('network-confirm-acknowledge'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      'I understand the disconnect risk and have a recovery path.',
                    ),
                    value: _acknowledged,
                    onChanged: (value) =>
                        setState(() => _acknowledged = value ?? false),
                  ),
                  TextField(
                    key: const Key('network-confirm-interface'),
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Type the exact interface ID',
                    ),
                    onChanged: (value) => setState(() => _target = value),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(TdSpacing.component),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: TdSpacing.related,
              runSpacing: TdSpacing.related,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('network-confirm-test'),
                  onPressed:
                      _acknowledged && _target == widget.request.interfaceId
                      ? () => Navigator.pop(context, true)
                      : null,
                  child: const Text('Start 60-second test'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

String _addressSummary(bool dhcp, List<NetworkAddress> addresses) {
  final ipv4 = addresses.where((address) => address.type == 'INET');
  if (dhcp) {
    return ipv4.isEmpty
        ? 'Automatic (DHCP)'
        : 'Automatic (DHCP)\nConfigured static aliases:\n${_addressSummary(false, addresses)}';
  }
  return ipv4.isEmpty
      ? 'No static IPv4 addresses'
      : ipv4
            .map((address) => '${address.address}/${address.netmask}')
            .join('\n');
}

class _ConfigurationSummary extends StatelessWidget {
  const _ConfigurationSummary({
    required this.description,
    required this.dhcp,
    required this.aliases,
    required this.mtu,
  });
  final String description;
  final bool dhcp;
  final List<NetworkAddress> aliases;
  final int? mtu;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Detail(
        label: 'Description',
        value: description.isEmpty ? 'Not set' : description,
      ),
      _Detail(label: 'IPv4 mode', value: dhcp ? 'Automatic (DHCP)' : 'Static'),
      _Detail(
        label: 'Static addresses',
        value: dhcp && !aliases.any((address) => address.type == 'INET')
            ? 'None · assigned by DHCP'
            : _addressSummary(false, aliases),
      ),
      _Detail(label: 'MTU', value: mtu?.toString() ?? 'Interface default'),
    ],
  );
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: TdSpacing.inline),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TdTypography.metadata.copyWith(
            color: context.tdTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 2),
        SelectableText(value),
      ],
    ),
  );
}
