import '../connection/connection_controller.dart';

/// An unverified iSCSI write remains fenced for this authenticated session,
/// even when a page or provider is recreated. Reconnection creates a new one.
final class IscsiWriteFence {
  IscsiWriteFence._();

  static final Expando<bool> _uncertain = Expando<bool>();

  static bool isUncertain(AuthenticatedSession session) =>
      _uncertain[session] == true;

  static void markUncertain(AuthenticatedSession session) {
    _uncertain[session] = true;
  }
}
