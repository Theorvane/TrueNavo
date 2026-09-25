import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test('single-line inputs reject invisible controls and bidi spoofing', () {
    final schema = AdminSchema.fromJson({'type': 'string'});
    for (final value in [
      'nas\nadmin',
      'nas\tadmin',
      'nas\u202Eadmin',
      'nas\u200Badmin',
    ]) {
      expect(schema.validate(value), isNotNull);
    }
    expect(schema.validate('data/공유 폴더'), isNull);
  });
  test('union siblings are not ignored and secret nested parent defaults are removed', () {
    expect(
      AdminSchema.fromJson({
        'anyOf': [
          {'type': 'string'},
          {'type': 'null'},
        ],
        'minLength': 5,
      }).supported,
      isFalse,
    );
    final schema = AdminSchema.fromJson({
      'type': 'object',
      'default': {'password': 'hidden-parent-default'},
      'examples': [
        {'password': 'hidden-example'},
      ],
      'properties': {
        'password': {'type': 'string', 'secret': true},
      },
    });
    expect(schema.hasDefault, isFalse);
    expect(schema.raw.toString(), isNot(contains('hidden-')));
    final secretEnum = AdminSchema.fromJson({
      'type': 'string',
      'secret': true,
      'enum': ['hidden-enum'],
    });
    expect(secretEnum.supported, isFalse);
    expect(secretEnum.raw.toString(), isNot(contains('hidden-enum')));
  });
  test(
    'schemas freeze nested data and reject untyped and unknown assertions',
    () {
      final raw = <String, Object?>{
        'type': 'string',
        'enum': ['A', 'B'],
      };
      final schema = AdminSchema.fromJson(raw);
      (raw['enum'] as List).add('C');
      expect(schema.enumValues, ['A', 'B']);
      expect(() => schema.raw['type'] = 'object', throwsUnsupportedError);
      expect(AdminSchema.fromJson({}).supported, isFalse);
      expect(
        AdminSchema.fromJson({'type': 'string', 'not': {}}).supported,
        isFalse,
      );
    },
  );

  test(
    'actual middleware array items wrapper uses repeated element validation',
    () {
      final schema = AdminSchema.fromJson({
        'type': 'array',
        'items': [
          {'type': 'integer', 'minimum': 1},
        ],
        'minItems': 1,
        'maxItems': 3,
        'uniqueItems': true,
      });
      expect(schema.supported, isTrue);
      expect(schema.validate([1, 2]), isNull);
      for (final value in [
        [],
        [0],
        ['1'],
        [1, 1],
        [1, 2, 3, 4],
      ]) {
        expect(schema.validate(value), isNotNull);
      }
    },
  );

  test('required objects reject unknown keys and permit omitted unsupported optional fields', () {
    final schema = AdminSchema.fromJson({
      'type': 'object',
      'required': ['name'],
      'properties': {
        'name': {'type': 'string'},
        'advanced': {},
      },
    });
    expect(schema.supported, isTrue);
    expect(schema.validate({'name': 'tank'}), isNull);
    for (final value in [
      {},
      {'name': 'tank', 'extra': true},
      {'name': 'tank', 'advanced': {}},
    ]) {
      expect(schema.validate(value), isNotNull);
    }
    expect(
      AdminSchema.fromJson({
        'type': 'object',
        'required': ['advanced'],
        'properties': {'advanced': {}},
      }).supported,
      isFalse,
    );
  });

  test('nullable type array preserves constraints on non-null branches', () {
    final schema = AdminSchema.fromJson({
      'type': ['string', 'null'],
      'minLength': 3,
      'pattern': '^nas',
    });
    expect(schema.nullable, isTrue);
    expect(schema.validate(null), isNull);
    expect(schema.validate('nas1'), isNull);
    expect(schema.validate('na'), isNotNull);
    expect(schema.validate('abc'), isNotNull);
  });

  test('anyOf and oneOf preserve enum const and numeric boundaries', () {
    final schema = AdminSchema.fromJson({
      'anyOf': [
        {'type': 'integer', 'minimum': 3, 'maximum': 9, 'multipleOf': 3},
        {
          'type': 'string',
          'enum': ['AUTO'],
        },
        {'type': 'null'},
      ],
    });
    for (final v in [3, 6, 9, 'AUTO', null]) {
      expect(schema.validate(v), isNull);
    }
    for (final v in [0, 4, 12, 3.0, 'auto']) {
      expect(schema.validate(v), isNotNull);
    }
    expect(
      AdminSchema.fromJson({
        'oneOf': [
          {'type': 'number'},
          {'type': 'integer'},
        ],
      }).validate(1),
      isNotNull,
    );
    expect(
      AdminSchema.fromJson({'type': 'string', 'const': 'fixed'})
          .validate('other'),
      isNotNull,
    );
  });

  test(
    'local references resolve and recursive or remote references fail closed',
    () {
      final schema = AdminSchema.fromJson({
        r'$defs': {
          'Name': {'type': 'string', 'minLength': 2},
        },
        r'$ref': r'#/$defs/Name',
      });
      expect(schema.validate('ab'), isNull);
      expect(schema.validate('a'), isNotNull);
      expect(
        AdminSchema.fromJson({r'$ref': 'https://remote/schema'}).supported,
        isFalse,
      );
      expect(
        AdminSchema.fromJson({
          r'$defs': {
            'loop': {r'$ref': r'#/$defs/loop'},
          },
          r'$ref': r'#/$defs/loop',
        }).supported,
        isFalse,
      );
    },
  );

  for (final property in ['secret', 'private', 'writeOnly']) {
    test('schema $property removes defaults and examples', () {
      final schema = AdminSchema.fromJson({
        'type': 'string',
        property: true,
        'default': 'do-not-display',
        'examples': ['hidden'],
      });
      expect(schema.secret, isTrue);
      expect(schema.hasDefault, isFalse);
      expect(schema.raw.toString(), isNot(contains('do-not-display')));
      expect(schema.raw.toString(), isNot(contains('hidden')));
    });
  }

  test('secret property-name heuristics remove defaults too', () {
    final schema = AdminSchema.fromJson({
      'type': 'object',
      'properties': {
        'api_key': {'type': 'string', 'default': 'hidden'},
      },
    });
    expect(schema.properties['api_key']!.secret, isTrue);
    expect(schema.raw.toString(), isNot(contains('hidden')));
  });

  test(
    'bounded schema and input do not accept non-finite or oversized values',
    () {
      expect(
        AdminSchema.fromJson({'type': 'number'}).validate(double.infinity),
        isNotNull,
      );
      expect(
        AdminSchema.fromJson({'type': 'string'}).validate('x' * 8193),
        isNotNull,
      );
      expect(
        AdminSchema.fromJson({'type': 'string', 'pattern': '['}).supported,
        isFalse,
      );
      expect(
        AdminSchema.fromJson({
          'type': 'array',
          'items': [
            {'type': 'string'},
            {'type': 'integer'},
          ],
        }).supported,
        isFalse,
      );
    },
  );
}
