import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/iscsi/iscsi_threshold_coordinator.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method({bool update = false}) => {
  'accepts': update
      ? [
          {
            '_name_': 'data',
            '_required_': true,
            'type': 'object',
            'properties': {
              'pool_avail_threshold': {
                'type': ['integer', 'null'],
              },
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
        'iscsi.global.config': _method(),
        'iscsi.global.sessions': _method(),
        'service.query': _method(),
        if (advertiseUpdate) 'iscsi.global.update': _method(update: true),
      },
    );
  }
  final bool advertiseUpdate;
  @override
  late final AdminCatalog adminCatalog;
  int? threshold = 20;
  bool activeSession = false;
  String state = 'STOPPED';
  bool unknownWrite = false;
  final calls = <AdminRequest>[];

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'iscsi.global.config':
        return AdminCompleted(
          request,
          value: {
            'id': 1,
            'basename': 'iqn.example',
            'isns_servers': <String>[],
            'listen_port': 3260,
            'pool_avail_threshold': threshold,
            'alua': false,
            'iser': false,
          },
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
          value: activeSession ? [<String, Object?>{}] : [],
        );
      case 'iscsi.global.update':
        if (unknownWrite) return AdminOutcomeUnknown(request);
        threshold =
            (request.arguments.single as Map)['pool_avail_threshold'] as int?;
        return AdminCompleted(request, value: null);
      default:
        throw StateError('Unexpected fixture method');
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
    coordinator = IscsiThresholdCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => DateTime.utc(2026),
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiThresholdCoordinator coordinator;
  bool current = true;
  int get writes =>
      api.calls.where((r) => r.method.name == 'iscsi.global.update').length;
}

void main() {
  test(
    'review and one-time submission send only threshold, then reread',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(30);
      expect(review.before, 20);
      expect(review.proposed, 30);
      expect(h.writes, 0);
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiThresholdOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((r) => r.method.name == 'iscsi.global.update')
            .arguments,
        [
          {'pool_avail_threshold': 30},
        ],
      );
      expect(h.api.threshold, 30);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiThresholdOutcome.rejected,
      );
      expect(h.writes, 1);
    },
  );

  test(
    'active clients and running service block review before write',
    () async {
      final h = _Harness();
      h.api.activeSession = true;
      await expectLater(h.coordinator.prepare(30), throwsStateError);
      h.api.activeSession = false;
      h.api.state = 'RUNNING';
      await expectLater(h.coordinator.prepare(30), throwsStateError);
      expect(h.writes, 0);
    },
  );

  test('configuration drift and wrong confirmation never submit', () async {
    final h = _Harness();
    final review = await h.coordinator.prepare(30);
    h.api.threshold = 40;
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiThresholdOutcome.rejected,
    );
    expect(h.writes, 0);
    h.api.threshold = 20;
    final next = await h.coordinator.prepare(30);
    expect(
      (await h.coordinator.execute(next, 'wrong')).outcome,
      IscsiThresholdOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('unknown submitted outcome fences future reviews', () async {
    final h = _Harness();
    h.api.unknownWrite = true;
    final review = await h.coordinator.prepare(30);
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiThresholdOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
    await expectLater(h.coordinator.prepare(35), throwsStateError);
    expect(h.writes, 1);
    final recreated = IscsiThresholdCoordinator(
      session: h.session,
      api: h.api,
      lock: ServerOperationLock(),
      isCurrent: () => true,
      now: () => DateTime.utc(2026),
    );
    expect(recreated.locked, isTrue);
    await expectLater(recreated.prepare(35), throwsStateError);
    expect(h.writes, 1);
  });

  test('missing update method and changed session send no write', () async {
    final missing = _Harness(advertiseUpdate: false);
    expect(missing.coordinator.available, isFalse);
    await expectLater(missing.coordinator.prepare(30), throwsStateError);
    expect(missing.writes, 0);
    final h = _Harness();
    final review = await h.coordinator.prepare(30);
    h.current = false;
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiThresholdOutcome.rejected,
    );
    expect(h.writes, 0);
  });
}
