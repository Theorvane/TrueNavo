import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/nvme/nvme_tcp_bind_address.dart';

void main() {
  test('explicit global and ULA IPv6 literals are creatable', () {
    for (final value in [
      '2001:db8::2',
      '2001:DB8:0:0:0:0:0:0002',
      'fd00::2',
      'FC00:1:2:3:4:5:6:7',
      '2001:db8:1:2:3:4:5:6',
    ]) {
      expect(NvmeTcpBindAddress.parse(value)?.creatable, true, reason: value);
    }
  });

  test('compressed case and padding variants have the same identity', () {
    expect(
      NvmeTcpBindAddress.equivalent('2001:db8::2', '2001:0DB8:0:0:0:0:0:0002'),
      true,
    );
    expect(NvmeTcpBindAddress.equivalent('fd00::2', 'fd00::3'), false);
    expect(NvmeTcpBindAddress.equivalent('2001:db8::2', '10.0.0.2'), false);
  });

  test('mapped IPv4 aliases collide but cannot be created', () {
    for (final alias in [
      '::ffff:10.0.0.2',
      '::FFFF:0A00:0002',
      '0:0:0:0:0:ffff:a00:2',
    ]) {
      expect(
        NvmeTcpBindAddress.equivalent(alias, '10.0.0.2'),
        true,
        reason: alias,
      );
      expect(NvmeTcpBindAddress.parse(alias)?.creatable, false);
    }
  });

  test('all wildcard spellings are detected conservatively', () {
    for (final value in [
      '',
      '0.0.0.0',
      '::',
      '0:0:0:0:0:0:0:0',
      '::ffff:0.0.0.0',
    ]) {
      expect(NvmeTcpBindAddress.parse(value)?.wildcard, true, reason: value);
      expect(NvmeTcpBindAddress.parse(value)?.creatable, false);
    }
  });

  test('local multicast mapped and scoped inputs cannot be created', () {
    for (final value in [
      '::1',
      'fe80::2',
      'fec0::2',
      'ff02::2',
      '::10.0.0.2',
      'fe80::2%eth0',
      '[2001:db8::2]',
      '2001:db8::192.0.2.1',
    ]) {
      expect(
        NvmeTcpBindAddress.parse(value)?.creatable ?? false,
        false,
        reason: value,
      );
    }
  });

  test('malformed and host-like inputs do not acquire an address identity', () {
    for (final value in [
      'host',
      ' 2001:db8::2',
      '2001:db8::2\n',
      '2001:db8:::2',
      '2001::db8::2',
      ':2001:db8::2',
      '2001:db8:0:0:0:0:0:0:2',
      '2001:db8:2',
      '2001:db8::10000',
      '2001:db8::g',
      '2001:db8::2/64',
      '01.2.3.4',
      '256.1.2.3',
      '::ffff:999.0.0.2',
      '::ffff:10.0.0.2:3',
    ]) {
      expect(NvmeTcpBindAddress.parse(value), isNull, reason: value);
    }
  });
}
