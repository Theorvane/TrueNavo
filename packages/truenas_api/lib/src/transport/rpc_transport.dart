import 'dart:typed_data';

/// Optional capability implemented only by a transport that can download using
/// the existing authenticated connection's exact authority and TLS trust.
/// Implementations must reject redirects, cap the body at 16 MiB, and never log
/// the bearer-token URL or persist response bytes. This is not a general HTTP API.
abstract interface class ConfigurationBackupDownloadTransport {
  bool get configurationBackupDownloadSupported;
  Future<Uint8List> downloadConfigurationBackup({
    required String relativeUrl,
    required int jobId,
  });
}

/// Uploads one reviewed configuration through the existing session's exact TLS
/// authority. Implementations consume and wipe [bytes] on every settled outcome,
/// never retry/redirect, and use `Authorization: Token`, not API-key Bearer auth.
/// This capability does not accept a path, method, filename or endpoint.
abstract interface class ConfigurationRestoreUploadTransport {
  bool get configurationRestoreUploadSupported;
  Future<int> uploadConfigurationRestore({
    required String token,
    required Uint8List bytes,
  });
}

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
