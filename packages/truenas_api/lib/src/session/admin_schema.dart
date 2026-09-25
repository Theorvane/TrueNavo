part of 'true_nas_session_repository.dart';

/// A bounded, immutable subset of the schema advertised by authenticated
/// middleware. Unknown assertions are not treated as permission to send JSON.
final class AdminSchema {
  AdminSchema.fromJson(Map<String, Object?> json)
    : raw = _schemaMap(json, json, 0);
  AdminSchema._(this.raw);

  final Map<String, Object?> raw;
  String? get type => raw['type'] is String ? raw['type'] as String : null;
  String? get title => raw['title'] is String ? raw['title'] as String : null;
  String? get description =>
      raw['description'] is String ? raw['description'] as String : null;
  bool get secret =>
      raw['secret'] == true ||
      raw['private'] == true ||
      raw['writeOnly'] == true ||
      raw['format'] == 'password';
  bool get hasDefault => !secret && raw.containsKey('default');
  Object? get defaultValue => hasDefault ? raw['default'] : null;
  List<Object?>? get enumValues =>
      raw['enum'] is List ? (raw['enum'] as List).cast<Object?>() : null;
  Map<String, AdminSchema> get properties {
    final value = raw['properties'];
    return Map.unmodifiable(
      value is Map
          ? {
              for (final e in value.entries)
                if (e.key is String && e.value is Map<String, Object?>)
                  e.key as String: AdminSchema._(
                    e.value as Map<String, Object?>,
                  ),
            }
          : <String, AdminSchema>{},
    );
  }

  Set<String> get requiredProperties => Set.unmodifiable({
    if (raw['required'] is List)
      ...(raw['required'] as List).whereType<String>(),
    for (final entry in properties.entries)
      if (entry.value.raw['_required_'] == true) entry.key,
  });
  AdminSchema? get items => raw['items'] is Map<String, Object?>
      ? AdminSchema._(raw['items'] as Map<String, Object?>)
      : null;
  List<AdminSchema> get variants {
    final value = raw['anyOf'] ?? raw['oneOf'];
    return List.unmodifiable(
      value is List
          ? value.whereType<Map<String, Object?>>().map(AdminSchema._)
          : <AdminSchema>[],
    );
  }

  bool get nullable =>
      type == 'null' ||
      raw['nullable'] == true ||
      variants.any((s) => s.type == 'null');

  bool get supported {
    if (raw['_unsupported_'] == true ||
        raw.keys.any((k) => !_knownKeys.contains(k))) {
      return false;
    }
    if (variants.isNotEmpty) {
      // JSON Schema permits assertions alongside a union. Do not silently
      // ignore those assertions; these rarer shapes need a dedicated adapter.
      if (raw.keys.any(_unionSiblingAssertions.contains) ||
          (raw.containsKey('anyOf') && raw.containsKey('oneOf'))) {
        return false;
      }
      return variants.every((s) => s.supported);
    }
    if (raw.containsKey('anyOf') || raw.containsKey('oneOf')) return false;
    if (type == 'object') {
      if (raw['properties'] != null && raw['properties'] is! Map) return false;
      return requiredProperties.every(
        (name) => properties[name]?.supported == true,
      );
    }
    if (type == 'array') return items?.supported == true;
    if (!{'string', 'integer', 'number', 'boolean', 'null'}.contains(type)) {
      return false;
    }
    if (raw['pattern'] != null) {
      if (raw['pattern'] is! String ||
          (raw['pattern'] as String).length > 512) {
        return false;
      }
      try {
        RegExp(raw['pattern'] as String);
      } on Object {
        return false;
      }
    }
    return true;
  }

  /// Null means valid. Errors deliberately contain no submitted values.
  String? validate(Object? value) => _valid(value, 0)
      ? null
      : 'This value does not match the server’s supported input schema.';

  bool _valid(Object? value, int depth) {
    if (!supported || depth > 12) return false;
    if (enumValues != null && !enumValues!.any((e) => _adminEqual(e, value))) {
      return false;
    }
    if (raw.containsKey('const') && !_adminEqual(raw['const'], value)) {
      return false;
    }
    if (variants.isNotEmpty) {
      final matches = variants.where((s) => s._valid(value, depth + 1)).length;
      return raw.containsKey('oneOf') ? matches == 1 : matches > 0;
    }
    if (value == null) return nullable;
    switch (type) {
      case 'string':
        if (value is! String ||
            value.length > 8192 ||
            RegExp(
              r'[\x00-\x1F\x7F\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]',
            ).hasMatch(value)) {
          // Generic native controls are single-line. Invisible controls and
          // multiline scripts/keys require a dedicated, escaped editor.
          return false;
        }
        if (!_bounds(value.runes.length, 'minLength', 'maxLength')) {
          return false;
        }
        if (raw['pattern'] is String &&
            !RegExp(raw['pattern'] as String).hasMatch(value)) {
          return false;
        }
        return true;
      case 'number':
      case 'integer':
        if (value is! num ||
            !value.isFinite ||
            (type == 'integer' && value is! int)) {
          return false;
        }
        if (!_bounds(value, 'minimum', 'maximum')) return false;
        if (raw['exclusiveMinimum'] case final num min) {
          if (value <= min) return false;
        }
        if (raw['exclusiveMaximum'] case final num max) {
          if (value >= max) return false;
        }
        if (raw['multipleOf'] case final num divisor) {
          if (divisor <= 0 ||
              (value / divisor - (value / divisor).round()).abs() > 1e-10) {
            return false;
          }
        }
        return true;
      case 'boolean':
        return value is bool;
      case 'object':
        if (value is! Map ||
            value.length > 128 ||
            value.keys.any((k) => k is! String)) {
          return false;
        }
        if (!_bounds(value.length, 'minProperties', 'maxProperties')) {
          return false;
        }
        if (!requiredProperties.every(value.containsKey)) return false;
        // Native forms intentionally do not accept arbitrary additional keys,
        // even when middleware's schema would allow an untyped JSON dictionary.
        return value.entries.every(
          (e) => properties[e.key]?._valid(e.value, depth + 1) == true,
        );
      case 'array':
        if (value is! List || value.length > 256 || items == null) return false;
        if (!_bounds(value.length, 'minItems', 'maxItems')) return false;
        if (raw['uniqueItems'] == true) {
          for (var i = 0; i < value.length; i++) {
            if (value.skip(i + 1).any((v) => _adminEqual(v, value[i]))) {
              return false;
            }
          }
        }
        return value.every((v) => items!._valid(v, depth + 1));
      default:
        return false;
    }
  }

  bool _bounds(num n, String minKey, String maxKey) =>
      (raw[minKey] is! num || n >= (raw[minKey] as num)) &&
      (raw[maxKey] is! num || n <= (raw[maxKey] as num));

  static const _knownKeys = {
    'type',
    'title',
    'description',
    'default',
    'examples',
    'deprecated',
    'readOnly',
    'writeOnly',
    'secret',
    'private',
    'format',
    'nullable',
    '_name_',
    '_required_',
    '_attrs_order_',
    '_unsupported_',
    r'$defs',
    'properties',
    'required',
    'additionalProperties',
    'items',
    'anyOf',
    'oneOf',
    'enum',
    'const',
    'minLength',
    'maxLength',
    'pattern',
    'minimum',
    'maximum',
    'exclusiveMinimum',
    'exclusiveMaximum',
    'multipleOf',
    'minItems',
    'maxItems',
    'uniqueItems',
    'minProperties',
    'maxProperties',
    'discriminator',
  };
  static const _unionSiblingAssertions = {
    'type',
    'properties',
    'required',
    'additionalProperties',
    'items',
    'minLength',
    'maxLength',
    'pattern',
    'minimum',
    'maximum',
    'exclusiveMinimum',
    'exclusiveMaximum',
    'multipleOf',
    'minItems',
    'maxItems',
    'uniqueItems',
    'minProperties',
    'maxProperties',
  };
}

final class AdminParameter {
  const AdminParameter({
    required this.name,
    required this.schema,
    required this.required,
  });
  final String name;
  final AdminSchema schema;
  final bool required;
}

Map<String, Object?> _schemaMap(Map input, Map root, int depth) {
  if (depth > 16 || input.length > 256 || input.keys.any((k) => k is! String)) {
    return const {'_unsupported_': true};
  }
  var source = Map<String, Object?>.from(input);
  final reference = source.remove(r'$ref');
  if (reference != null) {
    if (reference is! String || !reference.startsWith(r'#/$defs/')) {
      return const {'_unsupported_': true};
    }
    final definitions = root[r'$defs'];
    final resolved = definitions is Map
        ? definitions[reference.substring(8)]
        : null;
    if (resolved is! Map) return const {'_unsupported_': true};
    source = {..._schemaMap(resolved, root, depth + 1), ...source};
  }
  final secret =
      source['secret'] == true ||
      source['private'] == true ||
      source['writeOnly'] == true ||
      source['format'] == 'password' ||
      _adminSensitiveKey(source['_name_']?.toString() ?? '');
  if (secret) {
    source['secret'] = true;
    source.remove('default');
    source.remove('examples');
    if (source.containsKey('enum') || source.containsKey('const')) {
      source.remove('enum');
      source.remove('const');
      source['_unsupported_'] = true;
    }
  }
  if (source['type'] case final List types) {
    if (types.any((t) => t is! String)) return const {'_unsupported_': true};
    source.remove('type');
    final assertions = Map<String, Object?>.from(source);
    source = {
      'anyOf': types
          .map((t) => <String, Object?>{...assertions, 'type': t})
          .toList(),
      if (secret) 'secret': true,
      if (assertions.containsKey('default')) 'default': assertions['default'],
      if (assertions.containsKey('_name_')) '_name_': assertions['_name_'],
      if (assertions.containsKey('_required_'))
        '_required_': assertions['_required_'],
    };
  }
  // Middleware's get_json_schema wraps repeated array items in a one-item list.
  if (source['items'] case final List values) {
    if (values.length != 1) return const {'_unsupported_': true};
    source['items'] = values.single;
  }
  final result = <String, Object?>{};
  for (final e in source.entries) {
    if (e.key == r'$defs') continue;
    final value = e.value;
    if (e.key == 'properties' && value is Map) {
      result[e.key] = Map<String, Object?>.unmodifiable({
        for (final p in value.entries)
          if (p.key is String && p.value is Map)
            p.key as String: _schemaMap(
              {
                ...p.value as Map,
                if (_adminSensitiveKey(p.key as String)) 'secret': true,
              },
              root,
              depth + 1,
            ),
      });
    } else if ({'items', 'additionalProperties'}.contains(e.key) &&
        value is Map) {
      result[e.key] = _schemaMap(value, root, depth + 1);
    } else if ({'anyOf', 'oneOf'}.contains(e.key) && value is List) {
      result[e.key] = List<Object?>.unmodifiable([
        for (final v in value)
          v is Map
              ? _schemaMap(v, root, depth + 1)
              : const {'_unsupported_': true},
      ]);
    } else {
      result[e.key] = _adminFreeze(value, depth: depth + 1);
    }
  }
  if (_hasAdminSecretSchema(result)) {
    // A parent object/union default can contain a child's password even when
    // the parent itself is not a secret field. Never expose those defaults.
    result.remove('default');
    result.remove('examples');
  }
  return Map.unmodifiable(result);
}

bool _hasAdminSecretSchema(Object? schema) {
  if (schema is Map) {
    if (schema['secret'] == true) return true;
    return schema.values.any(_hasAdminSecretSchema);
  }
  return schema is List && schema.any(_hasAdminSecretSchema);
}

Object? _adminFreeze(Object? value, {int depth = 0}) {
  if (depth > 24) throw const AdminException(AdminExceptionReason.invalidInput);
  if (value == null ||
      value is bool ||
      value is String ||
      (value is num && value.isFinite)) {
    return value;
  }
  if (value is List && value.length <= 4096) {
    return List<Object?>.unmodifiable(
      value.map((v) => _adminFreeze(v, depth: depth + 1)),
    );
  }
  if (value is Map &&
      value.length <= 4096 &&
      value.keys.every((k) => k is String)) {
    return Map<String, Object?>.unmodifiable({
      for (final e in value.entries)
        e.key as String: _adminFreeze(e.value, depth: depth + 1),
    });
  }
  throw const AdminException(AdminExceptionReason.invalidInput);
}

bool _adminEqual(Object? a, Object? b) {
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable.generate(a.length).every((i) => _adminEqual(a[i], b[i]));
  }
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _adminEqual(a[k], b[k]));
  }
  return a == b;
}

bool _adminSensitiveKey(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  return normalized.contains('password') ||
      normalized.contains('passwd') ||
      normalized.contains('secret') ||
      normalized.contains('token') ||
      normalized.contains('privatekey') ||
      normalized.contains('apikey') ||
      normalized.contains('credential') ||
      normalized.endsWith('hash') ||
      {
        'key',
        'passphrase',
        'arguments',
        'args',
        'payload',
        'input',
        'rawresult',
        'error',
        'exception',
        'traceback',
      }.contains(normalized);
}
