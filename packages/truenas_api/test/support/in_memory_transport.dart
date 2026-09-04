import 'dart:async';

import 'package:truenas_api/truenas_api.dart';

final class InMemoryTransport implements RpcTransport {
  final _inbound = StreamController<String>();
  final sentFrames = <String>[];
  var closeCalls = 0;
  @override
  Stream<String> get inboundFrames => _inbound.stream;
  @override
  Future<void> send(String frame) async => sentFrames.add(frame);
  void add(String frame) => _inbound.add(frame);
  Future<void> fail(Object error) async => _inbound.addError(error);
  Future<void> finish() => _inbound.close();
  @override
  Future<void> close() async {
    closeCalls++;
    await _inbound.close();
  }
}

final class FakeConnector implements RpcConnector {
  FakeConnector(this.transport, {this.error});
  final InMemoryTransport transport;
  final Object? error;
  Uri? endpoint;
  @override
  Future<RpcTransport> connect(Uri value) async {
    endpoint = value;
    if (error != null) throw error!;
    return transport;
  }
}
