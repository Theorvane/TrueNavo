import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:yaml/yaml.dart';

import 'package:truenas_api/truenas_api.dart';

final class AuditExportArchiveSummary {
  const AuditExportArchiveSummary({
    required this.format,
    required this.rowCount,
    required this.decodedBytes,
  });
  final AuditExportFormat format;
  final int rowCount, decodedBytes;
}

final class AuditExportArchiveVerifier {
  const AuditExportArchiveVerifier({this.maxDecodedBytes = 64 * 1024 * 1024});
  final int maxDecodedBytes;

  AuditExportArchiveSummary? verify({
    required Uint8List compressed,
    required String filename,
    required AuditExportFormat format,
    AuditService service = AuditService.middleware,
  }) {
    if (maxDecodedBytes < 1024 || compressed.length < 3) return null;
    Uint8List? decoded;
    try {
      decoded = _inflate(compressed);
      if (!_gzipEnvelope(compressed, decoded)) return null;
      final result = _tar(decoded, filename, format, service);
      return result == null
          ? null
          : AuditExportArchiveSummary(
              format: format,
              rowCount: result,
              decodedBytes: decoded.length,
            );
    } on Object {
      return null;
    } finally {
      decoded?.fillRange(0, decoded.length, 0);
    }
  }

  Uint8List _inflate(Uint8List compressed) {
    final output = _BoundedByteSink(maxDecodedBytes);
    try {
      final input = gzip.decoder.startChunkedConversion(output);
      const chunk = 64 * 1024;
      for (var offset = 0; offset < compressed.length; offset += chunk) {
        final end = offset + chunk < compressed.length
            ? offset + chunk
            : compressed.length;
        input.addSlice(compressed, offset, end, false);
      }
      input.close();
      return output.takeBytes();
    } catch (_) {
      output.dispose();
      rethrow;
    }
  }

  bool _gzipEnvelope(Uint8List compressed, Uint8List decoded) {
    if (compressed.length < 18 ||
        compressed[0] != 0x1f ||
        compressed[1] != 0x8b ||
        compressed[2] != 8) {
      return false;
    }
    final flags = compressed[3];
    if ((flags & 0xe0) != 0) return false;
    var offset = 10;
    final trailer = compressed.length - 8;
    if ((flags & 4) != 0) {
      if (offset + 2 > trailer) return false;
      final length = compressed[offset] | (compressed[offset + 1] << 8);
      offset += 2 + length;
    }
    for (final flag in const [8, 16]) {
      if ((flags & flag) == 0) continue;
      while (offset < trailer && compressed[offset] != 0) {
        offset++;
      }
      if (offset >= trailer) return false;
      offset++;
    }
    if ((flags & 2) != 0) offset += 2;
    if (offset > trailer) return false;
    final view = ByteData.sublistView(compressed);
    final expectedCrc = view.getUint32(trailer, Endian.little);
    final expectedSize = view.getUint32(trailer + 4, Endian.little);
    return expectedSize == (decoded.length & 0xffffffff) &&
        expectedCrc == _crc32(decoded);
  }

  int _crc32(Uint8List bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) == 0 ? crc >>> 1 : (crc >>> 1) ^ 0xedb88320;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  int? _tar(
    Uint8List bytes,
    String filename,
    AuditExportFormat format,
    AuditService service,
  ) {
    if (bytes.length < 1536 || bytes.length % 512 != 0) return null;
    final suffix = '.${format.name}.tar.gz';
    if (!filename.endsWith(suffix)) return null;
    final id = filename.substring(0, filename.length - suffix.length);
    if (!_uuid(id)) return null;
    final directoryName = '$id.${format.name}';
    final componentName = '$id.part_00000.${format.name}';
    String? directory;
    Uint8List? payload;
    var offset = 0, zeroBlocks = 0;
    try {
      while (offset + 512 <= bytes.length) {
        final header = Uint8List.sublistView(bytes, offset, offset + 512);
        if (header.every((value) => value == 0)) {
          zeroBlocks++;
          offset += 512;
          if (zeroBlocks >= 2) {
            if (bytes.sublist(offset).any((value) => value != 0)) return null;
            break;
          }
          continue;
        }
        if (zeroBlocks != 0 || !_checksum(header) || !_ustar(header)) {
          return null;
        }
        final name = _tarName(header);
        final size = _octal(header, 124, 12);
        final type = header[156];
        if (name == null || size == null || !_safePath(name)) return null;
        final dataStart = offset + 512;
        final dataEnd = dataStart + size;
        final paddedEnd = dataStart + ((size + 511) ~/ 512) * 512;
        if (dataEnd > bytes.length || paddedEnd > bytes.length) return null;
        if (bytes.sublist(dataEnd, paddedEnd).any((value) => value != 0)) {
          return null;
        }
        final normalized = name.endsWith('/')
            ? name.substring(0, name.length - 1)
            : name;
        final leaf = normalized.split('/').last;
        if (type == 53) {
          if (size != 0 || leaf != directoryName || directory != null) {
            return null;
          }
          directory = normalized;
        } else if (type == 0 || type == 48) {
          if (leaf != componentName || payload != null) return null;
          final parent = normalized.substring(
            0,
            normalized.length - leaf.length - 1,
          );
          if (directory == null || parent != directory) return null;
          payload = Uint8List.sublistView(bytes, dataStart, dataEnd);
        } else {
          return null;
        }
        offset = paddedEnd;
      }
      if (zeroBlocks < 2 || directory == null) return null;
      if (payload == null) return 0;
      return switch (format) {
        AuditExportFormat.json => _jsonRows(payload, service),
        AuditExportFormat.csv => _csvRows(payload),
        AuditExportFormat.yaml => _yamlRows(payload, service),
      };
    } on Object {
      return null;
    }
  }

  bool _uuid(String value) =>
      RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
        r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).stringMatch(value) ==
      value;

  bool _ustar(Uint8List header) {
    final magic = header.sublist(257, 263);
    return ascii.decode(magic, allowInvalid: true).startsWith('ustar');
  }

  bool _checksum(Uint8List header) {
    final expected = _octal(header, 148, 8);
    if (expected == null) return false;
    var sum = 0;
    for (var i = 0; i < 512; i++) {
      sum += i >= 148 && i < 156 ? 32 : header[i];
    }
    return sum == expected;
  }

  int? _octal(Uint8List source, int start, int length) {
    final field = source.sublist(start, start + length);
    if (field.any((value) => value >= 128)) return null;
    final text = ascii
        .decode(field, allowInvalid: false)
        .replaceAll('\u0000', '')
        .trim();
    if (text.isEmpty || !RegExp(r'^[0-7]+$').hasMatch(text)) return null;
    return int.tryParse(text, radix: 8);
  }

  String? _tarName(Uint8List header) {
    String field(int start, int length) {
      final values = header.sublist(start, start + length);
      final end = values.indexOf(0);
      return utf8.decode(
        end < 0 ? values : values.sublist(0, end),
        allowMalformed: false,
      );
    }

    final name = field(0, 100);
    final prefix = field(345, 155);
    if (name.isEmpty) return null;
    return prefix.isEmpty ? name : '$prefix/$name';
  }

  bool _safePath(String value) {
    if (value.length > 300 ||
        value.startsWith('/') ||
        value.contains('\\') ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return false;
    }
    final normalized = value.endsWith('/')
        ? value.substring(0, value.length - 1)
        : value;
    final parts = normalized.split('/');
    return normalized.isNotEmpty &&
        parts.every((part) => part.isNotEmpty && part != '.' && part != '..');
  }

  int? _jsonRows(Uint8List payload, AuditService service) {
    final value = jsonDecode(utf8.decode(payload, allowMalformed: false));
    if (value is! List || value.isEmpty || value.length > 10000) return null;
    if (value.any((row) => row is! Map)) {
      return null;
    }
    return value.length;
  }

  int? _yamlRows(Uint8List payload, AuditService service) {
    final text = utf8.decode(payload, allowMalformed: false);
    if (text.isEmpty || text.contains('\u0000') || text.contains('\t')) {
      return null;
    }
    final value = loadYaml(text);
    if (value is! YamlList || value.isEmpty || value.length > 10000) {
      return null;
    }
    final budget = _YamlBudget();
    if (value.any((row) => row is! YamlMap || !_yamlValue(row, budget, 0))) {
      return null;
    }
    return value.length;
  }

  bool _yamlValue(Object? value, _YamlBudget budget, int depth) {
    if (++budget.nodes > 100000 || depth > 32) return false;
    if (value == null ||
        value is String ||
        value is num ||
        value is bool ||
        value is DateTime) {
      return true;
    }
    if (value is YamlList) {
      return value.every((entry) => _yamlValue(entry, budget, depth + 1));
    }
    if (value is YamlMap) {
      return value.entries.every(
        (entry) =>
            entry.key is String &&
            (entry.key as String).length <= 1024 &&
            _yamlValue(entry.value, budget, depth + 1),
      );
    }
    return false;
  }

  int? _csvRows(Uint8List payload) {
    final text = utf8.decode(payload, allowMalformed: false);
    if (text.isEmpty || text.contains('\u0000')) return null;
    final widths = <int>[];
    var fields = 1, quoted = false, hasData = false;
    for (var i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      if (quoted) {
        if (code == 34) {
          if (i + 1 < text.length && text.codeUnitAt(i + 1) == 34) {
            i++;
          } else {
            quoted = false;
          }
        }
        continue;
      }
      if (code == 34) {
        quoted = true;
      } else if (code == 44) {
        fields++;
      } else if (code == 10) {
        widths.add(fields);
        fields = 1;
        if (widths.length > 10001) return null;
      } else if (code != 13) {
        hasData = true;
      }
    }
    if (quoted) return null;
    if (!text.endsWith('\n') && hasData) widths.add(fields);
    if (widths.length < 2 || widths.length > 10001) return null;
    final width = widths.first;
    if (width == 0 || widths.any((value) => value != width)) return null;
    return widths.length - 1;
  }
}

final class _YamlBudget {
  int nodes = 0;
}

final class _BoundedByteSink extends ByteConversionSink {
  _BoundedByteSink(this.limit);
  final int limit;
  final List<Uint8List> _chunks = [];
  int _length = 0;
  bool _closed = false, _taken = false;

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    if (_closed || _taken || start < 0 || end < start || end > chunk.length) {
      throw const FormatException('Invalid gzip stream state.');
    }
    final count = end - start;
    if (_length + count > limit) {
      dispose();
      throw const FormatException('Decoded audit archive exceeds limit.');
    }
    if (count != 0) {
      final copy = Uint8List.fromList(chunk.sublist(start, end));
      _chunks.add(copy);
      _length += copy.length;
    }
    if (isLast) close();
  }

  @override
  void close() => _closed = true;

  Uint8List takeBytes() {
    if (!_closed || _taken) {
      throw const FormatException('Incomplete gzip stream.');
    }
    _taken = true;
    final result = Uint8List(_length);
    var offset = 0;
    for (final chunk in _chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
      chunk.fillRange(0, chunk.length, 0);
    }
    _chunks.clear();
    _length = 0;
    return result;
  }

  void dispose() {
    for (final chunk in _chunks) {
      chunk.fillRange(0, chunk.length, 0);
    }
    _chunks.clear();
    _length = 0;
    _closed = true;
    _taken = true;
  }
}
