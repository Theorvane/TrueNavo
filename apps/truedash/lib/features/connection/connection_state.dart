import 'package:truenas_api/truenas_api.dart';

sealed class ConnectionState {
  const ConnectionState();
}

final class ConnectionIdle extends ConnectionState {
  const ConnectionIdle();
}

final class ConnectionInProgress extends ConnectionState {
  const ConnectionInProgress();
}

final class ConnectionSucceeded extends ConnectionState {
  const ConnectionSucceeded(this.summary);
  final ServerSummary summary;
}

final class ConnectionFailed extends ConnectionState {
  const ConnectionFailed(this.message);
  final String message;
}
