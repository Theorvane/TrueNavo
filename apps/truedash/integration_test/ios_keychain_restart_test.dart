import 'dart:io' show Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _phase = String.fromEnvironment('keychainTestPhase');
// flutter_secure_storage maps `key` to the Keychain account attribute.
const _account =
    'com.truedash.truedash.integration-test.ios-keychain-restart.account';
const _service =
    'com.truedash.truedash.integration-test.ios-keychain-restart.service';
const _marker = 'truedash-ios-keychain-restart-marker-v1';

const _storage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accountName: _service,
    accessibility: KeychainAccessibility.unlocked_this_device,
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS Keychain persists across a separate app process restart', (
    tester,
  ) async {
    expect(
      Platform.isIOS,
      isTrue,
      reason: 'This integration test is iOS-only.',
    );

    switch (_phase) {
      case 'write':
        await _storage.delete(key: _account);
        await _storage.write(key: _account, value: _marker);
        expect(await _storage.read(key: _account), _marker);
        break;
      case 'read-delete':
        expect(await _storage.read(key: _account), _marker);
        await _storage.delete(key: _account);
        expect(await _storage.read(key: _account), isNull);
        break;
      default:
        fail(
          'Pass --dart-define=keychainTestPhase=write or '
          '--dart-define=keychainTestPhase=read-delete.',
        );
    }
  });
}
