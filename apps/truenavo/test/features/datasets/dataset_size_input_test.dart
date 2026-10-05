import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/datasets/dataset_size_input.dart';

void main() {
  for (final unit in DatasetSizeUnit.values) {
    test('${unit.label} exact sizes round-trip without floating point', () {
      for (final bytes in [
        0,
        1,
        3,
        1023,
        1024,
        1073741824,
        1099511627777,
        9007199254740991,
      ]) {
        expect(parseDatasetSize(formatDatasetSize(bytes, unit), unit), bytes);
      }
    });
  }
  test('decimal units produce exact integer bytes', () {
    expect(parseDatasetSize('1.5', DatasetSizeUnit.gibibytes), 1610612736);
    expect(parseDatasetSize('0.5', DatasetSizeUnit.kibibytes), 512);
    expect(parseDatasetSize('0.0009765625', DatasetSizeUnit.kibibytes), 1);
    expect(parseDatasetSize(' 0001.000 ', DatasetSizeUnit.bytes), 1);
  });
  test('fractional bytes are rejected, not rounded', () {
    expect(parseDatasetSize('1.5', DatasetSizeUnit.bytes), isNull);
    expect(parseDatasetSize('0.1', DatasetSizeUnit.kibibytes), isNull);
    expect(
      parseDatasetSize('0.00000000000000000000001', DatasetSizeUnit.tebibytes),
      isNull,
    );
  });
  for (final input in [
    '',
    '-1',
    '+1',
    '1e3',
    'NaN',
    '.5',
    '1.',
    '1,000',
    '1 000',
    '9007199254740992',
  ]) {
    test(
      'invalid byte input "$input" is rejected',
      () => expect(parseDatasetSize(input, DatasetSizeUnit.bytes), isNull),
    );
  }
  test('large-unit overflow and excessive input length are rejected', () {
    expect(parseDatasetSize('8192', DatasetSizeUnit.tebibytes), isNull);
    expect(parseDatasetSize('1${'0' * 128}', DatasetSizeUnit.bytes), isNull);
  });
  test('format preserves one byte in TiB exactly', () {
    expect(
      formatDatasetSize(1, DatasetSizeUnit.tebibytes),
      '0.0000000000009094947017729282379150390625',
    );
    expect(
      () => formatDatasetSize(-1, DatasetSizeUnit.bytes),
      throwsRangeError,
    );
  });
}
