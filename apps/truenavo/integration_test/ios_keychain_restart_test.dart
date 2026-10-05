import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:truenavo/features/tls_trust/platform_pin_storage.dart';
import 'package:truenavo/features/tls_trust/raw_pin_storage.dart';

const _phase = String.fromEnvironment('keychainTestPhase');
const _key = 'com.truenavo.tls-pin.integration-test.ios-keychain-restart.v1';
const _marker = 'truenavo-ios-keychain-restart-marker-v1';

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
    // Exercise the same platform-selected storage path used by the app.
    final storage = createPlatformRawPinStorage();

    switch (_phase) {
      case 'write':
        expect(await storage.delete(_key), const RawPinStorageResult.success());
        expect(
          await storage.write(_key, _marker),
          const RawPinStorageResult.success(),
        );
        expect(await storage.read(_key), const RawPinReadResult.value(_marker));
        break;
      case 'read-delete':
        expect(await storage.read(_key), const RawPinReadResult.value(_marker));
        expect(await storage.delete(_key), const RawPinStorageResult.success());
        expect(await storage.read(_key), const RawPinReadResult.absent());
        break;
      default:
        fail(
          'Pass --dart-define=keychainTestPhase=write or '
          '--dart-define=keychainTestPhase=read-delete.',
        );
    }
  });
}
