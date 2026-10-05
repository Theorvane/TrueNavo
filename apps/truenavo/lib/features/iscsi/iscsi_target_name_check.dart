import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../dashboard/dashboard_controller.dart';

/// On-demand server validation for a proposed *new* target name only.
class IscsiTargetNameCheck extends ConsumerStatefulWidget {
  const IscsiTargetNameCheck({super.key});

  @override
  ConsumerState<IscsiTargetNameCheck> createState() =>
      _IscsiTargetNameCheckState();
}

class _IscsiTargetNameCheckState extends ConsumerState<IscsiTargetNameCheck> {
  final _name = TextEditingController();
  Object? _requestSession;
  Object? _resultSession;
  String? _resultName;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _check(
    Object session,
    AuthenticatedAdminSession api,
    AdminMethodSpec method,
  ) async {
    final name = _name.text;
    if (name.isEmpty ||
        name.length > 120 ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      setState(() {
        _resultSession = session;
        _resultName = name;
        _message = 'Enter a non-empty target name of at most 120 characters.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _requestSession = session;
      _resultSession = null;
      _message = null;
    });
    String message;
    try {
      final result = await api.invokeAdmin(
        AdminRequest(method: method, arguments: [name]),
      );
      message = switch (result) {
        AdminCompleted(value: null) => 'The server accepts this name at this moment. It is not reserved or a target creation.',
        AdminCompleted(value: String()) =>
          'The server rejected this name. No target was created.',
        _ => 'Name validation is unavailable for this account.',
      };
    } on Object {
      message = 'Name validation failed. No target was created.';
    }
    if (!mounted ||
        !identical(_requestSession, session) ||
        !identical(ref.read(dashboardActiveSessionProvider), session) ||
        _name.text != name) {
      return;
    }
    setState(() {
      _busy = false;
      _resultSession = session;
      _resultName = name;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final repository = session?.repository;
    final api = repository is AuthenticatedAdminSession
        ? repository as AuthenticatedAdminSession
        : null;
    final method = api?.adminCatalog.method('iscsi.target.validate_name');
    final available =
        session?.endpoint != null &&
        api?.adminCatalog.versionSupported == true &&
        method?.supported == true;
    final busy = _busy && identical(session, _requestSession);
    final showResult =
        identical(session, _resultSession) && _resultName == _name.text;
    return TdPanel(
      title: 'Check new target name',
      description: 'Ask the server to validate a proposed name. This does not create or reserve a target; check again during a future creation review.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('iscsi-target-name-draft'),
            controller: _name,
            enabled: available && !busy,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Proposed new target name',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _message = null),
          ),
          FilledButton(
            key: const Key('iscsi-target-name-check'),
            onPressed:
                available &&
                    !busy &&
                    session != null &&
                    api != null &&
                    method != null
                ? () => _check(session, api, method)
                : null,
            child: const Text('Check name'),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: CircularProgressIndicator(),
            ),
          if (!available)
            const Text('This server does not expose target-name validation.'),
          if (showResult && _message != null) Text(_message!),
        ],
      ),
    );
  }
}
