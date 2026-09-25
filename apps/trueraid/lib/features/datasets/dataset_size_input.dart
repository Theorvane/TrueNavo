/// Binary units, with exact arithmetic for both parsing and unit changes.
enum DatasetSizeUnit {
  bytes('B', 1),
  kibibytes('KiB', 1024),
  mebibytes('MiB', 1048576),
  gibibytes('GiB', 1073741824),
  tebibytes('TiB', 1099511627776);

  const DatasetSizeUnit(this.label, this.multiplier);
  final String label;
  final int multiplier;
}

/// Decimal input is allowed only when it represents an integer number of bytes.
/// No floating point rounding, exponent notation, negative sizes or overflow.
int? parseDatasetSize(String input, DatasetSizeUnit unit) {
  final text = input.trim();
  if (text.length > 128 || !RegExp(r'^[0-9]+(?:\.[0-9]+)?$').hasMatch(text)) {
    return null;
  }
  final parts = text.split('.');
  final fraction = parts.length == 2 ? parts[1] : '';
  final numerator =
      BigInt.parse('${parts[0]}$fraction') * BigInt.from(unit.multiplier);
  final denominator = BigInt.from(10).pow(fraction.length);
  if (numerator.remainder(denominator) != BigInt.zero) return null;
  final bytes = numerator ~/ denominator;
  if (bytes > BigInt.from(9007199254740991)) return null;
  return bytes.toInt();
}

/// Every binary unit has a finite decimal representation. Preserve all digits.
String formatDatasetSize(int bytes, DatasetSizeUnit unit) {
  if (bytes < 0 || bytes > 9007199254740991) {
    throw RangeError.range(bytes, 0, 9007199254740991);
  }
  final denominator = BigInt.from(unit.multiplier);
  final size = BigInt.from(bytes);
  final whole = size ~/ denominator;
  var remainder = size.remainder(denominator);
  if (remainder == BigInt.zero) return whole.toString();
  final fraction = StringBuffer();
  while (remainder != BigInt.zero) {
    remainder *= BigInt.from(10);
    fraction.write(remainder ~/ denominator);
    remainder = remainder.remainder(denominator);
  }
  return '$whole.$fraction';
}
