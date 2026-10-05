import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/iscsi/iscsi_extent_comment_coordinator.dart';
import 'package:truenavo/features/iscsi/iscsi_extent_comment_editor.dart';
import 'package:truenavo/features/iscsi/iscsi_overview.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
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
      : [
          {'_name_': 'id', '_required_': true, 'type': 'integer'},
        ],
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
        'iscsi.extent.get_instance': _method(),
        if (advertiseUpdate) 'iscsi.extent.update': _method(update: true),
      },
    );
  }

  final bool advertiseUpdate;
  @override
  late final AdminCatalog adminCatalog;
  final row = <String, Object?>{
    'id': 5,
    'name': 'important-disk',
    'type': 'DISK',
    'comment': 'old',
    'enabled': true,
    'ro': false,
    'disk': 'private-backing-disk',
    'path': '/mnt/private',
    'serial': 'hidden-serial',
  };
  bool unknownWrite = false;
  bool driftAfterWrite = false;
  final calls = <AdminRequest>[];

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'iscsi.extent.get_instance':
        return AdminCompleted(request, value: Map<String, Object?>.from(row));
      case 'iscsi.extent.update':
        if (unknownWrite) return AdminOutcomeUnknown(request);
        row['comment'] = (request.arguments[1] as Map)['comment'];
        if (driftAfterWrite) row['disk'] = 'different-backing-disk';
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
    coordinator = IscsiExtentCommentCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiExtentCommentCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.extent.update')
      .length;
}

void main() {
  test(
    'review sends only comment and confirms full non-comment state',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(5, 'new');
      expect(review.before, 'old');
      expect(h.writes, 0);
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiExtentCommentOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((c) => c.method.name == 'iscsi.extent.update')
            .arguments,
        [
          5,
          {'comment': 'new'},
        ],
      );
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiExtentCommentOutcome.rejected,
      );
    },
  );

  test(
    'backing drift, altered comment and wrong phrase reject before write',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(5, 'new');
      h.api.row['disk'] = 'another-disk';
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiExtentCommentOutcome.rejected,
      );
      h.api.row['disk'] = 'private-backing-disk';
      final next = await h.coordinator.prepare(5, 'new');
      h.api.row['comment'] = 'external';
      expect(
        (await h.coordinator.execute(next, next.confirmation)).outcome,
        IscsiExtentCommentOutcome.rejected,
      );
      h.api.row['comment'] = 'old';
      final last = await h.coordinator.prepare(5, 'new');
      expect(
        (await h.coordinator.execute(last, 'wrong')).outcome,
        IscsiExtentCommentOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  test(
    'post-write drift and unknown receipt fence session without retry',
    () async {
      final h = _Harness();
      h.api.driftAfterWrite = true;
      final review = await h.coordinator.prepare(5, 'new');
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiExtentCommentOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);
      await expectLater(h.coordinator.prepare(5, 'again'), throwsStateError);
      expect(h.writes, 1);

      final next = _Harness();
      next.api.unknownWrite = true;
      final nextReview = await next.coordinator.prepare(5, 'new');
      expect(
        (await next.coordinator.execute(
          nextReview,
          nextReview.confirmation,
        )).outcome,
        IscsiExtentCommentOutcome.unknown,
      );
      expect(next.writes, 1);
    },
  );

  test(
    'expired, changed-session and incomplete preflight never write',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(5, 'new');
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiExtentCommentOutcome.rejected,
      );
      final next = await h.coordinator.prepare(5, 'new');
      h.current = false;
      expect(
        (await h.coordinator.execute(next, next.confirmation)).outcome,
        IscsiExtentCommentOutcome.rejected,
      );
      expect(h.writes, 0);
      final malformed = _Harness();
      malformed.api.row['path'] = '[truncated]';
      await expectLater(
        malformed.coordinator.prepare(5, 'new'),
        throwsStateError,
      );
      expect(malformed.writes, 0);
      expect(_Harness(advertiseUpdate: false).coordinator.available, isFalse);
    },
  );

  testWidgets(
    'editor holds review until exact confirmation and hides backing data',
    (tester) async {
      final h = _Harness();
      final overview = IscsiOverview.parse(
        portals: [],
        initiators: [],
        targets: [],
        extents: [h.api.row],
        mappings: [],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          ],
          child: MaterialApp(
            theme: TrueNavoTheme.dark(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: IscsiExtentCommentEditor(overview: overview),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('important-disk (#5)').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('iscsi-extent-comment-value')),
        'new',
      );
      await tester.tap(find.byKey(const Key('iscsi-extent-comment-review')));
      await tester.pumpAndSettle();
      expect(h.writes, 0);
      expect(find.textContaining('private-backing-disk'), findsNothing);
      expect(find.textContaining('hidden-serial'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('iscsi-extent-comment-confirmation')),
        'UPDATE EXTENT 5',
      );
      await tester.tap(find.byKey(const Key('iscsi-extent-comment-submit')));
      await tester.pumpAndSettle();
      expect(h.writes, 1);
      expect(h.api.row['comment'], 'new');
    },
  );

  testWidgets('long extent label fits a narrow editor', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = _Harness();
    h.api.row['name'] = 'extent-${'x' * 55}';
    final overview = IscsiOverview.parse(
      portals: [],
      initiators: [],
      targets: [],
      extents: [h.api.row],
      mappings: [],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: IscsiExtentCommentEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(h.writes, 0);
  });
}
