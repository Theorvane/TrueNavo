import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test('keeps only safe summary metadata and compares by value', () {
    final profile = ServerProfile.fromSafeSummary(
      id: 'opaque-1',
      summary: ServerSummary(
        originalHostInput: 'https://nas.example',
        endpointUri: Uri.parse('wss://nas.example/api/current'),
        identity: 'private-identity',
        version: '25.10',
        availableMethodNames: const {'private.method'},
      ),
    );

    expect(profile.displayName, 'nas.example');
    expect(profile.originalHostInput, 'https://nas.example');
    expect(profile.normalizedEndpoint, 'wss://nas.example/api/current');
    expect(profile.lastKnownVersion, '25.10');
    expect(profile, profile.copyWith(displayName: 'nas.example'));
  });
}
