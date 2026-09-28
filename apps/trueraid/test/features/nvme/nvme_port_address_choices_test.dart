import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/nvme/nvme_port_address_choices.dart';

void main() {
  test('bounded choices are sorted and compare equivalent IPv6 literals', () {
    final choices = NvmePortAddressChoices.parse('RDMA', {
      'fd00::2': 'ULA',
      '10.0.0.2': 'IPv4',
    });
    expect(choices.choices.map((c) => c.address), ['10.0.0.2', 'fd00::2']);
    expect(choices.contains('fd00:0:0:0:0:0:0:0002'), true);
    expect(choices.contains('10.0.0.3'), false);
  });
  test('unsupported address formats are visibly excluded', () {
    final choices = NvmePortAddressChoices.parse('TCP', {
      '': 'Wildcard',
      'fe80::1%eth0': 'Scoped',
      '::ffff:10.0.0.2': 'Mapped',
      '10.0.0.2': 'Allowed',
    });
    expect(choices.excludedCount, 3);
    expect(choices.choices.length, 1);
  });
  test('map ordering does not affect proof but descriptions do', () {
    final a = NvmePortAddressChoices.parse('TCP', {
      '10.0.0.1': 'one',
      '10.0.0.2': 'two',
    });
    final b = NvmePortAddressChoices.parse('TCP', {
      '10.0.0.2': 'two',
      '10.0.0.1': 'one',
    });
    final c = NvmePortAddressChoices.parse('TCP', {
      '10.0.0.1': 'changed',
      '10.0.0.2': 'two',
    });
    expect(a.proof, b.proof);
    expect(a.proof, isNot(c.proof));
  });
  test('empty map is a truthful empty inventory', () {
    expect(NvmePortAddressChoices.parse('RDMA', {}).choices, isEmpty);
  });
  test('malformed oversized and unsupported results fail closed', () {
    for (final value in [
      null,
      [],
      {'10.0.0.2': 123},
      {1: 'bad'},
      {'10.0.0.2': 'bad\nlabel'},
      {'bad\nkey': 'bad'},
      {'10.0.0.2': List.filled(257, 'x').join()},
      {for (var i = 0; i < 101; i++) '10.0.0.$i': 'row'},
    ]) {
      expect(
        () => NvmePortAddressChoices.parse('TCP', value),
        throwsStateError,
      );
    }
    expect(() => NvmePortAddressChoices.parse('FC', {}), throwsStateError);
  });
  test('equivalent duplicate choices cannot silently alias one another', () {
    expect(
      () => NvmePortAddressChoices.parse('TCP', {
        'fd00::2': 'one',
        'FD00:0:0:0:0:0:0:0002': 'two',
      }),
      throwsStateError,
    );
  });
}
