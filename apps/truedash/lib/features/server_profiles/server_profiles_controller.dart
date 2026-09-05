import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'server_profile.dart';

final serverProfilesControllerProvider =
    NotifierProvider<ServerProfilesController, ServerProfilesState>(
      ServerProfilesController.new,
    );

final class ServerProfilesState {
  ServerProfilesState({
    required List<ServerProfile> profiles,
    this.selectedProfileId,
  }) : profiles = UnmodifiableListView(profiles);

  final UnmodifiableListView<ServerProfile> profiles;
  final String? selectedProfileId;

  ServerProfile? get selectedProfile => switch (selectedProfileId) {
    null => null,
    final id => _profileWithId(id),
  };

  ServerProfile? _profileWithId(String id) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }
}

/// Session-only catalog. First registration order is preserved.
final class ServerProfilesController extends Notifier<ServerProfilesState> {
  @override
  ServerProfilesState build() => ServerProfilesState(profiles: const []);

  void registerAndSelect(ServerProfile profile) {
    final idIndex = state.profiles.indexWhere((item) => item.id == profile.id);
    final endpointIndex = state.profiles.indexWhere(
      (item) => item.normalizedEndpoint == profile.normalizedEndpoint,
    );
    if (idIndex < 0 && endpointIndex < 0) {
      state = ServerProfilesState(
        profiles: [...state.profiles, profile],
        selectedProfileId: profile.id,
      );
      return;
    }

    // An opaque ID names the catalog entry.  If the new endpoint belongs to a
    // different entry, remove that collision before replacing metadata in
    // place.  Otherwise an endpoint match keeps its first opaque ID.
    final replacementIndex = idIndex >= 0 ? idIndex : endpointIndex;
    final replacementId = state.profiles[replacementIndex].id;
    final profiles = <ServerProfile>[];
    for (var index = 0; index < state.profiles.length; index++) {
      if (index == endpointIndex && endpointIndex != replacementIndex) {
        continue;
      }
      if (index == replacementIndex) {
        profiles.add(
          ServerProfile(
            id: replacementId,
            displayName: profile.displayName,
            originalHostInput: profile.originalHostInput,
            normalizedEndpoint: profile.normalizedEndpoint,
            lastKnownVersion: profile.lastKnownVersion,
          ),
        );
      } else {
        profiles.add(state.profiles[index]);
      }
    }
    state = ServerProfilesState(
      profiles: profiles,
      selectedProfileId: replacementId,
    );
  }

  void select(String id) {
    if (state.profiles.every((profile) => profile.id != id)) return;
    state = ServerProfilesState(
      profiles: state.profiles,
      selectedProfileId: id,
    );
  }

  void remove(String id) {
    final profiles = state.profiles
        .where((profile) => profile.id != id)
        .toList();
    if (profiles.length == state.profiles.length) return;
    state = ServerProfilesState(
      profiles: profiles,
      selectedProfileId: state.selectedProfileId == id
          ? (profiles.isEmpty ? null : profiles.first.id)
          : state.selectedProfileId,
    );
  }
}
