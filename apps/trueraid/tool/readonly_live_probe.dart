// Explicit, one-shot appliance observation. Never import this in the app.
// Supply endpoint/account/pin as arguments; the API key is read only from stdin.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:trueraid/features/dashboard/dashboard_repository.dart';
import 'package:truenas_api/truenas_api.dart';

import 'readonly_probe_policy.dart';

void report(String stage, Map<String, Object?> result) =>
    stdout.writeln(jsonEncode({'stage': stage, ...result}));

/// Fixed messages only: never print remote exception text or response bodies.
String failureKind(Object error) => switch (error) {
  ReportingException e => 'reporting_${e.reason.name}',
  DatasetPropertiesException e => 'datasets_${e.reason.name}',
  NetworkException e => 'network_${e.reason.name}',
  RealtimeException() => 'realtime_unavailable',
  TimeoutException() => 'timeout',
  ReadOnlyProbePolicyException() => 'outbound_policy_rejected',
  _ => 'connection_or_response_rejected',
};

Future<void> main(List<String> args) async {
  if (args.length != 3 || !stdin.hasTerminal) {
    stderr.writeln(
      'Usage (interactive terminal only): dart run '
      'tool/readonly_live_probe.dart <https-endpoint> <account> '
      '<explicitly-trusted-sha256>',
    );
    exitCode = 64;
    return;
  }
  final endpoint = ValidatedEndpoint.parse(args[0]).connectionUri;
  final pin = args[2].replaceAll(':', '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(pin)) {
    stderr.writeln('A complete, explicitly trusted SHA-256 pin is required.');
    exitCode = 64;
    return;
  }
  final wasEchoing = stdin.echoMode;
  String? key;
  try {
    stdin.echoMode = false;
    stdout.writeln('API key (hidden; memory only):');
    key = stdin.readLineSync();
  } finally {
    stdin.echoMode = wasEchoing;
  }
  if (key == null || key.isEmpty) {
    stderr.writeln('No API key supplied.');
    exitCode = 64;
    return;
  }
  final connector = PinnedProbeConnector(endpoint, pin);
  final repository = TrueNasSessionRepository(
    connector: connector,
    credentialVault: const NoopCredentialVault(),
    managementRequestTimeout: const Duration(seconds: 20),
  );
  // Independent wall-clock limit; socket termination also cancels an RPC whose
  // Future.timeout would otherwise leave work pending on the connection.
  final watchdog = Timer(const Duration(seconds: 150), () {
    connector.dispose();
  });
  var failures = 0;
  Future<void> observe(
    String name,
    Future<Map<String, Object?>> Function() run,
  ) async {
    try {
      final result = await run().timeout(const Duration(seconds: 25));
      report(name, {'status': 'observed', ...result});
    } on Object catch (error) {
      failures++;
      report(name, {'status': 'failed', 'reason': failureKind(error)});
      if (error is TimeoutException) {
        connector.dispose();
        rethrow;
      }
    }
  }

  try {
    final summary = await repository
        .connect(
          serverInput: args[0],
          username: args[1],
          apiKey: key,
          rememberApiKey: false,
        )
        .timeout(const Duration(seconds: 30));
    key = null;
    report('connection', {
      'status': 'authenticated',
      'version':
          RegExp(r'^(?:TrueNAS-)?\d+\.\d+(?:\.\d+)*$').hasMatch(summary.version)
          ? summary.version
          : 'unrecognized_release',
      'advertisedMethods': summary.availableMethodNames.length,
      'adminMetadataMethods': repository.adminCatalog.methods.length,
      'adminSchemaSupported': repository.adminCatalog.methods.values
          .where((method) => method.supported)
          .length,
      'networkSupported': repository.networkCapabilities.supported,
      'datasetPropertiesSupported':
          repository.datasetPropertiesCapabilities.supported,
      'historySupported': repository.reportingCapabilities.supported,
      'realtimeSupported': repository.realtimeCapabilities.supported,
      'productTypeReadAdvertised': summary.availableMethodNames.contains(
        'system.product_type',
      ),
      'networkMethodsMissing': const {
        'interface.query',
        'interface.update',
        'interface.commit',
        'interface.checkin',
        'interface.checkin_waiting',
        'interface.has_pending_changes',
        'interface.rollback',
        'failover.licensed',
        'network.configuration.config',
        'interface.network_config_to_be_removed',
        'interface.services_restarted_on_sync',
        'app.used_host_ips',
      }.difference(summary.availableMethodNames).toList(),
    });
    // Cache each dashboard read within this probe, never on disk. The production
    // parsers see the real data; repeated screen reads do not requery the NAS.
    final queries = _CachedQueries(repository);
    final dashboard = DashboardRepository(queries);
    final methods = summary.availableMethodNames;
    await observe('dashboard', () async {
      final home = await dashboard.loadHome(methods);
      final storage = await dashboard.loadStorage(methods);
      final workloads = await dashboard.loadWorkloads(methods);
      final jobs = await dashboard.loadJobs(methods);
      return {
        'homeParsed': home is DashboardData<DashboardHome>,
        if (home is DashboardData<DashboardHome>) ...{
          'poolCountDisplayed': home.value.pools.length,
          'poolCapacityValues': home.value.pools
              .where((p) => p.capacityPercent != null)
              .length,
          'alertsAvailable': home.value.alertsAvailable,
        },
        'storageParsed': storage is DashboardData<DashboardStorage>,
        if (storage is DashboardData<DashboardStorage>) ...{
          'datasetsAvailable': storage.value.datasetsAvailable,
          'datasetCountDisplayed': storage.value.datasets.length,
        },
        'servicesParsed': workloads is DashboardData<DashboardWorkloads>,
        if (workloads is DashboardData<DashboardWorkloads>)
          'serviceCountDisplayed': workloads.value.services.length,
        'jobsParsed': jobs is DashboardData<DashboardJobs>,
        if (jobs is DashboardData<DashboardJobs>)
          'jobCountDisplayed': jobs.value.items.length,
      };
    });
    queries.clear();
    if (repository.networkCapabilities.supported) {
      await observe('network_inventory', () async {
        final inventory = await repository.loadNetworkInventory();
        return {
          'interfaceCount': inventory.interfaces.length,
          'blockedInterfaces': inventory.interfaces
              .where((i) => !i.editable)
              .length,
          'pendingChangesPresent': inventory.hasPendingChanges,
          'rollbackTimerPresent': inventory.checkinWaitingSeconds != null,
          'inventoryBlocked': inventory.blockedReason != null,
        };
      });
    }
    if (repository.datasetPropertiesCapabilities.supported) {
      await observe('dataset_properties', () async {
        final datasets = await repository.loadDatasetProperties();
        return {
          'count': datasets.length,
          'blocked': datasets.where((d) => !d.editable).length,
          'verifiedLeaves': datasets.where((d) => d.verifiedLeaf).length,
        };
      });
    }
    if (repository.reportingCapabilities.supported) {
      List<ReportingGraph> choices = const [];
      await observe('reporting_discovery', () async {
        final graphs = await repository.loadReportingGraphs();
        choices = graphs
            .where(
              (g) =>
                  g.supported &&
                  (g.identifiers == null || g.identifiers!.isNotEmpty),
            )
            .toList();
        return {'graphs': graphs.length, 'selectable': choices.length};
      });
      for (final name in const [
        'cpu',
        'memory',
        'interface',
        'disk',
        'arcsize',
      ]) {
        final matches = choices.where((graph) => graph.name == name);
        if (matches.isEmpty) {
          report('reporting_history_$name', {'status': 'not_available'});
          continue;
        }
        await observe('reporting_history_$name', () async {
          final graph = matches.first;
          final end = DateTime.now().toUtc();
          final histories = await repository.loadReportingHistory(
            ReportingRequest(
              graph: graph,
              identifier: graph.identifiers?.first,
              start: end.subtract(const Duration(minutes: 15)),
              end: end,
            ),
          );
          return {
            'results': histories.length,
            'series': histories.fold<int>(0, (n, h) => n + h.legend.length),
            'points': histories.fold<int>(0, (n, h) => n + h.points.length),
            'nullCells': histories.fold<int>(
              0,
              (n, h) =>
                  n +
                  h.points.fold<int>(
                    0,
                    (s, p) => s + p.values.where((v) => v == null).length,
                  ),
            ),
          };
        });
      }
    }
    if (repository.realtimeCapabilities.supported) {
      await observe('reporting_realtime', () async {
        final feed = await repository.openRealtimeFeed();
        try {
          final samples = await feed.samples
              .take(3)
              .toList()
              .timeout(const Duration(seconds: 12));
          final last = samples.isEmpty ? null : samples.last;
          return {
            'samples': samples.length,
            'cpuMeasurements':
                last?.cpu.values.where((c) => c.usage != null).length ?? 0,
            'memoryPartitionAvailable': last?.memoryUnavailableBytes != null,
            'interfaceCount': last?.interfaces.length ?? 0,
            'interfaceRateMeasurements':
                last?.interfaces.values
                    .where(
                      (i) =>
                          i.receivedBytesPerSecond != null &&
                          i.sentBytesPerSecond != null,
                    )
                    .length ??
                0,
            'diskRatesAvailable':
                last?.diskReadBytesPerSecond != null &&
                last?.diskWriteBytesPerSecond != null,
          };
        } finally {
          await feed.close();
        }
      });
    }
  } on Object catch (error) {
    failures++;
    report('probe', {'status': 'failed', 'reason': failureKind(error)});
  } finally {
    key = null;
    try {
      await repository.close().timeout(const Duration(seconds: 3));
    } on Object {
      // The physical socket is always destroyed below, including on timeout.
    }
    connector.dispose();
    watchdog.cancel();
    report('closed', {
      'failedStages': failures,
      'rpcCallCounts': connector.policy.callCounts,
      'remoteErrors': connector.remoteErrors,
      'credentialsPersisted': false,
    });
    exitCode = failures == 0 ? 0 : 1;
  }
}

final class _CachedQueries implements AuthenticatedSessionQueries {
  _CachedQueries(this.delegate);
  final AuthenticatedSessionQueries delegate;
  final _cache = <String, Future<Object?>>{};
  @override
  Future<Object?> query(String method) =>
      _cache.putIfAbsent(method, () => delegate.query(method));
  void clear() => _cache.clear();
}

/// No persistent trust store, redirects, proxies, or plaintext fallback.
final class PinnedProbeConnector implements RpcConnector {
  PinnedProbeConnector(this.endpoint, this.pin);
  final Uri endpoint;
  final String pin;
  final policy = ReadOnlyProbePolicy();
  final remoteErrors = <Map<String, Object?>>[];
  HttpClient? _http;
  Socket? _socket;
  bool _disposed = false;

  bool _matches(X509Certificate certificate) =>
      sha256.convert(certificate.der).toString() == pin;

  @override
  Future<RpcTransport> connect(Uri target) async {
    if (_disposed || target != endpoint || target.scheme != 'wss') {
      throw const HandshakeException('Pinned endpoint required.');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = ((_) => 'DIRECT')
      ..badCertificateCallback = (certificate, host, port) =>
          host == endpoint.host &&
          port == endpoint.replace(scheme: 'https').port &&
          _matches(certificate);
    _http = client;
    try {
      final request = await client.getUrl(target.replace(scheme: 'https'));
      request.followRedirects = false;
      final random = Random.secure();
      final nonce = base64Encode(List.generate(16, (_) => random.nextInt(256)));
      request.headers
        ..set(HttpHeaders.connectionHeader, 'Upgrade')
        ..set(HttpHeaders.upgradeHeader, 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set('Sec-WebSocket-Key', nonce);
      final response = await request.close();
      final certificate = response.certificate;
      final accept = base64Encode(
        sha1
            .convert(
              ascii.encode('${nonce}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'),
            )
            .bytes,
      );
      if (_disposed ||
          certificate == null ||
          !_matches(certificate) ||
          response.statusCode != HttpStatus.switchingProtocols ||
          response.headers.value('Sec-WebSocket-Accept') != accept ||
          response.headers.value(HttpHeaders.upgradeHeader)?.toLowerCase() !=
              'websocket' ||
          !(response.headers
                  .value(HttpHeaders.connectionHeader)
                  ?.toLowerCase()
                  .split(',')
                  .map((s) => s.trim())
                  .contains('upgrade') ??
              false) ||
          response.headers.value('Sec-WebSocket-Extensions') != null ||
          response.headers.value('Sec-WebSocket-Protocol') != null) {
        throw const HandshakeException('Pinned WebSocket handshake rejected.');
      }
      final socket = await response.detachSocket();
      _socket = socket;
      if (_disposed) {
        socket.destroy();
        throw const HandshakeException('Probe cancelled.');
      }
      return _ProbeTransport(
        WebSocket.fromUpgradedSocket(
          socket,
          serverSide: false,
          compression: CompressionOptions.compressionOff,
          maxPayloadLength: 16 * 1024 * 1024,
        ),
        policy,
        remoteErrors,
      );
    } on Object {
      dispose();
      rethrow;
    }
  }

  void dispose() {
    _disposed = true;
    _socket?.destroy();
    _http?.close(force: true);
  }
}

final class _ProbeTransport implements RpcTransport {
  _ProbeTransport(this.socket, this.policy, this.errors);
  final WebSocket socket;
  final ReadOnlyProbePolicy policy;
  final List<Map<String, Object?>> errors;
  final _pending = <Object?, String>{};
  int _received = 0;
  int _bytes = 0;

  @override
  Stream<String> get inboundFrames => socket.map((Object? event) {
    if (event is! String ||
        ++_received > 100 ||
        (_bytes += utf8.encode(event).length) > 32 * 1024 * 1024) {
      throw const FormatException('Probe response limit exceeded.');
    }
    policy.observeIncoming(event);
    final message = jsonDecode(event);
    if (message is Map) {
      final method = _pending.remove(message['id']);
      if (method == 'pool.query') {
        final rows = message['result'];
        if (rows is List) {
          report('pool_wire_shape', {
            'rows': rows
                .take(4)
                .map(
                  (row) => row is Map
                      ? {
                          for (final field in const [
                            'capacity',
                            'used_pct',
                            'size',
                            'allocated',
                            'free',
                            'used',
                          ])
                            field: _numericShape(row[field]),
                        }
                      : {'type': 'non_object'},
                )
                .toList(),
          });
        }
      } else if (method == 'reporting.get_data' ||
          method == 'reporting.graph') {
        final rows = message['result'];
        if (rows is List && rows.isNotEmpty && rows.first is Map) {
          final row = rows.first as Map;
          final data = row['data'];
          final legend = row['legend'];
          final aggregations = row['aggregations'];
          report('history_wire_shape', {
            'resultCount': rows.length,
            'nameIsCpu': row['name'] == 'cpu',
            'identifierType': _shape(row['identifier']),
            'identifierIsCpu': row['identifier'] == 'cpu',
            'start': _numericShape(row['start']),
            'end': _numericShape(row['end']),
            'legendLength': legend is List ? legend.length : null,
            'legendFirstIsTime':
                legend is List && legend.isNotEmpty && legend.first == 'time',
            'legendUnique':
                legend is List && legend.toSet().length == legend.length,
            'dataLength': data is List ? data.length : null,
            'firstRow': data is List && data.isNotEmpty && data.first is List
                ? (data.first as List).take(12).map(_numericShape).toList()
                : null,
            'lastRow': data is List && data.isNotEmpty && data.last is List
                ? (data.last as List).take(12).map(_numericShape).toList()
                : null,
            'rowWidths': data is List
                ? data
                      .map((r) => r is List ? r.length : -1)
                      .toSet()
                      .take(8)
                      .toList()
                : null,
            'aggregationCount': aggregations is Map
                ? aggregations.length
                : null,
            'aggregationShape': aggregations is Map
                ? {
                    for (final field in const ['min', 'mean', 'max'])
                      field: _shape(aggregations[field]),
                  }
                : null,
          });
        }
      }
      if (method != null && message['error'] is Map) {
        final code = (message['error'] as Map)['code'];
        errors.add({'method': method, 'code': code is int ? code : null});
      }
    }
    return event;
  });

  @override
  Future<void> send(String frame) async {
    policy.validateOutgoing(frame); // Must precede every actual socket write.
    final request = jsonDecode(frame) as Map;
    _pending[request['id']] = request['method'] as String;
    if (request['method'] == 'reporting.get_data' ||
        request['method'] == 'reporting.graph') {
      final query = (request['params'] as List)[1] as Map;
      report('history_requested_range', {
        'start': query['start'],
        'end': query['end'],
      });
    }
    socket.add(frame);
  }

  @override
  Future<void> close() async {
    await socket.close();
  }
}

String _shape(Object? value) => switch (value) {
  null => 'null',
  bool() => 'bool',
  int() => 'int',
  double() => 'double',
  String() => 'string',
  List() => 'list',
  Map() => 'object',
  _ => 'unknown',
};

Object? _numericShape(Object? value) {
  if (value is num && value.isFinite) return value;
  if (value is String && RegExp(r'^-?[0-9]+(?:\.[0-9]+)?%?$').hasMatch(value)) {
    return value;
  }
  return {'type': _shape(value)};
}
