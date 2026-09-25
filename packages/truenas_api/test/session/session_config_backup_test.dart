import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _secret = 'SYNTHETIC_PRIVATE_VALUE';
final _url = '/_download/71?auth_token=${'a' * 64}';
const _methods = {
  'system.version_short',
  'system.host_id',
  'system.state',
  'failover.licensed',
  'auth.me',
  'core.get_jobs',
  'config.save',
  'core.download',
};

class _Wire implements RpcTransport, ConfigurationBackupDownloadTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final transfers = <String>[];
  final values = <String, Object?>{
    'system.host_id': _host,
    'system.version_short': '25.10.1',
    'system.state': 'READY',
    'failover.licensed': false,
    'auth.me': {
      'privilege': {
        'roles': ['FULL_ADMIN'],
      },
      'pw_gecos': _secret,
    },
  };
  String version = '25.10.1';
  Set<String> methods = {..._methods};
  final metadata = <String, Map<String, Object?>>{};
  Object? receipt = [71, _url];
  Object? jobs = <Object?>[];
  Object? completion = [
    {
      'id': 71,
      'method': 'config.save',
      'state': 'SUCCESS',
      'error': null,
      'result': null,
    },
  ];
  Uint8List bytes = _sqlite();
  Completer<Uint8List>? heldTransfer;
  Completer<void>? heldRpc;
  String? heldRpcMethod;
  Object? transferError;
  bool supported = true, current = true;
  String? faultMethod;
  final counts = <String, int>{};
  void Function(String method, int count)? beforeReply;
  @override
  bool get configurationBackupDownloadSupported => supported;
  @override
  Future<Uint8List> downloadConfigurationBackup({
    required String relativeUrl,
    required int jobId,
  }) async {
    transfers.add(relativeUrl);
    expect(jobId, 71);
    if (transferError != null) throw transferError!;
    if (heldTransfer != null) return heldTransfer!.future;
    return bytes;
  }

  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(request);
    final method = request['method'] as String;
    counts[method] = (counts[method] ?? 0) + 1;
    beforeReply?.call(method, counts[method]!);
    if (method == heldRpcMethod) await heldRpc!.future;
    if (method == faultMethod) {
      inbound.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {
            'code': -32000,
            'message': _secret,
            'data': {'trace': _secret},
          },
        }),
      );
      return;
    }
    final Object? value = switch (method) {
      'auth.login_ex' => {'response_type': 'SUCCESS'},
      'system.info' => {'version': version},
      'core.get_methods' => {
        for (final name in methods)
          name: {
            'job': name == 'config.save',
            'downloadable': name == 'config.save',
            'uploadable': false,
            'no_auth_required': false,
            ...?metadata[name],
          },
      },
      'core.download' => receipt,
      'core.get_jobs' =>
        ((request['params'] as List).first as List).first[0] == 'id'
            ? completion
            : jobs,
      _ => values[method],
    };
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': value}),
      );
    }
  }

  @override
  Future<void> close() async {
    if (!inbound.isClosed) await inbound.close();
  }
}

class _Connector implements RpcConnector {
  const _Connector(this.wire);
  final RpcTransport wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class _PlainWire implements RpcTransport {
  _PlainWire(this.wire);
  final _Wire wire;
  @override
  Stream<String> get inboundFrames => wire.inboundFrames;
  @override
  Future<void> send(String frame) => wire.send(frame);
  @override
  Future<void> close() => wire.close();
}

class _Harness {
  _Harness(this.wire, {bool plain = false}) {
    repo = TrueNasSessionRepository(
      connector: _Connector(plain ? _PlainWire(wire) : wire),
      managementRequestTimeout: const Duration(milliseconds: 100),
      configurationBackupNow: () => now,
    );
  }
  final _Wire wire;
  late final TrueNasSessionRepository repo;
  DateTime now = DateTime.utc(2026, 9, 14);
}

Future<_Harness> _connected({
  void Function(_Wire)? configure,
  bool plain = false,
}) async {
  final wire = _Wire();
  configure?.call(wire);
  final h = _Harness(wire, plain: plain);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
    isConnectionCurrent: () => wire.current,
  );
  return h;
}

Future<ConfigurationBackupReview> _review(
  _Harness h, {
  bool seed = false,
  bool keys = false,
}) async => h.repo.reviewConfigurationBackup(
  ConfigurationBackupRequest(
    inventory: await h.repo.loadConfigurationBackup(),
    includeSecretSeed: seed,
    includeAuthorizedKeys: keys,
  ),
);
Future<ConfigurationBackupResult> _execute(
  _Harness h, {
  bool seed = false,
  bool keys = false,
}) async {
  final review = await _review(h, seed: seed, keys: keys);
  final warnings = review.warnings.join(' ');
  expect(
    warnings,
    contains('stored dataset encryption keys and other secrets may be present'),
  );
  expect(warnings, contains('Keep independent recovery-key backups.'));
  expect(
    warnings,
    isNot(contains('storage encryption recovery keys are not backed up')),
  );
  if (keys) {
    expect(warnings, contains('may already contain stored SSH private keys'));
  }
  return h.repo.executeConfigurationBackup(review, review.target);
}

Matcher _reason(ConfigurationBackupExceptionReason reason) =>
    isA<ConfigurationBackupException>().having(
      (e) => e.reason,
      'reason',
      reason,
    );
Uint8List _sqlite() {
  final bytes = Uint8List(512);
  bytes.setRange(0, 16, ascii.encode('SQLite format 3\u0000'));
  bytes[16] = 2;
  bytes[18] = 1;
  bytes[19] = 1;
  return bytes;
}

Uint8List _tar(
  Map<String, Uint8List> files, {
  bool pax = false,
  int type = 48,
}) {
  final builder = BytesBuilder();
  void add(String name, Uint8List data, int memberType) {
    final header = Uint8List(512);
    void put(int offset, String text) =>
        header.setRange(offset, offset + text.length, ascii.encode(text));
    put(0, name);
    put(100, '0000644');
    put(108, '0000000');
    put(116, '0000000');
    put(124, data.length.toRadixString(8).padLeft(11, '0'));
    put(136, '00000000000');
    header.fillRange(148, 156, 32);
    header[156] = memberType;
    put(257, 'ustar');
    put(263, '00');
    final checksum = header.fold<int>(0, (sum, byte) => sum + byte);
    put(148, checksum.toRadixString(8).padLeft(6, '0'));
    header[154] = 0;
    header[155] = 32;
    builder.add(header);
    builder.add(data);
    builder.add(Uint8List((512 - data.length % 512) % 512));
  }

  for (final entry in files.entries) {
    if (pax) {
      add(
        '././@PaxHeader',
        Uint8List.fromList(ascii.encode('30 mtime=1777777777.123456789\n')),
        120,
      );
    }
    add(entry.key, entry.value, type);
  }
  builder.add(Uint8List(1024));
  return builder.takeBytes();
}

void main() {
  _adversarialTests();
  _lifecycleTests();
  _fileTests();
  test('disconnected capability and methods are unavailable', () async {
    final repo = TrueNasSessionRepository(connector: _Connector(_Wire()));
    expect(repo.configurationBackupCapabilities.canExport, isFalse);
    await expectLater(
      repo.loadConfigurationBackup(),
      throwsA(_reason(ConfigurationBackupExceptionReason.notAuthenticated)),
    );
  });
  for (final plain in [true, false]) {
    test('unsupported transport $plain blocks before export', () async {
      final h = await _connected(
        plain: plain,
        configure: (wire) => wire.supported = false,
      );
      expect(h.repo.configurationBackupCapabilities.canExport, isFalse);
      await expectLater(
        h.repo.loadConfigurationBackup(),
        throwsA(
          _reason(ConfigurationBackupExceptionReason.unsupportedTransport),
        ),
      );
      expect(h.wire.transfers, isEmpty);
    });
  }
  for (final version in [
    '25.04.2',
    '26.04.0',
    '25.10.1-RC.1',
    '25.10-MASTER',
  ]) {
    test('unsupported version $version fails closed', () async {
      final h = await _connected(configure: (wire) => wire.version = version);
      await expectLater(
        h.repo.loadConfigurationBackup(),
        throwsA(_reason(ConfigurationBackupExceptionReason.unsupportedVersion)),
      );
    });
  }
  for (final method in _methods) {
    test('missing $method fails closed', () async {
      final h = await _connected(
        configure: (wire) => wire.methods.remove(method),
      );
      await expectLater(
        h.repo.loadConfigurationBackup(),
        throwsA(_reason(ConfigurationBackupExceptionReason.unavailableMethod)),
      );
    });
    for (final field in [
      'job',
      'downloadable',
      'uploadable',
      'no_auth_required',
      'private',
      '_private',
    ]) {
      test('unsafe $method metadata $field fails closed', () async {
        final expected =
            method == 'config.save' &&
            (field == 'job' || field == 'downloadable');
        final h = await _connected(
          configure: (wire) => wire.metadata[method] = {field: !expected},
        );
        await expectLater(
          h.repo.loadConfigurationBackup(),
          throwsA(
            _reason(ConfigurationBackupExceptionReason.unavailableMethod),
          ),
        );
      });
    }
  }
  for (final option in [
    (false, false),
    (true, false),
    (false, true),
    (true, true),
  ]) {
    test('exact backup payload and one-use artifact $option', () async {
      final h = await _connected();
      if (option.$1 || option.$2) {
        h.wire.bytes = _tar({
          'freenas-v1.db': _sqlite(),
          if (option.$1) 'pwenc_secret': Uint8List.fromList(List.filled(32, 7)),
          if (option.$2)
            'root_authorized_keys': Uint8List.fromList(
              ascii.encode('synthetic key'),
            ),
        }, pax: true);
      }
      final result = await _execute(h, seed: option.$1, keys: option.$2);
      expect(result.outcome, ConfigurationBackupOutcome.completed);
      expect(result.jobId, 71);
      expect(
        h.wire.calls
            .where((call) => call['method'] == 'core.download')
            .single['params'],
        [
          'config.save',
          [
            {
              'secretseed': option.$1,
              'pool_keys': false,
              'root_authorized_keys': option.$2,
            },
          ],
          option.$1 || option.$2
              ? 'truenas-configuration.tar'
              : 'truenas-configuration.db',
          false,
        ],
      );
      expect(
        h.wire.calls.any(
          (call) => [
            'config.save',
            'config.upload',
            'config.reset',
            'system.reboot',
            'system.shutdown',
          ].contains(call['method']),
        ),
        isFalse,
      );
      final artifact = result.artifact!;
      expect(artifact.includesSecretSeed, option.$1);
      expect(artifact.includesAuthorizedKeys, option.$2);
      final owned = artifact.takeBytes();
      expect(owned, same(h.wire.bytes));
      expect(artifact.isDisposed, isTrue);
      expect(() => artifact.takeBytes(), throwsStateError);
      owned.fillRange(0, owned.length, 0);
      expect(result.message, isNot(contains(_secret)));
    });
  }
}

void _adversarialTests() {
  final hostileReads = <String, List<Object?>>{
    'system.host_id': [null, '', 'host', 'A' * 64, '$_host\n'],
    'system.version_short': [null, '25.10.2', '25.10.1\n'],
    'system.state': [null, 'ready', _secret],
    'failover.licensed': [null, 'false', 0],
    'auth.me': [
      null,
      {},
      {'privilege': {}},
      {
        'privilege': {'roles': 'FULL_ADMIN'},
      },
      {
        'privilege': {
          'roles': ['FULL_ADMIN', 'FULL_ADMIN'],
        },
      },
      {
        'privilege': {
          'roles': ['FULL_ADMIN', _secret.toLowerCase()],
        },
      },
      {
        'privilege': {'roles': List.filled(1025, 'FULL_ADMIN')},
      },
    ],
  };
  for (final entry in hostileReads.entries) {
    for (var index = 0; index < entry.value.length; index++) {
      test('rejects hostile ${entry.key} shape $index', () async {
        final h = await _connected();
        h.wire.values[entry.key] = entry.value[index];
        await expectLater(
          h.repo.loadConfigurationBackup(),
          throwsA(isA<ConfigurationBackupException>()),
        );
        expect(
          h.wire.calls.any((call) => call['method'] == 'core.download'),
          isFalse,
        );
      });
    }
  }
  for (final change in <Map<String, Object?>>[
    {
      'auth.me': {
        'privilege': {
          'roles': ['READONLY_ADMIN'],
        },
      },
    },
    {'failover.licensed': true},
    {'system.state': 'BOOTING'},
    {'system.state': 'SHUTTING_DOWN'},
  ]) {
    test('safe readiness blocker ${change.keys.single}', () async {
      final h = await _connected();
      h.wire.values.addAll(change);
      final inventory = await h.repo.loadConfigurationBackup();
      expect(inventory.blockedReason, isNotNull);
      await expectLater(
        h.repo.reviewConfigurationBackup(
          ConfigurationBackupRequest(inventory: inventory),
        ),
        throwsA(_reason(ConfigurationBackupExceptionReason.invalidRequest)),
      );
    });
  }
  for (final jobs in <Object?>[
    null,
    {},
    List.filled(129, {}),
    [
      {'id': 1, 'method': 'config.save', 'state': 'SUCCESS'},
    ],
    [
      {'id': 0, 'method': 'config.save', 'state': 'RUNNING'},
    ],
    [
      {'id': 1, 'method': _secret, 'state': 'RUNNING'},
    ],
    [
      {'id': 1, 'method': 'config.save', 'state': 'RUNNING'},
      {'id': 1, 'method': 'config.save', 'state': 'RUNNING'},
    ],
  ]) {
    test(
      'invalid active-job projection fails closed ${jobs.hashCode}',
      () async {
        final h = await _connected();
        h.wire.jobs = jobs;
        await expectLater(
          h.repo.loadConfigurationBackup(),
          throwsA(_reason(ConfigurationBackupExceptionReason.invalidResponse)),
        );
      },
    );
  }
  test(
    'visible active job blocks review without retaining remote details',
    () async {
      final h = await _connected();
      h.wire.jobs = [
        {
          'id': 3,
          'method': 'config.save',
          'state': 'RUNNING',
          'arguments': _secret,
        },
      ];
      final inventory = await h.repo.loadConfigurationBackup();
      expect(inventory.conflictingJob, isTrue);
      expect(inventory.blockedReason, isNot(contains(_secret)));
    },
  );
  final badReceipts = <Object?>[
    null,
    {},
    [],
    [71],
    [71, _url, _secret],
    [0, _url],
    [-1, _url],
    [71.5, _url],
    [9007199254740992, _url],
    [71, null],
    for (final url in [
      'https://nas.example$_url',
      'https://evil.example$_url',
      '//evil.example$_url',
      '/_download/72?auth_token=${'a' * 64}',
      '/_download/071?auth_token=${'a' * 64}',
      '/_download/71?auth_token=abc',
      '/_download/71?auth_token=${'a' * 513}',
      '$_url&extra=1',
      '$_url#fragment',
      '$_url&auth_token=other',
      '$_url\n',
      '/_download/71?auth_token=${'%61' * 32}',
      '/_download/../71?auth_token=${'a' * 64}',
      '/_download/71?auth_token=${'a' * 32}+${'b' * 32}',
      '/_download/71?auth_token=${'a' * 32}=${'b' * 32}',
    ])
      [71, url],
  ];
  for (var index = 0; index < badReceipts.length; index++) {
    test('hostile download receipt $index never reaches HTTP', () async {
      final h = await _connected();
      h.wire.receipt = badReceipts[index];
      final result = await _execute(h);
      expect(result.outcome, ConfigurationBackupOutcome.unknown);
      expect(result.artifact, isNull);
      expect(h.wire.transfers, isEmpty);
      expect(result.message, isNot(contains('auth_token')));
      await expectLater(
        h.repo.loadConfigurationBackup(),
        throwsA(_reason(ConfigurationBackupExceptionReason.busy)),
      );
    });
  }
  for (final completion in <Object?>[
    null,
    [],
    {},
    [{}, {}],
    [{}],
    [
      {
        'id': 72,
        'method': 'config.save',
        'state': 'SUCCESS',
        'error': null,
        'result': null,
      },
    ],
    [
      {
        'id': 71,
        'method': 'config.upload',
        'state': 'SUCCESS',
        'error': null,
        'result': null,
      },
    ],
    for (final state in ['RUNNING', 'WAITING', _secret, null])
      [
        {
          'id': 71,
          'method': 'config.save',
          'state': state,
          'error': null,
          'result': null,
        },
      ],
    [
      {'id': 71, 'method': 'config.save', 'state': 'SUCCESS', 'result': null},
    ],
    [
      {'id': 71, 'method': 'config.save', 'state': 'SUCCESS', 'error': null},
    ],
    [
      {
        'id': 71,
        'method': 'config.save',
        'state': 'SUCCESS',
        'error': _secret,
        'result': null,
      },
    ],
    [
      {
        'id': 71,
        'method': 'config.save',
        'state': 'SUCCESS',
        'error': null,
        'result': _secret,
      },
    ],
  ]) {
    test(
      'unverified job completion ${completion.hashCode} discards bytes',
      () async {
        final h = await _connected();
        h.wire.completion = completion;
        final result = await _execute(h);
        expect(result.outcome, ConfigurationBackupOutcome.unknown);
        expect(result.artifact, isNull);
        expect(h.wire.bytes.every((byte) => byte == 0), isTrue);
        expect(result.message, isNot(contains(_secret)));
        expect(h.wire.transfers, hasLength(1));
      },
    );
  }
  for (final state in ['FAILED', 'ABORTED']) {
    test(
      'terminal $state job discards bytes and allows fresh readiness',
      () async {
        final h = await _connected();
        h.wire.completion = [
          {
            'id': 71,
            'method': 'config.save',
            'state': state,
            'error': _secret,
            'result': null,
          },
        ];
        final result = await _execute(h);
        expect(result.outcome, ConfigurationBackupOutcome.rejected);
        expect(result.artifact, isNull);
        expect(h.wire.bytes.every((byte) => byte == 0), isTrue);
        expect((await h.repo.loadConfigurationBackup()).blockedReason, isNull);
      },
    );
  }
}

void _lifecycleTests() {
  test('forged inventory is never reviewed', () async {
    final h = await _connected();
    const inventory = ConfigurationBackupInventory(
      endpoint: 'wss://nas.example/api/current',
      hostId: _host,
      currentVersion: '25.10.1',
      state: 'READY',
      fullAdmin: true,
      failoverLicensed: false,
      conflictingJob: false,
    );
    await expectLater(
      h.repo.reviewConfigurationBackup(
        const ConfigurationBackupRequest(inventory: inventory),
      ),
      throwsA(_reason(ConfigurationBackupExceptionReason.staleReview)),
    );
  });
  for (final action in [
    'bad-confirmation',
    'forged-review',
    'expired',
    'backwards-clock',
    'reload',
    'disconnect',
  ]) {
    test('consumed review rejects $action without download', () async {
      final h = await _connected();
      var review = await _review(h);
      var confirmation = review.target;
      switch (action) {
        case 'bad-confirmation':
          confirmation = 'BACKUP';
        case 'forged-review':
          review = ConfigurationBackupReview(
            request: review.request,
            endpoint: review.endpoint,
            warnings: [],
          );
        case 'expired':
          h.now = h.now.add(const Duration(minutes: 6));
        case 'backwards-clock':
          h.now = h.now.subtract(const Duration(seconds: 1));
        case 'reload':
          await h.repo.loadConfigurationBackup();
        case 'disconnect':
          h.wire.current = false;
      }
      final result = await h.repo.executeConfigurationBackup(
        review,
        confirmation,
      );
      expect(result.outcome, ConfigurationBackupOutcome.rejected);
      h.wire.current = true;
      h.now = DateTime.utc(2026, 9, 14);
      expect(
        (await h.repo.executeConfigurationBackup(
          review,
          review.target,
        )).outcome,
        ConfigurationBackupOutcome.rejected,
      );
      expect(
        h.wire.calls.where((call) => call['method'] == 'core.download'),
        isEmpty,
      );
    });
  }
  test('review expiry is checked again after preflight awaits', () async {
    final h = await _connected();
    final review = await _review(h);
    h.wire.beforeReply = (method, count) {
      if (method == 'auth.me') h.now = h.now.add(const Duration(minutes: 6));
    };
    expect(
      (await h.repo.executeConfigurationBackup(review, review.target)).outcome,
      ConfigurationBackupOutcome.rejected,
    );
    expect(h.wire.transfers, isEmpty);
  });
  for (final method in [
    'system.host_id',
    'system.version_short',
    'system.state',
    'auth.me',
  ]) {
    test('post-download changed $method discards bytes', () async {
      final h = await _connected();
      h.wire.beforeReply = (m, count) {
        if (m == method && h.wire.transfers.isNotEmpty) {
          h.wire.values[method] = switch (method) {
            'system.host_id' => 'f' * 64,
            'system.version_short' => '25.10.2',
            'system.state' => 'SHUTTING_DOWN',
            _ => {
              'privilege': {'roles': []},
            },
          };
        }
      };
      expect((await _execute(h)).outcome, ConfigurationBackupOutcome.unknown);
      expect(h.wire.bytes.every((byte) => byte == 0), isTrue);
    });
  }
  test('readiness identity changes mid-read reject before export', () async {
    final h = await _connected();
    h.wire.beforeReply = (method, count) {
      if (method == 'system.host_id' && count == 2) {
        h.wire.values[method] = 'f' * 64;
      }
    };
    await expectLater(
      h.repo.loadConfigurationBackup(),
      throwsA(_reason(ConfigurationBackupExceptionReason.staleReview)),
    );
    expect(h.wire.transfers, isEmpty);
  });
  for (final fault in ['core.download', 'core.get_jobs']) {
    test('remote $fault error is sanitized', () async {
      final h = await _connected();
      final review = await _review(h);
      h.wire.faultMethod = fault;
      final result = await h.repo.executeConfigurationBackup(
        review,
        review.target,
      );
      expect(result.message, isNot(contains(_secret)));
      expect(result.artifact, isNull);
      expect(
        result.outcome,
        fault == 'core.download'
            ? ConfigurationBackupOutcome.unknown
            : ConfigurationBackupOutcome.rejected,
      );
    });
  }
  test('late timed-out download buffer is wiped and never retried', () async {
    final h = await _connected();
    final held = Completer<Uint8List>();
    h.wire.heldTransfer = held;
    final result = await _execute(h);
    expect(result.outcome, ConfigurationBackupOutcome.unknown);
    expect(result.artifact, isNull);
    held.complete(h.wire.bytes);
    await Future<void>.delayed(Duration.zero);
    expect(h.wire.bytes.every((byte) => byte == 0), isTrue);
    expect(h.wire.transfers, hasLength(1));
  });
  test('session loss during transfer discards late sensitive bytes', () async {
    final h = await _connected();
    final held = Completer<Uint8List>();
    h.wire.heldTransfer = held;
    final future = _execute(h);
    while (h.wire.transfers.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    h.wire.current = false;
    held.complete(h.wire.bytes);
    final result = await future;
    expect(result.outcome, ConfigurationBackupOutcome.unknown);
    expect(h.wire.bytes.every((byte) => byte == 0), isTrue);
  });
  test(
    'in-flight backup and unknown fence block disk workspace SDK peer',
    () async {
      final h = await _connected(
        configure: (wire) {
          wire.methods.addAll({
            'disk.query',
            'device.get_info',
            'boot.get_disks',
            'disk.update',
          });
          _powerSetup(wire);
        },
      );
      final held = Completer<Uint8List>();
      h.wire.heldTransfer = held;
      final future = _execute(h);
      while (h.wire.transfers.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(
        h.repo.reviewDisk(_diskRequest()),
        throwsA(
          isA<DisksException>().having(
            (e) => e.reason,
            'reason',
            DisksExceptionReason.busy,
          ),
        ),
      );
      await expectLater(
        h.repo.loadConfigurationBackup(),
        throwsA(_reason(ConfigurationBackupExceptionReason.busy)),
      );
      await expectLater(
        h.repo.loadSystemPower(),
        throwsA(
          isA<SystemPowerException>().having(
            (e) => e.reason,
            'reason',
            SystemPowerExceptionReason.busy,
          ),
        ),
      );
      held.completeError(StateError(_secret));
      expect((await future).outcome, ConfigurationBackupOutcome.unknown);
      await expectLater(
        h.repo.reviewDisk(_diskRequest()),
        throwsA(
          isA<DisksException>().having(
            (e) => e.reason,
            'reason',
            DisksExceptionReason.busy,
          ),
        ),
      );
      await expectLater(
        h.repo.loadSystemPower(),
        throwsA(
          isA<SystemPowerException>().having(
            (e) => e.reason,
            'reason',
            SystemPowerExceptionReason.busy,
          ),
        ),
      );
    },
  );
  test(
    'in-flight disk read excludes backup and consumes attempted lease',
    () async {
      final h = await _connected(
        configure: (wire) {
          wire.methods.addAll({
            'disk.query',
            'device.get_info',
            'boot.get_disks',
          });
          wire.values.addAll({
            'disk.query': [],
            'device.get_info': {},
            'boot.get_disks': [],
          });
        },
      );
      final review = await _review(h);
      h.wire.heldRpc = Completer<void>();
      h.wire.heldRpcMethod = 'disk.query';
      final diskLoad = h.repo.loadDisks();
      while (!h.wire.calls.any((call) => call['method'] == 'disk.query')) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(
        h.repo.loadConfigurationBackup(),
        throwsA(_reason(ConfigurationBackupExceptionReason.busy)),
      );
      final rejected = await h.repo.executeConfigurationBackup(
        review,
        review.target,
      );
      expect(rejected.outcome, ConfigurationBackupOutcome.rejected);
      expect(rejected.message, contains('Another operation'));
      h.wire.heldRpc!.complete();
      await diskLoad;
      expect(
        (await h.repo.executeConfigurationBackup(
          review,
          review.target,
        )).outcome,
        ConfigurationBackupOutcome.rejected,
      );
      expect(h.wire.transfers, isEmpty);
    },
  );
  for (final unknown in [false, true]) {
    test('in-flight and terminal power $unknown exclude backup', () async {
      final h = await _connected(configure: _powerSetup);
      final backup = await _review(h);
      final inventory = await h.repo.loadSystemPower();
      final power = await h.repo.reviewSystemPower(
        SystemPowerRequest(
          inventory: inventory,
          action: SystemPowerAction.reboot,
          reason: 'Synthetic test',
        ),
      );
      h.wire.heldRpc = Completer<void>();
      h.wire.heldRpcMethod = 'system.reboot';
      if (unknown) h.wire.faultMethod = 'system.reboot';
      final resultFuture = h.repo.executeSystemPower(power, power.target);
      while (!h.wire.calls.any((call) => call['method'] == 'system.reboot')) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(
        h.repo.loadConfigurationBackup(),
        throwsA(_reason(ConfigurationBackupExceptionReason.busy)),
      );
      final blocked = await h.repo.executeConfigurationBackup(
        backup,
        backup.target,
      );
      expect(blocked.outcome, ConfigurationBackupOutcome.rejected);
      expect(blocked.message, contains('Another operation'));
      h.wire.heldRpc!.complete();
      expect(
        (await resultFuture).outcome,
        unknown ? SystemPowerOutcome.unknown : SystemPowerOutcome.accepted,
      );
      await expectLater(
        h.repo.loadConfigurationBackup(),
        throwsA(_reason(ConfigurationBackupExceptionReason.busy)),
      );
      expect(h.wire.transfers, isEmpty);
    });
  }
  test('artifact dispose wipes buffer without exposing remote values', () {
    final bytes = _sqlite();
    final artifact = ConfigurationBackupArtifact(
      bytes: bytes,
      filename: 'truenas-configuration.db',
      includesSecretSeed: false,
      includesAuthorizedKeys: false,
    );
    artifact.dispose();
    artifact.dispose();
    expect(artifact.byteLength, 0);
    expect(bytes.every((byte) => byte == 0), isTrue);
    expect(() => artifact.takeBytes(), throwsStateError);
  });
}

DiskRequest _diskRequest() {
  const disk = DiskSnapshot(
    identifier: '{serial}SYNTHETIC',
    name: 'sda',
    serial: 'SYNTHETIC',
    lunid: null,
    sizeBytes: 1024,
    model: null,
    type: 'HDD',
    bus: 'ATA',
    description: '',
    hddStandby: 'ALWAYS ON',
    advancedPowerManagement: 'DISABLED',
    pool: null,
    zfsGuid: null,
    rotationRate: 7200,
    identityVerified: true,
  );
  return DiskRequest(
    inventory: DiskInventory(
      endpoint: 'wss://nas.example/api/current',
      failoverLicensed: false,
      disks: [disk],
    ),
    disk: disk,
    settings: const DiskSettings(
      description: 'Synthetic changed',
      hddStandby: 'ALWAYS ON',
      advancedPowerManagement: 'DISABLED',
    ),
  );
}

void _powerSetup(_Wire wire) {
  wire.methods.addAll({
    'system.reboot.info',
    'boot.get_state',
    'boot.environment.query',
    'system.reboot',
    'system.shutdown',
  });
  wire.metadata['system.reboot'] = {'job': true};
  wire.metadata['system.shutdown'] = {'job': true};
  wire.values.addAll({
    'system.reboot': 73,
    'system.reboot.info': {
      'boot_id': '11111111-2222-4333-8444-555555555555',
      'reboot_required_reasons': [],
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
        'used_bytes': 4000,
        'active': true,
        'activated': true,
        'keep': true,
        'can_activate': true,
      },
    ],
  });
}

void _fileTests() {
  final cases = <String, Uint8List Function()>{
    'empty': () => Uint8List(0),
    'too-large': () => Uint8List(16 * 1024 * 1024 + 1),
    'text': () => Uint8List.fromList(ascii.encode(_secret)),
    'zeroes': () => Uint8List(512),
    'bad-page-size': () => _sqlite()..[16] = 3,
    'bad-write-version': () => _sqlite()..[18] = 0,
    'bad-read-version': () => _sqlite()..[19] = 9,
    'truncated-page': () => Uint8List.sublistView(_sqlite(), 0, 511),
    'tar-when-db-selected': () => _tar({'freenas-v1.db': _sqlite()}),
  };
  for (final entry in cases.entries) {
    test('database envelope rejects ${entry.key}', () async {
      final h = await _connected();
      h.wire.bytes = entry.value();
      expect((await _execute(h)).outcome, ConfigurationBackupOutcome.unknown);
      expect(h.wire.bytes.every((byte) => byte == 0), isTrue);
    });
  }
  final tarCases = <String, Uint8List Function()>{
    'database-only': _sqlite,
    'missing-seed': () => _tar({'freenas-v1.db': _sqlite()}),
    'missing-db': () => _tar({'pwenc_secret': Uint8List(32)}),
    'empty-seed': () =>
        _tar({'freenas-v1.db': _sqlite(), 'pwenc_secret': Uint8List(0)}),
    'oversized-seed': () =>
        _tar({'freenas-v1.db': _sqlite(), 'pwenc_secret': Uint8List(4097)}),
    'traversal': () =>
        _tar({'freenas-v1.db': _sqlite(), '../pwenc_secret': Uint8List(32)}),
    'extra-member': () => _tar({
      'freenas-v1.db': _sqlite(),
      'pwenc_secret': Uint8List(32),
      'extra': Uint8List(0),
    }),
    'unexpected-keys': () => _tar({
      'freenas-v1.db': _sqlite(),
      'pwenc_secret': Uint8List(32),
      'root_authorized_keys': Uint8List(0),
    }),
    'symlink': () => _tar({
      'freenas-v1.db': _sqlite(),
      'pwenc_secret': Uint8List(32),
    }, type: 50),
    'bad-checksum': () =>
        _tar({'freenas-v1.db': _sqlite(), 'pwenc_secret': Uint8List(32)})
          ..[0] = 0,
    'bad-sqlite': () =>
        _tar({'freenas-v1.db': Uint8List(512), 'pwenc_secret': Uint8List(32)}),
    'missing-zero-end': () =>
        _tar({'freenas-v1.db': _sqlite(), 'pwenc_secret': Uint8List(32)})
            .sublist(0, 2048),
  };
  for (final entry in tarCases.entries) {
    test('tar envelope rejects ${entry.key}', () async {
      final h = await _connected();
      h.wire.bytes = entry.value();
      expect(
        (await _execute(h, seed: true)).outcome,
        ConfigurationBackupOutcome.unknown,
      );
      expect(h.wire.bytes.every((byte) => byte == 0), isTrue);
    });
  }
  test(
    'requested authorized-key option permits absent optional files',
    () async {
      final h = await _connected();
      h.wire.bytes = _tar({'freenas-v1.db': _sqlite()});
      final result = await _execute(h, keys: true);
      expect(result.outcome, ConfigurationBackupOutcome.completed);
      result.artifact!.dispose();
    },
  );
}
