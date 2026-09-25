import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const collection = 'reporting.realtime:{"interval":2}';
final instant = DateTime.utc(2026, 9, 12);

void main() {
  test('disconnected repository exposes no feed and sends nothing', () async {
    final h = Harness();
    expect(h.repository.realtimeCapabilities.supported, isFalse);
    await expectLater(
      h.repository.openRealtimeFeed(),
      throwsA(isA<RealtimeException>()),
    );
    expect(h.transport.requests, isEmpty);
    await h.repository.close();
  });
  for (final version in ['25.04.2', '26.0', '25.10-RC.1', '25.10\n']) {
    test('unsupported version $version sends no subscription', () async {
      final h = await connected(version: version);
      expect(h.repository.realtimeCapabilities.supported, isFalse);
      await expectLater(
        h.repository.openRealtimeFeed(),
        throwsA(isA<RealtimeException>()),
      );
      expect(h.transport.subscriptions, isEmpty);
    });
  }
  for (final method in ['core.subscribe', 'core.unsubscribe']) {
    test('missing advertised $method blocks subscription', () async {
      final h = await connected(
        methods: {'core.subscribe', 'core.unsubscribe'}..remove(method),
      );
      await expectLater(
        h.repository.openRealtimeFeed(),
        throwsA(isA<RealtimeException>()),
      );
      expect(h.transport.subscriptions, isEmpty);
    });
  }
  test(
    'subscribes public event and unsubscribes exact returned id once',
    () async {
      final h = await connected();
      final feed = await h.repository.openRealtimeFeed();
      expect(h.transport.subscriptions.single['params'], [collection]);
      await feed.close();
      await feed.close();
      expect(h.transport.unsubscriptions.single['params'], ['feed-1']);
      expect(
        h.transport.requests.any(
          (r) => r['method'] == 'reporting.realtime.stats',
        ),
        isFalse,
      );
    },
  );
  test(
    'only exact collection_update added notifications yield samples',
    () async {
      final h = await connected();
      final feed = await h.repository.openRealtimeFeed();
      final samples = <RealtimeSample>[];
      final subscription = feed.samples.listen(samples.add);
      h.transport.event(fields(), eventCollection: 'reporting.realtime');
      h.transport.event(fields(), method: 'other');
      h.transport.event(fields(), msg: 'changed');
      h.transport.event(fields());
      await pump();
      expect(samples, hasLength(1));
      expect(samples.single.cpu['cpu']!.usage, 25);
      expect(samples.single.receivedAt.isUtc, isTrue);
      await subscription.cancel();
    },
  );
  test('notification before acknowledgement retains latest only', () async {
    final h = await connected();
    h.transport.hold = true;
    final opening = h.repository.openRealtimeFeed();
    await pump();
    h.transport.event(fields(usage: 11));
    h.transport.event(fields(usage: 22));
    await pump();
    h.transport.ack();
    final feed = await opening;
    final sample = await feed.samples.first;
    expect(sample.cpu['cpu']!.usage, 22);
  });
  test(
    'parallel feed request rejected while original remains active',
    () async {
      final h = await connected();
      final feed = await h.repository.openRealtimeFeed();
      await expectLater(
        h.repository.openRealtimeFeed(),
        throwsA(isA<RealtimeException>()),
      );
      expect(h.transport.subscriptions, hasLength(1));
      await feed.close();
      final next = await h.repository.openRealtimeFeed();
      expect(h.transport.subscriptions, hasLength(2));
      await next.close();
    },
  );
  test('remote errors are sanitized', () async {
    final h = await connected();
    h.transport.reject = true;
    await expectLater(
      h.repository.openRealtimeFeed(),
      throwsA(
        isA<RealtimeException>().having(
          (e) => e.userMessage,
          'sanitized message',
          isNot(contains('secret')),
        ),
      ),
    );
  });
  test(
    'late acknowledgement after timeout cancels orphan subscription',
    () async {
      final h = await connected(timeout: const Duration(milliseconds: 5));
      h.transport.hold = true;
      await expectLater(
        h.repository.openRealtimeFeed(),
        throwsA(isA<RealtimeException>()),
      );
      h.transport.ack();
      await pump();
      expect(h.transport.unsubscriptions.single['params'], ['feed-1']);
    },
  );
  test('server notify_unsubscribed clears feed with sanitized error', () async {
    final h = await connected();
    final feed = await h.repository.openRealtimeFeed();
    final errors = <Object>[];
    final done = Completer<void>();
    feed.samples.listen((_) {}, onError: errors.add, onDone: done.complete);
    h.transport.event({'secret': 'remote'}, method: 'notify_unsubscribed');
    await done.future;
    expect(errors.single, isA<RealtimeException>());
    expect(h.transport.unsubscriptions, hasLength(1));
  });
  test('malformed metrics terminate stream without remote content', () async {
    final h = await connected();
    final feed = await h.repository.openRealtimeFeed();
    final errors = <Object>[];
    final done = Completer<void>();
    feed.samples.listen((_) {}, onError: errors.add, onDone: done.complete);
    h.transport.event({'cpu': 'secret payload'});
    await done.future;
    expect(errors.single, isA<RealtimeException>());
  });
  test(
    'pausing a consumer cancels server source rather than buffering',
    () async {
      final h = await connected();
      final feed = await h.repository.openRealtimeFeed();
      final subscription = feed.samples.listen((_) {});
      subscription.pause();
      await pump();
      expect(h.transport.unsubscriptions, hasLength(1));
      subscription.resume();
      await subscription.cancel();
    },
  );
  test('repository close cancels subscription before closing socket', () async {
    final h = await connected();
    final feed = await h.repository.openRealtimeFeed();
    final done = feed.samples.drain<void>();
    await h.repository.close();
    await done;
    expect(h.transport.unsubscriptions, hasLength(1));
    expect(h.transport.closed, isTrue);
  });
  test('memory partition uses available complement; ARC is separate', () {
    final sample = parse(fields());
    expect(sample.memoryTotalBytes, 1000);
    expect(sample.memoryAvailableBytes, 600);
    expect(sample.memoryUnavailableBytes, 400);
    expect(sample.arcSizeBytes, 500);
  });
  test(
    'transport closure terminates the live source through watchdog',
    () async {
      final h = await connected();
      final feed = await h.repository.openRealtimeFeed();
      final errors = <Object>[];
      final done = Completer<void>();
      feed.samples.listen((_) {}, onError: errors.add, onDone: done.complete);
      await h.transport.close();
      await done.future.timeout(const Duration(seconds: 3));
      expect(errors.single, isA<RealtimeException>());
      expect(h.repository.realtimeCapabilities.supported, isFalse);
    },
  );
  test(
    'stalled source terminates after fifteen seconds without data',
    () async {
      final h = await connected();
      final feed = await h.repository.openRealtimeFeed();
      final errors = <Object>[];
      final done = Completer<void>();
      feed.samples.listen((_) {}, onError: errors.add, onDone: done.complete);
      await done.future.timeout(const Duration(seconds: 18));
      expect(errors.single, isA<RealtimeException>());
      expect(h.transport.unsubscriptions, hasLength(1));
    },
  );
  test('bidi and C1 interface labels are rejected before reaching the UI', () {
    for (final name in ['eth\u202e0', 'eth\u00850', 'eth\u20660']) {
      expect(
        () => parse({
          'interfaces': {name: {}},
        }),
        throwsA(isA<RealtimeException>()),
      );
    }
  });
  test('inconsistent or unknown memory has no pie denominator', () {
    final raw = fields();
    (raw['memory'] as Map)['physical_memory_available'] = 1100;
    expect(parse(raw).memoryUnavailableBytes, isNull);
    raw['memory'] = {};
    expect(parse(raw).memoryUnavailableBytes, isNull);
  });
  test('invalid numeric metrics remain null, legitimate zero remains zero', () {
    final raw = fields(usage: 0);
    (raw['cpu'] as Map)['cpu0'] = {'usage': 120, 'temp': double.nan};
    raw['disks'] = {'read_bytes': -1, 'write_bytes': double.infinity};
    final sample = parse(raw);
    expect(sample.cpu['cpu']!.usage, 0);
    expect(sample.cpu['cpu0']!.usage, isNull);
    expect(sample.cpu['cpu0']!.temperature, isNull);
    expect(sample.diskReadBytesPerSecond, isNull);
    expect(sample.diskWriteBytesPerSecond, isNull);
  });
  test('network byte rates stay byte rates; link speed stays megabits', () {
    final sample = parse(fields());
    expect(sample.interfaces['eth0']!.receivedBytesPerSecond, 125000);
    expect(sample.interfaces['eth0']!.sentBytesPerSecond, 250000);
    expect(sample.interfaces['eth0']!.speedMbps, 1000);
  });
  test('interval byte counts never masquerade as rates', () {
    final raw = fields();
    raw['interfaces'] = {
      'eth0': {'link_state': 'LINK_STATE_UP', 'received_bytes': 400},
    };
    expect(parse(raw).interfaces['eth0']!.receivedBytesPerSecond, isNull);
  });
  test('down or unknown links show unavailable rates rather than zero', () {
    final raw = fields();
    (raw['interfaces'] as Map)['eth0'] = {
      'link_state': 'LINK_STATE_DOWN',
      'received_bytes_rate': 0,
    };
    expect(parse(raw).interfaces['eth0']!.receivedBytesPerSecond, isNull);
  });
  test('all returned collections are immutable', () {
    final sample = parse(fields());
    expect(() => sample.cpu.clear(), throwsUnsupportedError);
    expect(() => sample.interfaces.clear(), throwsUnsupportedError);
  });
  for (final invalid in [
    <String, Object?>{'cpu': List.filled(3000, 0)},
    <String, Object?>{
      'interfaces': {for (var i = 0; i < 257; i++) 'eth$i': {}},
    },
    <String, Object?>{
      'interfaces': {'bad\nname': {}},
    },
  ]) {
    test(
      'oversized or malformed collection rejected ${invalid.keys.first}',
      () {
        expect(() => parse(invalid), throwsA(isA<RealtimeException>()));
      },
    );
  }
}

RealtimeSample parse(Object? raw) =>
    RealtimeSample.fromFields(raw, receivedAt: instant);
Map<String, Object?> fields({double usage = 25}) => {
  'cpu': {
    'cpu': {'usage': usage, 'temp': 45},
    'cpu0': {'usage': 30, 'temp': null},
  },
  'memory': {
    'physical_memory_total': 1000,
    'physical_memory_available': 600,
    'arc_size': 500,
  },
  'interfaces': {
    'eth0': {
      'link_state': 'LINK_STATE_UP',
      'speed': 1000,
      'received_bytes_rate': 125000,
      'sent_bytes_rate': 250000,
    },
  },
  'disks': {
    'read_bytes': 1024,
    'write_bytes': 2048,
    'read_ops': 20,
    'write_ops': 10,
    'busy': 15,
  },
  'zfs': {
    'demand_data_hit_percentage': 90,
    'demand_metadata_hit_percentage': 99,
  },
};
Future<void> pump() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Harness> connected({
  String version = '25.10.1',
  Set<String> methods = const {'core.subscribe', 'core.unsubscribe'},
  Duration timeout = const Duration(seconds: 1),
}) async {
  final h = Harness(version: version, methods: methods, timeout: timeout);
  addTearDown(h.repository.close);
  await h.repository.connect(
    serverInput: 'https://nas.example',
    apiKey: 'fixture-only',
    username: 'admin',
  );
  return h;
}

class Harness {
  Harness({
    String version = '25.10.1',
    Set<String> methods = const {'core.subscribe', 'core.unsubscribe'},
    Duration timeout = const Duration(seconds: 1),
  }) {
    transport = Transport(version, methods);
    repository = TrueNasSessionRepository(
      connector: Connector(transport),
      managementRequestTimeout: timeout,
    );
  }
  late final Transport transport;
  late final TrueNasSessionRepository repository;
}

class Connector implements RpcConnector {
  Connector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

class Transport implements RpcTransport {
  Transport(this.version, this.methods);
  final String version;
  final Set<String> methods;
  final inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  bool hold = false, reject = false, closed = false;
  Iterable<Map<String, Object?>> get subscriptions =>
      requests.where((r) => r['method'] == 'core.subscribe');
  Iterable<Map<String, Object?>> get unsubscriptions =>
      requests.where((r) => r['method'] == 'core.unsubscribe');
  @override
  Stream<String> get inboundFrames => inbound.stream;
  void ack() => respond(subscriptions.last, 'feed-${subscriptions.length}');
  void respond(Map r, Object? result) => inbound.add(
    jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
  );
  void event(
    Object? fields, {
    String eventCollection = collection,
    String method = 'collection_update',
    String msg = 'added',
  }) => inbound.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': {'collection': eventCollection, 'msg': msg, 'fields': fields},
    }),
  );
  @override
  Future<void> send(String frame) async {
    final r = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(r);
    switch (r['method']) {
      case 'auth.login_ex':
        respond(r, {'response_type': 'SUCCESS'});
      case 'auth.me':
        respond(r, {'username': 'admin'});
      case 'system.info':
        respond(r, {'version': version});
      case 'core.get_methods':
        respond(r, {
          for (final method in methods) method: {'job': false},
        });
      case 'core.subscribe':
        if (hold) return;
        if (reject) {
          inbound.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': r['id'],
              'error': {'code': -32001, 'message': 'secret'},
            }),
          );
          return;
        }
        ack();
      case 'core.unsubscribe':
        respond(r, null);
      default:
        throw StateError('Unexpected request ${r['method']}');
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await inbound.close();
  }
}
