final class JsonRpcProtocolException implements Exception {
  const JsonRpcProtocolException(this.message);
  final String message;
  @override
  String toString() => 'JSON-RPC protocol error: $message';
}

final class JsonRpcRemoteException implements Exception {
  const JsonRpcRemoteException({
    required this.code,
    required this.message,
    this.data,
  });
  final int code;
  final String message;
  final Object? data;
  @override
  String toString() => 'JSON-RPC remote error ($code): $message';
}
