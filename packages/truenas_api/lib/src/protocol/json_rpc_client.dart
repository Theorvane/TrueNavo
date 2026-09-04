import 'dart:async';
import 'dart:convert';

import '../transport/rpc_transport.dart';
import 'json_rpc_exceptions.dart';

final class JsonRpcClient {
  JsonRpcClient(this._transport) {
    _subscription = _transport.inboundFrames.listen(
      _onFrame,
      onError: _onTransportError,
      onDone: _onDone,
    );
  }

  final RpcTransport _transport;
  final _pending = <Object, Completer<Object?>>{};
  final _completedIds = <Object>{};
  final _notifications = StreamController<Map<String, Object?>>.broadcast();
  final _protocolErrors =
      StreamController<JsonRpcProtocolException>.broadcast();
  late final StreamSubscription<String> _subscription;
  bool _closed = false;

  Stream<Map<String, Object?>> get notifications => _notifications.stream;
  Stream<JsonRpcProtocolException> get protocolErrors => _protocolErrors.stream;

  Future<Object?> call(String method, {required Object id, Object? params}) {
    if (_closed)
      return Future<Object?>.error(const RpcTransportClosedException());
    if (_pending.containsKey(id) || _completedIds.contains(id)) {
      return Future<Object?>.error(
        const JsonRpcProtocolException('A request ID was reused.'),
      );
    }
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final request = <String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      'id': id,
    };
    if (params != null) request['params'] = params;
    _transport.send(jsonEncode(request)).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _pending.remove(id);
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    });
    return completer.future;
  }

  void _onFrame(String frame) {
    Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } on FormatException {
      _protocolFailure('Received malformed JSON.');
      return;
    }
    if (decoded is! Map) {
      _protocolFailure('Received a non-object JSON-RPC message.');
      return;
    }
    final message = Map<String, Object?>.from(decoded);
    if (message['jsonrpc'] != '2.0') {
      _protocolFailure('Received an unsupported JSON-RPC version.');
      return;
    }
    if (!message.containsKey('id')) {
      _notifications.add(message);
      return;
    }
    final id = message['id'];
    if (id is! String && id is! int) {
      _protocolFailure('Received a response with an invalid ID.');
      return;
    }
    final hasResult = message.containsKey('result');
    final hasError = message.containsKey('error');
    if (hasResult == hasError) {
      _protocolFailure(
        'A response must contain exactly one of result or error.',
      );
      return;
    }
    if (hasError) {
      final error = message['error'];
      if (error is! Map ||
          error['code'] is! int ||
          error['message'] is! String) {
        _protocolFailure('Received an invalid JSON-RPC error object.');
        return;
      }
    }
    final completer = _pending.remove(id);
    if (completer == null) {
      _protocolFailure(
        _completedIds.contains(id)
            ? 'Received a duplicate response ID.'
            : 'Received an unknown response ID.',
      );
      return;
    }
    _completedIds.add(id as Object);
    if (hasResult) {
      completer.complete(message['result']);
      return;
    }
    final error = message['error'] as Map;
    if (error['code'] is! int || error['message'] is! String) {
      _protocolFailure('Received an invalid JSON-RPC error object.');
      return;
    }
    completer.completeError(
      JsonRpcRemoteException(
        code: error['code'] as int,
        message: error['message'] as String,
        data: error['data'],
      ),
    );
  }

  void _onTransportError(Object error, StackTrace stackTrace) =>
      _failAll(error, stackTrace);
  void _onDone() =>
      _failAll(const RpcTransportClosedException(), StackTrace.current);

  void _protocolFailure(String message) {
    final error = JsonRpcProtocolException(message);
    _protocolErrors.add(error);
    _failAll(error, StackTrace.current);
  }

  void _failAll(Object error, StackTrace stackTrace) {
    final active = _pending.values.toList();
    _pending.clear();
    for (final completer in active) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failAll(const RpcTransportClosedException(), StackTrace.current);
    await _subscription.cancel();
    await _transport.close();
    await _notifications.close();
    await _protocolErrors.close();
  }
}
