import 'package:truenas_api/truenas_api.dart';

/// Safe, credential-free metadata for a saved server profile.
final class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.displayName,
    required this.originalHostInput,
    required this.normalizedEndpoint,
    required this.lastKnownVersion,
  });

  factory ServerProfile.fromSafeSummary({
    required String id,
    required ServerSummary summary,
  }) {
    final host = summary.endpointUri.host;
    return ServerProfile(
      id: id,
      displayName: host.isEmpty ? summary.originalHostInput : host,
      originalHostInput: summary.originalHostInput,
      normalizedEndpoint: summary.endpointUri.toString(),
      lastKnownVersion: summary.version,
    );
  }

  final String id;
  final String displayName;
  final String originalHostInput;
  final String normalizedEndpoint;
  final String lastKnownVersion;

  ServerProfile copyWith({
    String? displayName,
    String? originalHostInput,
    String? normalizedEndpoint,
    String? lastKnownVersion,
  }) => ServerProfile(
    id: id,
    displayName: displayName ?? this.displayName,
    originalHostInput: originalHostInput ?? this.originalHostInput,
    normalizedEndpoint: normalizedEndpoint ?? this.normalizedEndpoint,
    lastKnownVersion: lastKnownVersion ?? this.lastKnownVersion,
  );

  @override
  bool operator ==(Object other) =>
      other is ServerProfile &&
      id == other.id &&
      displayName == other.displayName &&
      originalHostInput == other.originalHostInput &&
      normalizedEndpoint == other.normalizedEndpoint &&
      lastKnownVersion == other.lastKnownVersion;

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    originalHostInput,
    normalizedEndpoint,
    lastKnownVersion,
  );
}
