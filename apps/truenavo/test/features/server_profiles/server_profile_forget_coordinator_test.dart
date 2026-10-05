import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/server_profiles/server_profile.dart';
import 'package:truenavo/features/server_profiles/server_profile_forget_coordinator.dart';
import 'package:truenavo/features/server_profiles/server_profiles_controller.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test(
    'deletes the canonical credential before removing the profile',
    () async {
      final events = <String>[];
      final coordinator = ServerProfileForgetCoordinator(
        vault: _Vault(events),
        removeSecretFirst:
            ({required profileId, required secretAction, isCurrent}) async {
              expect(profileId, 'one');
              expect(
                await secretAction(_profile),
                ServerProfilesSecretActionResult.succeeded,
              );
              events.add('remove:$profileId');
              return ServerProfilesGuardedRemoveResult.removed;
            },
      );

      expect(await coordinator.forget('one'), ForgetProfileOutcome.removed);
      expect(events, ['delete:wss://one/api/current', 'remove:one']);
    },
  );

  test('does not remove a profile when credential deletion fails', () async {
    var removes = 0;
    final coordinator = ServerProfileForgetCoordinator(
      vault: _Vault(const [], throwsOnDelete: true),
      removeSecretFirst:
          ({required profileId, required secretAction, isCurrent}) async {
            final action = await secretAction(_profile);
            expect(action, ServerProfilesSecretActionResult.failed);
            return ServerProfilesGuardedRemoveResult.secretActionFailed;
          },
    );

    expect(
      await coordinator.forget('one'),
      ForgetProfileOutcome.credentialDeleteFailed,
    );
    expect(removes, 0);
  });

  test('does not touch vault or store for a malformed endpoint', () async {
    var removes = 0;
    final vault = _Vault([]);
    final coordinator = ServerProfileForgetCoordinator(
      vault: vault,
      removeSecretFirst:
          ({required profileId, required secretAction, isCurrent}) async {
            expect(
              await secretAction(
                const ServerProfile(
                  id: 'bad',
                  displayName: 'Bad',
                  originalHostInput: 'bad',
                  normalizedEndpoint: ' https://bad ',
                  lastKnownVersion: '1',
                ),
              ),
              ServerProfilesSecretActionResult.preconditionFailed,
            );
            return ServerProfilesGuardedRemoveResult
                .secretActionPreconditionFailed;
          },
    );

    expect(
      await coordinator.forget('bad'),
      ForgetProfileOutcome.invalidProfile,
    );
    expect(vault.deleted, isEmpty);
    expect(removes, 0);
  });

  test(
    'reports a retained profile after a successful credential deletion',
    () async {
      final coordinator = ServerProfileForgetCoordinator(
        vault: _Vault([]),
        removeSecretFirst:
            ({required profileId, required secretAction, isCurrent}) async {
              await secretAction(_profile);
              return ServerProfilesGuardedRemoveResult.profileRemoveFailed;
            },
      );

      expect(
        await coordinator.forget('one'),
        ForgetProfileOutcome.profileRemoveFailed,
      );
    },
  );

  test('a caller can prevent a later store removal after disposal', () async {
    final delete = Completer<void>();
    var current = true;
    var removes = 0;
    final coordinator = ServerProfileForgetCoordinator(
      vault: _Vault([], deleteCompleter: delete),
      removeSecretFirst:
          ({required profileId, required secretAction, isCurrent}) async {
            final action = await secretAction(_profile);
            if (action != ServerProfilesSecretActionResult.succeeded ||
                isCurrent?.call() == false) {
              return ServerProfilesGuardedRemoveResult.preconditionFailed;
            }
            removes++;
            return ServerProfilesGuardedRemoveResult.removed;
          },
    );
    final forget = coordinator.forget('one', isCurrent: () => current);
    current = false;
    delete.complete();

    expect(await forget, ForgetProfileOutcome.cancelled);
    expect(removes, 0);
  });
}

const _profile = ServerProfile(
  id: 'one',
  displayName: 'One',
  originalHostInput: 'one',
  normalizedEndpoint: 'wss://one/api/current',
  lastKnownVersion: '1',
);

final class _Vault implements CredentialVault {
  _Vault(this.deleted, {this.throwsOnDelete = false, this.deleteCompleter});
  final List<String> deleted;
  final bool throwsOnDelete;
  final Completer<void>? deleteCompleter;

  @override
  Future<void> deleteApiKey(String endpointIdentifier) async {
    deleted.add('delete:$endpointIdentifier');
    if (throwsOnDelete) throw StateError('unavailable');
    await deleteCompleter?.future;
  }

  @override
  Future<String?> readApiKey(String endpointIdentifier) async => null;

  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async {}
}
