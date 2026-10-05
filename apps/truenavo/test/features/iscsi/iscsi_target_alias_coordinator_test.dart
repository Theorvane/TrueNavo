import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/iscsi/iscsi_overview.dart';
import 'package:truenavo/features/iscsi/iscsi_target_alias_coordinator.dart';
import 'package:truenavo/features/iscsi/iscsi_target_alias_editor.dart';
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
              'alias': {'type': 'string'},
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
    'name': 'target',
    'alias': 'old-label',
    'mode': 'ISCSI',
    'groups': <Object?>[],
    'auth_networks': <Object?>[],
  };
  final mappings = <Map<String, Object?>>[];
  final calls = <AdminRequest>[];
  String state = 'STOPPED';
  bool sessions = false;
  bool unknownUpdate = false;
  bool alterNameAfterUpdate = false;

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
      case 'iscsi.target.update':
        if (unknownUpdate) return AdminOutcomeUnknown(request);
        target['alias'] = (request.arguments[1] as Map)['alias'];
        if (alterNameAfterUpdate) target['name'] = 'other';
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
    coordinator = IscsiTargetAliasCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiTargetAliasCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.target.update')
      .length;
}

void main() {
  test('sets alias only after review and exact independent readback', () async {
    final h = _Harness();
    final review = await h.coordinator.prepare(3, 'new-label');
    expect(h.writes, 0);
    expect(review.confirmation, 'UPDATE ISCSI ALIAS #3 target');
    final result = await h.coordinator.execute(review, review.confirmation);
    expect(result.outcome, IscsiTargetAliasOutcome.completed);
    expect(h.writes, 1);
    expect(
      h.api.calls
          .singleWhere((call) => call.method.name == 'iscsi.target.update')
          .arguments,
      [
        3,
        {'alias': 'new-label'},
      ],
    );
    expect(h.api.target['name'], 'target');
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiTargetAliasOutcome.rejected,
    );
  });

  test('clears alias with explicit null instead of blank string', () async {
    final h = _Harness();
    await expectLater(h.coordinator.prepare(3, ''), throwsStateError);
    final review = await h.coordinator.prepare(3, null);
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiTargetAliasOutcome.completed,
    );
    expect(
      h.api.calls
          .singleWhere((call) => call.method.name == 'iscsi.target.update')
          .arguments,
      [
        3,
        {'alias': null},
      ],
    );
  });

  test(
    'access groups, mappings, service and sessions prevent submission',
    () async {
      final h = _Harness();
      h.api.target['groups'] = [
        {'portal': 1},
      ];
      await expectLater(h.coordinator.prepare(3, 'new'), throwsStateError);
      h.api.target['groups'] = [];
      h.api.mappings.add({'id': 8, 'target': 3, 'extent': 2, 'lunid': 0});
      await expectLater(h.coordinator.prepare(3, 'new'), throwsStateError);
      h.api.mappings.clear();
      h.api.state = 'RUNNING';
      await expectLater(h.coordinator.prepare(3, 'new'), throwsStateError);
      h.api.state = 'STOPPED';
      h.api.sessions = true;
      await expectLater(h.coordinator.prepare(3, 'new'), throwsStateError);
      expect(h.writes, 0);
      expect(_Harness(advertiseUpdate: false).coordinator.available, isFalse);
    },
  );

  test('drift, expiry and wrong confirmation reject without write', () async {
    final h = _Harness();
    final first = await h.coordinator.prepare(3, 'new');
    h.api.target['name'] = 'changed';
    expect(
      (await h.coordinator.execute(first, first.confirmation)).outcome,
      IscsiTargetAliasOutcome.rejected,
    );
    h.api.target['name'] = 'target';
    final second = await h.coordinator.prepare(3, 'new');
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(second, second.confirmation)).outcome,
      IscsiTargetAliasOutcome.rejected,
    );
    final third = await h.coordinator.prepare(3, 'new');
    expect(
      (await h.coordinator.execute(third, 'wrong')).outcome,
      IscsiTargetAliasOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test(
    'unknown response or name drift after write fences future edits',
    () async {
      final h = _Harness();
      h.api.unknownUpdate = true;
      final review = await h.coordinator.prepare(3, 'new');
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiTargetAliasOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);
      await expectLater(h.coordinator.prepare(3, 'another'), throwsStateError);

      final other = _Harness();
      other.api.alterNameAfterUpdate = true;
      final otherReview = await other.coordinator.prepare(3, 'new');
      expect(
        (await other.coordinator.execute(
          otherReview,
          otherReview.confirmation,
        )).outcome,
        IscsiTargetAliasOutcome.unknown,
      );
      expect(other.coordinator.locked, isTrue);
    },
  );

  testWidgets('editor requires review and exact confirmation', (tester) async {
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
              child: IscsiTargetAliasEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-target-alias-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 target').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('iscsi-target-alias-value')),
      'new',
    );
    await tester.tap(find.byKey(const Key('iscsi-target-alias-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-target-alias-confirmation')),
      'UPDATE ISCSI ALIAS #3 target',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-target-alias-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-target-alias-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });
}
