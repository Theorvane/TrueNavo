import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/iscsi/iscsi_overview.dart';
import 'package:truenavo/features/iscsi/iscsi_target_rename_coordinator.dart';
import 'package:truenavo/features/iscsi/iscsi_target_rename_editor.dart';
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
              'name': {'type': 'string'},
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
        'iscsi.target.get_instance': _method(),
        'iscsi.targetextent.query': _method(),
        'iscsi.target.validate_name': _method(),
        if (advertiseUpdate) 'iscsi.target.update': _method(update: true),
        'service.query': _method(),
        'iscsi.global.sessions': _method(),
      },
    );
  }
  final bool advertiseUpdate;
  @override
  late final AdminCatalog adminCatalog;
  final target = <String, Object?>{
    'id': 3,
    'name': 'old',
    'alias': 'display',
    'mode': 'ISCSI',
    'groups': <Object?>[],
    'auth_networks': <Object?>[],
  };
  final mappings = <Map<String, Object?>>[];
  final calls = <AdminRequest>[];
  String state = 'STOPPED';
  bool sessions = false;
  bool rejectName = false;
  bool unknownUpdate = false;
  bool alterAliasAfterUpdate = false;

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'iscsi.target.get_instance':
        return AdminCompleted(
          request,
          value: Map<String, Object?>.from(target),
        );
      case 'iscsi.targetextent.query':
        return AdminCompleted(
          request,
          value: [for (final row in mappings) Map<String, Object?>.from(row)],
        );
      case 'service.query':
        return AdminCompleted(
          request,
          value: [
            {'service': 'iscsitarget', 'enable': false, 'state': state},
          ],
        );
      case 'iscsi.global.sessions':
        return AdminCompleted(
          request,
          value: sessions ? [<String, Object?>{}] : [],
        );
      case 'iscsi.target.validate_name':
        return AdminCompleted(request, value: rejectName ? 'invalid' : null);
      case 'iscsi.target.update':
        if (unknownUpdate) return AdminOutcomeUnknown(request);
        target['name'] = (request.arguments[1] as Map)['name'];
        if (alterAliasAfterUpdate) target['alias'] = 'changed';
        return AdminCompleted(
          request,
          value: Map<String, Object?>.from(target),
        );
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
    coordinator = IscsiTargetRenameCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiTargetRenameCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.target.update')
      .length;
}

void main() {
  test(
    'sends name only after two exact snapshots and name validations',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(3, 'new');
      expect(h.writes, 0);
      expect(review.confirmation, 'RENAME ISCSI TARGET #3 old TO new');
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiTargetRenameOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((call) => call.method.name == 'iscsi.target.update')
            .arguments,
        [
          3,
          {'name': 'new'},
        ],
      );
      expect(
        h.api.calls
            .where((call) => call.method.name == 'iscsi.target.validate_name')
            .length,
        2,
      );
      expect(
        h.api.calls
            .where((call) => call.method.name == 'iscsi.target.validate_name')
            .every((call) => call.arguments[1] == 3),
        isTrue,
      );
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiTargetRenameOutcome.rejected,
      );
    },
  );

  test(
    'groups, networks, mappings, service, sessions and bad name block review',
    () async {
      final h = _Harness();
      h.api.target['groups'] = [
        {'portal': 1},
      ];
      await expectLater(h.coordinator.prepare(3, 'new'), throwsStateError);
      h.api.target['groups'] = [];
      h.api.target['auth_networks'] = ['192.0.2.0/24'];
      await expectLater(h.coordinator.prepare(3, 'new'), throwsStateError);
      h.api.target['auth_networks'] = [];
      h.api.mappings.add({'id': 8, 'target': 3, 'extent': 2, 'lunid': 0});
      await expectLater(h.coordinator.prepare(3, 'new'), throwsStateError);
      h.api.mappings.clear();
      h.api.state = 'RUNNING';
      await expectLater(h.coordinator.prepare(3, 'new'), throwsStateError);
      h.api.state = 'STOPPED';
      h.api.sessions = true;
      await expectLater(h.coordinator.prepare(3, 'new'), throwsStateError);
      h.api.sessions = false;
      h.api.rejectName = true;
      await expectLater(h.coordinator.prepare(3, 'new'), throwsStateError);
      expect(h.writes, 0);
      expect(_Harness(advertiseUpdate: false).coordinator.available, isFalse);
    },
  );

  test(
    'drift, expiry, wrong phrase and session switch reject before write',
    () async {
      final h = _Harness();
      final first = await h.coordinator.prepare(3, 'new');
      h.api.target['alias'] = 'changed';
      expect(
        (await h.coordinator.execute(first, first.confirmation)).outcome,
        IscsiTargetRenameOutcome.rejected,
      );
      h.api.target['alias'] = 'display';
      final second = await h.coordinator.prepare(3, 'new');
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.coordinator.execute(second, second.confirmation)).outcome,
        IscsiTargetRenameOutcome.rejected,
      );
      final third = await h.coordinator.prepare(3, 'new');
      expect(
        (await h.coordinator.execute(third, 'wrong')).outcome,
        IscsiTargetRenameOutcome.rejected,
      );
      final fourth = await h.coordinator.prepare(3, 'new');
      h.current = false;
      expect(
        (await h.coordinator.execute(fourth, fourth.confirmation)).outcome,
        IscsiTargetRenameOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  test(
    'unknown outcome and changed non-name field fence subsequent writes',
    () async {
      final h = _Harness();
      h.api.unknownUpdate = true;
      final review = await h.coordinator.prepare(3, 'new');
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiTargetRenameOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);
      await expectLater(h.coordinator.prepare(3, 'again'), throwsStateError);

      final other = _Harness();
      other.api.alterAliasAfterUpdate = true;
      final otherReview = await other.coordinator.prepare(3, 'new');
      expect(
        (await other.coordinator.execute(
          otherReview,
          otherReview.confirmation,
        )).outcome,
        IscsiTargetRenameOutcome.unknown,
      );
      expect(other.coordinator.locked, isTrue);
    },
  );

  testWidgets('editor requires review and typed target-specific confirmation', (
    tester,
  ) async {
    final h = _Harness();
    final overview = IscsiOverview.parse(
      portals: [],
      initiators: [],
      targets: [h.api.target],
      extents: [],
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
              child: IscsiTargetRenameEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-target-rename-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 old').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('iscsi-target-rename-name')),
      'new',
    );
    await tester.tap(find.byKey(const Key('iscsi-target-rename-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-target-rename-confirmation')),
      'RENAME ISCSI TARGET #3 old TO new',
    );
    await tester.tap(find.byKey(const Key('iscsi-target-rename-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });
}
