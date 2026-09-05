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
    final existingIndex = state.profiles.indexWhere(
      (item) => item.normalizedEndpoint == profile.normalizedEndpoint,
    );
    if (existingIndex < 0) {
      state = ServerProfilesState(
        profiles: [...state.profiles, profile],
        selectedProfileId: profile.id,
      );
      return;
    }
    final existing = state.profiles[existingIndex];
    final updated = profile.copyWith();
    final profiles = [...state.profiles];
    profiles[existingIndex] = ServerProfile(
      id: existing.id,
      displayName: updated.displayName,
      originalHostInput: updated.originalHostInput,
      normalizedEndpoint: updated.normalizedEndpoint,
      lastKnownVersion: updated.lastKnownVersion,
    );
    state = ServerProfilesState(
      profiles: profiles,
      selectedProfileId: existing.id,
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
