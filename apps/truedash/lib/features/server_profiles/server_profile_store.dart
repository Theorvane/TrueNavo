import 'server_profile.dart';

final class ServerProfileSnapshot {
  ServerProfileSnapshot({
    required List<ServerProfile> profiles,
    required this.selectedProfileId,
  }) : profiles = List.unmodifiable(profiles);

  final List<ServerProfile> profiles;
  final String? selectedProfileId;
}

abstract interface class ServerProfileStore {
  Future<ServerProfileSnapshot> load();
  Future<ServerProfileSnapshot> registerAndSelect(ServerProfile profile);
  Future<ServerProfileSnapshot> registerAndSelectWithCapabilities({
    required ServerProfile profile,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
    required bool Function() isCommitValid,
  });
  Future<ServerProfileSnapshot> select(String id);
  Future<ServerProfileSnapshot> remove(String id);
  Future<void> replaceCapabilities({
    required String profileId,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
  });
  Future<Set<String>> readCapabilities(String profileId, DateTime now);
  Future<void> close();
}
