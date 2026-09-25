import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

// Independent fake transport: no HTTP, filesystem, credentials or real server.
const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _boot = '11111111-2222-4333-8444-555555555555';
const _service = ServiceControlCommand(
  service: 'smb',
  action: ServiceControlAction.start,
);
const _reads = {
  'system.version_short',
  'system.host_id',
  'system.reboot.info',
  'system.state',
  'failover.licensed',
  'boot.get_state',
  'boot.environment.query',
  'core.get_jobs',
  'auth.me',
};
const _methods = {
  ..._reads,
  'config.reset',
  'config.save',
  'core.download',
  'config.upload',
  'auth.generate_token',
  'system.reboot',
  'system.shutdown',
  'service.control',
  'boot.environment.clone',
  'update.status',
  'update.available_versions',
};
const _jobs = {
  'config.reset',
  'config.save',
  'config.upload',
  'system.reboot',
  'system.shutdown',
  'service.control',
};

void main() {
  for (final job in [true, false]) {
    for (final reboot in [true, false]) {
      test(
        'complete generic reset metadata job=$job reboot=$reboot cannot bypass native review',
        () async {
          final h = await _connected(resetJob: job, defaultReboot: reboot);
          final spec = h.repo.adminCatalog.method('config.reset')!;
          expect(spec.parameters.single.schema.supported, isTrue);
          expect(spec.supported, isFalse);
          expect(spec.unsupportedReason, contains('native'));
          final before = h.wire.calls.length;
          await expectLater(
            h.repo.invokeAdmin(
              AdminRequest(
                method: spec,
                arguments: [
                  {'reboot': reboot},
                ],
              ),
            ),
            throwsA(
              isA<AdminException>().having(
                (e) => e.reason,
                'reason',
                AdminExceptionReason.unavailableMethod,
              ),
            ),
          );
          expect(h.wire.calls.length, before);
          expect(h.wire.resetCalls, isEmpty);
        },
      );
    }
  }
  test(
    'dashboard query allowlist cannot invoke config.reset even when advertised',
    () async {
      final h = await _connected();
      final before = h.wire.calls.length;
      await expectLater(
        h.repo.query('config.reset'),
        throwsA(isA<SessionQueryException>()),
      );
      expect(h.wire.calls.length, before);
      expect(h.wire.resetCalls, isEmpty);
    },
  );
  for (final receipt in [71, null, 'remote-error']) {
    test(
      'pending and terminal reset receipt=$receipt fence peers without replay or polling',
      () async {
        final h = await _connected();
        final peers = await _peerReviews(h);
        final review = await _resetReview(h);
        h.wire.hold('config.reset');
        final submitted = h.repo.executeConfigurationReset(
          review,
          review.target,
          isCurrent: () => true,
        );
        await h.wire.entered!.future.timeout(const Duration(seconds: 2));
        final before = h.wire.calls.length;
        await _expectFenced(h, peers);
        expect(h.wire.calls.length, before);
        h.wire.release!.complete(receipt);
        final result = await submitted;
        expect(
          result.outcome,
          receipt == 71
              ? ConfigurationResetOutcome.accepted
              : ConfigurationResetOutcome.unknown,
        );
        expect(result.jobId, receipt == 71 ? 71 : isNull);
        await _expectFenced(h, peers);
        expect(
          (await h.repo.executeConfigurationReset(
            review,
            review.target,
            isCurrent: () => true,
          )).outcome,
          ConfigurationResetOutcome.rejected,
        );
        await expectLater(
          h.repo.loadConfigurationReset(),
          throwsA(
            isA<ConfigurationResetException>().having(
              (e) => e.reason,
              'reason',
              ConfigurationResetExceptionReason.busy,
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          h.wire.calls.length,
          before,
          reason: 'No replay, job polling, separate reboot, token or peer request is sent.',
        );
        expect(h.wire.resetCalls.single['params'], [
          {'reboot': true},
        ]);
        expect(h.wire.transfers, 0);
        expect(
          h.wire.calls.where(
            (c) => [
              'system.reboot',
              'system.shutdown',
              'core.download',
              'config.upload',
              'auth.generate_token',
              'service.control',
              'update.status',
              'update.available_versions',
              'boot.environment.clone',
              'core.job_abort',
            ].contains(c['method']),
          ),
          isEmpty,
        );
      },
    );
  }
  for (final peer in [
    'backup',
    'restore',
    'power',
    'boot',
    'updates',
    'service',
  ]) {
    test(
      'in-flight $peer blocks reset and consumes the attempted reset review',
      () async {
        final h = await _connected();
        final review = await _resetReview(h);
        final heldMethod = switch (peer) {
          'backup' || 'restore' => 'auth.me',
          'power' => 'system.reboot.info',
          'boot' => 'boot.environment.query',
          'updates' => 'system.version_short',
          _ => 'service.control',
        };
        h.wire.hold(heldMethod);
        final Future<Object?> pending = switch (peer) {
          'backup' => h.repo.loadConfigurationBackup(),
          'restore' => h.repo.loadConfigurationRestore(),
          'power' => h.repo.loadSystemPower(),
          'boot' => h.repo.loadBootEnvironments(),
          'updates' => h.repo.loadSystemUpdates(),
          _ => h.repo.execute(_service),
        };
        await h.wire.entered!.future.timeout(const Duration(seconds: 2));
        final before = h.wire.calls.length;
        final blocked = await h.repo.executeConfigurationReset(
          review,
          review.target,
          isCurrent: () => true,
        );
        expect(blocked.outcome, ConfigurationResetOutcome.rejected);
        expect(blocked.message, contains('Another operation'));
        expect(h.wire.calls.length, before);
        expect(h.wire.resetCalls, isEmpty);
        h.wire.release!.complete(
          peer == 'service' ? 82 : h.wire.values[heldMethod],
        );
        await pending;
        expect(
          (await h.repo.executeConfigurationReset(
            review,
            review.target,
            isCurrent: () => true,
          )).outcome,
          ConfigurationResetOutcome.rejected,
        );
        expect(h.wire.resetCalls, isEmpty);
      },
    );
  }
  for (final peer in ['power', 'restore']) {
    for (final uncertain in [false, true]) {
      test(
        'terminal $peer uncertain=$uncertain forbids a previously reviewed reset',
        () async {
          final h = await _connected();
          final reset = await _resetReview(h);
          if (peer == 'power') {
            final power = await h.repo.reviewSystemPower(
              SystemPowerRequest(
                inventory: await h.repo.loadSystemPower(),
                action: SystemPowerAction.reboot,
                reason: 'Synthetic maintenance',
              ),
            );
            h.wire.values['system.reboot'] = uncertain ? null : 82;
            final outcome = await h.repo.executeSystemPower(
              power,
              power.target,
            );
            expect(
              outcome.outcome,
              uncertain
                  ? SystemPowerOutcome.unknown
                  : SystemPowerOutcome.accepted,
            );
          } else {
            final restore = await _restoreReview(h);
            h.wire.uploadFails = uncertain;
            final outcome = await h.repo.executeConfigurationRestore(
              restore,
              restore.target,
              isCurrent: () => true,
            );
            expect(
              outcome.outcome,
              uncertain
                  ? ConfigurationRestoreOutcome.unknown
                  : ConfigurationRestoreOutcome.accepted,
            );
          }
          final before = h.wire.calls.length;
          final blocked = await h.repo.executeConfigurationReset(
            reset,
            reset.target,
            isCurrent: () => true,
          );
          expect(blocked.outcome, ConfigurationResetOutcome.rejected);
          expect(blocked.message, contains('Another operation'));
          expect(h.wire.calls.length, before);
          expect(h.wire.resetCalls, isEmpty);
        },
      );
    }
  }
}

Future<void> _expectFenced(_Harness h, _Peers peers) async {
  final repo = h.repo;
  expect(
    (await repo.executeConfigurationBackup(
      peers.backup,
      peers.backup.target,
    )).outcome,
    ConfigurationBackupOutcome.rejected,
  );
  expect(
    (await repo.executeConfigurationRestore(
      peers.restore,
      peers.restore.target,
      isCurrent: () => true,
    )).outcome,
    ConfigurationRestoreOutcome.rejected,
  );
  expect(peers.restore.request.file.isDisposed, isTrue);
  expect(
    (await repo.executeSystemPower(peers.power, peers.power.target)).outcome,
    SystemPowerOutcome.rejected,
  );
  await expectLater(
    repo.execute(_service),
    throwsA(
      isA<ManagementException>().having(
        (e) => e.reason,
        'reason',
        ManagementExceptionReason.busy,
      ),
    ),
  );
  await expectLater(
    repo.executeBootEnvironment(peers.boot),
    throwsA(
      isA<BootEnvironmentsException>().having(
        (e) => e.reason,
        'reason',
        BootEnvironmentsExceptionReason.busy,
      ),
    ),
  );
  await expectLater(
    repo.executeSystemUpdate(peers.update, peers.update.target),
    throwsA(
      isA<SystemUpdatesException>().having(
        (e) => e.reason,
        'reason',
        SystemUpdatesExceptionReason.busy,
      ),
    ),
  );
  await expectLater(
    repo.loadConfigurationBackup(),
    throwsA(
      isA<ConfigurationBackupException>().having(
        (e) => e.reason,
        'reason',
        ConfigurationBackupExceptionReason.busy,
      ),
    ),
  );
  await expectLater(
    repo.loadConfigurationRestore(),
    throwsA(
      isA<ConfigurationRestoreException>().having(
        (e) => e.reason,
        'reason',
        ConfigurationRestoreExceptionReason.busy,
      ),
    ),
  );
  await expectLater(
    repo.loadSystemPower(),
    throwsA(
      isA<SystemPowerException>().having(
        (e) => e.reason,
        'reason',
        SystemPowerExceptionReason.busy,
      ),
    ),
  );
}

typedef _Peers = ({
  ConfigurationBackupReview backup,
  ConfigurationRestoreReview restore,
  SystemPowerReview power,
  BootEnvironmentReview boot,
  SystemUpdateReview update,
});
Future<_Peers> _peerReviews(_Harness h) async {
  final repo = h.repo;
  final backup = await repo.reviewConfigurationBackup(
    ConfigurationBackupRequest(inventory: await repo.loadConfigurationBackup()),
  );
  final restore = await _restoreReview(h);
  final power = await repo.reviewSystemPower(
    SystemPowerRequest(
      inventory: await repo.loadSystemPower(),
      action: SystemPowerAction.reboot,
      reason: 'Synthetic maintenance',
    ),
  );
  final bootInventory = await repo.loadBootEnvironments();
  final boot = await repo.reviewBootEnvironment(
    BootEnvironmentRequest(
      inventory: bootInventory,
      snapshot: bootInventory.environments.single,
      action: BootEnvironmentAction.clone,
      targetName: 'synthetic-clone',
    ),
  );
  final update = await repo.reviewSystemUpdate(
    SystemUpdateRequest(
      inventory: await repo.loadSystemUpdates(),
      action: SystemUpdateAction.check,
    ),
  );
  return (
    backup: backup,
    restore: restore,
    power: power,
    boot: boot,
    update: update,
  );
}

Future<ConfigurationRestoreReview> _restoreReview(_Harness h) async {
  final inventory = await h.repo.loadConfigurationRestore();
  final bytes = Uint8List(512)
    ..setRange(0, 16, ascii.encode('SQLite format 3\u0000'));
  bytes[16] = 2;
  bytes[18] = 1;
  bytes[19] = 1;
  final file = await h.repo.prepareConfigurationRestore(bytes);
  expect(bytes.every((b) => b == 0), isTrue);
  return h.repo.reviewConfigurationRestore(
    ConfigurationRestoreRequest(inventory: inventory, file: file),
  );
}

Future<ConfigurationResetReview> _resetReview(_Harness h) async =>
    h.repo.reviewConfigurationReset(
      ConfigurationResetRequest(
        inventory: await h.repo.loadConfigurationReset(),
      ),
    );
Future<_Harness> _connected({
  bool resetJob = true,
  bool defaultReboot = true,
}) async {
  final wire = _Wire(resetJob, defaultReboot);
  final repo = TrueNasSessionRepository(
    connector: _Connector(wire),
    managementRequestTimeout: const Duration(seconds: 2),
  );
  addTearDown(repo.close);
  await repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
  );
  return _Harness(repo, wire);
}

class _Harness {
  _Harness(this.repo, this.wire);
  final TrueNasSessionRepository repo;
  final _Wire wire;
}

class _Connector implements RpcConnector {
  _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class _Wire
    implements
        RpcTransport,
        ConfigurationBackupDownloadTransport,
        ConfigurationRestoreUploadTransport {
  _Wire(this.resetJob, this.defaultReboot);
  final bool resetJob, defaultReboot;
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final values = <String, Object?>{
    'system.version_short': '25.10.1',
    'system.host_id': _host,
    'system.reboot.info': {'boot_id': _boot, 'reboot_required_reasons': []},
    'system.state': 'READY',
    'failover.licensed': false,
    'auth.me': {
      'privilege': {
        'roles': ['FULL_ADMIN'],
      },
    },
    'boot.get_state': {
      'name': 'boot-pool',
      'healthy': true,
      'status': 'ONLINE',
      'scan': null,
    },
    'boot.environment.query': [
      {
        'id': '25.10.1',
        'dataset': 'boot-pool/ROOT/25.10.1',
        'created': '2026-09-14T01:00:00',
        'used_bytes': 4096,
        'active': true,
        'activated': true,
        'keep': true,
        'can_activate': true,
      },
    ],
    'core.get_jobs': [],
    'config.reset': 71,
    'service.control': 82,
    'system.reboot': 82,
    'auth.generate_token': 't' * 64,
  };
  String? heldMethod;
  Completer<void>? entered;
  Completer<Object?>? release;
  int transfers = 0;
  bool uploadFails = false;
  List<Map<String, dynamic>> get resetCalls =>
      calls.where((c) => c['method'] == 'config.reset').toList();
  void hold(String method) {
    heldMethod = method;
    entered = Completer<void>();
    release = Completer<Object?>();
  }

  @override
  bool get configurationBackupDownloadSupported => true;
  @override
  bool get configurationRestoreUploadSupported => true;
  @override
  Future<Uint8List> downloadConfigurationBackup({
    required String relativeUrl,
    required int jobId,
  }) async {
    transfers++;
    throw StateError('Unexpected synthetic download.');
  }

  @override
  Future<int> uploadConfigurationRestore({
    required String token,
    required Uint8List bytes,
  }) async {
    transfers++;
    try {
      if (uploadFails) throw StateError('Synthetic upload failure.');
      return 82;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(request);
    final method = request['method'] as String;
    Object? value;
    if (method == heldMethod) {
      heldMethod = null;
      entered!.complete();
      value = await release!.future;
    } else {
      value = switch (method) {
        'auth.login_ex' => {'response_type': 'SUCCESS'},
        'system.info' => {'version': '25.10.1'},
        'core.get_methods' => {
          for (final name in _methods)
            name: {
              'job': name == 'config.reset' ? resetJob : _jobs.contains(name),
              'uploadable': name == 'config.upload',
              'downloadable': name == 'config.save',
              'filterable': false,
              'no_auth_required': false,
              'roles': ['FULL_ADMIN'],
              'accepts': name == 'config.reset'
                  ? [
                      {
                        '_name_': 'options',
                        '_required_': false,
                        'type': 'object',
                        'additionalProperties': false,
                        'properties': {
                          'reboot': {
                            'type': 'boolean',
                            'default': defaultReboot,
                          },
                        },
                      },
                    ]
                  : [],
              'returns': [
                {'type': 'null'},
              ],
            },
        },
        _ => values[method],
      };
    }
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          if (value == 'remote-error')
            'error': {
              'code': -32000,
              'message': 'Synthetic hidden remote error',
              'data': {'errno': 13},
            }
          else
            'result': value,
        }),
      );
    }
  }

  @override
  Future<void> close() async {
    if (!inbound.isClosed) await inbound.close();
  }
}
