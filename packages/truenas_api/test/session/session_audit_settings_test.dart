import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _boot = '11111111-2222-4333-8444-555555555555';

Map<String, Object?> _config([int retention = 30]) => {
  'id': 1,
  'retention': retention,
  'reservation': 0,
  'quota': 0,
  'quota_fill_warning': 75,
  'quota_fill_critical': 90,
  'remote_logging_enabled': false,
  'space': {
    'used': 1024,
    'used_by_dataset': 1024,
    'used_by_reservation': 0,
    'used_by_snapshots': 0,
    'available': 2048,
  },
  'enabled_services': {
    'MIDDLEWARE': <Object?>[],
    'SMB': <Object?>[],
    'SUDO': <Object?>[],
  },
};

final class _Wire implements RpcTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  Map<String, Object?> config = _config();
  bool failWrite = false;
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final call = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(call);
    final method = call['method'] as String;
    if (method == 'audit.update' && failWrite) {
      inbound.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': call['id'],
          'error': {'code': -32000, 'message': 'SYNTHETIC_SECRET'},
        }),
      );
      return;
    }
    final value = switch (method) {
      'auth.login_ex' => {'response_type': 'SUCCESS'},
      'system.info' => {'version': '25.10.1'},
      'core.get_methods' => {
        for (final name in {
          'system.version_short',
          'system.host_id',
          'system.reboot.info',
          'system.state',
          'failover.licensed',
          'boot.get_state',
          'boot.environment.query',
          'core.get_jobs',
          'auth.me',
          'audit.config',
          'audit.update',
        })
          name: {
            'job': false,
            'uploadable': false,
            'downloadable': false,
            'no_auth_required': false,
            'check_pipes': false,
          },
      },
      'system.version_short' => '25.10.1',
      'system.host_id' => _host,
      'system.reboot.info' => {'boot_id': _boot, 'reboot_required_reasons': []},
      'system.state' => 'READY',
      'failover.licensed' => false,
      'boot.get_state' => {
        'name': 'boot-pool',
        'healthy': true,
        'status': 'ONLINE',
        'scan': null,
      },
      'boot.environment.query' => [
        {
          'id': '25.10.1',
          'dataset': 'boot-pool/ROOT/25.10.1',
          'created': '2026-09-14T01:00:00',
          'used_bytes': 4000,
          'active': true,
          'activated': true,
          'keep': true,
          'can_activate': true,
        },
      ],
      'core.get_jobs' => <Object?>[],
      'auth.me' => {
        'privilege': {
          'roles': ['FULL_ADMIN'],
        },
      },
      'audit.config' => config,
      'audit.update' => _updated(call),
      _ => null,
    };
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': call['id'], 'result': value}),
    );
  }

  Object? _updated(Map<String, dynamic> call) {
    final patch = (call['params'] as List).single as Map;
    config = {...config, ...patch.cast<String, Object?>()};
    return config;
  }

  @override
  Future<void> close() async {
    await inbound.close();
  }
}

final class _Connector implements RpcConnector {
  const _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

Future<(TrueNasSessionRepository, _Wire)> _connected() async {
  final wire = _Wire();
  final repo = TrueNasSessionRepository(
    connector: _Connector(wire),
    managementRequestTimeout: const Duration(milliseconds: 300),
  );
  addTearDown(repo.close);
  await repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
  );
  return (repo, wire);
}

Future<AuditSettingsReview> _review(TrueNasSessionRepository repo) async {
  final inventory = await repo.loadAuditSettings();
  return repo.reviewAuditSettings(
    AuditSettingsRequest(
      inventory: inventory,
      retentionDays: 20,
      shorterRetentionAccepted: true,
      datasetImpactAccepted: true,
    ),
  );
}

void main() {
  test(
    'read projects safe scalars and requires both impact consents',
    () async {
      final (repo, wire) = await _connected();
      final inventory = await repo.loadAuditSettings();
      expect(inventory.settings.retentionDays, 30);
      expect(inventory.settings.usedBytes, 1024);
      expect(inventory.blockedReason, isNull);
      final request = AuditSettingsRequest(
        inventory: inventory,
        retentionDays: 20,
        shorterRetentionAccepted: false,
        datasetImpactAccepted: true,
      );
      expect(request.validationError, isNotNull);
      expect(wire.calls.where((c) => c['method'] == 'audit.update'), isEmpty);
    },
  );

  test(
    'one-field update requires exact confirmation and verifies readback',
    () async {
      final (repo, wire) = await _connected();
      final review = await _review(repo);
      final rejected = await repo.executeAuditSettings(
        review,
        'wrong',
        isCurrent: () => true,
      );
      expect(rejected.outcome, AuditSettingsOutcome.rejected);
      expect(wire.calls.where((c) => c['method'] == 'audit.update'), isEmpty);
      final fresh = await _review(repo);
      final result = await repo.executeAuditSettings(
        fresh,
        fresh.target,
        isCurrent: () => true,
      );
      expect(result.outcome, AuditSettingsOutcome.completed);
      final writes = wire.calls
          .where((c) => c['method'] == 'audit.update')
          .toList();
      expect(writes, hasLength(1));
      expect((writes.single['params'] as List).single, {'retention': 20});
    },
  );

  test(
    'post-dispatch server error is unknown and fences another write',
    () async {
      final (repo, wire) = await _connected();
      final review = await _review(repo);
      wire.failWrite = true;
      final result = await repo.executeAuditSettings(
        review,
        review.target,
        isCurrent: () => true,
      );
      expect(result.outcome, AuditSettingsOutcome.unknown);
      expect(result.message, isNot(contains('SYNTHETIC_SECRET')));
      await expectLater(
        repo.loadAuditSettings(),
        throwsA(isA<AuditSettingsException>()),
      );
    },
  );
  test("config drift blocks review before any update", () async {
    final (repo, wire) = await _connected();
    final inventory = await repo.loadAuditSettings();
    wire.config = {...wire.config, "remote_logging_enabled": true};
    await expectLater(
      repo.reviewAuditSettings(
        AuditSettingsRequest(
          inventory: inventory,
          retentionDays: 20,
          shorterRetentionAccepted: true,
          datasetImpactAccepted: true,
        ),
      ),
      throwsA(isA<AuditSettingsException>()),
    );
    expect(wire.calls.where((c) => c["method"] == "audit.update"), isEmpty);
  });

  test("route expiry before dispatch", () async {
    final (repo, wire) = await _connected();
    final review = await _review(repo);
    final result = await repo.executeAuditSettings(
      review,
      review.target,
      isCurrent: () => false,
    );
    expect(result.outcome, AuditSettingsOutcome.rejected);
    expect(wire.calls.where((c) => c["method"] == "audit.update"), isEmpty);
  });
  test(
    "storage policy sends only changed fields and verifies readback",
    () async {
      final (repo, wire) = await _connected();
      final inventory = await repo.loadAuditSettings();
      final review = await repo.reviewAuditSettings(
        AuditSettingsRequest(
          inventory: inventory,
          retentionDays: inventory.settings.retentionDays,
          reservationGiB: 1,
          quotaGiB: 5,
          warningPercent: 70,
          criticalPercent: 90,
          shorterRetentionAccepted: false,
          datasetImpactAccepted: true,
        ),
      );
      final result = await repo.executeAuditSettings(
        review,
        review.target,
        isCurrent: () => true,
      );
      expect(result.outcome, AuditSettingsOutcome.completed);
      final write = wire.calls.singleWhere(
        (c) => c["method"] == "audit.update",
      );
      expect((write["params"] as List).single, {
        "reservation": 1,
        "quota": 5,
        "quota_fill_warning": 70,
      });
    },
  );

  test("invalid storage relationship is rejected without an update", () async {
    final (repo, wire) = await _connected();
    final inventory = await repo.loadAuditSettings();
    final request = AuditSettingsRequest(
      inventory: inventory,
      retentionDays: inventory.settings.retentionDays,
      reservationGiB: 6,
      quotaGiB: 5,
      warningPercent: 70,
      criticalPercent: 90,
      shorterRetentionAccepted: false,
      datasetImpactAccepted: true,
    );
    expect(request.validationError, contains("at least the reservation"));
    await expectLater(
      repo.reviewAuditSettings(request),
      throwsA(isA<AuditSettingsException>()),
    );
    expect(wire.calls.where((c) => c["method"] == "audit.update"), isEmpty);
  });
  test("quota below current warning capacity is rejected locally", () async {
    final (repo, wire) = await _connected();
    wire.config = {
      ...wire.config,
      "space": {
        ...(wire.config["space"]! as Map).cast<String, Object?>(),
        "used_by_dataset": 900 * 1024 * 1024,
      },
    };
    final inventory = await repo.loadAuditSettings();
    final request = AuditSettingsRequest(
      inventory: inventory,
      retentionDays: inventory.settings.retentionDays,
      reservationGiB: 0,
      quotaGiB: 1,
      warningPercent: 75,
      criticalPercent: 90,
      shorterRetentionAccepted: false,
      datasetImpactAccepted: true,
    );
    expect(request.validationError, contains("already exceed"));
    expect(wire.calls.where((c) => c["method"] == "audit.update"), isEmpty);
  });
}
