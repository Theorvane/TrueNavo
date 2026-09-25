part of 'true_nas_session_repository.dart';

/// The public reporting.realtime event source, never its private stats RPC.
abstract interface class AuthenticatedRealtimeSession {
  RealtimeCapabilities get realtimeCapabilities;
  Future<RealtimeFeed> openRealtimeFeed();
}

abstract interface class RealtimeFeed {
  Stream<RealtimeSample> get samples;
  Future<void> close();
}

final class RealtimeCapabilities {
  const RealtimeCapabilities({required this.supported, this.blockedReason});
  final bool supported;
  final String? blockedReason;
}

final class RealtimeException implements Exception {
  const RealtimeException();
  String get userMessage =>
      'Live measurements are unavailable. Check the connection and REPORTING_READ access, then retry.';
}

final class RealtimeCpu {
  const RealtimeCpu({this.usage, this.temperature});
  final double? usage;
  final double? temperature;
}

final class RealtimeInterface {
  const RealtimeInterface({
    required this.linkUp,
    this.speedMbps,
    this.receivedBytesPerSecond,
    this.sentBytesPerSecond,
  });
  final bool? linkUp;
  final double? speedMbps;
  final double? receivedBytesPerSecond;
  final double? sentBytesPerSecond;
}

final class RealtimeSample {
  RealtimeSample({
    required this.receivedAt,
    required Map<String, RealtimeCpu> cpu,
    required Map<String, RealtimeInterface> interfaces,
    this.memoryTotalBytes,
    this.memoryAvailableBytes,
    this.arcSizeBytes,
    this.diskReadBytesPerSecond,
    this.diskWriteBytesPerSecond,
    this.diskReadOpsPerSecond,
    this.diskWriteOpsPerSecond,
    this.diskBusyPercent,
    this.arcDataHitPercent,
    this.arcMetadataHitPercent,
  }) : cpu = Map.unmodifiable(cpu),
       interfaces = Map.unmodifiable(interfaces);

  /// Client receipt time in UTC: this event contains no server timestamp.
  final DateTime receivedAt;
  final Map<String, RealtimeCpu> cpu;
  final Map<String, RealtimeInterface> interfaces;
  final double? memoryTotalBytes, memoryAvailableBytes, arcSizeBytes;
  final double? diskReadBytesPerSecond, diskWriteBytesPerSecond;
  final double? diskReadOpsPerSecond, diskWriteOpsPerSecond, diskBusyPercent;
  final double? arcDataHitPercent, arcMetadataHitPercent;

  /// Only these complementary quantities form a partition. ARC is separate:
  /// reclaimable cache overlaps Linux available memory.
  double? get memoryUnavailableBytes {
    final total = memoryTotalBytes;
    final available = memoryAvailableBytes;
    if (total == null || total <= 0 || available == null || available > total) {
      return null;
    }
    return total - available;
  }

  factory RealtimeSample.fromFields(
    Object? fields, {
    required DateTime receivedAt,
  }) {
    if (fields is! Map || fields.length > 32) throw const RealtimeException();
    final cpus = _rtMap(fields['cpu'], 2049);
    final nics = _rtMap(fields['interfaces'], 256);
    final memory = _rtMap(fields['memory'], 32);
    final disks = _rtMap(fields['disks'], 32);
    final zfs = _rtMap(fields['zfs'], 64);
    return RealtimeSample(
      receivedAt: receivedAt.toUtc(),
      cpu: {
        for (final e in cpus.entries)
          if (RegExp(r'^cpu[0-9]*$').hasMatch(e.key))
            e.key: RealtimeCpu(
              usage: _rtNumber(_rtMap(e.value, 16)['usage'], max: 100),
              temperature: _rtNumber(
                _rtMap(e.value, 16)['temp'],
                min: -273.15,
                max: 1000,
              ),
            ),
      },
      interfaces: {for (final e in nics.entries) e.key: _rtInterface(e.value)},
      memoryTotalBytes: _rtNumber(memory['physical_memory_total']),
      memoryAvailableBytes: _rtNumber(memory['physical_memory_available']),
      arcSizeBytes: _rtNumber(memory['arc_size']),
      diskReadBytesPerSecond: _rtNumber(disks['read_bytes']),
      diskWriteBytesPerSecond: _rtNumber(disks['write_bytes']),
      diskReadOpsPerSecond: _rtNumber(disks['read_ops']),
      diskWriteOpsPerSecond: _rtNumber(disks['write_ops']),
      diskBusyPercent: _rtNumber(disks['busy'], max: 100),
      arcDataHitPercent: _rtNumber(zfs['demand_data_hit_percentage'], max: 100),
      arcMetadataHitPercent: _rtNumber(
        zfs['demand_metadata_hit_percentage'],
        max: 100,
      ),
    );
  }
}

Map<String, Object?> _rtMap(Object? raw, int limit) {
  if (raw == null) return const {};
  if (raw is! Map ||
      raw.length > limit ||
      raw.keys.any(
        (key) =>
            key is! String ||
            key.isEmpty ||
            key.length > 256 ||
            RegExp(
              r'[\x00-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]',
            ).hasMatch(key),
      )) {
    throw const RealtimeException();
  }
  return Map<String, Object?>.from(raw);
}

double? _rtNumber(Object? raw, {double min = 0, double max = 1e18}) {
  if (raw is! num) return null;
  final value = raw.toDouble();
  return value.isFinite && value >= min && value <= max ? value : null;
}

RealtimeInterface _rtInterface(Object? raw) {
  final map = _rtMap(raw, 16);
  final up = switch (map['link_state']) {
    'LINK_STATE_UP' => true,
    'LINK_STATE_DOWN' => false,
    _ => null,
  };
  return RealtimeInterface(
    linkUp: up,
    speedMbps: _rtNumber(map['speed']),
    // Interval byte counts are not rates, and a down link is not a measured zero.
    receivedBytesPerSecond: up == true
        ? _rtNumber(map['received_bytes_rate'])
        : null,
    sentBytesPerSecond: up == true ? _rtNumber(map['sent_bytes_rate']) : null,
  );
}

final class _SessionRealtime {
  _SessionRealtime({
    required this.client,
    required this.summary,
    required this.nextId,
    required this.isCurrent,
    required this.requestTimeout,
  });
  final JsonRpcClient client;
  final ServerSummary summary;
  final String Function() nextId;
  final bool Function() isCurrent;
  final Duration requestTimeout;
  _RealtimeFeed? _feed;
  RealtimeCapabilities get capabilities {
    final version = RegExp(r'^(?:TrueNAS-)?25\.10(?:\.\d+)*$')
        .hasMatch(summary.version);
    final methods = summary.availableMethodNames;
    final supported =
        isCurrent() &&
        version &&
        methods.contains('core.subscribe') &&
        methods.contains('core.unsubscribe');
    return RealtimeCapabilities(
      supported: supported,
      blockedReason: supported ? null : 'Live charts require a connected stable TrueNAS 25.10 server with event subscription support.',
    );
  }

  Future<RealtimeFeed> open() async {
    if (!capabilities.supported || _feed != null) {
      throw const RealtimeException();
    }
    final feed = _RealtimeFeed(this);
    _feed = feed;
    try {
      await feed.start();
      return feed;
    } on Object {
      await feed.close();
      throw const RealtimeException();
    }
  }

  Future<void> close() async {
    await _feed?.close();
  }
}

final class _RealtimeFeed implements RealtimeFeed {
  _RealtimeFeed(this.owner) {
    _samples = StreamController<RealtimeSample>(
      sync: true,
      onListen: () {
        scheduleMicrotask(() {
          final latest = _early;
          _early = null;
          if (!_closed && latest != null) _samples.add(latest);
        });
      },
      // Consumers must cancel, not accumulate an unbounded paused stream.
      onPause: () => unawaited(close()),
      onCancel: close,
    );
  }
  static const collection = 'reporting.realtime:{"interval":2}';
  final _SessionRealtime owner;
  late final StreamController<RealtimeSample> _samples;
  StreamSubscription<Map<String, Object?>>? _notifications;
  StreamSubscription<JsonRpcProtocolException>? _protocol;
  Timer? _watchdog;
  String? _subscriptionId;
  bool _closed = false;
  bool _ready = false;
  RealtimeSample? _early;
  final _age = Stopwatch()..start();
  Duration _lastReceived = Duration.zero;
  @override
  Stream<RealtimeSample> get samples => _samples.stream;
  Future<void> start() async {
    _notifications = owner.client.notifications.listen(
      _onNotification,
      onDone: _fail,
      onError: (Object _) => _fail(),
    );
    _protocol = owner.client.protocolErrors.listen((_) => _fail());
    // Retain the original future for late-ack cleanup after cancellation/timeout.
    final pending = owner.client.call(
      'core.subscribe',
      id: owner.nextId(),
      params: [collection],
    );
    unawaited(
      pending.then((result) async {
        if (result is String && result.isNotEmpty && result.length <= 256) {
          _subscriptionId = result;
          if (_closed) await _unsubscribe();
        }
      }, onError: (Object _) {}),
    );
    final result = await pending.timeout(owner.requestTimeout);
    if (_closed ||
        !owner.isCurrent() ||
        result is! String ||
        result.isEmpty ||
        result.length > 256) {
      throw const RealtimeException();
    }
    _subscriptionId = result;
    _ready = true;
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!owner.isCurrent() ||
          _age.elapsed - _lastReceived > const Duration(seconds: 15)) {
        _fail();
      }
    });
  }

  void _onNotification(Map<String, Object?> notification) {
    if (_closed || !owner.isCurrent()) return;
    final params = notification['params'];
    if (params is! Map || params['collection'] != collection) return;
    if (notification['method'] == 'notify_unsubscribed') {
      _fail();
      return;
    }
    if (notification['method'] != 'collection_update' ||
        params['msg'] != 'added') {
      return;
    }
    try {
      final sample = RealtimeSample.fromFields(
        params['fields'],
        receivedAt: DateTime.now().toUtc(),
      );
      _lastReceived = _age.elapsed;
      if (_ready && _samples.hasListener) {
        _samples.add(sample);
      } else {
        _early = sample;
      } // At most one pre-ack/pre-listener sample.
    } on Object {
      _fail();
    }
  }

  void _fail() {
    if (_closed) return;
    if (_samples.hasListener) _samples.addError(const RealtimeException());
    unawaited(close());
  }

  Future<void> _unsubscribe() async {
    final id = _subscriptionId;
    _subscriptionId = null;
    if (id == null || !owner.client.isOpen) return;
    try {
      await owner.client
          .call('core.unsubscribe', id: owner.nextId(), params: [id])
          .timeout(owner.requestTimeout);
    } on Object {
      /* Socket closure also disposes the server event source. */
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _watchdog?.cancel();
    _early = null;
    await _notifications?.cancel();
    await _protocol?.cancel();
    await _unsubscribe();
    if (identical(owner._feed, this)) owner._feed = null;
    // Do not await a paused or not-yet-listened controller's close future.
    unawaited(_samples.close());
  }
}
