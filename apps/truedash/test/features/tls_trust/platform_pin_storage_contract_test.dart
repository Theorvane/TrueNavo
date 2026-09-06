import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/tls_trust/platform_pin_storage_windows.dart';
import 'package:truedash/features/tls_trust/raw_pin_storage.dart';

void main() {
  String source(String path) =>
      File('lib/features/tls_trust/$path').readAsStringSync();
  test('web route cannot load secure storage', () {
    final web = source('platform_pin_storage_unsupported.dart');
    expect(web, isNot(contains('flutter_secure_storage')));
    expect(web, contains('unsupportedPlatform'));
  });
  test(
    'Windows selects direct Credential Manager and has bounded safe targets',
    () {
      final io = source('platform_pin_storage_io.dart');
      final windows = source('platform_pin_storage_windows.dart');
      expect(io, contains('WindowsCredentialRawPinStorage'));
      expect(
        windows,
        allOf(
          contains('CredRead('),
          contains('CredWrite('),
          contains('CredDelete('),
          contains('CRED_PERSIST_LOCAL_MACHINE'),
        ),
      );
      expect(
        windows,
        allOf(
          contains('_maxTargetChars = 256'),
          contains('_maxCredentialBytes = 2560'),
          contains('sha256.convert'),
        ),
      );
      expect(windows, isNot(contains('flutter_secure_storage_windows')));
      expect(windows, isNot(contains('MethodChannel')));
    },
  );
  test('Windows credential failure statuses fail closed except not found', () {
    expect(
      WindowsCredentialStatus.read(succeeded: false, errorCode: 1168),
      const RawPinReadResult.absent(),
    );
    expect(
      WindowsCredentialStatus.read(succeeded: false, errorCode: 5),
      const RawPinReadResult.failure(RawPinStorageFailure.readFailed),
    );
    expect(
      WindowsCredentialStatus.delete(succeeded: false, errorCode: 1168),
      const RawPinStorageResult.success(),
    );
    expect(
      WindowsCredentialStatus.delete(succeeded: false, errorCode: 5),
      const RawPinStorageResult.failure(RawPinStorageFailure.deleteFailed),
    );
  });
  test(
    'native security configuration is strict and Linux documents libsecret',
    () {
      final io = source('platform_pin_storage_io.dart');
      final android = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      final linux = File('linux/CMakeLists.txt').readAsStringSync();
      final debug = File('macos/Runner/DebugProfile.entitlements')
          .readAsStringSync();
      final release = File('macos/Runner/Release.entitlements')
          .readAsStringSync();
      expect(
        io,
        allOf(
          contains('resetOnError: false'),
          contains('storageNamespace'),
          contains('unlocked_this_device'),
          contains('usesDataProtectionKeychain: true'),
        ),
      );
      expect(android, contains('android:allowBackup="false"'));
      expect(linux, allOf(contains('libsecret-1'), contains('keyring')));
      expect(debug, contains('<key>keychain-access-groups</key>\n\t<array/>'));
      expect(
        release,
        contains('<key>keychain-access-groups</key>\n\t<array/>'),
      );
    },
  );
  test('macOS CI verifies Task 2 entitlements with an ad-hoc signature', () {
    final ci = File('../../.gitlab-ci.yml').readAsStringSync();
    expect(ci, contains('xcodebuild -quiet'));
    expect(ci, contains('CODE_SIGNING_ALLOWED=NO'));
    expect(ci, contains('codesign --force --deep --sign - --entitlements'));
    expect(ci, contains('codesign --verify --deep --strict'));
    expect(ci, contains("get('com.apple.security.network.client') is True"));
    expect(ci, contains("'keychain-access-groups' in"));
  });
  test('iOS Runner configurations and entitlement plist enable only Keychain access groups', () {
    final project = File('ios/Runner.xcodeproj/project.pbxproj')
        .readAsStringSync();
    final entitlements = File('ios/Runner/Runner.entitlements');
    final plist = _keychainGroups(entitlements.readAsStringSync());
    final runnerConfigurations = <String, String>{
      for (final name in ['Debug', 'Profile', 'Release'])
        name: _runnerBuildSettings(project, name),
    };
    for (final configuration in runnerConfigurations.values) {
      expect(
        configuration,
        contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'),
      );
    }
    expect(plist, isEmpty);
  });
  test('macOS CI builds and validates signed iOS simulator output in isolated DerivedData', () {
    final ci = File('../../.gitlab-ci.yml').readAsStringSync();
    expect(ci, contains('build ios --simulator --debug --config-only'));
    expect(ci, contains('ios-task2-derived'));
    expect(ci, contains('-sdk iphonesimulator'));
    expect(ci, contains('-configuration Debug'));
    expect(ci, contains('Debug-iphonesimulator/Runner.app'));
    expect(ci, contains('ios/Runner/Runner.entitlements'));
    expect(ci, contains('keychain-access-groups'));
  });
  test('macOS CI runs the iOS Keychain restart integration runner', () {
    final ci = File('../../.gitlab-ci.yml').readAsStringSync();
    final runner = File('tool/run_ios_keychain_restart_integration_test.sh')
        .readAsStringSync();
    final xcrunShim = File('tool/xcrun_with_derived_data.sh')
        .readAsStringSync();
    final integration = File('integration_test/ios_keychain_restart_test.dart')
        .readAsStringSync();

    expect(ci, contains('./tool/run_ios_keychain_restart_integration_test.sh'));
    expect(runner, contains('integration_test/ios_keychain_restart_test.dart'));
    expect(runner, contains('TRUEDASH_IOS_TEST_DERIVED_DATA'));
    expect(runner, contains('xcrun_with_derived_data.sh'));
    expect(runner, contains('simctl create'));
    expect(runner, contains(r'simctl delete "$device_udid"'));
    expect(runner, contains('created_simulator=true'));
    expect(runner, isNot(contains('booted or shutdown')));
    expect(runner, contains('simctl list devices available -j'));
    expect(runner, contains('deviceTypeIdentifier'));
    expect(xcrunShim, contains('-derivedDataPath'));
    expect(xcrunShim, contains(r'${TRUEDASH_IOS_TEST_DERIVED_DATA:?}'));
    expect(
      integration,
      contains("String.fromEnvironment('keychainTestPhase')"),
    );
    expect(integration, contains("case 'write':"));
    expect(integration, contains("case 'read-delete':"));
    expect(integration, contains('createPlatformRawPinStorage()'));
    expect(integration, contains('RawPinStorageResult.success'));
    expect(integration, isNot(contains('FlutterSecureStorage')));
    expect(integration, isNot(contains('IOSOptions')));
    expect(integration, isNot(contains('accountName')));
  });
  test(
    'native conditional storage uses OS-released hashed app-private locks',
    () {
      final io = source('platform_pin_storage_io.dart');
      final windows = source('platform_pin_storage_windows.dart');
      final lock = source('native_pin_storage_lock.dart');
      for (final backend in <String>[io, windows]) {
        expect(
          backend,
          contains(
            'NativePinStorageLock.appPrivate(getApplicationSupportDirectory)',
          ),
        );
        expect(backend, contains('_lock.withKeys'));
        expect(backend, contains('_readUnlocked'));
        expect(backend, contains('_writeUnlocked'));
        expect(backend, contains('_deleteUnlocked'));
      }
      expect(lock, contains('sha256.convert'));
      expect(lock, contains('FileLock.blockingExclusive'));
      expect(lock, contains('await file.unlock()'));
      expect(lock, contains('await file.close()'));
      expect(lock, isNot(contains('envelope')));
    },
  );
  test('persistent representation excludes profile, API key and raw certificate fields', () {
    final pinStore = source('pin_store.dart');
    expect(pinStore, isNot(contains('ServerProfile')));
    expect(pinStore, isNot(contains('apiKey')));
    expect(pinStore, isNot(contains('rawDer')));
  });
}

String _runnerBuildSettings(String project, String configuration) {
  final identifier = configuration == 'Profile'
      ? '249021D4217E4FDB00AE95B9'
      : configuration == 'Debug'
      ? '97C147061CF9000F007C117D'
      : '97C147071CF9000F007C117D';
  final match = RegExp(
    '$identifier.*?buildSettings = \\{(.*?)\\};\\s*name = $configuration;',
    dotAll: true,
  ).firstMatch(project);
  return match?.group(1) ?? fail('missing Runner $configuration configuration');
}

List<String> _keychainGroups(String plist) {
  final dictionary = RegExp(
    r'<dict>(.*?)</dict>',
    dotAll: true,
  ).firstMatch(plist)?.group(1);
  if (dictionary == null) fail('entitlements has no dictionary');
  final group = RegExp(
    r'<key>keychain-access-groups</key>\s*<array>(.*?)</array>|<key>keychain-access-groups</key>\s*<array\s*/>',
    dotAll: true,
  ).firstMatch(dictionary);
  if (group == null || RegExp(r'<key>').allMatches(dictionary).length != 1) {
    fail('entitlements must contain only keychain-access-groups');
  }
  final contents = group.group(1) ?? '';
  final strings = RegExp(
    r'<string>(.*?)</string>',
    dotAll: true,
  ).allMatches(contents).map((match) => match.group(1)!).toList();
  if (contents
      .replaceAll(RegExp(r'<string>.*?</string>', dotAll: true), '')
      .trim()
      .isNotEmpty) {
    fail('keychain-access-groups must be an array of strings');
  }
  return strings;
}
