import 'dart:convert';

/// A deliberately narrow wire guard for the one-session read-only probe.
///
/// Outgoing frames must be canonical [jsonEncode] output, as produced by the
/// SDK. This also rejects duplicate JSON keys and ambiguous number encodings.
/// Only method counts are exposed; payloads and authentication values are never
/// retained. Request IDs and one subscription ID are held for protocol safety.
final class ReadOnlyProbePolicy {
  final Map<String, int> _callCounts = {};
  final Set<Object> _requestIds = {};
  Object? _subscribeRequestId;
  String? _subscriptionId;
  bool _subscribeAttempted = false;

  Map<String, int> get callCounts => Map.unmodifiable(_callCounts);

  static const _parameterlessReads = {
    'auth.me',
    'system.info',
    'system.product_type',
    'core.get_methods',
    'pool.query',
    'pool.dataset.query',
    'service.query',
    'alert.list',
    'core.get_jobs',
    'failover.licensed',
    'interface.has_pending_changes',
    'interface.checkin_waiting',
    'interface.query',
    'network.configuration.config',
    'interface.network_config_to_be_removed',
    'interface.services_restarted_on_sync',
    'app.used_host_ips',
  };

  // Exact enum used by the SDK's verified 25.10 reporting.get_data adapter.
  static const _batchGraphs = {
    'cpu',
    'cputemp',
    'disk',
    'interface',
    'load',
    'processes',
    'memory',
    'uptime',
    'arcactualrate',
    'arcrate',
    'arcsize',
    'arcresult',
    'disktemp',
    'upscharge',
    'upsruntime',
    'upsvoltage',
    'upscurrent',
    'upsfrequency',
    'upsload',
    'upstemperature',
  };

  static const _datasetProperties = [
    'guid',
    'creation',
    'used',
    'referenced',
    'available',
    'quota',
    'refquota',
    'reservation',
    'refreservation',
    'compression',
    'atime',
    'readonly',
    'mountpoint',
    'encryption',
    'encryptionroot',
    'keystatus',
    'acltype',
    'aclmode',
    'filesystem_count',
  ];
  static const _collection = 'reporting.realtime:{"interval":2}';

  /// Throws a constant, payload-free exception before a forbidden frame is sent.
  void validateOutgoing(String frame) {
    try {
      if (frame.length > 65536) _reject();
      final request = jsonDecode(frame);
      if (request is! Map<String, dynamic> ||
          jsonEncode(request) != frame ||
          !_keys(request, {'jsonrpc', 'method', 'id'}, optional: {'params'}) ||
          request['jsonrpc'] != '2.0' ||
          request['method'] is! String ||
          !_validRequestId(request['id']) ||
          _requestIds.contains(request['id']) ||
          _requestIds.length >= 256) {
        _reject();
      }
      final method = request['method'] as String;
      final params = request['params'];
      final allowed = switch (method) {
        'auth.login_ex' => _login(params),
        'pool.dataset.query' => _noParams(params) || _datasetQuery(params),
        'reporting.graphs' =>
          params is List &&
              params.length == 2 &&
              params[0] is List &&
              (params[0] as List).isEmpty &&
              params[1] is Map &&
              (params[1] as Map).isEmpty,
        'reporting.get_data' => _history(params, batch: true),
        'reporting.graph' => _history(params, batch: false),
        'core.subscribe' =>
          !_subscribeAttempted &&
              params is List &&
              params.length == 1 &&
              params.single == _collection,
        'core.unsubscribe' =>
          _subscriptionId != null &&
              params is List &&
              params.length == 1 &&
              params.single == _subscriptionId,
        _ => _parameterlessReads.contains(method) && _noParams(params),
      };
      if (!allowed) _reject();
      _requestIds.add(request['id'] as Object);
      _callCounts.update(method, (count) => count + 1, ifAbsent: () => 1);
      if (method == 'core.subscribe') {
        _subscribeAttempted = true;
        _subscribeRequestId = request['id'];
      } else if (method == 'core.unsubscribe') {
        // Never retry an unacknowledged unsubscribe; closing the socket is the
        // probe's fallback cleanup. A policy permits one subscription attempt.
        _subscriptionId = null;
      }
    } on Object {
      throw const ReadOnlyProbePolicyException();
    }
  }

  /// Observes the response to this policy's own subscription request only.
  /// Unrelated messages cannot authorize an unsubscribe target.
  void observeIncoming(String frame) {
    try {
      final response = jsonDecode(frame);
      if (response is! Map<String, dynamic> || response['jsonrpc'] != '2.0') {
        _reject();
      }
      if (_subscribeRequestId == null ||
          response['id'] != _subscribeRequestId) {
        return;
      }
      if (_keys(response, {'jsonrpc', 'id', 'error'})) {
        final error = response['error'];
        if (error is! Map ||
            error['code'] is! int ||
            error['message'] is! String) {
          _reject();
        }
        _subscribeRequestId = null;
        return;
      }
      if (!_keys(response, {'jsonrpc', 'id', 'result'}) ||
          response['result'] is! String ||
          (response['result'] as String).isEmpty ||
          (response['result'] as String).length > 256) {
        _reject();
      }
      _subscriptionId = response['result'] as String;
      _subscribeRequestId = null;
    } on Object {
      throw const ReadOnlyProbePolicyException();
    }
  }

  static bool _validRequestId(Object? value) =>
      (value is int && value >= 0 && value <= 9007199254740991) ||
      (value is String && RegExp(r'^[A-Za-z0-9_.:-]{1,64}$').hasMatch(value));

  static bool _noParams(Object? value) =>
      value == null || (value is List && value.isEmpty);

  static bool _keys(
    Map value,
    Set<String> required, {
    Set<String> optional = const {},
  }) =>
      required.every(value.containsKey) &&
      value.keys.every(
        (key) => required.contains(key) || optional.contains(key),
      );

  static bool _text(Object? value, int limit) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.length <= limit &&
      !RegExp(
        r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
      ).hasMatch(value);

  static bool _login(Object? params) {
    if (params is! List || params.length != 1 || params.single is! Map) {
      return false;
    }
    final login = params.single as Map;
    return _keys(login, {'mechanism', 'username', 'api_key'}) &&
        login['mechanism'] == 'API_KEY_PLAIN' &&
        _text(login['username'], 256) &&
        _text(login['api_key'], 8192);
  }

  static bool _datasetQuery(Object? params) {
    if (params is! List ||
        params.length != 2 ||
        params[1] is! Map ||
        jsonEncode(params[0]) != '[["type","in",["FILESYSTEM","VOLUME"]]]') {
      return false;
    }
    final options = params[1] as Map;
    final extra = options['extra'];
    return _keys(options, {'limit', 'extra'}) &&
        options['limit'] is int &&
        options['limit'] == 1025 &&
        extra is Map &&
        _keys(extra, {
          'flat',
          'retrieve_children',
          'retrieve_user_props',
          'properties',
        }) &&
        extra['flat'] == true &&
        extra['retrieve_children'] == false &&
        extra['retrieve_user_props'] == true &&
        jsonEncode(extra['properties']) == jsonEncode(_datasetProperties);
  }

  static bool _history(Object? params, {required bool batch}) {
    if (params is! List || params.length != 2 || params[1] is! Map) {
      return false;
    }
    final query = params[1] as Map;
    if (!_keys(query, {'start', 'end', 'aggregate'}) ||
        query['aggregate'] != true) {
      return false;
    }
    final start = query['start'];
    final end = query['end'];
    if (start is! int ||
        end is! int ||
        start <= 0 ||
        end > 253402300799 ||
        end - start < 60 ||
        end - start > 1800) {
      return false;
    }
    if (!batch) {
      final name = params[0];
      return name is String &&
          RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(name) &&
          !_batchGraphs.contains(name);
    }
    final graphs = params[0];
    if (graphs is! List || graphs.length != 1 || graphs.single is! Map) {
      return false;
    }
    final graph = graphs.single as Map;
    return _keys(graph, {'name', 'identifier'}) &&
        _batchGraphs.contains(graph['name']) &&
        (graph['identifier'] == null || _text(graph['identifier'], 256));
  }

  static Never _reject() => throw const ReadOnlyProbePolicyException();
}

final class ReadOnlyProbePolicyException implements Exception {
  const ReadOnlyProbePolicyException();

  @override
  String toString() => 'Read-only probe policy rejected a frame.';
}
