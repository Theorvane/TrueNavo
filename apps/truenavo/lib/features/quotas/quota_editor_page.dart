import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'quotas_controller.dart';
import 'quotas_page.dart'
    show QuotaOperationBanner, quotaIdLabel, quotaQuantity;

class QuotaEditorPage extends ConsumerStatefulWidget {
  const QuotaEditorPage({
    required this.session,
    required this.inventory,
    required this.kind,
    this.entry,
    super.key,
  });
  final AuthenticatedSession session;
  final QuotaInventory inventory;
  final QuotaKind kind;
  final QuotaEntry? entry;

  @override
  ConsumerState<QuotaEditorPage> createState() => _QuotaEditorPageState();
}

class _QuotaEditorPageState extends ConsumerState<QuotaEditorPage> {
  final _id = TextEditingController(),
      _bytes = TextEditingController(),
      _objects = TextEditingController();
  String _byteMode = 'unchanged', _objectMode = 'unchanged';
  QuotaIdentity? _identity;
  String? _error;
  var _expired = false, _resolving = false, _reviewing = false;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _id.text = widget.entry?.id.toString() ?? '';
  }

  @override
  void dispose() {
    _generation++;
    _id.dispose();
    _bytes.dispose();
    _objects.dispose();
    super.dispose();
  }

  void _expire() {
    if (_expired) return;
    _expired = true;
    _generation++;
    _identity = null;
    _error = null;
    _id.clear();
    _bytes.clear();
    _objects.clear();
  }

  bool get _current =>
      !_expired &&
      identical(widget.session, ref.read(dashboardActiveSessionProvider));

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (!identical(next, widget.session) && !_expired) setState(_expire);
    });
    if (!identical(widget.session, ref.watch(dashboardActiveSessionProvider))) {
      _expire();
    }
    final state = ref.watch(quotasControllerProvider);
    final canSet =
        ref
            .watch(quotasSessionProvider)
            ?.quotaCapabilities
            .canSet(widget.kind) ==
        true;
    final enabled = !_resolving && !_reviewing && !state.locked && canSet;
    final identity = _identity;
    final baseline = identity == null
        ? null
        : widget.inventory.entry(identity.kind, identity.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _expired ? 'Connection changed' : '${widget.kind.label} quota',
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _expired
                    ? [
                        const Text(
                          'This quota form has expired. Return to the quota workspace and load the current server before starting again.',
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          key: const Key('quota-editor-close'),
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Close'),
                        ),
                      ]
                    : [
                        Text(
                          '${widget.kind.label} quota',
                          style: TdTypography.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        Text('Server: ${widget.session.endpoint}'),
                        Text('Dataset: ${widget.inventory.dataset.id}'),
                        const SizedBox(height: 16),
                        const QuotaOperationBanner(),
                        const Text(
                          'Resolve the numeric identity on this server before setting its limits.',
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('quota-identity-id'),
                          controller: _id,
                          readOnly: widget.entry != null,
                          enabled: enabled,
                          keyboardType: TextInputType.number,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'Numeric ${quotaIdLabel(widget.kind)}',
                          ),
                          onChanged: (_) => setState(() {
                            _identity = null;
                            _error = null;
                            _byteMode = 'unchanged';
                            _objectMode = 'unchanged';
                            _bytes.clear();
                            _objects.clear();
                            _generation++;
                          }),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          key: const Key('quota-identity-resolve'),
                          onPressed: enabled ? _resolve : null,
                          child: Text(
                            'Resolve ${widget.kind.label.toLowerCase()}',
                          ),
                        ),
                        if (_resolving) const LinearProgressIndicator(),
                        if (identity != null) ...[
                          const SizedBox(height: 16),
                          TdPanel(
                            title: identity.displayLabel,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'Numeric target: ${identity.kind.wire} ${identity.id}',
                                ),
                                Text('Source: ${identity.source}'),
                                Text(
                                  identity.local
                                      ? 'Local identity'
                                      : 'Directory identity',
                                ),
                                if (identity.sid != null)
                                  Text('SID: ${identity.sid}'),
                                const SizedBox(height: 8),
                                Text(
                                  'Current byte limit: ${_limit(baseline?.byteLimit ?? 0, objects: false)}',
                                ),
                                Text(
                                  'Current object limit: ${_limit(baseline?.objectLimit ?? 0, objects: true)}',
                                ),
                                Text(
                                  'Reported byte usage: ${baseline?.usedBytes == null ? 'Unavailable' : quotaQuantity(baseline!.usedBytes!, objects: false)}',
                                ),
                                Text(
                                  'Reported object usage: ${baseline?.usedObjects == null ? 'Unavailable' : quotaQuantity(baseline!.usedObjects!, objects: true)}',
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          _modeSelector(objects: false, enabled: enabled),
                          if (_byteMode == 'limited') ...[
                            const SizedBox(height: 12),
                            TextField(
                              key: const Key('quota-byte-limit'),
                              controller: _bytes,
                              enabled: enabled,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Byte limit (exact bytes)',
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          _modeSelector(objects: true, enabled: enabled),
                          if (_objectMode == 'limited') ...[
                            const SizedBox(height: 12),
                            TextField(
                              key: const Key('quota-object-limit'),
                              controller: _objects,
                              enabled: enabled,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Object limit (whole objects)',
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          const Text(
                            'Keep a field unchanged to preserve its current limit. Unlimited removes that limit. Lowering a limit below current usage can immediately deny further writes or object creation.',
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(_error!, key: const Key('quota-editor-error')),
                          const SizedBox(height: 12),
                        ],
                        if (_reviewing) const LinearProgressIndicator(),
                        FilledButton(
                          key: const Key('quota-review'),
                          onPressed: enabled && identity != null
                              ? _review
                              : null,
                          child: const Text('Review limits'),
                        ),
                      ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeSelector({required bool objects, required bool enabled}) =>
      DropdownButtonFormField<String>(
        key: Key('quota-limit-${objects ? 'objects' : 'bytes'}-mode'),
        initialValue: objects ? _objectMode : _byteMode,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: objects ? 'Object limit' : 'Byte limit',
        ),
        items: const [
          DropdownMenuItem(
            value: 'unchanged',
            child: Text(
              'Keep unchanged',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          DropdownMenuItem(
            value: 'limited',
            child: Text(
              'Set a limit',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          DropdownMenuItem(
            value: 'unlimited',
            child: Text(
              'Unlimited',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        onChanged: enabled
            ? (value) => setState(() {
                if (objects) {
                  _objectMode = value!;
                } else {
                  _byteMode = value!;
                }
                _error = null;
              })
            : null,
      );

  Future<void> _resolve() async {
    final id = _whole(_id.text, maximum: 4294967294);
    if (id == null || id == 0) {
      setState(
        () => _error =
            'Enter a whole numeric ${quotaIdLabel(widget.kind)} from 1 to 4294967294. Root identities are protected.',
      );
      return;
    }
    final api = ref.read(quotasSessionProvider);
    if (api == null || !_current) return;
    final generation = ++_generation;
    setState(() {
      _identity = null;
      _resolving = true;
      _error = null;
    });
    try {
      final identity = await api.resolveQuotaIdentity(
        widget.inventory,
        widget.kind,
        id,
      );
      if (!mounted || generation != _generation || !_current) return;
      if (identity.kind != widget.kind || identity.id != id) {
        setState(
          () => _error = 'The resolved identity did not match the requested numeric ID. Reload quotas before continuing.',
        );
        return;
      }
      final baseline = widget.inventory.entry(identity.kind, identity.id);
      setState(() {
        _identity = identity;
        _byteMode = 'unchanged';
        _objectMode = 'unchanged';
        _bytes.text = (baseline?.byteLimit ?? 0) > 0
            ? '${baseline!.byteLimit}'
            : '';
        _objects.text = (baseline?.objectLimit ?? 0) > 0
            ? '${baseline!.objectLimit}'
            : '';
      });
    } on QuotaException catch (error) {
      if (mounted && generation == _generation && _current) {
        setState(() => _error = error.userMessage);
      }
    } on Object {
      if (mounted && generation == _generation && _current) {
        setState(
          () => _error = 'This numeric identity could not be resolved. Remote details were withheld.',
        );
      }
    } finally {
      if (mounted && generation == _generation && _current) {
        setState(() => _resolving = false);
      }
    }
  }

  Future<void> _review() async {
    final identity = _identity;
    final api = ref.read(quotasSessionProvider);
    if (identity == null || api == null || !_current) return;
    final bytes = _byteMode == 'limited' ? _whole(_bytes.text) : 0;
    final objects = _objectMode == 'limited' ? _whole(_objects.text) : 0;
    if (_byteMode == 'limited' && (bytes == null || bytes == 0) ||
        _objectMode == 'limited' && (objects == null || objects == 0)) {
      setState(
        () => _error = 'Enter positive whole limits up to 9007199254740991. Choose Unlimited to remove a limit.',
      );
      return;
    }
    final change = QuotaChange(
      inventory: widget.inventory,
      identity: identity,
      byteLimit: _byteMode == 'unchanged' ? null : bytes,
      objectLimit: _objectMode == 'unchanged' ? null : objects,
    );
    if (change.validationError != null) {
      setState(() => _error = change.validationError);
      return;
    }
    final generation = ++_generation;
    setState(() {
      _reviewing = true;
      _error = null;
    });
    QuotaReview review;
    try {
      review = await api.reviewQuotaChange(change);
    } on QuotaException catch (error) {
      if (mounted && generation == _generation && _current) {
        setState(() => _error = error.userMessage);
      }
      return;
    } on Object {
      if (mounted && generation == _generation && _current) {
        setState(
          () => _error = 'The limits could not be reviewed. Refresh quotas before trying again.',
        );
      }
      return;
    } finally {
      if (mounted && generation == _generation && _current) {
        setState(() => _reviewing = false);
      }
    }
    if (!mounted || generation != _generation || !_current) return;
    final confirmation = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          QuotaReviewDialog(session: widget.session, review: review),
    );
    if (!mounted || confirmation == null || !_current) return;
    await ref
        .read(quotasControllerProvider.notifier)
        .execute(widget.session, review, confirmation);
    if (mounted &&
        _current &&
        ref.read(quotasControllerProvider).result?.outcome ==
            QuotaOutcome.verified) {
      Navigator.of(context).pop();
    }
  }
}

class QuotaReviewDialog extends ConsumerStatefulWidget {
  const QuotaReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final QuotaReview review;
  @override
  ConsumerState<QuotaReviewDialog> createState() => _QuotaReviewDialogState();
}

class _QuotaReviewDialogState extends ConsumerState<QuotaReviewDialog> {
  final _confirmation = TextEditingController();
  var _acknowledged = false, _expired = false;
  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  void _expire() {
    _expired = true;
    _confirmation.clear();
    _acknowledged = false;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (!identical(next, widget.session) && !_expired) setState(_expire);
    });
    if (!identical(widget.session, ref.watch(dashboardActiveSessionProvider))) {
      _expire();
    }
    final review = widget.review;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _expired ? 'Connection changed' : 'Review quota limits',
                style: TdTypography.titleMedium,
              ),
              const SizedBox(height: 16),
              if (_expired) ...[
                const Text(
                  'This review has expired. Close it and load quotas from the current server before reviewing another change.',
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  key: const Key('quota-review-close'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ] else ...[
                Text('Server: ${widget.session.endpoint}'),
                Text('Dataset: ${review.dataset.id}'),
                Text(review.identity.displayLabel),
                Text('Source: ${review.identity.source}'),
                if (review.identity.sid != null)
                  Text('SID: ${review.identity.sid}'),
                const SizedBox(height: 16),
                for (final text in [...review.changes, ...review.warnings])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(text),
                  ),
                Text('Exact confirmation: ${review.confirmation}'),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('quota-confirm-text'),
                  controller: _confirmation,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Type the exact confirmation',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  key: const Key('quota-confirm-acknowledge'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    'I understand quota limits can deny writes and object creation.',
                  ),
                  value: _acknowledged,
                  onChanged: (value) =>
                      setState(() => _acknowledged = value == true),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('quota-confirm-submit'),
                  onPressed:
                      _acknowledged && _confirmation.text == review.confirmation
                      ? () => Navigator.of(context).pop(_confirmation.text)
                      : null,
                  child: const Text('Apply reviewed limits'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const Key('quota-confirm-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

int? _whole(String value, {int maximum = 9007199254740991}) {
  if (!RegExp(r'^[0-9]+$').hasMatch(value)) return null;
  final parsed = int.tryParse(value);
  return parsed != null && parsed >= 0 && parsed <= maximum ? parsed : null;
}

String _limit(int value, {required bool objects}) =>
    value == 0 ? 'Unlimited' : quotaQuantity(value, objects: objects);
