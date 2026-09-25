import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _boot = '11111111-2222-4333-8444-555555555555';
const _report =
    '/var/tmp/audit/12345678-1234-4234-8234-123456789abc.csv.tar.gz';
final _url = '/_download/71?auth_token=${'a' * 64}';

final class _Wire
    implements RpcTransport, ConfigurationBackupDownloadTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  String exportState = 'RUNNING';
  Object? downloadReceipt = [71, _url];
  Uint8List bytes = Uint8List.fromList([0x1f, 0x8b, 0x08, 0, 1, 2]);
  List<Object?>? exportArguments;

  @override
  bool get configurationBackupDownloadSupported => true;

  @override
  Future<Uint8List> downloadConfigurationBackup({
    required String relativeUrl,
    required int jobId,
  }) async {
    expect(relativeUrl, _url);
    expect(jobId, 71);
    return Uint8List.fromList(bytes);
  }

  @override
  Stream<String> get inboundFrames => inbound.stream;

  @override
  Future<void> send(String frame) async {
    final call = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(call);
    final method = call['method'] as String;
    if (method == 'audit.export') {
      exportArguments = call['params'] as List<Object?>;
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
          'audit.export',
          'audit.download_report',
          'core.download',
        })
          name: {
            'job': name == 'audit.export' || name == 'audit.download_report',
            'uploadable': false,
            'downloadable': name == 'audit.download_report',
            'no_auth_required': false,
          },
      },
      'system.version_short' => '25.10.1',
      'system.host_id' => _host,
      'system.reboot.info' => {
        'boot_id': _boot,
        'reboot_required_reasons': <Object?>[],
      },
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
      'auth.me' => {
        'privilege': {
          'roles': ['FULL_ADMIN'],
        },
      },
      'audit.export' => 41,
      'core.download' => downloadReceipt,
      'core.get_jobs' => _jobs(call),
      _ => null,
    };
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': call['id'], 'result': value}),
    );
  }

  Object? _jobs(Map<String, dynamic> call) {
    final filters = (call['params'] as List).first as List;
    if (filters.isEmpty || filters.first is! List) return <Object?>[];
    final first = filters.first as List;
    if (first.first != 'id') return <Object?>[];
    if (first.last == 41) {
      return [
        {
          'id': 41,
          'method': 'audit.export',
          'arguments': exportArguments,
          'state': exportState,
          'error': null,
          'result': exportState == 'SUCCESS' ? _report : null,
        },
      ];
    }
    if (first.last == 71) {
      return [
        {
          'id': 71,
          'method': 'audit.download_report',
          'state': 'SUCCESS',
          'error': null,
          'result': null,
        },
      ];
    }
    return <Object?>[];
  }

  @override
  Future<void> close() async => inbound.close();
}

final class _Connector implements RpcConnector {
  const _Connector(this.wire);
  final RpcTransport wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

Future<(TrueNasSessionRepository, _Wire)> _connected() async {
  final wire = _Wire();
  final repo = TrueNasSessionRepository(
    connector: _Connector(wire),
    managementRequestTimeout: const Duration(milliseconds: 300),
    auditExportNow: () => DateTime.utc(2026, 9, 15),
  );
  addTearDown(repo.close);
  await repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
  );
  return (repo, wire);
}

AuditExportRequest _request() => AuditExportRequest(
  query: AuditQuery(
    from: DateTime.utc(2026, 9, 14),
    until: DateTime.utc(2026, 9, 15),
    username: 'operator',
    success: true,
  ),
  format: AuditExportFormat.csv,
  sensitiveDataAccepted: true,
  serverArtifactAccepted: true,
  rowLimitAccepted: true,
);

void main() {
  test('requires exact confirmation and submits one bounded export', () async {
    final (repo, wire) = await _connected();
    final review = await repo.reviewAuditExport(_request());
    final rejected = await repo.executeAuditExport(
      review,
      'wrong',
      isCurrent: () => true,
    );
    expect(rejected.outcome, AuditExportOutcome.rejected);
    expect(wire.calls.where((c) => c['method'] == 'audit.export'), isEmpty);

    final fresh = await repo.reviewAuditExport(_request());
    final result = await repo.executeAuditExport(
      fresh,
      fresh.target,
      isCurrent: () => true,
    );
    expect(result.outcome, AuditExportOutcome.pending);
    final writes = wire.calls
        .where((c) => c['method'] == 'audit.export')
        .toList();
    expect(writes, hasLength(1));
    final payload = (writes.single['params'] as List).single as Map;
    expect(payload['services'], ['MIDDLEWARE']);
    expect(payload['remote_controller'], false);
    expect(payload['export_format'], 'CSV');
    expect((payload['query-options'] as Map)['limit'], 10000);
    expect(wire.calls.where((c) => c['method'] == 'audit.query'), isEmpty);
  });

  test(
    'poll never replays export and verifies both jobs before bytes',
    () async {
      final (repo, wire) = await _connected();
      final review = await repo.reviewAuditExport(_request());
      final submitted = await repo.executeAuditExport(
        review,
        review.target,
        isCurrent: () => true,
      );
      final pending = await repo.pollAuditExport(
        submitted.operation!,
        isCurrent: () => true,
      );
      expect(pending.outcome, AuditExportOutcome.pending);
      expect(
        wire.calls.where((c) => c['method'] == 'audit.export'),
        hasLength(1),
      );
      expect(wire.calls.where((c) => c['method'] == 'core.download'), isEmpty);

      wire.exportState = 'SUCCESS';
      final completed = await repo.pollAuditExport(
        submitted.operation!,
        isCurrent: () => true,
      );
      expect(completed.outcome, AuditExportOutcome.completed);
      expect(completed.artifact!.filename, _report.split('/').last);
      final bytes = completed.artifact!.takeBytes();
      expect(bytes.sublist(0, 3), [0x1f, 0x8b, 0x08]);
      expect(
        wire.calls.where((c) => c['method'] == 'audit.export'),
        hasLength(1),
      );
      expect(
        wire.calls.where((c) => c['method'] == 'core.download'),
        hasLength(1),
      );
    },
  );

  test(
    'malformed download receipt is unknown and fences the session',
    () async {
      final (repo, wire) = await _connected();
      final review = await repo.reviewAuditExport(_request());
      final submitted = await repo.executeAuditExport(
        review,
        review.target,
        isCurrent: () => true,
      );
      wire.exportState = 'SUCCESS';
      wire.downloadReceipt = [71, 'https://evil.example/report'];
      final result = await repo.pollAuditExport(
        submitted.operation!,
        isCurrent: () => true,
      );
      expect(result.outcome, AuditExportOutcome.unknown);
      expect(result.artifact, isNull);
      await expectLater(
        repo.reviewAuditExport(_request()),
        throwsA(isA<AuditExportException>()),
      );
    },
  );
}
