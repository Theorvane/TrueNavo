import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared by dedicated management workflows and the administration workspace.
/// A route change cannot make an in-flight operation appear safe to duplicate.
final serverOperationLockProvider = Provider<ServerOperationLock>(
  (ref) => ServerOperationLock(),
);

final class ServerOperationLock {
  Object? _owner;

  Object? acquire() {
    if (_owner != null) return null;
    return _owner = Object();
  }

  void release(Object owner) {
    if (identical(_owner, owner)) _owner = null;
  }
}
