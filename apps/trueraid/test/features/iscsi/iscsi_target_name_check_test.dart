import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_target_name_check.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method() => {
  'accepts': [
    {'_name_': 'name', '_required_': true, 'type': 'string'},
    {'_name_': 'existing_id', '_required_': false, 'type': 'integer'},
  ],
  'returns': [
    {
      'anyOf': [
        {'type': 'string'},
        {'type': 'null'},
      ],
    },
  ],
  'job': false,
  'filterable': false,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'roles': ['SHARING_ISCSI_TARGET_WRITE'],
};

class _Fake implements SessionRepository, AuthenticatedAdminSession {
  _Fake({this.advertise = true}) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {if (advertise) 'iscsi.target.validate_name': _method()},
    );
  }
  final bool advertise;
  @override
  late final AdminCatalog adminCatalog;
  final calls = <AdminRequest>[];
  Future<AdminResult> Function(AdminRequest)? responder;

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    return responder?.call(request) ?? AdminCompleted(request, value: null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AuthenticatedSession _session(_Fake fake) => AuthenticatedSession(
  profileId: 'fixture',
  repository: fake,
  availableMethodNames: const {},
  endpoint: 'wss://fixture.example/api/current',
);

void main() {
  testWidgets('name check is on demand and never creates a target', (
    tester,
  ) async {
    final fake = _Fake();
    final session = _session(fake);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => session),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(body: IscsiTargetNameCheck()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fake.calls, isEmpty);
    final draft = find.byKey(const Key('iscsi-target-name-draft'));
    final button = find.byKey(const Key('iscsi-target-name-check'));
    await tester.enterText(draft, 'backup-target');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(fake.calls.single.method.name, 'iscsi.target.validate_name');
    expect(fake.calls.single.arguments, ['backup-target']);
    expect(find.textContaining('server accepts this name'), findsOneWidget);
    await tester.enterText(draft, 'different');
    await tester.pumpAndSettle();
    expect(find.textContaining('server accepts this name'), findsNothing);
    fake.responder = (request) async =>
        AdminCompleted(request, value: 'duplicate');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.textContaining('server rejected this name'), findsOneWidget);
    expect(find.textContaining('duplicate'), findsNothing);
    expect(
      fake.calls.every(
        (call) => call.method.name == 'iscsi.target.validate_name',
      ),
      isTrue,
    );
  });

  testWidgets('unsupported method disables validation', (tester) async {
    final fake = _Fake(advertise: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => _session(fake)),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(body: IscsiTargetNameCheck()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('iscsi-target-name-check')),
          )
          .onPressed,
      isNull,
    );
    expect(fake.calls, isEmpty);
  });

  testWidgets('changing the draft clears a previous validation result', (
    tester,
  ) async {
    final fake = _Fake();
    final pending = Completer<AdminResult>();
    fake.responder = (_) => pending.future;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => _session(fake)),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(body: IscsiTargetNameCheck()),
        ),
      ),
    );
    final draft = find.byKey(const Key('iscsi-target-name-draft'));
    await tester.enterText(draft, 'first');
    await tester.tap(find.byKey(const Key('iscsi-target-name-check')));
    await tester.pump();
    expect(fake.calls.length, 1);
    // The field is disabled during the request. A later edit must clear the
    // previous result rather than presenting it for a different name.
    pending.complete(AdminCompleted(fake.calls.single, value: null));
    await tester.pumpAndSettle();
    await tester.enterText(draft, 'second');
    await tester.pumpAndSettle();
    expect(find.textContaining('server accepts this name'), findsNothing);
  });
}
