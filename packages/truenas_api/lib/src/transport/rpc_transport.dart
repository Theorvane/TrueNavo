abstract interface class RpcTransport {
  Stream<String> get inboundFrames;
  Future<void> send(String frame);
  Future<void> close();
}

abstract interface class RpcConnector {
  Future<RpcTransport> connect(Uri endpoint);
}

final class TlsHandshakeException implements Exception {
  const TlsHandshakeException();
  @override
  String toString() => 'The secure TLS connection could not be verified.';
}

final class RpcTransportClosedException implements Exception {
  const RpcTransportClosedException();
  @override
  String toString() =>
      'The server connection closed before the request completed.';
}
