import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/tls_trust/models.dart';
import 'package:trueraid/features/tls_trust/tls_trust_providers.dart';

void main() {
  group('production trust clock', () {
    test('produces a timestamp PinRecord accepts', () {
      // The deterministic fake clocks used everywhere else hid a real defect:
      // `DateTime.now()` is local and microsecond-precise, so the coordinator
      // threw while constructing the record it was about to commit.
      final digest = 'A' * 64;
      for (var attempt = 0; attempt < 200; attempt++) {
        final record = PinRecord(
          leafDerSha256: digest,
          createdAt: trustClockNow(),
        );
        expect(record.createdAt.isUtc, isTrue);
        expect(record.createdAt.microsecond, 0);
      }
    });

    test('stays within a millisecond of the wall clock', () {
      final before = DateTime.now().toUtc();
      final captured = trustClockNow();
      final after = DateTime.now().toUtc();

      expect(
        captured.isBefore(before.subtract(const Duration(milliseconds: 1))),
        isFalse,
      );
      expect(captured.isAfter(after), isFalse);
    });
  });
}
