import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> question(String name, Map<String, Object?> schema) => {
  'variable': name,
  'label': name,
  'schema': schema,
};

AppConfigSchema describe(
  List<Object?> questions,
  Map<String, Object?> values,
) => AppConfigSchema.fromVersionDetails({
  'schema': {'questions': questions},
}, currentValues: values);

AppConfigField field(AppConfigSchema schema, String id) =>
    schema.fields.firstWhere((field) => field.id == id);

AppConfigPatch patch(String id, Object? value) =>
    AppConfigPatch(fieldId: id, value: value);

void main() {
  test(
    'changed ports use exact schema semantics without defaults or key guessing',
    () {
      Map<String, Object?> group(String name) => question(name, {
        'type': 'dict',
        'attrs': [
          question('bind_mode', {
            'type': 'string',
            'enum': [
              {'value': 'published'},
              {'value': 'exposed'},
              {'value': ''},
            ],
          }),
          question('port_number', {
            'type': 'int',
            'min': 1,
            'max': 65535,
            'show_if': [
              ['bind_mode', '=', 'published'],
            ],
          }),
        ],
      });
      final schema = describe(
        [
          question('direct', {
            'type': 'int',
            r'$ref': ['definitions/port'],
            'min': 1,
            'max': 65535,
          }),
          group('published'),
          group('exposed'),
          question('unrelated', {
            'type': 'dict',
            'attrs': [
              question('port_number', {'type': 'int', 'min': 1, 'max': 65535}),
            ],
          }),
          question('ordinary', {'type': 'int'}),
        ],
        {
          'direct': 30000,
          'published': {'bind_mode': 'published', 'port_number': 30001},
          'exposed': {'bind_mode': 'exposed', 'port_number': 30002},
          'unrelated': {'port_number': 30003},
          'ordinary': 1,
        },
      );
      expect(field(schema, '/direct').isPort, isTrue);
      expect(field(schema, '/published/port_number').isPort, isTrue);
      expect(field(schema, '/exposed/port_number').isPort, isFalse);
      expect(field(schema, '/unrelated/port_number').isPort, isFalse);
      expect(
        schema.changedPorts([
          patch('/ordinary', 2),
          patch('/unrelated/port_number', 30100),
        ]),
        isEmpty,
      );
      expect(schema.changedPorts([patch('/direct', 31000)]), [31000]);
      expect(
        schema.changedPorts([
          patch('/published/port_number', 31001),
          patch('/direct', 31000),
        ]),
        [31001, 31000],
      );
      expect(
        schema.validatePatches([
          patch('/direct', 31000),
          patch('/published/port_number', 31000),
        ]),
        isNotNull,
      );
      expect(
        () => schema.changedPorts([patch('/exposed/port_number', 31002)]),
        throwsFormatException,
      );
    },
  );

  test(
    'private container defaults cannot hide effectful scalar descendants',
    () {
      for (final container in <Map<String, Object?>>[
        {
          'type': 'dict',
          'private': true,
          'default': {'volume': 'secret-dataset'},
          'attrs': [
            question('volume', {
              'type': 'string',
              r'$ref': ['normalize/ix_volume'],
            }),
          ],
        },
        {
          'type': 'list',
          'private': true,
          'default': ['secret-dataset'],
          'items': [
            question('volume', {
              'type': 'string',
              r'$ref': ['normalize/ix_volume'],
            }),
          ],
        },
        {
          'type': 'list',
          'default': ['secret-dataset'],
          'items': [
            question('volume', {
              'type': 'string',
              'private': true,
              r'$ref': ['normalize/ix_volume'],
            }),
          ],
        },
      ]) {
        final schema = describe(
          [
            question('ordinary', {'type': 'int'}),
            question('protected', container),
          ],
          {'ordinary': 1},
        );
        expect(schema.supported, isFalse);
        expect(schema.fields.every((field) => !field.editable), isTrue);
        expect(
          schema.fields.map((field) => field.schema.raw).toString(),
          isNot(contains('secret-dataset')),
        );
      }
    },
  );

  test(
    'patches and visible numeric values stay in exact JSON integer range',
    () {
      final schema = describe(
        [
          question('ordinary', {'type': 'int'}),
          question('oversized', {'type': 'int'}),
        ],
        {'ordinary': 1, 'oversized': 9007199254740992},
      );
      expect(field(schema, '/oversized').valueVisible, isFalse);
      expect(field(schema, '/oversized').editable, isFalse);
      expect(
        schema.validatePatches([patch('/ordinary', 9007199254740991)]),
        isNull,
      );
      expect(
        schema.validatePatches([patch('/ordinary', 9007199254740992)]),
        isNotNull,
      );
      expect(
        schema.validatePatches([patch('/ordinary', -9007199254740992)]),
        isNotNull,
      );
      expect(
        schema.validatePatches([patch('/ordinary', -9223372036854775808)]),
        isNotNull,
      );
      final minimum = describe(
        [
          question('minimum', {'type': 'int'}),
        ],
        {'minimum': -9223372036854775808},
      );
      expect(field(minimum, '/minimum').valueVisible, isFalse);
      expect(field(minimum, '/minimum').editable, isFalse);
    },
  );

  test(
    'changed roots preserve opaque, private, hidden and list siblings exactly',
    () {
      final values = <String, Object?>{
        'settings': {
          'count': 2,
          'password': 'secret-existing',
          'hidden': 'internal',
          'opaque': {
            'x': [1, null, 'opaque-secret'],
          },
          'entries': [
            {'name': 'kept', 'token': 'nested-secret'},
          ],
        },
        'unrelated': {'opaque': true},
      };
      final schema = describe([
        question('settings', {
          'type': 'dict',
          'attrs': [
            question('count', {
              'type': 'int',
              'min': 1,
              'max': 10,
              'default': 99,
            }),
            question('password', {'type': 'string', 'private': true}),
            question('hidden', {'type': 'string', 'hidden': true}),
            question('entries', {
              'type': 'list',
              'items': [
                question('item', {'type': 'dict', 'attrs': []}),
              ],
            }),
            question('missing', {
              'type': 'string',
              'default': 'never-injected',
            }),
          ],
        }),
      ], values);
      expect(schema.supported, isTrue);
      final changed = schema.applyPatches(values, [
        patch('/settings/count', 3),
      ]);
      expect(changed.keys, ['settings']);
      final expected = Map<String, Object?>.from(values['settings']! as Map);
      expected['count'] = 3;
      expect(changed['settings'], expected);
      expect((values['settings']! as Map)['count'], 2);
      expect((changed['settings']! as Map).containsKey('missing'), isFalse);
      expect(
        field(schema, '/settings/count').schema.raw.containsKey('default'),
        isFalse,
      );
      expect(field(schema, '/settings/count').currentValue, 2);
      expect(
        schema.parameters.every(
          (parameter) => !parameter.required && !parameter.schema.hasDefault,
        ),
        isTrue,
      );
    },
  );

  test('secrets and hidden parents never retain values or schema defaults', () {
    final schema = describe(
      [
        question('name', {'type': 'string'}),
        question('credentials', {
          'type': 'dict',
          'private': true,
          'default': {'user': 'schema-secret'},
          'attrs': [
            question('user', {'type': 'string', 'default': 'another-secret'}),
          ],
        }),
        question('hidden_group', {
          'type': 'dict',
          'hidden': true,
          'attrs': [
            question('value', {'type': 'string'}),
          ],
        }),
        question('password', {
          'type': 'string',
          'default': 'default-secret',
          'enum': [
            {'value': 'enum-secret'},
          ],
        }),
      ],
      {
        'name': 'demo',
        'credentials': {'user': 'current-secret'},
        'hidden_group': {'value': 'hidden-secret'},
        'password': 'password-secret',
      },
    );
    expect(schema.fields.map((field) => field.id), [
      '/name',
      '/credentials',
      '/hidden_group',
      '/password',
    ]);
    for (final protected in schema.fields.skip(1)) {
      expect(protected.currentValue, isNull);
      expect(protected.valueVisible, isFalse);
      expect(protected.secret, isTrue);
      expect(protected.editable, isFalse);
      expect(protected.schema.raw.toString(), isNot(contains('-secret')));
      expect(protected.schema.hasDefault, isFalse);
    }
    expect(
      patch('/password', 'patch-secret').toString(),
      isNot(contains('patch-secret')),
    );
  });

  test(
    'readonly visible null differs from retained non-scalar and unsafe values',
    () {
      final schema = describe(
        [
          question('nullable', {'type': 'string', 'null': true}),
          question('multiline', {'type': 'string'}),
          question('bidi', {'type': 'string'}),
          question('path', {'type': 'hostpath'}),
          question('items', {'type': 'list', 'items': []}),
        ],
        {
          'nullable': null,
          'multiline': 'first\nsecond',
          'bidi': 'a\u202Eb',
          'path': '/mnt/pool/data',
          'items': ['opaque'],
        },
      );
      expect(field(schema, '/nullable').valueVisible, isTrue);
      expect(field(schema, '/nullable').currentValue, isNull);
      expect(field(schema, '/nullable').editable, isTrue);
      for (final id in ['/multiline', '/bidi', '/path', '/items']) {
        expect(field(schema, id).currentValue, isNull);
        expect(field(schema, id).valueVisible, isFalse);
        expect(field(schema, id).editable, isFalse);
      }
    },
  );

  test('immutable existing values are preserved rather than replaced with defaults', () {
    final values = <String, Object?>{'fixed': 42, 'enabled': false};
    final schema = describe([
      question('fixed', {'type': 'int', 'immutable': true, 'default': 1}),
      question('enabled', {'type': 'boolean', 'default': true}),
    ], values);
    expect(field(schema, '/fixed').currentValue, 42);
    expect(field(schema, '/fixed').schema.raw.containsKey('const'), isFalse);
    expect(schema.validatePatches([patch('/fixed', 1)]), isNotNull);
    expect(schema.applyPatches(values, [patch('/enabled', true)]), {
      'enabled': true,
    });
  });

  test('JSON pointers escape separators without conflating dotted names', () {
    final values = <String, Object?>{
      'a/b': {'x~y': 1},
      'a.b': 2,
      'a': {'b': 3},
    };
    final schema = describe([
      question('a/b', {
        'type': 'dict',
        'attrs': [
          question('x~y', {'type': 'int'}),
        ],
      }),
      question('a.b', {'type': 'int'}),
      question('a', {
        'type': 'dict',
        'attrs': [
          question('b', {'type': 'int'}),
        ],
      }),
    ], values);
    expect(schema.fields.map((field) => field.id), [
      '/a~1b/x~0y',
      '/a.b',
      '/a/b',
    ]);
    expect(
      schema.applyPatches(values, [patch('/a~1b/x~0y', 7), patch('/a.b', 8)]),
      {
        'a/b': {'x~y': 7},
        'a.b': 8,
      },
    );
    expect(schema.validatePatches([patch('/a/b/x~y', 2)]), isNotNull);
  });

  test('only explicit distinct existing scalar changes are accepted', () {
    final values = <String, Object?>{'count': 2, 'name': 'demo'};
    final schema = describe([
      question('count', {'type': 'int', 'min': 1, 'max': 5}),
      question('name', {'type': 'string', 'max_length': 10}),
      question('missing', {'type': 'string', 'default': 'default'}),
    ], values);
    for (final patches in <List<AppConfigPatch>>[
      [],
      [patch('/unknown', 1)],
      [patch('/missing', 'new')],
      [patch('/count', 3), patch('/count', 4)],
      [patch('/count', 2)],
      [patch('/count', 6)],
      [patch('/count', '3')],
      [patch('/count', null)],
      [patch('/name', 'line\nbreak')],
      [
        patch('/name', {'unsafe': true}),
      ],
    ]) {
      expect(schema.validatePatches(patches), isNotNull);
      expect(() => schema.applyPatches(values, patches), throwsFormatException);
    }
    expect(
      schema.validatePatches([patch('/count', 4), patch('/name', 'new')]),
      isNull,
    );
  });

  test(
    'changed leaf and missing ancestor are rejected against fresh config',
    () {
      final schema = describe(
        [
          question('nested', {
            'type': 'dict',
            'attrs': [
              question('count', {'type': 'int'}),
            ],
          }),
        ],
        {
          'nested': {'count': 1},
        },
      );
      for (final values in <Map<String, Object?>>[
        {},
        {'nested': null},
        {'nested': {}},
        {
          'nested': {'count': 2},
        },
      ]) {
        expect(
          () => schema.applyPatches(values, [patch('/nested/count', 3)]),
          throwsFormatException,
        );
      }
      expect(
        schema.applyPatches(
          {
            'nested': {'count': 1, 'fresh_opaque': 'preserved'},
          },
          [patch('/nested/count', 3)],
        ),
        {
          'nested': {'count': 3, 'fresh_opaque': 'preserved'},
        },
      );
    },
  );

  test('conditional selectors and inactive fields are preserved unchanged', () {
    final schema = describe(
      [
        question('mode', {'type': 'string'}),
        question('active', {
          'type': 'int',
          'show_if': [
            ['mode', '=', 'on'],
          ],
        }),
        question('inactive', {
          'type': 'int',
          'show_if': [
            ['mode', '=', 'off'],
          ],
        }),
      ],
      {'mode': 'on', 'active': 1, 'inactive': 2},
    );
    expect(field(schema, '/mode').editable, isFalse);
    expect(field(schema, '/active').editable, isTrue);
    expect(field(schema, '/inactive').editable, isFalse);
    expect(schema.validatePatches([patch('/mode', 'off')]), isNotNull);
  });

  test('dict-valued selector protects every descendant', () {
    final schema = describe(
      [
        question('options', {
          'type': 'dict',
          'attrs': [
            question('enabled', {'type': 'boolean'}),
          ],
        }),
        question('count', {
          'type': 'int',
          'show_if': [
            [
              'options',
              '=',
              {'enabled': true},
            ],
          ],
        }),
      ],
      {
        'options': {'enabled': true},
        'count': 1,
      },
    );
    expect(field(schema, '/options/enabled').editable, isFalse);
    expect(field(schema, '/count').editable, isTrue);
  });

  test('unrecognized conditional and legacy subquestions block all edits', () {
    for (final settings in <Map<String, Object?>>[
      {
        'type': 'string',
        'show_if': [
          ['mode', 'regex', '.*'],
        ],
      },
      {'type': 'boolean', 'show_subquestions_if': true, 'subquestions': []},
    ]) {
      final schema = describe(
        [
          question('ordinary', {'type': 'int'}),
          question('special', settings),
        ],
        {'ordinary': 1, 'special': true},
      );
      expect(schema.supported, isFalse);
      expect(schema.fields.every((field) => !field.editable), isTrue);
    }
  });

  test('present GPU and ix-volume normalizers block unrelated edits even when hidden', () {
    for (final ref in [
      'definitions/gpu_configuration',
      'normalize/ix_volume',
    ]) {
      final schema = describe(
        [
          question('ordinary', {'type': 'int'}),
          question('device', {
            'type': 'dict',
            r'$ref': [ref],
            'show_if': [
              ['ordinary', '=', 99],
            ],
            'attrs': [],
          }),
        ],
        {
          'ordinary': 1,
          'device': {'dataset_name': 'existing'},
        },
      );
      expect(schema.supported, isFalse);
      expect(field(schema, '/ordinary').editable, isFalse);
      expect(schema.validatePatches([patch('/ordinary', 2)]), isNotNull);
    }
  });

  test('implicit default dict normalizers block edits when absent', () {
    for (final ref in [
      'definitions/gpu_configuration',
      'normalize/ix_volume',
    ]) {
      final schema = describe(
        [
          question('ordinary', {'type': 'int'}),
          question('device', {
            'type': 'dict',
            r'$ref': [ref],
            'attrs': [],
          }),
        ],
        {'ordinary': 1},
      );
      expect(schema.supported, isFalse);
    }
  });

  test(
    'active ACL, private defaults and nested ACL defaults block all edits',
    () {
      for (final acl in <Map<String, Object?>>[
        {
          'type': 'dict',
          r'$ref': ['normalize/acl'],
          'private': true,
          'default': {
            'entries': [1],
            'path': '/mnt/data',
          },
          'attrs': [],
        },
        {
          'type': 'dict',
          r'$ref': ['normalize/acl'],
          'attrs': [
            question('path', {'type': 'string', 'default': '/mnt/data'}),
            question('entries', {
              'type': 'list',
              'default': [1],
              'items': [
                question('entry', {'type': 'int'}),
              ],
            }),
          ],
        },
        {
          'type': 'dict',
          r'$ref': ['normalize/acl'],
          'attrs': [],
        },
      ]) {
        final schema = describe(
          [
            question('ordinary', {'type': 'int'}),
            question('acl', acl),
          ],
          {
            'ordinary': 1,
            if (acl['private'] != true)
              'acl': acl['attrs'] is List && (acl['attrs'] as List).isNotEmpty
                  ? {}
                  : {
                      'entries': [1],
                      'path': '/mnt/data',
                    },
          },
        );
        expect(schema.supported, isFalse);
      }
    },
  );

  test('explicit empty ACL entries do not schedule permission actions', () {
    final values = <String, Object?>{
      'ordinary': 1,
      'acl': {'entries': [], 'path': '/mnt/data'},
    };
    final schema = describe([
      question('ordinary', {'type': 'int'}),
      question('acl', {
        'type': 'dict',
        r'$ref': ['normalize/acl'],
        'attrs': [
          question('path', {'type': 'string'}),
          question('entries', {'type': 'list', 'items': []}),
        ],
      }),
    ], values);
    expect(schema.supported, isTrue);
    expect(field(schema, '/acl/path').editable, isFalse);
    expect(schema.applyPatches(values, [patch('/ordinary', 2)]), {
      'ordinary': 2,
    });
  });

  test('normalizers inside retained lists and unsupported list topology block all edits', () {
    final volume = question('item', {
      'type': 'dict',
      r'$ref': ['normalize/ix_volume'],
      'attrs': [],
    });
    for (final items in <List<Object?>>[
      [volume],
      [
        volume,
        question('other', {'type': 'string'}),
      ],
    ]) {
      final schema = describe(
        [
          question('ordinary', {'type': 'int'}),
          question('volumes', {'type': 'list', 'items': items}),
        ],
        {
          'ordinary': 1,
          'volumes': [
            {'dataset_name': 'data'},
          ],
        },
      );
      expect(schema.supported, isFalse);
    }
  });

  test('unknown reference normalization blocks all edits', () {
    final schema = describe(
      [
        question('ordinary', {'type': 'int'}),
        question('other', {
          'type': 'string',
          r'$ref': ['normalize/future_effect'],
        }),
      ],
      {'ordinary': 1, 'other': 'retained'},
    );
    expect(schema.supported, isFalse);
  });

  test('exact bounded port and timezone references support scalar edits', () {
    final schema = describe(
      [
        question('port', {
          'type': 'int',
          r'$ref': ['definitions/port'],
          'min': 1,
          'max': 65535,
        }),
        question('timezone', {
          'type': 'string',
          r'$ref': ['definitions/timezone'],
          'enum': [
            {'value': 'UTC'},
            {'value': 'Europe/London'},
          ],
        }),
        question('certificate', {
          'type': 'int',
          r'$ref': ['definitions/certificate'],
        }),
      ],
      {'port': 30000, 'timezone': 'UTC', 'certificate': 1},
    );
    expect(field(schema, '/port').editable, isTrue);
    expect(field(schema, '/timezone').editable, isTrue);
    expect(field(schema, '/certificate').editable, isFalse);
    expect(
      schema.validatePatches([
        patch('/port', 31000),
        patch('/timezone', 'Europe/London'),
      ]),
      isNull,
    );
    expect(schema.validatePatches([patch('/port', 70000)]), isNotNull);
  });

  test('unsupported scalar assertions and unsafe enum metadata are not ignored or retained', () {
    final schema = describe(
      [
        question('ordinary', {'type': 'int'}),
        question('text', {'type': 'string', 'min': 5}),
        question('enum', {
          'type': 'string',
          'enum': [
            {
              'value': {'password': 'secret-in-enum'},
            },
            {'value': 'shown'},
          ],
        }),
        question('future', {'type': 'string', 'future_assertion': true}),
      ],
      {'ordinary': 1, 'text': 'abcdef', 'enum': 'shown', 'future': 'kept'},
    );
    for (final id in ['/text', '/enum', '/future']) {
      expect(field(schema, id).editable, isFalse);
      expect(
        field(schema, id).schema.raw.toString(),
        isNot(contains('secret-in-enum')),
      );
    }
  });

  test('public field metadata and collections cannot be mutated', () {
    final schema = describe(
      [
        question('count', {'type': 'int'}),
      ],
      {'count': 1},
    );
    expect(() => schema.fields.clear(), throwsUnsupportedError);
    expect(() => schema.fields.first.path.add('new'), throwsUnsupportedError);
    expect(
      () => schema.fields.first.schema.raw['default'] = 'injected',
      throwsUnsupportedError,
    );
    expect(() => schema.parameters.clear(), throwsUnsupportedError);
  });

  test('canonical storage and security trees remain readonly while resource limits can change', () {
    final schema = describe(
      [
        question('storage', {
          'type': 'dict',
          'attrs': [
            question('read_only', {'type': 'boolean'}),
            question('ordinary_nested_name', {'type': 'string'}),
          ],
        }),
        question('run_as_context', {
          'type': 'dict',
          'attrs': [
            question('uid', {'type': 'int'}),
            question('gid', {'type': 'int'}),
          ],
        }),
        question('privileged', {'type': 'boolean'}),
        question('security_context', {
          'type': 'dict',
          'attrs': [
            question('enabled', {'type': 'boolean'}),
          ],
        }),
        question('ix_context', {
          'type': 'dict',
          'attrs': [
            question('marker', {'type': 'int'}),
          ],
        }),
        question('resources', {
          'type': 'dict',
          'attrs': [
            question('limits', {
              'type': 'dict',
              'attrs': [
                question('cpus', {'type': 'int', 'min': 1, 'max': 16}),
                question('memory', {'type': 'int', 'min': 128, 'max': 65536}),
              ],
            }),
          ],
        }),
      ],
      {
        'storage': {'read_only': false, 'ordinary_nested_name': 'kept'},
        'run_as_context': {'uid': 1000, 'gid': 1000},
        'privileged': false,
        'security_context': {'enabled': false},
        'ix_context': {'marker': 1},
        'resources': {
          'limits': {'cpus': 2, 'memory': 1024},
        },
      },
    );
    expect(schema.supported, isTrue);
    expect(
      schema.fields.where((field) => field.editable).map((field) => field.id),
      ['/resources/limits/cpus', '/resources/limits/memory'],
    );
    expect(
      schema.validatePatches([patch('/storage/read_only', true)]),
      isNotNull,
    );
    expect(schema.validatePatches([patch('/privileged', true)]), isNotNull);
  });

  test('missing malformed oversized schema is safely blocked', () {
    for (final details in <Map<String, Object?>>[
      {},
      {'schema': {}},
      {
        'schema': {'questions': 'invalid'},
      },
      {
        'schema': {
          'questions': List.generate(
            257,
            (i) => question('field$i', {'type': 'int'}),
          ),
        },
      },
    ]) {
      final schema = AppConfigSchema.fromVersionDetails(
        details,
        currentValues: {},
      );
      expect(schema.supported, isFalse);
      expect(schema.blockedReason, isNotNull);
      expect(schema.fields, isEmpty);
    }
  });
}
