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
  test('persistent representation excludes profile, API key and raw certificate fields', () {
    final pinStore = source('pin_store.dart');
    expect(pinStore, isNot(contains('ServerProfile')));
    expect(pinStore, isNot(contains('apiKey')));
    expect(pinStore, isNot(contains('rawDer')));
  });
}
