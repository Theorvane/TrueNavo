import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'rpc_transport.dart';

/// Uses the platform's normal TLS policy. There is intentionally no trust hook.
final class WebSocketRpcConnector implements RpcConnector {
  const WebSocketRpcConnector();

  @override
  Future<RpcTransport> connect(Uri endpoint) async =>
      _ChannelTransport(WebSocketChannel.connect(endpoint));
}

final class _ChannelTransport implements RpcTransport {
  _ChannelTransport(this._channel);
  final WebSocketChannel _channel;
  bool _closed = false;

  @override
  Stream<String> get inboundFrames => _channel.stream.transform(
    StreamTransformer.fromHandlers(
      handleData: (dynamic value, sink) => sink.add(value as String),
      handleError: (Object error, StackTrace stackTrace, sink) {
        final value = error.toString().toLowerCase();
        if (value.contains('certificate') ||
            value.contains('tls') ||
            value.contains('handshake')) {
          sink.addError(const TlsHandshakeException(), stackTrace);
        } else {
          sink.addError(error, stackTrace);
        }
      },
    ),
  );

  @override
  Future<void> send(String frame) async {
    if (_closed) throw const RpcTransportClosedException();
    _channel.sink.add(frame);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel.sink.close();
  }
}
