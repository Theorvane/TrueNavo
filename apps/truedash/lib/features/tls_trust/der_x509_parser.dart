import 'dart:convert';
import 'dart:typed_data';

import 'certificate_facts.dart';

/// Strict, structural DER reader for facts from one presented X.509 leaf.
NativeParsedLeafFacts parsePresentedLeafDer(Uint8List der) {
  try {
    if (der.isEmpty || der.length > 64 * 1024) {
      throw const FormatException();
    }
    final root = _DerReader(der);
    final certificate = _DerReader(root.one(0x30));
    root.finish();
    final tbs = certificate.take(0x30);
    final outerAlgorithm = certificate.take(0x30);
    _signatureValue(certificate.take(0x03));
    certificate.finish();

    final reader = _DerReader(tbs);
    // Version is DEFAULT v1 when omitted. DER must not encode that default.
    final version = reader.peekTag() == 0xa0 ? _version(reader.take(0xa0)) : 0;
    _serialNumber(reader.take(0x02));
    final innerAlgorithm = reader.take(0x30);
    _algorithmIdentifier(innerAlgorithm);
    if (!_bytesEqual(innerAlgorithm, outerAlgorithm)) {
      throw const FormatException();
    }
    _algorithmIdentifier(outerAlgorithm);
    final issuer = _nameSummary(reader.take(0x30));
    final validity = _DerReader(reader.take(0x30));
    final notBefore = _time(validity.takeAny());
    final notAfter = _time(validity.takeAny());
    validity.finish();
    final subject = _nameCommonName(reader.take(0x30));
    _subjectPublicKeyInfo(reader.take(0x30));

    var issuerUniqueIdSeen = false;
    var subjectUniqueIdSeen = false;
    var extensionsSeen = false;
    var sanPresent = false;
    final dnsSans = <String>[];
    final ipSans = <String>[];
    final extensionOids = <String>{};
    while (!reader.isFinished) {
      switch (reader.peekTag()) {
        case 0x81:
          if (issuerUniqueIdSeen || subjectUniqueIdSeen || extensionsSeen) {
            throw const FormatException();
          }
          issuerUniqueIdSeen = true;
          reader.take(0x81);
        case 0x82:
          if (subjectUniqueIdSeen || extensionsSeen) {
            throw const FormatException();
          }
          subjectUniqueIdSeen = true;
          reader.take(0x82);
        case 0xa3:
          if (extensionsSeen) throw const FormatException();
          extensionsSeen = true;
          final wrapped = _DerReader(reader.take(0xa3));
          final extensions = wrapped.one(0x30);
          wrapped.finish();
          final extensionReader = _DerReader(extensions);
          while (!extensionReader.isFinished) {
            final ext = _DerReader(extensionReader.take(0x30));
            final oid = _oid(ext.take(0x06));
            if (!extensionOids.add(oid)) throw const FormatException();
            if (ext.peekTag() == 0x01) _critical(ext.take(0x01));
            final value = ext.take(0x04);
            ext.finish();
            if (oid == '2.5.29.17') {
              sanPresent = true;
              final namesWrapper = _DerReader(value);
              final names = namesWrapper.one(0x30);
              namesWrapper.finish();
              final nameReader = _DerReader(names);
              while (!nameReader.isFinished) {
                final nameTag = nameReader.peekTag();
                final raw = nameReader.take(nameTag);
                if (nameTag == 0x82) {
                  final name = ascii.decode(raw, allowInvalid: false);
                  if (name.isEmpty) throw const FormatException();
                  dnsSans.add(name);
                } else if (nameTag == 0x87) {
                  if (raw.length != 4 && raw.length != 16) {
                    throw const FormatException();
                  }
                  ipSans.add(_ipText(raw));
                }
              }
            }
          }
        default:
          throw const FormatException();
      }
    }
    // RFC 5280 permits unique IDs only in v2/v3, and extensions only in v3.
    if (version == 0 && (issuerUniqueIdSeen || subjectUniqueIdSeen)) {
      throw const FormatException();
    }
    if (extensionsSeen && version != 2) throw const FormatException();
    return NativeParsedLeafFacts(
      subjectCommonName: subject,
      dnsSubjectAlternativeNames: dnsSans,
      ipSubjectAlternativeNames: ipSans,
      hasSubjectAlternativeNames: sanPresent,
      issuerSummary: issuer,
      notValidBefore: notBefore,
      notValidAfter: notAfter,
    );
  } catch (_) {
    throw const FormatException('Malformed DER X.509 certificate.');
  }
}

int _version(Uint8List bytes) {
  final reader = _DerReader(bytes);
  final integer = reader.take(0x02);
  reader.finish();
  if (integer.length != 1 || integer.single > 2) throw const FormatException();
  // Version is DEFAULT v1, so DER must omit an explicit zero value.
  if (integer.single == 0) throw const FormatException();
  return integer.single;
}

void _critical(Uint8List bytes) {
  // DER omits a DEFAULT FALSE value; an explicit critical field is TRUE only.
  if (bytes.length != 1 || bytes.single != 0xff) {
    throw const FormatException();
  }
}

void _serialNumber(Uint8List bytes) {
  if (bytes.isEmpty || (bytes.first & 0x80) != 0) throw const FormatException();
  if (bytes.length > 1 && bytes.first == 0 && (bytes[1] & 0x80) == 0) {
    throw const FormatException();
  }
}

void _algorithmIdentifier(Uint8List bytes) {
  final reader = _DerReader(bytes);
  _oid(reader.take(0x06));
  if (!reader.isFinished) reader.takeAny();
  reader.finish();
}

void _subjectPublicKeyInfo(Uint8List bytes) {
  final reader = _DerReader(bytes);
  _algorithmIdentifier(reader.take(0x30));
  _signatureValue(reader.take(0x03));
  reader.finish();
}

void _signatureValue(Uint8List bytes) {
  if (bytes.length < 2 || bytes.first > 7) throw const FormatException();
  if (bytes.first > 0 && (bytes.last & ((1 << bytes.first) - 1)) != 0) {
    throw const FormatException();
  }
}

String _nameSummary(Uint8List content) {
  final reader = _DerReader(content);
  final parts = <String>[];
  while (!reader.isFinished) {
    final set = _DerReader(reader.take(0x31));
    while (!set.isFinished) {
      final attribute = _DerReader(set.take(0x30));
      final oid = _oid(attribute.take(0x06));
      final value = _directoryString(attribute.takeAny());
      attribute.finish();
      final label = switch (oid) {
        '2.5.4.3' => 'CN',
        '2.5.4.10' => 'O',
        '2.5.4.11' => 'OU',
        '2.5.4.6' => 'C',
        '2.5.4.7' => 'L',
        '2.5.4.8' => 'ST',
        _ => null,
      };
      if (label != null) parts.add('$label=$value');
    }
  }
  if (parts.isEmpty) throw const FormatException();
  return parts.join(', ');
}

String? _nameCommonName(Uint8List content) {
  final reader = _DerReader(content);
  String? commonName;
  while (!reader.isFinished) {
    final set = _DerReader(reader.take(0x31));
    while (!set.isFinished) {
      final attribute = _DerReader(set.take(0x30));
      final oid = _oid(attribute.take(0x06));
      final value = _directoryString(attribute.takeAny());
      attribute.finish();
      if (oid == '2.5.4.3') {
        if (commonName != null) throw const FormatException();
        commonName = value;
      }
    }
  }
  return commonName;
}

String _directoryString(_DerValue value) {
  final bytes = value.bytes;
  final text = switch (value.tag) {
    0x0c => utf8.decode(bytes, allowMalformed: false),
    0x13 => _printable(bytes),
    0x16 => ascii.decode(bytes, allowInvalid: false),
    0x1e => _bmp(bytes),
    _ => throw const FormatException(),
  };
  if (text.isEmpty ||
      text.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw const FormatException();
  }
  return text;
}

String _printable(Uint8List bytes) {
  const allowed =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 \'()+,-./:=?';
  final text = ascii.decode(bytes, allowInvalid: false);
  if (text.codeUnits.any(
    (unit) => !allowed.contains(String.fromCharCode(unit)),
  )) {
    throw const FormatException();
  }
  return text;
}

String _bmp(Uint8List bytes) {
  if (bytes.length.isOdd) throw const FormatException();
  final codeUnits = <int>[];
  for (var i = 0; i < bytes.length; i += 2) {
    final unit = (bytes[i] << 8) | bytes[i + 1];
    if (unit >= 0xd800 && unit <= 0xdfff) throw const FormatException();
    codeUnits.add(unit);
  }
  return String.fromCharCodes(codeUnits);
}

DateTime _time(_DerValue value) {
  if (value.tag != 0x17 && value.tag != 0x18) throw const FormatException();
  final text = ascii.decode(value.bytes, allowInvalid: false);
  final match = RegExp(
    value.tag == 0x17
        ? r'^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$'
        : r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$',
  ).firstMatch(text);
  if (match == null) throw const FormatException();
  final year = value.tag == 0x17
      ? (int.parse(match[1]!) >= 50 ? 1900 : 2000) + int.parse(match[1]!)
      : int.parse(match[1]!);
  if (year == 0) throw const FormatException();
  final values = [year, for (var i = 2; i <= 6; i++) int.parse(match[i]!)];
  final date = DateTime.utc(
    values[0],
    values[1],
    values[2],
    values[3],
    values[4],
    values[5],
  );
  if (date.year != values[0] ||
      date.month != values[1] ||
      date.day != values[2] ||
      date.hour != values[3] ||
      date.minute != values[4] ||
      date.second != values[5]) {
    throw const FormatException();
  }
  return date;
}

String _oid(Uint8List bytes) {
  if (bytes.isEmpty) throw const FormatException();
  final values = <int>[];
  var offset = 0;
  final first = _base128(bytes, () => offset, (value) => offset = value);
  values.add(
    first < 40
        ? 0
        : first < 80
        ? 1
        : 2,
  );
  values.add(first < 80 ? first % 40 : first - 80);
  while (offset < bytes.length) {
    values.add(_base128(bytes, () => offset, (value) => offset = value));
  }
  return values.join('.');
}

int _base128(
  Uint8List bytes,
  int Function() getOffset,
  void Function(int) setOffset,
) {
  var offset = getOffset();
  if (offset >= bytes.length || bytes[offset] == 0x80) {
    throw const FormatException();
  }
  var value = 0;
  while (true) {
    if (offset >= bytes.length || value > (0x7fffffff >> 7)) {
      throw const FormatException();
    }
    final byte = bytes[offset++];
    value = (value << 7) | (byte & 0x7f);
    if (value > 0x7fffffff) throw const FormatException();
    if ((byte & 0x80) == 0) break;
  }
  setOffset(offset);
  return value;
}

String _ipText(Uint8List bytes) => bytes.length == 4
    ? bytes.join('.')
    : List.generate(
        8,
        (i) => ((bytes[i * 2] << 8) | bytes[i * 2 + 1]).toRadixString(16),
      ).join(':');

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

final class _DerValue {
  const _DerValue(this.tag, this.bytes);
  final int tag;
  final Uint8List bytes;
}

final class _DerReader {
  _DerReader(this._bytes);
  final Uint8List _bytes;
  var _offset = 0;
  bool get isFinished => _offset == _bytes.length;
  int peekTag() {
    if (isFinished) throw const FormatException();
    return _bytes[_offset];
  }

  Uint8List one(int tag) => take(tag);
  Uint8List take(int tag) {
    final value = takeAny();
    if (value.tag != tag) throw const FormatException();
    return value.bytes;
  }

  _DerValue takeAny() {
    if (_offset + 2 > _bytes.length) throw const FormatException();
    final tag = _bytes[_offset++];
    if ((tag & 0x1f) == 0x1f) throw const FormatException();
    final firstLength = _bytes[_offset++];
    final int length;
    if (firstLength < 0x80) {
      length = firstLength;
    } else {
      final count = firstLength & 0x7f;
      if (count == 0 ||
          count > 4 ||
          _offset + count > _bytes.length ||
          _bytes[_offset] == 0) {
        throw const FormatException();
      }
      var decoded = 0;
      for (var i = 0; i < count; i++) {
        decoded = (decoded << 8) | _bytes[_offset++];
      }
      if (decoded < 128) throw const FormatException();
      length = decoded;
    }
    if (length > _bytes.length - _offset) throw const FormatException();
    final result = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return _DerValue(tag, result);
  }

  void finish() {
    if (!isFinished) throw const FormatException();
  }
}
