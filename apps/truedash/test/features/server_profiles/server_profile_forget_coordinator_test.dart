import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/local_persistence/persistence_failure.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';
import 'package:truedash/features/server_profiles/server_profile_forget_coordinator.dart';
import 'package:truedash/features/server_profiles/server_profile_store.dart';
import 'package:truedash/features/server_profiles/server_profiles_controller.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test(
    'deletes the canonical credential before removing the profile',
    () async {
      final events = <String>[];
      final coordinator = ServerProfileForgetCoordinator(
        vault: _Vault(events),
        removeProfile: (id) async {
          events.add('remove:$id');
          return _success;
        },
      );

      expect(await coordinator.forget(_profile), ForgetProfileOutcome.removed);
      expect(events, ['delete:wss://one/api/current', 'remove:one']);
    },
  );

  test('does not remove a profile when credential deletion fails', () async {
    var removes = 0;
    final coordinator = ServerProfileForgetCoordinator(
      vault: _Vault(const [], throwsOnDelete: true),
      removeProfile: (_) async {
        removes++;
        return _success;
      },
    );

    expect(
      await coordinator.forget(_profile),
      ForgetProfileOutcome.credentialDeleteFailed,
    );
    expect(removes, 0);
  });

  test('does not touch vault or store for a malformed endpoint', () async {
    var removes = 0;
    final vault = _Vault([]);
    final coordinator = ServerProfileForgetCoordinator(
      vault: vault,
      removeProfile: (_) async {
        removes++;
        return _success;
      },
    );

    expect(
      await coordinator.forget(
        const ServerProfile(
          id: 'bad',
          displayName: 'Bad',
          originalHostInput: 'bad',
          normalizedEndpoint: ' https://bad ',
          lastKnownVersion: '1',
        ),
      ),
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
        removeProfile: (_) async => ServerProfilesMutationResult.failed(
          ServerProfileSnapshot(profiles: [_profile], selectedProfileId: 'one'),
          PersistenceFailureKind.unavailable,
        ),
      );

      expect(
        await coordinator.forget(_profile),
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
      removeProfile: (_) async {
        removes++;
        return _success;
      },
    );
    final forget = coordinator.forget(_profile, isCurrent: () => current);
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

final _success = ServerProfilesMutationResult.success(
  ServerProfileSnapshot(profiles: const [], selectedProfileId: null),
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
