import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TrueNavo package and native application identifiers stay aligned', () {
    final expected = <String, List<String>>{
      'pubspec.yaml': ['name: truenavo'],
      'android/app/build.gradle.kts': [
        'namespace = "com.sloki9637.truenavo"',
        'applicationId = "com.sloki9637.truenavo"',
      ],
      'ios/Runner.xcodeproj/project.pbxproj': [
        'PRODUCT_BUNDLE_IDENTIFIER = com.sloki9637.truenavo;',
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

  test(
    'store workflows and Android entry point use the registered mobile ID',
    () {
      const id = 'com.sloki9637.truenavo';
      expect(
        File('../../.github/workflows/android-google-play.yml')
            .readAsStringSync(),
        contains('packageName: $id'),
      );
      expect(
        File('../../.github/workflows/ios-app-store-connect.yml')
            .readAsStringSync(),
        contains('BUNDLE_ID: $id'),
      );
      expect(
        File(
          'android/app/src/main/kotlin/com/sloki9637/truenavo/MainActivity.kt',
        ).readAsStringSync(),
        startsWith('package $id'),
      );
    },
  );

  test('App Store icon is a 1024px RGB PNG without alpha', () {
    final bytes = File(
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/'
      'Icon-App-1024x1024@1x.png',
    ).readAsBytesSync();
    expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final header = ByteData.sublistView(bytes);
    expect(header.getUint32(16), 1024);
    expect(header.getUint32(20), 1024);
    expect(bytes[25], 2); // PNG truecolor RGB, not RGBA.
    expect(File('../../brand/truenavo-icon.png').existsSync(), isTrue);
  });

  test(
    'icon generation does not change boolean Xcode asset-symbol settings',
    () {
      final project = File('ios/Runner.xcodeproj/project.pbxproj')
          .readAsStringSync();
      final settings = RegExp(
        r'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = (.+);',
      ).allMatches(project);
      expect(settings, isNotEmpty);
      for (final setting in settings) {
        expect(setting.group(1), 'YES');
      }
    },
  );
}
