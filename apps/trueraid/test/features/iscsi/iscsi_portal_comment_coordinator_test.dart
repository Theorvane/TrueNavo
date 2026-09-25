import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
import 'package:trueraid/features/iscsi/iscsi_portal_comment_coordinator.dart';
import 'package:trueraid/features/iscsi/iscsi_portal_comment_editor.dart';
import 'package:trueraid/features/iscsi/iscsi_threshold_coordinator.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method({bool update = false}) => {
  'accepts': update
      ? [
          {'_name_': 'id', '_required_': true, 'type': 'integer'},
          {
            '_name_': 'data',
            '_required_': true,
            'type': 'object',
            'properties': {
              'comment': {'type': 'string'},
            },
          },
        ]
      : <Object?>[],
  'returns': [
    {'type': 'object', 'properties': <String, Object?>{}},
  ],
  'job': false,
  'filterable': false,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'roles': ['FULL_ADMIN'],
};

class _Fake implements SessionRepository, AuthenticatedAdminSession {
  _Fake({this.advertiseUpdate = true}) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        'iscsi.portal.query': _method(),
        if (advertiseUpdate) 'iscsi.portal.update': _method(update: true),
        'iscsi.global.config': _method(),
        'iscsi.global.sessions': _method(),
        'service.query': _method(),
        'iscsi.global.update': _method(update: true),
      },
    );
  }
  final bool advertiseUpdate;
  @override
  late final AdminCatalog adminCatalog;
  String comment = 'old';
  int tag = 7;
  String address = '192.0.2.10';
  bool unknownWrite = false;
  bool driftAfterWrite = false;
  final calls = <AdminRequest>[];

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'iscsi.portal.query':
        return AdminCompleted(
          request,
          value: [
            {
              'id': 5,
              'tag': tag,
              'listen': [
                {'ip': address, 'port': 3260},
              ],
              'comment': comment,
            },
          ],
        );
      case 'iscsi.portal.update':
        if (unknownWrite) return AdminOutcomeUnknown(request);
        comment = (request.arguments[1] as Map)['comment'] as String;
        if (driftAfterWrite) address = '192.0.2.11';
        return AdminCompleted(request, value: null);
      default:
        throw StateError('Unexpected fake call');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({bool advertiseUpdate = true})
    : api = _Fake(advertiseUpdate: advertiseUpdate) {
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    coordinator = IscsiPortalCommentCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiPortalCommentCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.portal.update')
      .length;
}

void main() {
  test('comment-only review sends one field and verifies readback', () async {
    final h = _Harness();
    final review = await h.coordinator.prepare(5, 'new description');
    expect(review.before, 'old');
    expect(h.writes, 0);
    final result = await h.coordinator.execute(review, review.confirmation);
    expect(result.outcome, IscsiPortalCommentOutcome.completed);
    expect(h.writes, 1);
    expect(
      h.api.calls
          .singleWhere((call) => call.method.name == 'iscsi.portal.update')
          .arguments,
      [
        5,
        {'comment': 'new description'},
      ],
    );
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalCommentOutcome.rejected,
    );
    expect(h.writes, 1);
  });

  test('listener or tag drift and wrong phrase reject before write', () async {
    final h = _Harness();
    final review = await h.coordinator.prepare(5, 'new');
    h.api.address = '192.0.2.11';
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalCommentOutcome.rejected,
    );
    h.api.address = '192.0.2.10';
    final next = await h.coordinator.prepare(5, 'new');
    h.api.tag = 8;
    expect(
      (await h.coordinator.execute(next, next.confirmation)).outcome,
      IscsiPortalCommentOutcome.rejected,
    );
    h.api.tag = 7;
    final last = await h.coordinator.prepare(5, 'new');
    expect(
      (await h.coordinator.execute(last, 'wrong')).outcome,
      IscsiPortalCommentOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('post-write listener drift fences all iSCSI editors', () async {
    final h = _Harness();
    h.api.driftAfterWrite = true;
    final review = await h.coordinator.prepare(5, 'new');
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalCommentOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
    final threshold = IscsiThresholdCoordinator(
      session: h.session,
      api: h.api,
      lock: ServerOperationLock(),
      isCurrent: () => true,
      now: () => DateTime.utc(2026),
    );
    expect(threshold.locked, isTrue);
    await expectLater(threshold.prepare(30), throwsStateError);
    expect(h.writes, 1);
  });

  test('unknown receipt and expired review do not retry', () async {
    final h = _Harness();
    final review = await h.coordinator.prepare(5, 'new');
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalCommentOutcome.rejected,
    );
    expect(h.writes, 0);
    final next = await h.coordinator.prepare(5, 'new');
    h.api.unknownWrite = true;
    expect(
      (await h.coordinator.execute(next, next.confirmation)).outcome,
      IscsiPortalCommentOutcome.unknown,
    );
    expect(h.writes, 1);
    await expectLater(h.coordinator.prepare(5, 'again'), throwsStateError);
  });

  test('missing method and changed connection send nothing', () async {
    final missing = _Harness(advertiseUpdate: false);
    expect(missing.coordinator.available, isFalse);
    await expectLater(missing.coordinator.prepare(5, 'new'), throwsStateError);
    final h = _Harness();
    final review = await h.coordinator.prepare(5, 'new');
    h.current = false;
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalCommentOutcome.rejected,
    );
    expect(missing.writes + h.writes, 0);
  });

  testWidgets('editor requires review and confirmation', (tester) async {
    final h = _Harness();
    final overview = IscsiOverview.parse(
      portals: [
        {
          'id': 5,
          'listen': [
            {'ip': '192.0.2.10', 'port': 3260},
          ],
          'comment': 'old',
        },
      ],
      initiators: [],
      targets: [],
      extents: [],
      mappings: [],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: IscsiPortalCommentEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Portal #5').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('iscsi-portal-comment-value')),
      'new',
    );
    await tester.tap(find.byKey(const Key('iscsi-portal-comment-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.textContaining('Before: old'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('iscsi-portal-comment-confirmation')),
      'UPDATE PORTAL 5',
    );
    await tester.tap(find.byKey(const Key('iscsi-portal-comment-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(h.api.comment, 'new');
  });
}
