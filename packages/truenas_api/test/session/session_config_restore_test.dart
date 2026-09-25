import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _boot = '11111111-2222-4333-8444-555555555555';
const _secret = 'SYNTHETIC_PRIVATE_DATA';
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
const _methods = {..._reads, 'auth.generate_token', 'config.upload'};
final _token = 't' * 64;

Map<String, Object?> _environment() => {
  'id': '25.10.1',
  'dataset': 'boot-pool/ROOT/25.10.1',
  'created': '2026-09-14T01:00:00',
  'used_bytes': 4000,
  'active': true,
  'activated': true,
  'keep': true,
  'can_activate': true,
};

class _Wire
    implements
        RpcTransport,
        ConfigurationRestoreUploadTransport,
        ConfigurationBackupDownloadTransport {
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final uploads = <Uint8List>[];
  final uploadSnapshots = <Uint8List>[];
  final tokens = <String>[];
  final values = <String, Object?>{
    'system.version_short': '25.10.1',
    'system.host_id': _host,
    'system.reboot.info': {'boot_id': _boot, 'reboot_required_reasons': []},
    'system.state': 'READY',
    'failover.licensed': false,
    'boot.get_state': {
      'name': 'boot-pool',
      'healthy': true,
      'status': 'ONLINE',
      'scan': null,
    },
    'boot.environment.query': [_environment()],
    'core.get_jobs': [],
    'auth.me': {
      'privilege': {
        'roles': ['FULL_ADMIN'],
      },
      'pw_gecos': _secret,
    },
    'auth.generate_token': _token,
    'system.reboot': 73,
  };
  final methods = <String>{..._methods};
  final metadata = <String, Map<String, Object?>>{};
  final counts = <String, int>{};
  String version = '25.10.1';
  bool current = true, supported = true;
  int receipt = 71;
  String? faultMethod, heldMethod;
  Completer<void>? heldRpc;
  Completer<int>? heldUpload;
  Object? uploadError;
  bool synchronousUploadError = false;
  void Function(String method, int count)? beforeReply;
  @override
  bool get configurationRestoreUploadSupported => supported;
  @override
  bool get configurationBackupDownloadSupported => supported;
  @override
  Future<Uint8List> downloadConfigurationBackup({
    required String relativeUrl,
    required int jobId,
  }) => throw StateError('Unexpected backup download.');
  @override
  Future<int> uploadConfigurationRestore({
    required String token,
    required Uint8List bytes,
  }) {
    tokens.add(token);
    uploads.add(bytes);
    uploadSnapshots.add(Uint8List.fromList(bytes));
    if (synchronousUploadError) throw StateError(_secret);
    if (uploadError != null) return Future<int>.error(uploadError!);
    return heldUpload?.future ?? Future.value(receipt);
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
    if (method == heldMethod) await heldRpc!.future;
    if (method == faultMethod) {
      if (!inbound.isClosed) {
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
      }
      return;
    }
    final Object? value = switch (method) {
      'auth.login_ex' => {'response_type': 'SUCCESS'},
      'system.info' => {'version': version},
      'core.get_methods' => {
        for (final name in methods)
          name: {
            'job': [
              'config.upload',
              'config.save',
              'system.reboot',
              'system.shutdown',
            ].contains(name),
            'uploadable': name == 'config.upload',
            'downloadable': name == 'config.save',
            'no_auth_required': false,
            ...?metadata[name],
          },
      },
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
  const _Connector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

class _PlainWire implements RpcTransport {
  const _PlainWire(this.wire);
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
      configurationRestoreNow: () => now,
      managementRequestTimeout: const Duration(milliseconds: 100),
    );
  }
  final _Wire wire;
  late final TrueNasSessionRepository repo;
  DateTime now = DateTime.utc(2026, 9, 14);
  bool authorized = true;
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

Future<ConfigurationRestoreReview> _review(
  _Harness h, {
  Uint8List? bytes,
}) async {
  final inventory = await h.repo.loadConfigurationRestore();
  final file = await h.repo.prepareConfigurationRestore(bytes ?? _sqlite());
  return h.repo.reviewConfigurationRestore(
    ConfigurationRestoreRequest(inventory: inventory, file: file),
  );
}

Future<ConfigurationRestoreResult> _execute(
  _Harness h, {
  Uint8List? bytes,
}) async {
  final review = await _review(h, bytes: bytes);
  return h.repo.executeConfigurationRestore(
    review,
    review.target,
    isCurrent: () => h.authorized,
  );
}

Matcher _reason(ConfigurationRestoreExceptionReason reason) =>
    isA<ConfigurationRestoreException>().having(
      (e) => e.reason,
      'reason',
      reason,
    );
Uint8List _sqlite([int length = 512]) {
  final bytes = Uint8List(length);
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
  _fileTests();
  _lifecycleTests();
  _readinessTests();
  _peerTests();
  test(
    'disconnected preparation consumes sensitive input without transport',
    () async {
      final repo = TrueNasSessionRepository(connector: _Connector(_Wire()));
      final bytes = _sqlite();
      expect(repo.configurationRestoreCapabilities.canRestore, isFalse);
      await expectLater(
        repo.prepareConfigurationRestore(bytes),
        throwsA(_reason(ConfigurationRestoreExceptionReason.notAuthenticated)),
      );
      expect(bytes.every((byte) => byte == 0), isTrue);
    },
  );
  for (final plain in [false, true]) {
    test(
      'unsupported transport $plain blocks local prepare and readiness',
      () async {
        final h = await _connected(
          plain: plain,
          configure: (wire) => wire.supported = false,
        );
        await expectLater(
          h.repo.loadConfigurationRestore(),
          throwsA(
            _reason(ConfigurationRestoreExceptionReason.unsupportedTransport),
          ),
        );
        final bytes = _sqlite();
        await expectLater(
          h.repo.prepareConfigurationRestore(bytes),
          throwsA(
            _reason(ConfigurationRestoreExceptionReason.unsupportedTransport),
          ),
        );
        expect(bytes.every((byte) => byte == 0), isTrue);
        expect(h.wire.uploads, isEmpty);
      },
    );
  }
  for (final version in [
    '25.04.2',
    '26.04.0',
    '25.10.1-RC.1',
    '25.10-MASTER',
  ]) {
    test('unsupported version $version', () async {
      final h = await _connected(configure: (wire) => wire.version = version);
      await expectLater(
        h.repo.loadConfigurationRestore(),
        throwsA(
          _reason(ConfigurationRestoreExceptionReason.unsupportedVersion),
        ),
      );
    });
  }
  for (final method in _methods) {
    test('missing $method fails closed', () async {
      final h = await _connected(
        configure: (wire) => wire.methods.remove(method),
      );
      await expectLater(
        h.repo.loadConfigurationRestore(),
        throwsA(_reason(ConfigurationRestoreExceptionReason.unavailableMethod)),
      );
    });
    for (final field in [
      'job',
      'uploadable',
      'downloadable',
      'no_auth_required',
      'private',
      '_private',
    ]) {
      test('invalid metadata $method $field fails closed', () async {
        final expected =
            method == 'config.upload' &&
            (field == 'job' || field == 'uploadable');
        final h = await _connected(
          configure: (wire) => wire.metadata[method] = {field: !expected},
        );
        await expectLater(
          h.repo.loadConfigurationRestore(),
          throwsA(
            _reason(ConfigurationRestoreExceptionReason.unavailableMethod),
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
    test(
      'capsule actual metadata and exact single accepted upload $option',
      () async {
        final h = await _connected();
        final bytes = !option.$1 && !option.$2
            ? _sqlite()
            : _tar({
                'freenas-v1.db': _sqlite(),
                if (option.$1)
                  'pwenc_secret': Uint8List.fromList(List.filled(32, 7)),
                if (option.$2)
                  'admin_authorized_keys': Uint8List.fromList(
                    ascii.encode('synthetic authorized key'),
                  ),
              }, pax: true);
        final original = Uint8List.fromList(bytes);
        final before = h.wire.calls.length;
        final file = await h.repo.prepareConfigurationRestore(bytes);
        expect(h.wire.calls, hasLength(before));
        expect(bytes.every((byte) => byte == 0), isTrue);
        expect(file.sha256, crypto.sha256.convert(original).toString());
        expect(file.byteLength, original.length);
        expect(file.hasSecretSeed, option.$1);
        expect(
          file.authorizedKeyMembers,
          option.$2 ? ['admin_authorized_keys'] : [],
        );
        final inventory = await h.repo.loadConfigurationRestore();
        final review = await h.repo.reviewConfigurationRestore(
          ConfigurationRestoreRequest(inventory: inventory, file: file),
        );
        expect(review.target, 'RESTORE $_host');
        final result = await h.repo.executeConfigurationRestore(
          review,
          review.target,
          isCurrent: () => true,
        );
        expect(result.outcome, ConfigurationRestoreOutcome.accepted);
        expect(result.jobId, 71);
        expect(
          h.wire.calls
              .where((call) => call['method'] == 'auth.generate_token')
              .single['params'],
          [60, {}, true, true],
        );
        expect(h.wire.uploadSnapshots.single, original);
        expect(h.wire.tokens, [_token]);
        expect(h.wire.uploads.single.every((byte) => byte == 0), isTrue);
        expect(file.isDisposed, isTrue);
        expect(
          h.wire.calls.any(
            (call) => [
              'config.upload',
              'config.reset',
              'system.reboot',
              'system.shutdown',
              'core.download',
            ].contains(call['method']),
          ),
          isFalse,
        );
        await expectLater(
          h.repo.loadConfigurationRestore(),
          throwsA(_reason(ConfigurationRestoreExceptionReason.busy)),
        );
        expect(result.message, isNot(contains(_token)));
        expect(result.message, isNot(contains(_secret)));
      },
    );
  }
}

void _peerTests() {
  void peers(_Wire wire) => wire.methods.addAll({
    'config.save',
    'core.download',
    'system.reboot',
    'system.shutdown',
    'disk.query',
    'device.get_info',
    'boot.get_disks',
    'disk.update',
  });
  for (final unknown in [false, true]) {
    test(
      'in-flight and terminal restore $unknown exclude backup power and disk mutation',
      () async {
        final h = await _connected(configure: peers);
        h.wire.heldUpload = Completer<int>();
        final resultFuture = _execute(h);
        while (h.wire.uploads.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        Future<void> check() async {
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
          await expectLater(
            h.repo.loadConfigurationBackup(),
            throwsA(
              isA<ConfigurationBackupException>().having(
                (e) => e.reason,
                'reason',
                ConfigurationBackupExceptionReason.busy,
              ),
            ),
          );
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
          final bytes = _sqlite();
          await expectLater(
            h.repo.prepareConfigurationRestore(bytes),
            throwsA(_reason(ConfigurationRestoreExceptionReason.busy)),
          );
          expect(bytes.every((byte) => byte == 0), isTrue);
        }

        await check();
        if (unknown) {
          h.wire.heldUpload!.completeError(StateError(_secret));
        } else {
          h.wire.heldUpload!.complete(71);
        }
        expect(
          (await resultFuture).outcome,
          unknown
              ? ConfigurationRestoreOutcome.unknown
              : ConfigurationRestoreOutcome.accepted,
        );
        await check();
        expect(h.wire.uploads, hasLength(1));
      },
    );
  }
  for (final peer in ['power', 'backup', 'disk']) {
    test(
      'in-flight $peer readiness excludes restore and consumes attempted lease',
      () async {
        final h = await _connected(configure: peers);
        final review = await _review(h);
        h.wire.values.addAll({
          'disk.query': [],
          'device.get_info': {},
          'boot.get_disks': [],
        });
        h.wire.heldRpc = Completer<void>();
        h.wire.heldMethod = switch (peer) {
          'disk' => 'disk.query',
          'backup' => 'auth.me',
          _ => 'system.reboot.info',
        };
        final initialCount = h.wire.counts[h.wire.heldMethod] ?? 0;
        final Future<Object?> pending = switch (peer) {
          'disk' => h.repo.loadDisks(),
          'backup' => h.repo.loadConfigurationBackup(),
          _ => h.repo.loadSystemPower(),
        };
        while ((h.wire.counts[h.wire.heldMethod] ?? 0) == initialCount) {
          await Future<void>.delayed(Duration.zero);
        }
        final rejected = await h.repo.executeConfigurationRestore(
          review,
          review.target,
          isCurrent: () => true,
        );
        expect(rejected.outcome, ConfigurationRestoreOutcome.rejected);
        expect(rejected.message, contains('Another operation'));
        expect(review.request.file.isDisposed, isTrue);
        h.wire.heldRpc!.complete();
        await pending;
        expect(
          (await h.repo.executeConfigurationRestore(
            review,
            review.target,
            isCurrent: () => true,
          )).outcome,
          ConfigurationRestoreOutcome.rejected,
        );
        expect(h.wire.uploads, isEmpty);
      },
    );
  }
  for (final unknown in [false, true]) {
    test('terminal power $unknown blocks restore token and upload', () async {
      final h = await _connected(configure: peers);
      final restore = await _review(h);
      final inventory = await h.repo.loadSystemPower();
      final power = await h.repo.reviewSystemPower(
        SystemPowerRequest(
          inventory: inventory,
          action: SystemPowerAction.reboot,
          reason: 'Synthetic',
        ),
      );
      if (unknown) h.wire.faultMethod = 'system.reboot';
      final result = await h.repo.executeSystemPower(power, power.target);
      expect(
        result.outcome,
        unknown ? SystemPowerOutcome.unknown : SystemPowerOutcome.accepted,
      );
      final blocked = await h.repo.executeConfigurationRestore(
        restore,
        restore.target,
        isCurrent: () => true,
      );
      expect(blocked.outcome, ConfigurationRestoreOutcome.rejected);
      expect(blocked.message, contains('Another operation'));
      expect(h.wire.uploads, isEmpty);
      expect(h.wire.tokens, isEmpty);
    });
  }
  test('a failed reconnect disposes previous repository-issued file', () async {
    final h = await _connected();
    final file = await h.repo.prepareConfigurationRestore(_sqlite());
    await expectLater(
      h.repo.connect(
        serverInput: 'http://insecure.example',
        apiKey: 'synthetic',
        username: 'admin',
      ),
      throwsA(anything),
    );
    expect(file.isDisposed, isTrue);
    expect(h.repo.configurationRestoreCapabilities.connected, isFalse);
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

void _fileTests() {
  final malformed = <String, Uint8List Function()>{
    'empty': () => Uint8List(0),
    'too-small': () => Uint8List(511),
    'too-large': () => _sqlite(10485760 + 512),
    'bad-magic': () => Uint8List(512),
    'bad-page-size': () => _sqlite()..[16] = 3,
    'bad-write-format': () => _sqlite()..[18] = 0,
    'truncated-page': () => Uint8List.fromList([..._sqlite(), 0]),
    'tar-missing-db': () => _tar({'pwenc_secret': Uint8List(32)}),
    'tar-empty-seed': () =>
        _tar({'freenas-v1.db': _sqlite(), 'pwenc_secret': Uint8List(0)}),
    'tar-unexpected-member': () =>
        _tar({'freenas-v1.db': _sqlite(), 'evil': Uint8List(0)}),
    'tar-traversal': () => _tar({'../freenas-v1.db': _sqlite()}),
    'tar-symlink': () => _tar({'freenas-v1.db': _sqlite()}, type: 50),
    'tar-invalid-db': () => _tar({'freenas-v1.db': Uint8List(512)}),
    'tar-checksum': () => _tar({'freenas-v1.db': _sqlite()})..[0] = 0,
    'tar-not-terminated': () =>
        _tar({'freenas-v1.db': _sqlite()}).sublist(0, 1024),
    'tar-unsupported-pax': () =>
        _tar({'freenas-v1.db': _sqlite()}, pax: true)..[515] = 120,
  };
  for (final entry in malformed.entries) {
    test('invalid local ${entry.key} is wiped without RPC', () async {
      final h = await _connected();
      final before = h.wire.calls.length;
      final bytes = entry.value();
      await expectLater(
        h.repo.prepareConfigurationRestore(bytes),
        throwsA(_reason(ConfigurationRestoreExceptionReason.invalidFile)),
      );
      expect(bytes.every((byte) => byte == 0), isTrue);
      expect(h.wire.calls, hasLength(before));
      expect(h.wire.uploads, isEmpty);
    });
  }
  test(
    'exact 10MiB local envelope is admitted but 16MiB backup is not',
    () async {
      final h = await _connected();
      final accepted = _sqlite(10485760);
      final file = await h.repo.prepareConfigurationRestore(accepted);
      expect(file.byteLength, 10485760);
      file.dispose();
      final rejected = _sqlite(16 * 1024 * 1024);
      await expectLater(
        h.repo.prepareConfigurationRestore(rejected),
        throwsA(_reason(ConfigurationRestoreExceptionReason.invalidFile)),
      );
      expect(rejected.every((byte) => byte == 0), isTrue);
    },
  );
  test(
    'archive reports each actual authorized-key member and missing seed',
    () async {
      final h = await _connected();
      final file = await h.repo.prepareConfigurationRestore(
        _tar({
          'freenas-v1.db': _sqlite(),
          'root_authorized_keys': Uint8List(0),
          'truenas_admin_authorized_keys': Uint8List(0),
          'admin_authorized_keys': Uint8List(0),
        }, pax: true),
      );
      expect(file.format, ConfigurationRestoreFormat.tar);
      expect(file.hasSecretSeed, isFalse);
      expect(file.authorizedKeyMembers, [
        'admin_authorized_keys',
        'root_authorized_keys',
        'truenas_admin_authorized_keys',
      ]);
      expect(
        () => file.authorizedKeyMembers.add('evil'),
        throwsUnsupportedError,
      );
    },
  );
  test(
    'new local file invalidates and disposes previously issued capsule',
    () async {
      final h = await _connected();
      final old = await h.repo.prepareConfigurationRestore(_sqlite());
      final fresh = await h.repo.prepareConfigurationRestore(_sqlite());
      expect(old.isDisposed, isTrue);
      expect(fresh.isDisposed, isFalse);
      await h.repo.close();
      expect(fresh.isDisposed, isTrue);
    },
  );
  test(
    'external factory capsule cannot forge repository-issued input',
    () async {
      final h = await _connected();
      final inventory = await h.repo.loadConfigurationRestore();
      final file = ConfigurationRestoreFile.fromBytes(_sqlite());
      addTearDown(file.dispose);
      await expectLater(
        h.repo.reviewConfigurationRestore(
          ConfigurationRestoreRequest(inventory: inventory, file: file),
        ),
        throwsA(_reason(ConfigurationRestoreExceptionReason.staleReview)),
      );
      expect(h.wire.uploads, isEmpty);
    },
  );
  test('review warns automatic reboot missing material and stored secrets without claiming validation', () async {
    final h = await _connected();
    final review = await _review(h);
    final text = review.warnings.join(' ');
    expect(text, contains('automatically requests a reboot'));
    expect(text, contains('NO PASSWORD SECRET SEED'));
    expect(
      text,
      contains(
        'removes existing admin, truenas_admin and root authorized-key files',
      ),
    );
    expect(
      text,
      contains(
        'stored dataset encryption keys, SSH private keys and other secrets',
      ),
    );
    expect(
      text,
      contains(
        'source server, TrueNAS version, authenticity, database integrity',
      ),
    );
    expect(text, contains('inherits session privileges'));
    expect(text, contains('not restricted to this method'));
  });
}

void _lifecycleTests() {
  for (final change in [
    'confirmation',
    'forged-review',
    'file-dispose',
    'file-replace',
    'reload',
    'expired',
    'backwards-clock',
    'session',
    'foreground',
  ]) {
    test('single-use review rejects $change without token or upload', () async {
      final h = await _connected();
      var review = await _review(h);
      var confirmation = review.target;
      switch (change) {
        case 'confirmation':
          confirmation = 'RESTORE';
        case 'forged-review':
          review = ConfigurationRestoreReview(
            request: review.request,
            endpoint: review.endpoint,
            warnings: [],
          );
        case 'file-dispose':
          review.request.file.dispose();
        case 'file-replace':
          await h.repo.prepareConfigurationRestore(_sqlite());
        case 'reload':
          await h.repo.loadConfigurationRestore();
        case 'expired':
          h.now = h.now.add(const Duration(minutes: 6));
        case 'backwards-clock':
          h.now = h.now.subtract(const Duration(seconds: 1));
        case 'session':
          h.wire.current = false;
        case 'foreground':
          h.authorized = false;
      }
      final result = await h.repo.executeConfigurationRestore(
        review,
        confirmation,
        isCurrent: () => h.authorized,
      );
      expect(result.outcome, ConfigurationRestoreOutcome.rejected);
      h.authorized = true;
      h.wire.current = true;
      h.now = DateTime.utc(2026, 9, 14);
      expect(
        (await h.repo.executeConfigurationRestore(
          review,
          review.target,
          isCurrent: () => true,
        )).outcome,
        ConfigurationRestoreOutcome.rejected,
      );
      expect(h.wire.tokens, isEmpty);
      expect(
        h.wire.calls.where((call) => call['method'] == 'auth.generate_token'),
        isEmpty,
      );
    });
  }
  for (final phase in [
    'auth.me',
    'system.host_id',
    'boot.get_state',
    'auth.generate_token',
  ]) {
    for (final cancel in ['foreground', 'file', 'expiry', 'session']) {
      test('preflight $phase then $cancel prevents upload', () async {
        final h = await _connected();
        final review = await _review(h);
        h.wire.beforeReply = (method, count) {
          if (method != phase) return;
          switch (cancel) {
            case 'foreground':
              h.authorized = false;
            case 'file':
              review.request.file.dispose();
            case 'expiry':
              h.now = h.now.add(const Duration(minutes: 6));
            case 'session':
              h.wire.current = false;
          }
        };
        final result = await h.repo.executeConfigurationRestore(
          review,
          review.target,
          isCurrent: () => h.authorized,
        );
        expect(result.outcome, ConfigurationRestoreOutcome.rejected);
        expect(h.wire.uploads, isEmpty);
        expect(review.request.file.isDisposed, isTrue);
        expect(result.message, isNot(contains(_token)));
        expect(result.message, isNot(contains(_secret)));
      });
    }
  }
  test('throwing foreground callback fails closed without token', () async {
    final h = await _connected();
    final review = await _review(h);
    final result = await h.repo.executeConfigurationRestore(
      review,
      review.target,
      isCurrent: () => throw StateError(_secret),
    );
    expect(result.outcome, ConfigurationRestoreOutcome.rejected);
    expect(h.wire.uploads, isEmpty);
    expect(result.message, isNot(contains(_secret)));
  });
  for (final value in <Object?>[
    null,
    true,
    71,
    {},
    [],
    '',
    'a' * 31,
    'a' * 513,
    '$_token\n',
    '$_token=',
    '$_token&x=1',
  ]) {
    test(
      'invalid generated token ${value.hashCode} never reaches upload',
      () async {
        final h = await _connected();
        h.wire.values['auth.generate_token'] = value;
        expect(
          (await _execute(h)).outcome,
          ConfigurationRestoreOutcome.rejected,
        );
        expect(h.wire.uploads, isEmpty);
      },
    );
  }
  for (final fault in ['auth.generate_token', 'system.host_id']) {
    test('pre-upload remote $fault error is sanitized and rejected', () async {
      final h = await _connected();
      final review = await _review(h);
      h.wire.faultMethod = fault;
      final result = await h.repo.executeConfigurationRestore(
        review,
        review.target,
        isCurrent: () => true,
      );
      expect(result.outcome, ConfigurationRestoreOutcome.rejected);
      expect(h.wire.uploads, isEmpty);
      expect(result.message, isNot(contains(_secret)));
    });
  }
  for (final error in ['sync', 'async', 'zero', 'negative', 'overflow']) {
    test('every uncertain native upload $error fences without retry', () async {
      final h = await _connected();
      switch (error) {
        case 'sync':
          h.wire.synchronousUploadError = true;
        case 'async':
          h.wire.uploadError = StateError(_secret);
        case 'zero':
          h.wire.receipt = 0;
        case 'negative':
          h.wire.receipt = -1;
        case 'overflow':
          h.wire.receipt = 9007199254740992;
      }
      final result = await _execute(h);
      expect(result.outcome, ConfigurationRestoreOutcome.unknown);
      expect(h.wire.uploads, hasLength(1));
      expect(h.wire.uploads.single.every((byte) => byte == 0), isTrue);
      expect(result.message, isNot(contains(_secret)));
      await expectLater(
        h.repo.loadConfigurationRestore(),
        throwsA(_reason(ConfigurationRestoreExceptionReason.busy)),
      );
    });
  }
  test(
    'timeout does not wipe in-flight transport bytes but late completion does',
    () async {
      final h = await _connected();
      h.wire.heldUpload = Completer<int>();
      final result = await _execute(h);
      expect(result.outcome, ConfigurationRestoreOutcome.unknown);
      expect(h.wire.uploads.single, _sqlite());
      h.wire.heldUpload!.complete(71);
      await Future<void>.delayed(Duration.zero);
      expect(h.wire.uploads.single.every((byte) => byte == 0), isTrue);
      expect(h.wire.uploads, hasLength(1));
    },
  );
  test('UI capsule disposal cannot mutate upload-owned copy', () async {
    final h = await _connected();
    final review = await _review(h);
    h.wire.heldUpload = Completer<int>();
    final resultFuture = h.repo.executeConfigurationRestore(
      review,
      review.target,
      isCurrent: () => h.authorized,
    );
    while (h.wire.uploads.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    review.request.file.dispose();
    h.authorized = false;
    expect(h.wire.uploads.single, _sqlite());
    h.wire.heldUpload!.complete(71);
    expect((await resultFuture).outcome, ConfigurationRestoreOutcome.accepted);
    expect(h.wire.uploads.single.every((byte) => byte == 0), isTrue);
  });
}

void _readinessTests() {
  final invalid = <String, Object?>{
    'auth.me': {
      'privilege': {'roles': null},
    },
    'system.host_id': '$_host\n',
    'system.reboot.info': {'boot_id': _secret, 'reboot_required_reasons': []},
    'system.version_short': '25.10.2',
    'system.state': 'ready',
    'failover.licensed': null,
    'boot.get_state': {
      'name': 'boot-pool',
      'healthy': true,
      'status': 'ONLINE',
      'scan': {'state': null},
    },
    'boot.environment.query': [{}],
    'core.get_jobs': [
      {'id': 0, 'method': 'config.upload', 'state': 'RUNNING'},
    ],
  };
  for (final entry in invalid.entries) {
    test('invalid readiness ${entry.key} never permits review', () async {
      final h = await _connected();
      h.wire.values[entry.key] = entry.value;
      await expectLater(
        h.repo.loadConfigurationRestore(),
        throwsA(isA<ConfigurationRestoreException>()),
      );
      expect(h.wire.uploads, isEmpty);
    });
  }
  final blocked = <String, Map<String, Object?>>{
    'readonly': {
      'auth.me': {
        'privilege': {
          'roles': ['READONLY_ADMIN'],
        },
      },
    },
    'HA': {'failover.licensed': true},
    'booting': {'system.state': 'BOOTING'},
    'jobs': {
      'core.get_jobs': [
        {'id': 4, 'method': 'config.upload', 'state': 'RUNNING'},
      ],
    },
    'boot-unhealthy': {
      'boot.get_state': {
        'name': 'boot-pool',
        'healthy': false,
        'status': 'DEGRADED',
        'scan': null,
      },
    },
    'boot-scanning': {
      'boot.get_state': {
        'name': 'boot-pool',
        'healthy': true,
        'status': 'ONLINE',
        'scan': {'state': 'SCANNING'},
      },
    },
    'next-boot': {
      'boot.environment.query': [
        {..._environment(), 'activated': false},
        {
          ..._environment(),
          'id': 'older',
          'dataset': 'boot-pool/ROOT/older',
          'active': false,
        },
      ],
    },
  };
  for (final entry in blocked.entries) {
    test('blocked readiness ${entry.key} rejects restoration review', () async {
      final h = await _connected();
      h.wire.values.addAll(entry.value);
      final inventory = await h.repo.loadConfigurationRestore();
      expect(inventory.blockedReason, isNotNull);
      final file = await h.repo.prepareConfigurationRestore(_sqlite());
      await expectLater(
        h.repo.reviewConfigurationRestore(
          ConfigurationRestoreRequest(inventory: inventory, file: file),
        ),
        throwsA(_reason(ConfigurationRestoreExceptionReason.invalidRequest)),
      );
    });
  }
  for (final method in ['system.host_id', 'system.reboot.info', 'auth.me']) {
    test('mid-read $method identity privilege change fails closed', () async {
      final h = await _connected();
      h.wire.beforeReply = (name, count) {
        if (name == method && count == (name == 'auth.me' ? 3 : 2)) {
          h.wire.values[name] = switch (name) {
            'system.host_id' => 'f' * 64,
            'system.reboot.info' => {
              'boot_id': '11111111-2222-4333-8444-666666666666',
              'reboot_required_reasons': [],
            },
            _ => {
              'privilege': {'roles': []},
            },
          };
        }
      };
      await expectLater(
        h.repo.loadConfigurationRestore(),
        throwsA(isA<ConfigurationRestoreException>()),
      );
    });
  }
}
