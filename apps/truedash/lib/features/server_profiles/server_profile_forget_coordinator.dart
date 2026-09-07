import 'package:truenas_api/truenas_api.dart';

import '../credentials/credential_storage_key.dart';
import 'server_profile.dart';
import 'server_profiles_controller.dart';

/// The outcomes intentionally contain no server identity or credential data.
enum ForgetProfileOutcome {
  removed,
  invalidProfile,
  credentialDeleteFailed,
  profileRemoveFailed,
  cancelled,
}

/// Runs the irreversible credential deletion before changing saved profiles.
///
/// This is deliberately independent of a popup route and UI state so callers
/// can make disposal and retry behaviour deterministic.
final class ServerProfileForgetCoordinator {
  ServerProfileForgetCoordinator({
    required this.vault,
    required this.removeProfile,
  });

  final CredentialVault vault;
  final Future<ServerProfilesMutationResult> Function(String profileId)
  removeProfile;

  Future<ForgetProfileOutcome> forget(
    ServerProfile profile, {
    bool Function()? isCurrent,
  }) async {
    if (!_isCurrent(isCurrent) || !_hasCanonicalEndpoint(profile)) {
      return ForgetProfileOutcome.invalidProfile;
    }
    try {
      await vault.deleteApiKey(profile.normalizedEndpoint);
    } on Object {
      return ForgetProfileOutcome.credentialDeleteFailed;
    }
    if (!_isCurrent(isCurrent)) return ForgetProfileOutcome.cancelled;
    final result = await removeProfile(profile.id);
    if (!_isCurrent(isCurrent)) return ForgetProfileOutcome.cancelled;
    return result.succeeded
        ? ForgetProfileOutcome.removed
        : ForgetProfileOutcome.profileRemoveFailed;
  }

  bool _hasCanonicalEndpoint(ServerProfile profile) {
    try {
      final endpoint = ValidatedEndpoint.parse(profile.normalizedEndpoint);
      if (endpoint.connectionUri.toString() != profile.normalizedEndpoint) {
        return false;
      }
      credentialStorageKey(profile.normalizedEndpoint);
      return true;
    } on Object {
      return false;
    }
  }

  bool _isCurrent(bool Function()? callback) {
    try {
      return callback?.call() ?? true;
    } on Object {
      return false;
    }
  }
}
