part of 'true_nas_session_repository.dart';

/// Adapter for the catalog's questions.yaml format, which is not JSON Schema.
/// Source: middleware TS-25.10.1 apps/schema_construction_utils.py.
/// Only server-issued questions define the accepted values. Inactive branches
/// are removed before transmission, and unknown assertions are never ignored.
final class AppFormSchema {
  factory AppFormSchema.fromVersionDetails(Map<String, Object?> details) {
    final schema = details['schema'];
    return AppFormSchema.fromQuestions(
      schema is Map ? schema['questions'] : null,
    );
  }

  factory AppFormSchema.fromQuestions(Object? questions) {
    try {
      final budget = [0];
      return AppFormSchema._(_appQuestions(questions, 0, budget));
    } on Object {
      return AppFormSchema._(const [], malformed: true);
    }
  }

  AppFormSchema._(this._questions, {this.malformed = false}) {
    initialValues = Map.unmodifiable(
      _appDefaults(_questions, includeHidden: true),
    );
    valuesSchema = AdminSchema.fromJson(_appObjectSchema(_questions));
    parameters = List.unmodifiable([
      AdminParameter(name: 'values', schema: valuesSchema, required: true),
    ]);
    final reasons = <String>[];
    if (malformed) {
      reasons.add('This application has no supported configuration schema.');
    }
    _appInspect(_questions, initialValues, reasons);
    unsupportedReasons = List.unmodifiable(reasons.toSet());
    warnings = List.unmodifiable({
      if (_appAny(_questions, (q) => q.condition != null)) 'Conditional fields apply only when their sibling settings match. Inactive fields are omitted.',
      if (_appAny(_questions, (q) => q.refs.contains('normalize/ix_volume'))) 'The selected storage settings can create TrueNAS-managed application datasets.',
      if (_appAny(_questions, (q) => q.type == 'hostpath')) 'Host paths grant the application access to existing files. Review each path and mount permission.',
      if (_appAny(_questions, (q) => q.refs.contains('normalize/acl'))) 'Changing filesystem ACLs requires a dedicated permissions review and is unavailable in this form.',
      if (_appAny(_questions, (q) => q.immutable))
        'Some settings are immutable after installation.',
    });
  }

  final List<_AppQuestion> _questions;
  final bool malformed;
  late final List<AdminParameter> parameters;
  late final AdminSchema valuesSchema;

  /// Defaults contain no secret values; hidden system defaults are retained.
  late final Map<String, Object?> initialValues;
  late final List<String> unsupportedReasons;
  late final List<String> warnings;
  bool get supported => !malformed && unsupportedReasons.isEmpty;
  String? get blockedReason => supported ? null : unsupportedReasons.first;

  /// The static form displays optional conditional controls with a hint. A
  /// caller with a live change callback may instead display only active ones.
  List<AdminParameter> schemaFor(Map<String, Object?> values) => [
    AdminParameter(
      name: 'values',
      schema: AdminSchema.fromJson(
        _appObjectSchema(_questions, context: values),
      ),
      required: true,
    ),
  ];

  String? validate(Map<String, Object?> values) {
    try {
      buildValues(values);
      return null;
    } on Object {
      return 'Complete the active required fields and check their limits. Unsupported settings cannot be submitted.';
    }
  }

  Map<String, Object?> buildValues(Map<String, Object?> values) {
    if (malformed) {
      throw const FormatException('Unsupported application schema.');
    }
    return Map.unmodifiable(_appPrepare(_questions, values, 0));
  }

  /// Exact review values with secrets removed. The UI must bound the rendered
  /// preview and block oversized reviews rather than silently omitting fields.
  Object? previewValues(Map<String, Object?> values) =>
      _adminSanitize(buildValues(values), schema: valuesSchema, bounded: false);

  /// Ports are identified by catalog semantics, never by scanning user text.
  List<int> portsFor(Map<String, Object?> values) {
    final prepared = buildValues(values);
    final ports = <int>[];
    void visit(List<_AppQuestion> questions, Map values) {
      for (final q in questions) {
        if (!values.containsKey(q.name)) continue;
        final value = values[q.name];
        if (value is int &&
            (q.refs.contains('definitions/port') ||
                _appPublishedPort(q, questions, values))) {
          ports.add(value);
        }
        if (value is Map) visit(q.children, value);
        if (value is List && q.item != null) {
          for (final item in value) {
            if (item is Map) visit(q.item!.children, item);
            if (q.item!.refs.contains('definitions/port') && item is int) {
              ports.add(item);
            }
          }
        }
      }
    }

    visit(_questions, prepared);
    return List.unmodifiable(ports);
  }
}

/// Current catalog port groups use these exact sibling names and conditions.
/// This is deliberately narrower than guessing from arbitrary field names.
bool _appPublishedPort(
  _AppQuestion question,
  List<_AppQuestion> siblings,
  Map values,
) {
  if (question.name != 'port_number' ||
      question.type != 'int' ||
      question.constraints['minimum'] != 1 ||
      question.constraints['maximum'] != 65535 ||
      !_adminEqual(question.condition, [
        ['bind_mode', '=', 'published'],
      ]) ||
      values['bind_mode'] != 'published') {
    return false;
  }
  final mode = siblings.where((q) => q.name == 'bind_mode').firstOrNull;
  final choices = mode?.constraints['enum'];
  return mode?.type == 'string' &&
      choices is List &&
      choices.contains('published') &&
      choices.every((value) => {'published', 'exposed', ''}.contains(value));
}

enum _AppAbsent { value }

const _appAbsent = _AppAbsent.value;

final class _AppQuestion {
  _AppQuestion({
    required this.name,
    required this.title,
    required this.description,
    required this.type,
    required this.required,
    required this.hidden,
    required this.secret,
    required this.immutable,
    required this.nullable,
    required this.condition,
    required this.refs,
    required this.children,
    required this.item,
    required this.constraints,
    required this.defaultValue,
    required this.unsupported,
  });
  final String name, title, description, type;
  final bool required, hidden, secret, immutable, nullable;
  final Object? condition;
  final List<String> refs;
  final List<_AppQuestion> children;
  final _AppQuestion? item;
  final Map<String, Object?> constraints;
  final Object? defaultValue;
  final bool unsupported;
  bool get hasDefault => !identical(defaultValue, _appAbsent);
}

List<_AppQuestion> _appQuestions(Object? raw, int depth, List<int> budget) {
  if (raw is! List || raw.length > 256 || depth > 10) {
    throw const FormatException('Invalid application questions.');
  }
  final names = <String>{};
  return List.unmodifiable(
    raw.map((rawQuestion) {
      if (rawQuestion is! Map || ++budget[0] > 2048) {
        throw const FormatException('Invalid application question.');
      }
      final name = rawQuestion['variable'];
      final schema = rawQuestion['schema'];
      if (name is! String ||
          name.isEmpty ||
          name.length > 128 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
          !names.add(name) ||
          schema is! Map) {
        throw const FormatException('Invalid application question.');
      }
      final type = schema['type'] is String ? schema['type'] as String : '';
      final secret =
          schema['private'] == true ||
          schema['secret'] == true ||
          _adminSensitiveKey(name);
      final children = type == 'dict'
          ? _appQuestions(schema['attrs'] ?? [], depth + 1, budget)
          : <_AppQuestion>[];
      final rawItems = schema['items'];
      final items = type == 'list' && rawItems is List && rawItems.length == 1
          ? _appQuestions(rawItems, depth + 1, budget)
          : <_AppQuestion>[];
      final refs = schema[r'$ref'] is List
          ? (schema[r'$ref'] as List).whereType<String>().toList()
          : <String>[];
      final constraints = <String, Object?>{};
      for (final entry in const {
        'min_length': 'minLength',
        'max_length': 'maxLength',
        'valid_chars': 'pattern',
      }.entries) {
        if (schema.containsKey(entry.key)) {
          constraints[entry.value] = schema[entry.key];
        }
      }
      for (final entry in {
        'min': type == 'list' ? 'minItems' : 'minimum',
        'max': type == 'list' ? 'maxItems' : 'maximum',
      }.entries) {
        if (schema.containsKey(entry.key)) {
          constraints[entry.value] = schema[entry.key];
        }
      }
      var malformedEnum = false;
      if (schema.containsKey('enum')) {
        final rawEnum = schema['enum'];
        if (rawEnum is! List ||
            rawEnum.isEmpty ||
            rawEnum.length > 2048 ||
            rawEnum.any((e) => e is! Map || !e.containsKey('value'))) {
          malformedEnum = true;
        } else {
          constraints['enum'] = rawEnum
              .map((e) => (e as Map)['value'])
              .toList();
        }
      }
      final condition = schema['show_if'];
      final malformedAssertions =
          [
            'required',
            'null',
            'private',
            'secret',
            'hidden',
            'immutable',
            'editable',
          ].any((key) => schema.containsKey(key) && schema[key] is! bool) ||
          [
            'min',
            'max',
            'min_length',
            'max_length',
          ].any((key) => schema.containsKey(key) && schema[key] is! num) ||
          (schema.containsKey('valid_chars') &&
              schema['valid_chars'] is! String);
      final unsupported =
          !{
            'int',
            'string',
            'text',
            'boolean',
            'dict',
            'list',
            'path',
            'hostpath',
            'uri',
          }.contains(type) ||
          schema.keys.any((key) => !_appQuestionKeys.contains(key)) ||
          (schema.containsKey(r'$ref') &&
              (schema[r'$ref'] is! List ||
                  refs.length != (schema[r'$ref'] as List).length)) ||
          refs.any((ref) => !_appKnownRefs.contains(ref)) ||
          refs.contains('normalize/acl') ||
          (schema['subquestions'] is List &&
              (schema['subquestions'] as List).isNotEmpty) ||
          schema.containsKey('show_subquestions_if') ||
          (condition != null && !_appConditionSupported(condition)) ||
          (type == 'list' && rawItems is List && rawItems.length > 1) ||
          (secret && !{'string', 'text'}.contains(type)) ||
          malformedEnum ||
          malformedAssertions;
      Object? defaultValue = _appAbsent;
      if (!secret && schema.containsKey('default')) {
        defaultValue = _appCleanDefault(
          schema['default'],
          type,
          children,
          items.firstOrNull,
        );
      }
      final result = _AppQuestion(
        name: name,
        title: _appPlainText(rawQuestion['label'], name),
        description: _appPlainText(rawQuestion['description'], ''),
        type: type,
        required: schema['required'] == true,
        hidden: schema['hidden'] == true,
        secret: secret,
        immutable: schema['immutable'] == true || schema['editable'] == false,
        nullable: schema['null'] == true,
        condition: _adminFreeze(condition),
        refs: List.unmodifiable(refs),
        children: children,
        item: items.firstOrNull,
        constraints: Map.unmodifiable(constraints),
        defaultValue: defaultValue,
        unsupported: unsupported,
      );
      return result;
    }),
  );
}

const _appQuestionKeys = {
  'type',
  'attrs',
  'items',
  'required',
  'null',
  'default',
  'private',
  'secret',
  'hidden',
  'immutable',
  'editable',
  'enum',
  'min',
  'max',
  'min_length',
  'max_length',
  'valid_chars',
  'valid_chars_error',
  'show_if',
  r'$ref',
  r'$ui-ref',
  'subquestions',
  'show_subquestions_if',
  'additional_attrs',
  'description',
  'title',
  'language',
  'ipv4',
  'ipv6',
  'cidr',
};
const _appKnownRefs = {
  'definitions/timezone',
  'definitions/node_bind_ip',
  'definitions/port',
  'definitions/certificate',
  'definitions/gpu_configuration',
  'normalize/ix_volume',
  'normalize/acl',
};

String _appPlainText(Object? value, String fallback) {
  if (value is! String || value.isEmpty) return fallback;
  final plain = value.replaceAll(
    RegExp(r'<[^>]*>|[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'),
    ' ',
  );
  return plain.length <= 600 ? plain : plain.substring(0, 600);
}

Object? _appCleanDefault(
  Object? value,
  String type,
  List<_AppQuestion> children,
  _AppQuestion? item,
) {
  if (value is Map && type == 'dict') {
    if (value.keys.any((name) => !children.any((q) => q.name == name))) {
      throw const FormatException('Unknown field in application default.');
    }
    return Map<String, Object?>.unmodifiable({
      for (final q in children)
        if (!q.secret && value.containsKey(q.name))
          q.name: _appCleanDefault(value[q.name], q.type, q.children, q.item),
    });
  }
  if (value is List && type == 'list') {
    if (value.length > 100 || (value.isNotEmpty && item == null)) {
      throw const FormatException('Unsupported default.');
    }
    if (item?.secret == true) return const <Object?>[];
    return List<Object?>.unmodifiable(
      value.map(
        (v) => _appCleanDefault(v, item!.type, item.children, item.item),
      ),
    );
  }
  return _adminFreeze(value);
}

Map<String, Object?> _appDefaults(
  List<_AppQuestion> questions, {
  required bool includeHidden,
}) {
  final result = <String, Object?>{};
  for (final q in questions) {
    if (q.secret || (!includeHidden && q.hidden) || q.unsupported) continue;
    if (q.hasDefault) {
      result[q.name] = q.defaultValue;
    } else if (q.type == 'dict') {
      result[q.name] = _appDefaults(q.children, includeHidden: includeHidden);
    } else if (q.type == 'list') {
      result[q.name] = <Object?>[];
    }
  }
  return result;
}

Map<String, Object?> _appObjectSchema(
  List<_AppQuestion> questions, {
  Map<String, Object?>? context,
  bool conditional = false,
}) {
  final eval = {..._appDefaults(questions, includeHidden: true), ...?context};
  final visible = questions.where(
    (q) =>
        !q.hidden &&
        (context == null ||
            q.condition == null ||
            !_appConditionSupported(q.condition) ||
            _appCondition(q.condition, eval)),
  );
  return {
    'type': 'object',
    'title': 'Application settings',
    'additionalProperties': false,
    'properties': {
      for (final q in visible)
        q.name: _appUiSchema(
          q,
          conditional: conditional || q.condition != null,
          conditionHint: _appConditionHint(q.condition, questions),
        ),
    },
    'required': [
      for (final q in visible)
        if (!conditional &&
            q.condition == null &&
            !q.unsupported &&
            (q.required || q.hasDefault || q.type == 'dict'))
          q.name,
    ],
  };
}

Map<String, Object?> _appUiSchema(
  _AppQuestion q, {
  bool conditional = false,
  String? conditionHint,
}) {
  if (q.unsupported) return {'_unsupported_': true, 'title': q.title};
  final base = <String, Object?>{
    'type': switch (q.type) {
      'dict' => 'object',
      'list' => 'array',
      'int' => 'integer',
      'boolean' => 'boolean',
      _ => 'string',
    },
    'title': q.title,
    if (q.description.isNotEmpty || q.condition != null)
      'description':
          '${q.description}${q.condition == null ? '' : ' Applies when ${conditionHint ?? 'the related sibling settings match'}. Inactive values are omitted.'}',
    if (q.nullable) 'nullable': true,
    if (q.secret) 'secret': true,
    ...q.constraints,
  };
  if (q.type == 'dict') {
    base.addAll(_appObjectSchema(q.children, conditional: conditional));
    base['title'] = q.title;
  } else if (q.type == 'list') {
    base['items'] = q.item == null
        ? {'type': 'null'}
        : _appUiSchema(q.item!, conditional: conditional);
    if (q.item == null || q.item!.unsupported) {
      base['items'] = {'type': 'null'};
      base['maxItems'] = 0;
    }
  }
  if (q.hasDefault && !q.secret && q.type != 'dict') {
    base['default'] = q.defaultValue;
  }
  if (q.immutable &&
      q.hasDefault &&
      !q.secret &&
      {'string', 'int', 'boolean', 'path'}.contains(q.type)) {
    base['const'] = q.defaultValue;
  }
  return base;
}

String? _appConditionHint(Object? condition, List<_AppQuestion> siblings) {
  if (condition == null || !_appConditionSupported(condition)) return null;
  String describe(Object? raw) {
    final rule = raw as List;
    if (rule.length == 2) {
      return '(${(rule[1] as List).map(describe).join(' or ')})';
    }
    final name = rule[0] as String;
    final sibling = siblings.where((q) => q.name == name).firstOrNull;
    final label = sibling?.title ?? _appPlainText(name, 'Related setting');
    final value = rule[2];
    final rendered = sibling?.secret == true || _adminSensitiveKey(name)
        ? 'the protected condition'
        : value is bool || value is num || value is String || value == null
        ? _appPlainText('$value', 'the selected value')
        : 'one of the specified choices';
    return '$label ${rule[1]} $rendered';
  }

  return (condition as List).map(describe).join(' and ');
}

Map<String, Object?> _appPrepare(
  List<_AppQuestion> questions,
  Map input,
  int depth,
) {
  if (depth > 12 ||
      input.length > 256 ||
      input.keys.any((k) => k is! String) ||
      input.keys.any((key) => !questions.any((q) => q.name == key))) {
    throw const FormatException('Unknown application field.');
  }
  final context = {..._appDefaults(questions, includeHidden: true), ...input};
  final result = <String, Object?>{};
  for (final q in questions) {
    if (q.condition != null) {
      if (!_appConditionSupported(q.condition)) {
        throw const FormatException('Unsupported application condition.');
      }
      if (!_appCondition(q.condition, context)) continue;
    }
    Object? value = input.containsKey(q.name) ? input[q.name] : _appAbsent;
    if (q.hidden &&
        !identical(value, _appAbsent) &&
        (!q.hasDefault || !_adminEqual(value, q.defaultValue))) {
      throw const FormatException(
        'Hidden application fields cannot be changed.',
      );
    }
    if (identical(value, _appAbsent)) {
      if (q.hasDefault) {
        value = q.defaultValue;
      } else if (q.type == 'dict') {
        value = <String, Object?>{};
      } else if (q.type == 'list') {
        value = <Object?>[];
      } else if (q.required) {
        throw const FormatException('Required application field missing.');
      } else {
        continue;
      }
    }
    if (q.unsupported) {
      throw const FormatException('Unsupported active application field.');
    }
    if (value == null && q.nullable) {
      result[q.name] = null;
      continue;
    }
    if (q.type == 'dict') {
      if (value is! Map) {
        throw const FormatException('Expected application object.');
      }
      result[q.name] = _appPrepare(q.children, value, depth + 1);
    } else if (q.type == 'list') {
      if (value is! List ||
          value.length > 100 ||
          (q.constraints['minItems'] is num &&
              value.length < (q.constraints['minItems'] as num)) ||
          (q.constraints['maxItems'] is num &&
              value.length > (q.constraints['maxItems'] as num)) ||
          (value.isNotEmpty && q.item == null)) {
        throw const FormatException('Invalid application list.');
      }
      result[q.name] = List<Object?>.unmodifiable([
        for (final item in value)
          _appPrepare([q.item!], {q.item!.name: item}, depth + 1)[q.item!.name],
      ]);
    } else {
      if (AdminSchema.fromJson(_appUiSchema(q)).validate(value) != null) {
        throw const FormatException('Invalid application value.');
      }
      if ({'hostpath', 'path'}.contains(q.type) &&
          (value is! String ||
              !value.startsWith('/') ||
              value.split('/').contains('..'))) {
        throw const FormatException('Application paths must be absolute.');
      }
      if (q.type == 'hostpath' &&
          (value is! String ||
              !value.startsWith('/mnt/') ||
              value == '/mnt/')) {
        throw const FormatException('Choose an application dataset path.');
      }
      if (q.type == 'uri' &&
          (value is! String || Uri.tryParse(value)?.hasScheme != true)) {
        throw const FormatException('Invalid application URI.');
      }
      if (q.type == 'ipaddr') {
        throw const FormatException(
          'IP address schema requires a dedicated validator.',
        );
      }
      result[q.name] = value;
    }
  }
  return result;
}

void _appInspect(
  List<_AppQuestion> questions,
  Map values,
  List<String> reasons,
) {
  final context = {..._appDefaults(questions, includeHidden: true), ...values};
  for (final q in questions) {
    if (q.condition != null) {
      if (!_appConditionSupported(q.condition)) {
        reasons.add('The application uses an unsupported conditional field.');
        continue;
      }
      if (!_appCondition(q.condition, context)) continue;
    }
    if (q.unsupported && (q.required || q.hasDefault || q.type == 'dict')) {
      reasons.add('An active application setting requires a dedicated editor.');
    }
    if (q.hidden && q.required && !q.hasDefault) {
      reasons.add('A hidden required setting has no usable default.');
    }
    if (q.type == 'dict') {
      _appInspect(
        q.children,
        values[q.name] is Map ? values[q.name] as Map : {},
        reasons,
      );
    }
  }
}

bool _appAny(List<_AppQuestion> questions, bool Function(_AppQuestion) test) =>
    questions.any(
      (q) =>
          test(q) ||
          _appAny(q.children, test) ||
          (q.item != null && _appAny([q.item!], test)),
    );

bool _appConditionSupported(Object? condition, [int depth = 0]) {
  if (depth > 8 || condition is! List || condition.length > 64) return false;
  return condition.every((rule) {
    if (rule is! List) return false;
    if (rule.length == 2 && rule[0] == 'OR') {
      return _appConditionSupported(rule[1], depth + 1);
    }
    return rule.length == 3 &&
        rule[0] is String &&
        {'=', '!=', 'in', 'nin', '>', '>=', '<', '<='}.contains(rule[1]) &&
        (!{'in', 'nin'}.contains(rule[1]) || rule[2] is List);
  });
}

bool _appCondition(Object? condition, Map context) {
  bool matches(Object? raw) {
    final rule = raw as List;
    if (rule.length == 2) return (rule[1] as List).any(matches);
    Object? actual = context;
    for (final part in (rule[0] as String).split('.')) {
      if (actual is! Map || !actual.containsKey(part)) return false;
      actual = actual[part];
    }
    final expected = rule[2];
    return switch (rule[1]) {
      '=' => _adminEqual(actual, expected),
      '!=' => !_adminEqual(actual, expected),
      'in' => (expected as List).any((v) => _adminEqual(actual, v)),
      'nin' => !(expected as List).any((v) => _adminEqual(actual, v)),
      '>' => actual is num && expected is num && actual > expected,
      '>=' => actual is num && expected is num && actual >= expected,
      '<' => actual is num && expected is num && actual < expected,
      '<=' => actual is num && expected is num && actual <= expected,
      _ => false,
    };
  }

  return (condition as List).every(matches);
}
