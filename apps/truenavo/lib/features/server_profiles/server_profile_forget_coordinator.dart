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
    required this.removeSecretFirst,
  });

  final CredentialVault vault;
  final Future<ServerProfilesGuardedRemoveResult> Function({
    required String profileId,
    required Future<ServerProfilesSecretActionResult> Function(
      ServerProfile profile,
    )
    secretAction,
    bool Function()? isCurrent,
  })
  removeSecretFirst;

  Future<ForgetProfileOutcome> forget(
    String profileId, {
    bool Function()? isCurrent,
  }) async {
    final result = await removeSecretFirst(
      profileId: profileId,
      isCurrent: isCurrent,
      secretAction: (profile) async {
        if (!_isCurrent(isCurrent) || !_hasCanonicalEndpoint(profile)) {
          return ServerProfilesSecretActionResult.preconditionFailed;
        }
        try {
          await vault.deleteApiKey(profile.normalizedEndpoint);
          return ServerProfilesSecretActionResult.succeeded;
        } on Object {
          return ServerProfilesSecretActionResult.failed;
        }
      },
    );
    return switch (result) {
      ServerProfilesGuardedRemoveResult.removed => ForgetProfileOutcome.removed,
      ServerProfilesGuardedRemoveResult.secretActionFailed =>
        ForgetProfileOutcome.credentialDeleteFailed,
      ServerProfilesGuardedRemoveResult.profileRemoveFailed =>
        ForgetProfileOutcome.profileRemoveFailed,
      ServerProfilesGuardedRemoveResult.preconditionFailed =>
        ForgetProfileOutcome.cancelled,
      ServerProfilesGuardedRemoveResult.secretActionPreconditionFailed ||
      ServerProfilesGuardedRemoveResult.notFound =>
        _isCurrent(isCurrent)
            ? ForgetProfileOutcome.invalidProfile
            : ForgetProfileOutcome.cancelled,
    };
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
