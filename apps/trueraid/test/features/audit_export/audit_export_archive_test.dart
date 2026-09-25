import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/audit_export/audit_export_archive.dart';
import 'package:truenas_api/truenas_api.dart';

const _id = '01234567-89ab-4cde-8f01-23456789abcd';

void main() {
  group('AuditExportArchiveVerifier', () {
    test('accepts a bounded JSON report without changing the input', () {
      final compressed = _archive(
        format: AuditExportFormat.json,
        payload: utf8.encode('[{"event":"login"},{"event":"logout"}]'),
      );
      final original = Uint8List.fromList(compressed);

      final result = const AuditExportArchiveVerifier().verify(
        compressed: compressed,
        filename: '$_id.json.tar.gz',
        format: AuditExportFormat.json,
      );

      expect(result?.rowCount, 2);
      expect(result?.decodedBytes, greaterThanOrEqualTo(2048));
      expect(compressed, orderedEquals(original));
    });

    test('accepts quoted CSV records including embedded newlines', () {
      final result = const AuditExportArchiveVerifier().verify(
        compressed: _archive(
          format: AuditExportFormat.csv,
          payload: utf8.encode(
            'event,message\nlogin,"comma, quote ""and"" newline\nvalue"\nlogout,ok\n',
          ),
        ),
        filename: '$_id.csv.tar.gz',
        format: AuditExportFormat.csv,
      );

      expect(result?.rowCount, 2);
    });

    test('accepts the bounded TrueNAS YAML list shape', () {
      final result = const AuditExportArchiveVerifier().verify(
        compressed: _archive(
          format: AuditExportFormat.yaml,
          payload: utf8.encode(
            '- event: login\n  success: true\n- event: logout\n',
          ),
        ),
        filename: '$_id.yaml.tar.gz',
        format: AuditExportFormat.yaml,
      );

      expect(result?.rowCount, 2);
    });

    test('rejects malformed or non-map YAML records', () {
      for (final payload in [
        '- event: [unterminated\n',
        '- scalar-only\n',
        'event: not-a-list\n',
      ]) {
        expect(
          const AuditExportArchiveVerifier().verify(
            compressed: _archive(
              format: AuditExportFormat.yaml,
              payload: utf8.encode(payload),
            ),
            filename: '$_id.yaml.tar.gz',
            format: AuditExportFormat.yaml,
          ),
          isNull,
        );
      }
    });

    test('accepts the empty directory emitted for zero matching rows', () {
      final result = const AuditExportArchiveVerifier().verify(
        compressed: _archive(format: AuditExportFormat.json),
        filename: '$_id.json.tar.gz',
        format: AuditExportFormat.json,
      );

      expect(result?.rowCount, 0);
    });

    test('rejects unsafe, unexpected and malformed archive members', () {
      final cases = <Uint8List>[
        _archive(
          format: AuditExportFormat.json,
          payload: utf8.encode('[{}]'),
          directory: '../$_id.json',
        ),
        _archive(
          format: AuditExportFormat.json,
          payload: utf8.encode('[{}]'),
          directory: '/$_id.json',
        ),
        _archive(
          format: AuditExportFormat.json,
          payload: utf8.encode('[{}]'),
          fileType: 50,
        ),
        _archive(
          format: AuditExportFormat.json,
          payload: utf8.encode('[{}]'),
          fileLeaf: 'extra.json',
        ),
        _archive(
          format: AuditExportFormat.json,
          payload: utf8.encode('[{}]'),
          corruptPadding: true,
        ),
      ];

      for (final compressed in cases) {
        expect(
          const AuditExportArchiveVerifier().verify(
            compressed: compressed,
            filename: '$_id.json.tar.gz',
            format: AuditExportFormat.json,
          ),
          isNull,
        );
      }
    });

    test('rejects checksum, truncation, gzip and decoded-size failures', () {
      final badChecksum = _archive(
        format: AuditExportFormat.json,
        payload: utf8.encode('[{}]'),
        corruptChecksum: true,
      );
      final valid = _archive(
        format: AuditExportFormat.json,
        payload: utf8.encode('[{}]'),
      );
      final badGzipCrc = Uint8List.fromList(valid);
      badGzipCrc[badGzipCrc.length - 8] ^= 1;
      final tooLarge = _archive(
        format: AuditExportFormat.json,
        payload: utf8.encode('[{"value":"${'x' * 2048}"}]'),
      );

      for (final compressed in <Uint8List>[
        badChecksum,
        badGzipCrc,
        Uint8List.fromList(valid.sublist(0, valid.length - 4)),
        Uint8List.fromList([0x1f, 0x8b, 0x08]),
      ]) {
        expect(
          const AuditExportArchiveVerifier().verify(
            compressed: compressed,
            filename: '$_id.json.tar.gz',
            format: AuditExportFormat.json,
          ),
          isNull,
        );
      }
      expect(
        const AuditExportArchiveVerifier(maxDecodedBytes: 2048).verify(
          compressed: tooLarge,
          filename: '$_id.json.tar.gz',
          format: AuditExportFormat.json,
        ),
        isNull,
      );
    });

    test('rejects filename and payload format mismatches', () {
      final archive = _archive(
        format: AuditExportFormat.json,
        payload: utf8.encode('[{}]'),
      );
      expect(
        const AuditExportArchiveVerifier().verify(
          compressed: archive,
          filename: '$_id.csv.tar.gz',
          format: AuditExportFormat.csv,
        ),
        isNull,
      );
      expect(
        const AuditExportArchiveVerifier().verify(
          compressed: archive,
          filename: 'not-a-uuid.json.tar.gz',
          format: AuditExportFormat.json,
        ),
        isNull,
      );
    });
  });
}

Uint8List _archive({
  required AuditExportFormat format,
  List<int>? payload,
  String? directory,
  String? fileLeaf,
  int fileType = 48,
  bool corruptChecksum = false,
  bool corruptPadding = false,
}) {
  final directoryName = directory ?? 'reports/$_id.${format.name}';
  final tar = BytesBuilder(copy: false)
    ..add(_header('$directoryName/', type: 53));
  if (payload != null) {
    tar
      ..add(
        _header(
          '$directoryName/${fileLeaf ?? '$_id.part_00000.${format.name}'}',
          type: fileType,
          size: payload.length,
          corruptChecksum: corruptChecksum,
        ),
      )
      ..add(payload);
    final padding = List<int>.filled((512 - payload.length % 512) % 512, 0);
    if (corruptPadding && padding.isNotEmpty) padding[0] = 1;
    tar.add(padding);
  }
  tar.add(List<int>.filled(1024, 0));
  return Uint8List.fromList(gzip.encode(tar.takeBytes()));
}

Uint8List _header(
  String path, {
  required int type,
  int size = 0,
  bool corruptChecksum = false,
}) {
  final header = Uint8List(512);
  final pathBytes = utf8.encode(path);
  if (pathBytes.length <= 100) {
    _writeText(header, 0, 100, path);
  } else {
    final separator = path.lastIndexOf('/');
    if (separator <= 0) throw ArgumentError.value(path, 'path');
    _writeText(header, 0, 100, path.substring(separator + 1));
    _writeText(header, 345, 155, path.substring(0, separator));
  }
  _writeOctal(header, 100, 8, 0x1a4);
  _writeOctal(header, 108, 8, 0);
  _writeOctal(header, 116, 8, 0);
  _writeOctal(header, 124, 12, size);
  _writeOctal(header, 136, 12, 0);
  header.fillRange(148, 156, 32);
  header[156] = type;
  _writeText(header, 257, 6, 'ustar');
  _writeText(header, 263, 2, '00');
  final checksum = header.fold<int>(0, (sum, value) => sum + value);
  _writeOctal(header, 148, 8, checksum + (corruptChecksum ? 1 : 0));
  return header;
}

void _writeText(Uint8List target, int offset, int width, String value) {
  final bytes = utf8.encode(value);
  if (bytes.length > width) throw ArgumentError.value(value, 'value');
  target.setRange(offset, offset + bytes.length, bytes);
}

void _writeOctal(Uint8List target, int offset, int width, int value) {
  final text = value.toRadixString(8).padLeft(width - 2, '0');
  _writeText(target, offset, width, '$text\u0000');
}
