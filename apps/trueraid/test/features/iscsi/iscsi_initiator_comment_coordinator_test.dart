import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_initiator_comment_coordinator.dart';
import 'package:trueraid/features/iscsi/iscsi_initiator_comment_editor.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
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
        'iscsi.initiator.query': _method(),
        if (advertiseUpdate) 'iscsi.initiator.update': _method(update: true),
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
  List<String> names = ['iqn.example:client'];
  bool unknownWrite = false;
  bool driftAfterWrite = false;
  final calls = <AdminRequest>[];

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'iscsi.initiator.query':
        return AdminCompleted(
          request,
          value: [
            {'id': 7, 'initiators': names, 'comment': comment},
          ],
        );
      case 'iscsi.initiator.update':
        if (unknownWrite) return AdminOutcomeUnknown(request);
        comment = (request.arguments[1] as Map)['comment'] as String;
        if (driftAfterWrite) names = ['iqn.example:someone-else'];
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
    coordinator = IscsiInitiatorCommentCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => DateTime.utc(2026),
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiInitiatorCommentCoordinator coordinator;
  bool current = true;
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.initiator.update')
      .length;
}

void main() {
  test(
    'comment-only review sends one field and verifies independent readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(7, 'new description');
      expect(review.before, 'old');
      expect(h.writes, 0);
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiCommentOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((call) => call.method.name == 'iscsi.initiator.update')
            .arguments,
        [
          7,
          {'comment': 'new description'},
        ],
      );
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiCommentOutcome.rejected,
      );
      expect(h.writes, 1);
    },
  );

  test('drift and incorrect confirmation reject before write', () async {
    final h = _Harness();
    final review = await h.coordinator.prepare(7, 'new');
    h.api.names = ['iqn.example:changed'];
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiCommentOutcome.rejected,
    );
    h.api.names = ['iqn.example:client'];
    final next = await h.coordinator.prepare(7, 'new');
    expect(
      (await h.coordinator.execute(next, 'wrong')).outcome,
      IscsiCommentOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test(
    'post-write access drift is unknown and fences both iSCSI editors',
    () async {
      final h = _Harness();
      h.api.driftAfterWrite = true;
      final review = await h.coordinator.prepare(7, 'new');
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiCommentOutcome.unknown,
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
    },
  );

  test('missing method and changed session send nothing', () async {
    final missing = _Harness(advertiseUpdate: false);
    expect(missing.coordinator.available, isFalse);
    await expectLater(missing.coordinator.prepare(7, 'new'), throwsStateError);
    final h = _Harness();
    final review = await h.coordinator.prepare(7, 'new');
    h.current = false;
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiCommentOutcome.rejected,
    );
    expect(missing.writes + h.writes, 0);
  });
  testWidgets(
    'editor requires review and confirmation before one comment write',
    (tester) async {
      final h = _Harness();
      final overview = IscsiOverview.parse(
        portals: <Object?>[],
        targets: <Object?>[],
        extents: <Object?>[],
        mappings: <Object?>[],
        initiators: [
          {
            'id': 7,
            'initiators': ['iqn.example:client'],
            'comment': 'old',
          },
        ],
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
                child: IscsiInitiatorCommentEditor(overview: overview),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(h.writes, 0);
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Group #7').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('iscsi-comment-value')),
        'new',
      );
      await tester.tap(find.byKey(const Key('iscsi-comment-review')));
      await tester.pumpAndSettle();
      expect(h.writes, 0);
      expect(find.textContaining('Before: old'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('iscsi-comment-confirmation')),
        'UPDATE INITIATOR 7',
      );
      await tester.tap(find.byKey(const Key('iscsi-comment-submit')));
      await tester.pumpAndSettle();
      expect(h.writes, 1);
      expect(h.api.comment, 'new');
    },
  );
}
