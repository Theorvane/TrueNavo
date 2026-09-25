import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _methods = {
  'boot.environment.query',
  'boot.environment.clone',
  'boot.environment.keep',
  'boot.environment.activate',
  'boot.environment.destroy',
  'failover.licensed',
  'core.get_jobs',
  'pool.dataset.create',
};
const _secret = 'synthetic-remote-details-never-display';
Map<String, Object?> _row(
  String id, {
  bool active = false,
  bool activated = false,
  bool keep = false,
}) => {
  'id': id,
  'dataset': 'boot-pool/ROOT/$id',
  'created': '2026-09-10T12:00:00',
  'used_bytes': 1073741824,
  'used': '1 GiB',
  'active': active,
  'activated': activated,
  'keep': keep,
  'can_activate': true,
};
Matcher _reason(BootEnvironmentsExceptionReason reason) =>
    isA<BootEnvironmentsException>().having((e) => e.reason, 'reason', reason);

void main() {
  test(
    'disconnected and unverified releases fail before inventory reads',
    () async {
      final transport = _Transport();
      final disconnected = TrueNasSessionRepository(
        connector: _Connector(transport),
      );
      addTearDown(disconnected.close);
      expect(disconnected.bootEnvironmentsCapabilities.connected, isFalse);
      await expectLater(
        disconnected.loadBootEnvironments(),
        throwsA(_reason(BootEnvironmentsExceptionReason.notAuthenticated)),
      );
      expect(transport.requests, isEmpty);
      for (final version in ['25.04.2', '26.0.0', '25.10-BETA', '25.10.1\n']) {
        final h = await _connected(version: version);
        expect(h.repo.bootEnvironmentsCapabilities.supported, isFalse);
        await expectLater(
          h.repo.loadBootEnvironments(),
          throwsA(_reason(BootEnvironmentsExceptionReason.unsupportedVersion)),
        );
        expect(h.wire.requests, hasLength(4));
      }
    },
  );

  test(
    'read capability is independent of mutation method availability',
    () async {
      final h = await _connected(
        methods: {
          'boot.environment.query',
          'failover.licensed',
          'core.get_jobs',
        },
      );
      expect(h.repo.bootEnvironmentsCapabilities.supported, isTrue);
      for (final action in BootEnvironmentAction.values) {
        expect(h.repo.bootEnvironmentsCapabilities.supports(action), isFalse);
      }
      expect((await h.repo.loadBootEnvironments()).environments, hasLength(2));
      expect(h.wire.writes, isEmpty);
    },
  );

  test('inventory is bounded, immutable, accurate, and read-only', () async {
    final h = await _connected();
    final inventory = await h.repo.loadBootEnvironments();
    expect(inventory.environments, hasLength(2));
    expect(inventory.environments.singleWhere((e) => e.active).id, '25.10.1');
    expect(
      inventory.environments.singleWhere((e) => e.activated).id,
      '25.10.1',
    );
    expect(inventory.environments.first.usedBytes, 1073741824);
    expect(() => inventory.environments.clear(), throwsUnsupportedError);
    expect(inventory.blockedReason, isNull);
    expect(h.wire.requests.last['params'], [
      [],
      {'limit': 129},
    ]);
    expect(
      h.wire.requests.singleWhere(
        (r) => r['method'] == 'core.get_jobs',
      )['params'],
      [
        [
          [
            'state',
            'in',
            ['WAITING', 'RUNNING'],
          ],
        ],
        {
          'limit': 129,
          'select': ['id', 'method', 'state'],
        },
      ],
    );
    expect(h.wire.writes, isEmpty);
  });

  for (final action in [
    BootEnvironmentAction.clone,
    BootEnvironmentAction.keep,
    BootEnvironmentAction.activate,
    BootEnvironmentAction.delete,
  ]) {
    test(
      '$action sends one exact synchronous operation and verifies independently',
      () async {
        final h = await _connected();
        final review = await _review(h, action);
        final readsBefore = h.wire.queryCount;
        final result = await h.repo.executeBootEnvironment(review);
        expect(result.outcome, BootEnvironmentOutcome.verified);
        expect(h.wire.queryCount - readsBefore, 2);
        expect(h.wire.writes, hasLength(1));
        final expected = switch (action) {
          BootEnvironmentAction.clone => {
            'id': '25.04.2',
            'target': 'safe-copy',
          },
          BootEnvironmentAction.keep => {'id': '25.04.2', 'value': true},
          _ => {'id': '25.04.2'},
        };
        expect(h.wire.writes.single['params'], [expected]);
        expect(
          h.wire.requests.where((r) => r['method'] == 'system.reboot'),
          isEmpty,
        );
        if (action == BootEnvironmentAction.activate) {
          expect(
            h.wire.rows.singleWhere((r) => r['active'] == true)['id'],
            '25.10.1',
          );
          expect(
            h.wire.rows.singleWhere((r) => r['activated'] == true)['id'],
            '25.04.2',
          );
          expect(result.message, contains('no reboot'));
        }
        await expectLater(
          h.repo.executeBootEnvironment(review),
          throwsA(_reason(BootEnvironmentsExceptionReason.staleReview)),
        );
        expect(h.wire.writes, hasLength(1));
      },
    );
  }

  test(
    'rename, invalid names and polluted requests cannot send a mutation',
    () async {
      final h = await _connected();
      final inventory = await h.repo.loadBootEnvironments();
      final source = inventory.environments.first;
      final requests = [
        BootEnvironmentRequest(
          inventory: inventory,
          snapshot: source,
          action: BootEnvironmentAction.rename,
          targetName: 'new',
        ),
        for (final target in [
          '',
          '../escape',
          '-flag',
          'has space',
          'x\n',
          'x' * 65,
          source.id,
        ])
          BootEnvironmentRequest(
            inventory: inventory,
            snapshot: source,
            action: BootEnvironmentAction.clone,
            targetName: target,
          ),
        BootEnvironmentRequest(
          inventory: inventory,
          snapshot: source,
          action: BootEnvironmentAction.delete,
          keep: false,
        ),
        BootEnvironmentRequest(
          inventory: inventory,
          snapshot: source,
          action: BootEnvironmentAction.keep,
          keep: false,
        ),
      ];
      for (final request in requests) {
        expect(request.validationError, isNotNull);
        await expectLater(
          h.repo.reviewBootEnvironment(request),
          throwsA(isA<BootEnvironmentsException>()),
        );
      }
      expect(h.wire.writes, isEmpty);
    },
  );

  test(
    'active, next-boot, kept, and unsupported environments cannot be deleted',
    () async {
      for (final field in ['active', 'activated', 'keep', 'can_activate']) {
        final h = await _connected();
        if (field == 'active' || field == 'activated') {
          h.wire.rows.first[field] = false;
        }
        h.wire.rows.last[field] = field != 'can_activate';
        final inventory = await h.repo.loadBootEnvironments();
        final request = BootEnvironmentRequest(
          inventory: inventory,
          snapshot: inventory.environments.first,
          action: BootEnvironmentAction.delete,
        );
        expect(request.snapshot.canDelete, isFalse);
        await expectLater(
          h.repo.reviewBootEnvironment(request),
          throwsA(_reason(BootEnvironmentsExceptionReason.invalidRequest)),
        );
        expect(h.wire.writes, isEmpty);
      }
    },
  );

  test('unsupported source and already activated target are refused', () async {
    final h = await _connected();
    h.wire.rows.last['can_activate'] = false;
    final inventory = await h.repo.loadBootEnvironments();
    for (final action in [
      BootEnvironmentAction.clone,
      BootEnvironmentAction.activate,
    ]) {
      await expectLater(
        h.repo.reviewBootEnvironment(
          BootEnvironmentRequest(
            inventory: inventory,
            snapshot: inventory.environments.first,
            action: action,
            targetName: action == BootEnvironmentAction.clone ? 'copy' : null,
          ),
        ),
        throwsA(_reason(BootEnvironmentsExceptionReason.invalidRequest)),
      );
    }
    await expectLater(
      h.repo.reviewBootEnvironment(
        BootEnvironmentRequest(
          inventory: inventory,
          snapshot: inventory.environments.last,
          action: BootEnvironmentAction.activate,
        ),
      ),
      throwsA(_reason(BootEnvironmentsExceptionReason.invalidRequest)),
    );
  });

  test('HA and running boot/update dependencies block review', () async {
    for (final condition in [
      'ha',
      'boot.scrub',
      'update.update',
      'failover.upgrade',
      'system.reboot',
    ]) {
      final h = await _connected();
      h.wire.licensed = condition == 'ha';
      if (condition != 'ha') {
        h.wire.jobs = [
          {'id': 1, 'method': condition, 'state': 'RUNNING'},
        ];
      }
      final inventory = await h.repo.loadBootEnvironments();
      expect(inventory.blockedReason, isNotNull);
      await expectLater(
        h.repo.reviewBootEnvironment(
          BootEnvironmentRequest(
            inventory: inventory,
            snapshot: inventory.environments.first,
            action: BootEnvironmentAction.keep,
            keep: true,
          ),
        ),
        throwsA(_reason(BootEnvironmentsExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    }
  });

  test(
    'job/private/uploadable metadata cannot enter synchronous mutation path',
    () async {
      for (final field in [
        'job',
        'private',
        'no_auth_required',
        'uploadable',
        'downloadable',
      ]) {
        final h = await _connected(
          metadataOverride: {
            'boot.environment.keep': {field: true},
          },
        );
        expect(
          h.repo.bootEnvironmentsCapabilities.supports(
            BootEnvironmentAction.keep,
          ),
          isFalse,
        );
        final inventory = await h.repo.loadBootEnvironments();
        await expectLater(
          h.repo.reviewBootEnvironment(
            BootEnvironmentRequest(
              inventory: inventory,
              snapshot: inventory.environments.first,
              action: BootEnvironmentAction.keep,
              keep: true,
            ),
          ),
          throwsA(_reason(BootEnvironmentsExceptionReason.unavailableMethod)),
        );
        expect(h.wire.writes, isEmpty);
      }
    },
  );

  test(
    'invented inventory and a review from another session are refused',
    () async {
      final first = await _connected();
      final second = await _connected();
      final inventory = await first.repo.loadBootEnvironments();
      final copied = BootEnvironmentInventory(
        environments: inventory.environments,
        failoverLicensed: false,
      );
      await expectLater(
        first.repo.reviewBootEnvironment(
          BootEnvironmentRequest(
            inventory: copied,
            snapshot: copied.environments.first,
            action: BootEnvironmentAction.keep,
            keep: true,
          ),
        ),
        throwsA(_reason(BootEnvironmentsExceptionReason.staleReview)),
      );
      final review = await _review(first, BootEnvironmentAction.keep);
      await expectLater(
        second.repo.executeBootEnvironment(review),
        throwsA(_reason(BootEnvironmentsExceptionReason.staleReview)),
      );
      expect(second.wire.writes, isEmpty);
      await first.repo.loadBootEnvironments();
      await expectLater(
        first.repo.executeBootEnvironment(review),
        throwsA(_reason(BootEnvironmentsExceptionReason.staleReview)),
      );
    },
  );

  test('fresh identity, next-boot, target collisions and dependencies invalidate review', () async {
    for (final change in ['created', 'next-boot', 'target', 'job']) {
      final h = await _connected();
      final review = await _review(h, BootEnvironmentAction.clone);
      switch (change) {
        case 'created':
          h.wire.rows.last['created'] = '2026-09-11T12:00:00';
        case 'next-boot':
          h.wire.rows.first['activated'] = false;
          h.wire.rows.last['activated'] = true;
        case 'target':
          h.wire.rows.add(_row('safe-copy'));
        case 'job':
          h.wire.jobs = [
            {'id': 1, 'method': 'update.update', 'state': 'RUNNING'},
          ];
      }
      final result = await h.repo.executeBootEnvironment(review);
      expect(result.outcome, BootEnvironmentOutcome.rejected, reason: change);
      expect(h.wire.writes, isEmpty);
    }
  });

  test(
    'volatile usage changes do not replace immutable environment identity',
    () async {
      final h = await _connected();
      final review = await _review(h, BootEnvironmentAction.keep);
      h.wire.rows.first['used_bytes'] = 2000000000;
      expect(
        (await h.repo.executeBootEnvironment(review)).outcome,
        BootEnvironmentOutcome.verified,
      );
    },
  );

  test(
    'readback mismatch and missing synchronous acknowledgement stay unknown',
    () async {
      for (final fault in [
        'integer',
        'missing',
        'other-change',
        'remote-error',
      ]) {
        final h = await _connected();
        final review = await _review(h, BootEnvironmentAction.keep);
        h.wire.afterMutation = () {
          if (fault == 'other-change') h.wire.rows.first['keep'] = false;
        };
        h.wire.wrongAcknowledgement = fault == 'integer' || fault == 'missing';
        h.wire.nullAcknowledgement = fault == 'missing';
        h.wire.remoteError = fault == 'remote-error';
        final result = await h.repo.executeBootEnvironment(review);
        expect(result.outcome, BootEnvironmentOutcome.unknown, reason: fault);
        expect(result.message, isNot(contains(_secret)));
        await h.repo.loadBootEnvironments();
        await expectLater(
          _review(h, BootEnvironmentAction.keep),
          throwsA(_reason(BootEnvironmentsExceptionReason.busy)),
        );
        expect(h.wire.writes, hasLength(1));
        expect(
          h.wire.requests
              .where((r) => r['method'] == 'core.get_jobs')
              .every(
                (r) =>
                    ((r['params'] as List).first as List).first[0] == 'state',
              ),
          isTrue,
        );
      }
    },
  );

  test(
    'timeout holds shared mutation lock and never retries or cancels a job',
    () async {
      final h = await _connected(timeout: const Duration(milliseconds: 40));
      final review = await _review(h, BootEnvironmentAction.keep);
      h.wire.suppressMutation = true;
      final pending = h.repo.executeBootEnvironment(review);
      await _until(() => h.wire.writes.isNotEmpty);
      await expectLater(
        h.repo.execute(
          const CreateDatasetCommand(parent: 'tank', name: 'blocked'),
        ),
        throwsA(isA<ManagementException>()),
      );
      expect((await pending).outcome, BootEnvironmentOutcome.unknown);
      await expectLater(
        h.repo.executeBootEnvironment(review),
        throwsA(_reason(BootEnvironmentsExceptionReason.busy)),
      );
      expect(h.wire.writes, hasLength(1));
      expect(
        h.wire.requests.where(
          (r) =>
              r['method'] == 'core.job_abort' ||
              r['method'] == 'pool.dataset.create',
        ),
        isEmpty,
      );
    },
  );

  test(
    'disconnect after submission never verifies the previous operation',
    () async {
      final h = await _connected();
      final review = await _review(h, BootEnvironmentAction.activate);
      h.wire.suppressMutation = true;
      final pending = h.repo.executeBootEnvironment(review);
      await _until(() => h.wire.writes.isNotEmpty);
      await h.repo.close();
      expect((await pending).outcome, BootEnvironmentOutcome.unknown);
      expect(h.wire.writes, hasLength(1));
    },
  );

  test('malformed identities, flags, dates, byte values and duplicate rows fail safely', () async {
    for (final change in <void Function(_Transport)>[
      (w) => w.rows.last.remove('active'),
      (w) => w.rows.last['dataset'] = 'tank/user-data',
      (w) => w.rows.last['id'] = 'name\n',
      (w) => w.rows.last['created'] = 'yesterday',
      (w) => w.rows.last['created'] = '2026-02-30T12:00:00',
      (w) => w.rows.last['created'] = '2026-13-01T12:00:00',
      (w) => w.rows.last['created'] = '2026-09-10T24:00:00',
      (w) => w.rows.last['created'] = '2026-09-10T12:00:00+25:00',
      (w) => w.rows.last['used_bytes'] = -1,
      (w) => w.rows.last['used_bytes'] = 9007199254740992,
      (w) => w.rows.add({...w.rows.last}),
      (w) => w.rows.last['active'] = true,
      (w) => w.rows.first['activated'] = false,
      (w) => w.rows = [
        for (var i = 0; i < 129; i++)
          _row('entry-$i', active: i == 0, activated: i == 0),
      ],
    ]) {
      final h = await _connected();
      change(h.wire);
      await expectLater(
        h.repo.loadBootEnvironments(),
        throwsA(_reason(BootEnvironmentsExceptionReason.invalidResponse)),
      );
      expect(h.wire.writes, isEmpty);
    }
  });
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 1000 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

Future<BootEnvironmentReview> _review(
  _Harness h,
  BootEnvironmentAction action,
) async {
  final inventory = await h.repo.loadBootEnvironments();
  return h.repo.reviewBootEnvironment(
    BootEnvironmentRequest(
      inventory: inventory,
      snapshot: inventory.environments.singleWhere((e) => e.id == '25.04.2'),
      action: action,
      targetName: action == BootEnvironmentAction.clone ? 'safe-copy' : null,
      keep: action == BootEnvironmentAction.keep ? true : null,
    ),
  );
}

final class _Harness {
  _Harness(this.repo, this.wire);
  final TrueNasSessionRepository repo;
  final _Transport wire;
}

Future<_Harness> _connected({
  String version = '25.10.1',
  Set<String> methods = _methods,
  Map<String, Map<String, Object?>> metadataOverride = const {},
  Duration timeout = const Duration(seconds: 2),
}) async {
  final wire = _Transport(
    version: version,
    methods: methods,
    metadataOverride: metadataOverride,
  );
  final repo = TrueNasSessionRepository(
    connector: _Connector(wire),
    managementRequestTimeout: timeout,
  );
  addTearDown(repo.close);
  await repo.connect(
    serverInput: 'https://synthetic.example',
    username: 'fixture-user',
    apiKey: 'fixture-key',
  );
  return _Harness(repo, wire);
}

final class _Connector implements RpcConnector {
  _Connector(this.wire);
  final _Transport wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

final class _Transport implements RpcTransport {
  _Transport({
    this.version = '25.10.1',
    this.methods = _methods,
    this.metadataOverride = const {},
  });
  final String version;
  final Set<String> methods;
  final Map<String, Map<String, Object?>> metadataOverride;
  final _incoming = StreamController<String>();
  final requests = <Map<String, dynamic>>[];
  List<Map<String, Object?>> rows = [
    _row('25.10.1', active: true, activated: true, keep: true),
    _row('25.04.2'),
  ];
  List<Object?> jobs = [];
  bool licensed = false;
  bool wrongAcknowledgement = false;
  bool nullAcknowledgement = false;
  bool remoteError = false;
  bool suppressMutation = false;
  void Function()? afterMutation;
  int get queryCount =>
      requests.where((r) => r['method'] == 'boot.environment.query').length;
  List<Map<String, dynamic>> get writes => requests
      .where(
        (r) => {
          'boot.environment.clone',
          'boot.environment.keep',
          'boot.environment.activate',
          'boot.environment.destroy',
        }.contains(r['method']),
      )
      .toList();
  @override
  Stream<String> get inboundFrames => _incoming.stream;
  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    requests.add(request);
    final method = request['method'] as String;
    Object? result;
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'username': 'fixture-user'};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final name in methods)
            name: {
              'job': false,
              'no_auth_required': false,
              'uploadable': false,
              'downloadable': false,
              ...?metadataOverride[name],
            },
        };
      case 'failover.licensed':
        result = licensed;
      case 'core.get_jobs':
        result = jobs;
      case 'boot.environment.query':
        result = rows;
      default:
        if (!method.startsWith('boot.environment.')) {
          throw StateError('Unexpected synthetic method');
        }
        final args = (request['params'] as List).single as Map;
        final row = rows.singleWhere((r) => r['id'] == args['id']);
        switch (method) {
          case 'boot.environment.clone':
            result = _row(args['target'] as String)
              ..['created'] = '2026-09-12T12:00:00';
            rows.add(result as Map<String, Object?>);
          case 'boot.environment.keep':
            row['keep'] = args['value'];
            result = row;
          case 'boot.environment.activate':
            for (final item in rows) {
              item['activated'] = identical(item, row);
            }
            result = row;
          case 'boot.environment.destroy':
            rows.remove(row);
            result = null;
          default:
            throw StateError('Unexpected synthetic mutation');
        }
        afterMutation?.call();
        if (suppressMutation) return;
        if (remoteError) {
          _incoming.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': request['id'],
              'error': {'code': -1, 'message': _secret, 'data': _secret},
            }),
          );
          return;
        }
        if (wrongAcknowledgement) result = nullAcknowledgement ? null : 4321;
    }
    _incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}
