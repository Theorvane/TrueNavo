import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/iscsi/iscsi_sessions.dart';

void main() {
  test('projects only public session fields and records UTC observation', () {
    final snapshot = IscsiSessionsSnapshot.parse([
      {
        'initiator': 'iqn.client\n',
        'initiator_addr': '192.0.2.10',
        'target': 'iqn.target',
        'iser': false,
        'offload': true,
        'chap_secret': 'must-not-be-retained',
        'auth': {'secret': 'must-not-be-retained'},
      },
    ], DateTime.parse('2026-01-01T09:00:00+09:00'));

    expect(snapshot.observedAt.toIso8601String(), '2026-01-01T00:00:00.000Z');
    expect(snapshot.sessions, hasLength(1));
    expect(snapshot.sessions.single.initiator, 'iqn.client');
    expect(snapshot.sessions.single.initiatorAddress, '192.0.2.10');
    expect(snapshot.sessions.single.target, 'iqn.target');
    expect(snapshot.sessions.single.iser, isFalse);
    expect(snapshot.sessions.single.offload, isTrue);
    expect(
      snapshot.sessions.single.toString(),
      isNot(contains('must-not-be-retained')),
    );
    expect(() => snapshot.sessions.clear(), throwsUnsupportedError);
  });

  test(
    'rejects malformed or oversized reports rather than showing partial data',
    () {
      final now = DateTime.utc(2026);
      expect(
        () => IscsiSessionsSnapshot.parse(null, now),
        throwsFormatException,
      );
      expect(
        () => IscsiSessionsSnapshot.parse([1], now),
        throwsFormatException,
      );
      expect(
        () => IscsiSessionsSnapshot.parse(
          List.filled(101, <String, Object>{}),
          now,
        ),
        throwsFormatException,
      );
      expect(
        () => IscsiSessionsSnapshot.parse([
          {
            'initiator': 'iqn.client',
            'initiator_addr': '192.0.2.10',
            'target': 'iqn.target',
            'iser': false,
          },
        ], now),
        throwsFormatException,
      );
    },
  );

  test('accepts an empty live report', () {
    expect(
      IscsiSessionsSnapshot.parse([], DateTime.utc(2026)).sessions,
      isEmpty,
    );
  });
}
