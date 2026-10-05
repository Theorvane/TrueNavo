import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/iscsi/iscsi_listener_choices.dart';

void main() {
  test('retains only offered IP keys, not HA backing descriptions', () {
    final choices = IscsiListenerChoices.parse({
      '192.0.2.10': 'private-node-a / private-node-b',
      '2001:db8::10': 'interface detail',
    }, now: () => DateTime.utc(2026, 9, 26));
    expect(choices.addresses, {'192.0.2.10', '2001:db8::10'});
    expect(choices.observedAt, DateTime.utc(2026, 9, 26));
    expect(choices.toString(), isNot(contains('private-node-a')));
  });

  test('rejects malformed or oversized choice maps', () {
    for (final raw in [
      <String, Object?>{'192.0.2.10': 7},
      <String, Object?>{'bad\naddress': 'invalid'},
      <String, Object?>{'': 'empty'},
      <String, Object?>{'192.0.2.10': 'x' * 513},
      <String, Object?>{for (var i = 0; i < 101; i++) '192.0.2.$i': 'choice'},
      <Object?>[],
    ]) {
      expect(() => IscsiListenerChoices.parse(raw), throwsFormatException);
    }
  });
}
