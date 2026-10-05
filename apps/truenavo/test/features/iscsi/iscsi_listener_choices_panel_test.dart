import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/iscsi/iscsi_listener_choices_panel.dart';
import 'package:truenavo/features/iscsi/iscsi_overview.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method() => {
  'accepts': <Object?>[],
  'returns': [
    {'type': 'object', 'properties': <String, Object?>{}},
  ],
  'job': false,
  'filterable': false,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'roles': ['READONLY_ADMIN'],
};

class _Fake implements SessionRepository, AuthenticatedAdminSession {
  _Fake({this.advertise = true}) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {if (advertise) 'iscsi.portal.listen_ip_choices': _method()},
    );
  }
  final bool advertise;
  @override
  late final AdminCatalog adminCatalog;
  final calls = <AdminRequest>[];

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    return AdminCompleted(
      request,
      value: {
        '192.0.2.10': 'private HA backing address',
        '192.0.2.20': 'other interface',
      },
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

IscsiOverview _overview() => IscsiOverview.parse(
  portals: [
    {
      'id': 5,
      'listen': [
        {'ip': '192.0.2.10', 'port': 3260},
        {'ip': '192.0.2.99', 'port': 3260},
      ],
    },
  ],
  initiators: [],
  targets: [],
  extents: [],
  mappings: [],
);

void main() {
  testWidgets(
    'loads only on request and compares configured listener entries',
    (tester) async {
      final fake = _Fake();
      final session = AuthenticatedSession(
        profileId: 'fixture',
        repository: fake,
        availableMethodNames: const {},
        endpoint: 'wss://fixture.example/api/current',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardActiveSessionProvider.overrideWith((ref) => session),
          ],
          child: MaterialApp(
            theme: TrueNavoTheme.dark(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: IscsiListenerChoicesPanel(overview: _overview()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fake.calls, isEmpty);
      expect(
        find.text('Choices are loaded only when requested.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('iscsi-load-listener-choices')));
      await tester.pumpAndSettle();
      expect(fake.calls.single.method.name, 'iscsi.portal.listen_ip_choices');
      expect(fake.calls.single.arguments, isEmpty);
      expect(
        find.textContaining('1 of 2 configured listener entries appear'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('iscsi-listener-choice-ratio')),
            )
            .value,
        0.5,
      );
      expect(find.textContaining('Not in current choice list'), findsOneWidget);
      expect(find.textContaining('private HA backing address'), findsNothing);
      await tester.tap(find.byKey(const Key('iscsi-hide-listener-choices')));
      await tester.pumpAndSettle();
      expect(
        find.text('Choices are loaded only when requested.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('missing method disables loading without any request', (
    tester,
  ) async {
    final fake = _Fake(advertise: false);
    final session = AuthenticatedSession(
      profileId: 'fixture',
      repository: fake,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => session),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: Scaffold(
            body: IscsiListenerChoicesPanel(overview: _overview()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('iscsi-load-listener-choices')),
          )
          .onPressed,
      isNull,
    );
    expect(fake.calls, isEmpty);
  });
}
