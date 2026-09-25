import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> question(String name, Map<String, Object?> schema) => {
  'variable': name,
  'label': name,
  'schema': schema,
};

AppFormSchema form(List<Object?> questions) =>
    AppFormSchema.fromVersionDetails({
      'schema': {'questions': questions},
    });

void main() {
  test('current catalog port groups detect only active published bindings', () {
    final schema = form([
      question('network', {
        'type': 'dict',
        'attrs': [
          question('host_network', {'type': 'boolean', 'default': false}),
          question('web_port', {
            'type': 'dict',
            'show_if': [
              ['host_network', '=', false],
            ],
            'attrs': [
              question('bind_mode', {
                'type': 'string',
                'default': 'published',
                'enum': [
                  {'value': 'published', 'description': 'Publish'},
                  {'value': 'exposed', 'description': 'Expose'},
                  {'value': '', 'description': 'None'},
                ],
              }),
              question('port_number', {
                'type': 'int',
                'min': 1,
                'max': 65535,
                'default': 30013,
                'show_if': [
                  ['bind_mode', '=', 'published'],
                ],
              }),
            ],
          }),
        ],
      }),
      question('unrelated', {
        'type': 'dict',
        'attrs': [
          question('port_number', {
            'type': 'int',
            'min': 1,
            'max': 65535,
            'default': 40000,
          }),
        ],
      }),
    ]);
    expect(schema.portsFor({}), [30013]);
    expect(
      schema.portsFor({
        'network': {
          'web_port': {'port_number': 31000},
        },
      }),
      [31000],
    );
    for (final mode in ['exposed', '']) {
      expect(
        schema.portsFor({
          'network': {
            'web_port': {'bind_mode': mode, 'port_number': 31000},
          },
        }),
        isEmpty,
      );
    }
    expect(
      schema.portsFor({
        'network': {'host_network': true},
      }),
      isEmpty,
    );
    expect(schema.buildValues({})['unrelated'], {'port_number': 40000});
  });

  test('review previews preserve port and path while redacting nested private values', () {
    final schema = form([
      question('port', {'type': 'int', 'default': 30000}),
      question('mount', {'type': 'hostpath', 'required': true}),
      question('settings', {
        'type': 'dict',
        'attrs': [
          question('opaque', {'type': 'string', 'private': true}),
          question('api_token', {'type': 'string'}),
        ],
      }),
      question('accounts', {
        'type': 'list',
        'items': [
          question('account', {
            'type': 'dict',
            'attrs': [
              question('name', {'type': 'string'}),
              question('opaque', {'type': 'string', 'private': true}),
            ],
          }),
        ],
      }),
    ]);
    final preview = schema.previewValues({
      'mount': '/mnt/tank/media',
      'settings': {'opaque': 'private-value', 'api_token': 'token-value'},
      'accounts': [
        {'name': 'demo', 'opaque': 'nested-private-value'},
      ],
    });
    expect(preview, {
      'port': 30000,
      'mount': '/mnt/tank/media',
      'settings': {'opaque': '[redacted]', 'api_token': '[redacted]'},
      'accounts': [
        {'name': 'demo', 'opaque': '[redacted]'},
      ],
    });
    expect(preview.toString(), isNot(contains('private-value')));
    expect(preview.toString(), isNot(contains('token-value')));
  });

  test('native scalar fields normalize catalog types, enums and bounds', () {
    final schema = form([
      question('name', {'type': 'string', 'required': true, 'min_length': 3}),
      question('port', {
        'type': 'int',
        'default': 30000,
        'min': 1,
        'max': 65535,
        r'$ref': ['definitions/port'],
      }),
      question('enabled', {'type': 'boolean', 'default': false}),
      question('mode', {
        'type': 'string',
        'default': 'http',
        'enum': [
          {'value': 'http', 'description': 'HTTP'},
          {'value': 'https', 'description': 'HTTPS'},
        ],
      }),
    ]);
    expect(schema.supported, isTrue);
    expect(schema.parameters.single.name, 'values');
    expect(schema.parameters.single.schema.properties['port']!.type, 'integer');
    expect(schema.buildValues({'name': 'demo'}), {
      'name': 'demo',
      'port': 30000,
      'enabled': false,
      'mode': 'http',
    });
    expect(schema.portsFor({'name': 'demo'}), [30000]);
    expect(schema.validate({'name': 'aa'}), isNotNull);
    expect(schema.validate({'name': 'demo', 'port': 65536}), isNotNull);
    expect(schema.validate({'name': 'demo', 'mode': 'other'}), isNotNull);
    expect(schema.validate({'name': 'demo', 'port': '30000'}), isNotNull);
  });

  test('conditions use sibling defaults, prune inactive data and require active fields', () {
    final schema = form([
      question('network', {
        'type': 'dict',
        'attrs': [
          question('host_network', {'type': 'boolean', 'default': false}),
          question('port', {
            'type': 'int',
            'required': true,
            'min': 1,
            'max': 65535,
            'show_if': [
              ['host_network', '=', false],
            ],
            r'$ref': ['definitions/port'],
          }),
        ],
      }),
    ]);
    expect(schema.supported, isTrue);
    expect(
      schema.valuesSchema.properties['network']!.requiredProperties,
      contains('host_network'),
    );
    expect(
      schema.valuesSchema.properties['network']!.requiredProperties,
      isNot(contains('port')),
    );
    expect(schema.validate({}), isNotNull);
    expect(
      schema.buildValues({
        'network': {'host_network': true, 'port': 'ignored-inactive'},
      }),
      {
        'network': {'host_network': true},
      },
    );
    expect(
      schema.portsFor({
        'network': {'host_network': true, 'port': 2000},
      }),
      isEmpty,
    );
    expect(
      schema.buildValues({
        'network': {'port': 2000},
      }),
      {
        'network': {'host_network': false, 'port': 2000},
      },
    );
  });

  test(
    'inactive ACL branches allow normal storage; active ACL use is blocked',
    () {
      final schema = form([
        question('storage', {
          'type': 'dict',
          r'$ref': ['normalize/ix_volume'],
          'attrs': [
            question('dataset_name', {
              'type': 'string',
              'required': true,
              'hidden': true,
              'default': 'config',
            }),
            question('acl_enable', {'type': 'boolean', 'default': false}),
            question('acl', {
              'type': 'dict',
              'attrs': [],
              'show_if': [
                ['acl_enable', '=', true],
              ],
              r'$ref': ['normalize/acl'],
            }),
          ],
        }),
      ]);
      expect(schema.supported, isTrue);
      expect(schema.warnings, anyElement(contains('datasets')));
      expect(schema.buildValues({}), {
        'storage': {'dataset_name': 'config', 'acl_enable': false},
      });
      expect(
        schema.valuesSchema.properties['storage']!.properties,
        isNot(contains('dataset_name')),
      );
      expect(
        schema.validate({
          'storage': {'acl_enable': true},
        }),
        isNotNull,
      );
      expect(
        schema.validate({
          'storage': {'dataset_name': '../other'},
        }),
        isNotNull,
      );
      final prepared = schema.buildValues({});
      expect(schema.buildValues(prepared), prepared);
    },
  );

  test(
    'recursive list items retain native objects and enforce required children',
    () {
      final schema = form([
        question('additional_envs', {
          'type': 'list',
          'default': [],
          'max': 2,
          'items': [
            question('env', {
              'type': 'dict',
              'attrs': [
                question('name', {'type': 'string', 'required': true}),
                question('value', {'type': 'string'}),
              ],
            }),
          ],
        }),
      ]);
      expect(schema.supported, isTrue);
      expect(schema.buildValues({}), {'additional_envs': []});
      expect(
        schema.buildValues({
          'additional_envs': [
            {'name': 'MODE', 'value': 'test'},
          ],
        }),
        {
          'additional_envs': [
            {'name': 'MODE', 'value': 'test'},
          ],
        },
      );
      expect(
        schema.validate({
          'additional_envs': [
            {'value': 'test'},
          ],
        }),
        isNotNull,
      );
      expect(
        schema.validate({
          'additional_envs': [
            {'name': 'A'},
            {'name': 'B'},
            {'name': 'C'},
          ],
        }),
        isNotNull,
      );
    },
  );

  test(
    'secrets never appear in defaults, parent defaults, or validation errors',
    () {
      final schema = form([
        question('database', {
          'type': 'dict',
          'default': {'user': 'demo', 'password': 'parent-secret'},
          'attrs': [
            question('user', {'type': 'string', 'default': 'demo'}),
            question('password', {
              'type': 'string',
              'private': true,
              'default': 'child-secret',
              'required': true,
            }),
          ],
        }),
      ]);
      expect(schema.initialValues.toString(), isNot(contains('secret')));
      expect(
        schema.valuesSchema.raw.toString(),
        isNot(contains('parent-secret')),
      );
      expect(
        schema.valuesSchema.raw.toString(),
        isNot(contains('child-secret')),
      );
      expect(
        schema
            .valuesSchema
            .properties['database']!
            .properties['password']!
            .secret,
        isTrue,
      );
      expect(schema.validate({}), isNotNull);
      expect(
        schema.validate({
          'database': {'password': 'private\nvalue'},
        }),
        isNot(contains('private')),
      );
      expect(
        schema.buildValues({
          'database': {'password': 'entered-password'},
        }),
        {
          'database': {'user': 'demo', 'password': 'entered-password'},
        },
      );
    },
  );

  test('unknown fields, conditions, assertions and mandatory custom types fail closed', () {
    final schema = form([
      question('name', {'type': 'string'}),
    ]);
    expect(
      schema.validate({
        'ix_context': {'something': true},
      }),
      isNotNull,
    );
    expect(
      form([
        question('x', {'type': 'custom', 'required': true}),
      ]).supported,
      isFalse,
    );
    expect(
      form([
        question('x', {
          'type': 'string',
          'required': true,
          'new_constraint': true,
        }),
      ]).supported,
      isFalse,
    );
    expect(
      form([
        question('x', {
          'type': 'string',
          'show_if': [
            ['name', '~', 'a'],
          ],
        }),
      ]).supported,
      isFalse,
    );
    expect(
      form([
        question('x', {'type': 'int', 'required': true, 'min': 'bad'}),
      ]).supported,
      isFalse,
    );
    expect(AppFormSchema.fromVersionDetails({}).supported, isFalse);
    expect(
      form([
        question('same', {'type': 'string'}),
        question('same', {'type': 'int'}),
      ]).supported,
      isFalse,
    );
  });

  test(
    'an unsupported optional scalar can be omitted but cannot be submitted',
    () {
      final schema = form([
        question('advanced', {'type': 'future-type'}),
      ]);
      expect(schema.supported, isTrue);
      expect(schema.buildValues({}), isEmpty);
      expect(schema.validate({'advanced': 'arbitrary'}), isNotNull);
    },
  );

  test('untyped arrays only permit empty arrays', () {
    final schema = form([
      question('items', {'type': 'list', 'default': [], 'items': []}),
    ]);
    expect(schema.buildValues({}), {'items': []});
    expect(
      schema.validate({
        'items': ['untyped'],
      }),
      isNotNull,
    );
    expect(schema.valuesSchema.properties['items']!.raw['maxItems'], 0);
  });

  test('immutable defaults use fixed controls and cannot be overwritten', () {
    final schema = form([
      question('identifier', {
        'type': 'string',
        'immutable': true,
        'default': 'fixed',
      }),
    ]);
    expect(schema.valuesSchema.properties['identifier']!.raw['const'], 'fixed');
    expect(schema.validate({'identifier': 'other'}), isNotNull);
    expect(schema.buildValues({}), {'identifier': 'fixed'});
  });

  test('host paths are absolute dataset paths and reject traversal', () {
    final schema = form([
      question('path', {'type': 'hostpath', 'required': true}),
    ]);
    expect(schema.validate({'path': '/mnt/tank/media'}), isNull);
    for (final path in [
      '/etc',
      'mnt/tank',
      '/mnt/',
      '/mnt/tank/../other',
      '/mnt/tank\nother',
    ]) {
      expect(schema.validate({'path': path}), isNotNull);
    }
  });

  test('OR and membership conditions evaluate deterministically', () {
    final schema = form([
      question('mode', {'type': 'string', 'default': 'none'}),
      question('value', {
        'type': 'string',
        'required': true,
        'show_if': [
          [
            'OR',
            [
              [
                'mode',
                'in',
                ['a', 'b'],
              ],
              ['mode', '=', 'c'],
            ],
          ],
        ],
      }),
    ]);
    expect(schema.buildValues({}), {'mode': 'none'});
    expect(schema.validate({'mode': 'b'}), isNotNull);
    expect(schema.buildValues({'mode': 'c', 'value': 'yes'}), {
      'mode': 'c',
      'value': 'yes',
    });
  });

  test('parent defaults with unknown keys are not silently truncated', () {
    final schema = form([
      question('settings', {
        'type': 'dict',
        'default': {'unexpected': true},
        'attrs': [],
      }),
    ]);
    expect(schema.supported, isFalse);
  });
}
