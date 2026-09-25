import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'time_settings_charts.dart';
import 'time_settings_controller.dart';
import 'time_settings_review.dart';

class TimeSettingsEditorDialog extends ConsumerStatefulWidget {
  const TimeSettingsEditorDialog({
    required this.session,
    required this.inventory,
    required this.action,
    this.server,
    super.key,
  });
  final AuthenticatedSession session;
  final TimeSettingsInventory inventory;
  final TimeSettingsAction action;
  final NtpServerSnapshot? server;
  @override
  ConsumerState<TimeSettingsEditorDialog> createState() =>
      _TimeSettingsEditorDialogState();
}

class _TimeSettingsEditorDialogState
    extends ConsumerState<TimeSettingsEditorDialog> {
  late final TextEditingController _address, _min, _max;
  late String _timezone;
  String _filter = '';
  bool _burst = false,
      _iburst = true,
      _prefer = false,
      _expired = false,
      _closing = false;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    final settings = widget.server?.settings;
    _address = TextEditingController(text: settings?.address ?? '');
    _min = TextEditingController(text: '${settings?.minPoll ?? 6}');
    _max = TextEditingController(text: '${settings?.maxPoll ?? 10}');
    _burst = settings?.burst ?? false;
    _iburst = settings?.iburst ?? true;
    _prefer = settings?.prefer ?? false;
    _timezone = widget.inventory.timezone;
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _expire() {
    if (_expired || _closing || !mounted) return;
    ref.read(timeSettingsControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _address.clear();
      _min.clear();
      _max.clear();
      _filter = '';
    });
  }

  TimeSettingsRequest get _request => TimeSettingsRequest(
    inventory: widget.inventory,
    action: widget.action,
    server: widget.server,
    timezone: widget.action == TimeSettingsAction.timezone ? _timezone : null,
    settings: widget.action == TimeSettingsAction.timezone
        ? null
        : NtpServerSettings(
            address: _address.text,
            minPoll: int.tryParse(_min.text) ?? -1,
            maxPoll: int.tryParse(_max.text) ?? -1,
            burst: _burst,
            iburst: _iburst,
            prefer: _prefer,
          ),
  );
  void _finish(TimeSettingsRequest? request) {
    _closing = true;
    Navigator.of(context).pop(request);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _address.dispose();
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false && !_expired && !_closing) {
      _expired = true;
      ref.read(timeSettingsControllerProvider.notifier).abandonRoute();
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(timeSettingsInventoryProvider, (_, next) {
      if (next.isLoading || !identical(widget.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(timeSettingsInventoryProvider);
    final current =
        !_expired &&
        !_closing &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.inventory, inventory.asData?.value);
    final request = _request,
        zones = widget.inventory.timezones
            .where((zone) => zone.toLowerCase().contains(_filter.toLowerCase()))
            .toList();
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('time-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? timeSettingsActionLabel(widget.action)
                    : 'Time-settings editor expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details are hidden. Reload configuration before editing again.',
                )
              else ...[
                Text(widget.session.endpoint!),
                const SizedBox(height: 12),
                if (widget.action == TimeSettingsAction.timezone) ...[
                  Text('Current timezone: ${widget.inventory.timezone}'),
                  Text('Selected timezone: $_timezone'),
                  TextField(
                    key: const Key('time-zone-filter'),
                    decoration: const InputDecoration(
                      labelText: 'Find an advertised timezone',
                    ),
                    onChanged: (value) => setState(() => _filter = value),
                  ),
                  Text(
                    'Showing ${zones.take(20).length} of ${zones.length} matching choices. Refine the search to find another timezone.',
                  ),
                  for (final zone in zones.take(20))
                    ListTile(
                      key: Key('time-zone-$zone'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(zone),
                      trailing: Icon(
                        _timezone == zone
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                      ),
                      onTap: () => setState(() => _timezone = zone),
                    ),
                ] else ...[
                  const Text(
                    'IPv4 address or DNS hostname, at most 120 ASCII characters. No URL, port, path or credentials. Existing IPv6 rows may be displayed, but the server probe used by this editor requires IPv4.',
                  ),
                  TextField(
                    key: const Key('time-ntp-address'),
                    controller: _address,
                    maxLength: 120,
                    minLines: 1,
                    maxLines: 4,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'NTP IPv4 address or hostname',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  TextField(
                    key: const Key('time-ntp-min'),
                    controller: _min,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Minimum poll exponent (4–16)',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  Text(
                    'Minimum interval: ${pollSeconds(int.tryParse(_min.text) ?? -1)}',
                  ),
                  TextField(
                    key: const Key('time-ntp-max'),
                    controller: _max,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Maximum poll exponent (5–17)',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  Text(
                    'Maximum interval: ${pollSeconds(int.tryParse(_max.text) ?? -1)}',
                  ),
                  const Text(
                    'Intervals are 2^exponent seconds, not literal seconds. Minimum must be smaller than maximum.',
                  ),
                  CheckboxListTile(
                    key: const Key('time-ntp-burst'),
                    contentPadding: EdgeInsets.zero,
                    value: _burst,
                    onChanged: (value) =>
                        setState(() => _burst = value ?? false),
                    title: const Text('Burst — controlled servers only'),
                  ),
                  const Text(
                    'Do not enable burst for public NTP servers. This option is intended for servers you directly control.',
                  ),
                  CheckboxListTile(
                    key: const Key('time-ntp-iburst'),
                    contentPadding: EdgeInsets.zero,
                    value: _iburst,
                    onChanged: (value) =>
                        setState(() => _iburst = value ?? false),
                    title: const Text('Initial burst (iburst)'),
                  ),
                  CheckboxListTile(
                    key: const Key('time-ntp-prefer'),
                    contentPadding: EdgeInsets.zero,
                    value: _prefer,
                    onChanged: (value) =>
                        setState(() => _prefer = value ?? false),
                    title: const Text('Prefer this configured source'),
                  ),
                  const Text(
                    'Prefer is a selection preference, typically for independently trusted accurate hardware. It is not a measured quality score. Saving even an options-only edit triggers the server-side probe and can restart ntpd.',
                  ),
                ],
                if (request.validationError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      request.validationError!,
                      key: const Key('time-editor-validation'),
                    ),
                  ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('time-editor-cancel'),
                    onPressed: () => _finish(null),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('time-editor-review'),
                    onPressed: current && request.validationError == null
                        ? () => _finish(request)
                        : null,
                    child: const Text('Review change — no write yet'),
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
