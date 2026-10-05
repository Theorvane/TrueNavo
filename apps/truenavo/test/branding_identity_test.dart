import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TrueNavo package and native application identifiers stay aligned', () {
    final expected = <String, List<String>>{
      'pubspec.yaml': ['name: truenavo'],
      'android/app/build.gradle.kts': [
        'namespace = "com.truenavo.truenavo"',
        'applicationId = "com.truenavo.truenavo"',
      ],
      'ios/Runner.xcodeproj/project.pbxproj': [
        'PRODUCT_BUNDLE_IDENTIFIER = com.truenavo.truenavo;',
      ],
      'macos/Runner/Configs/AppInfo.xcconfig': [
        'PRODUCT_NAME = truenavo',
        'PRODUCT_BUNDLE_IDENTIFIER = com.truenavo.truenavo',
      ],
      'linux/CMakeLists.txt': [
        'set(BINARY_NAME "truenavo")',
        'set(APPLICATION_ID "com.truenavo.truenavo")',
      ],
      'windows/CMakeLists.txt': ['project(truenavo LANGUAGES CXX)'],
      'lib/features/local_persistence/database_connection_constants.dart': [
        "truenavo_local_state",
      ],
      'lib/features/credentials/credential_storage_key.dart': [
        'com.truenavo.api-key.v1',
      ],
      'lib/features/tls_trust/pin_store.dart': ['com.truenavo.tls-pin.v1'],
    };
    for (final entry in expected.entries) {
      final source = File(entry.key).readAsStringSync();
      for (final marker in entry.value) {
        expect(source, contains(marker), reason: entry.key);
      }
      expect(source, isNot(contains('com.trueraid')), reason: entry.key);
    }
    final manifest = jsonDecode(File('web/manifest.json').readAsStringSync());
    expect(manifest['name'], 'TrueNavo');
    expect(manifest['short_name'], 'TrueNavo');
    expect(manifest['id'], '/truenavo');
  });
}
