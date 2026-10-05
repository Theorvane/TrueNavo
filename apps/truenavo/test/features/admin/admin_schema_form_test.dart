import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/admin/admin_schema_form.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  testWidgets('empty argument list builds an empty list', (tester) async {
    final form = await _pump(tester, []);
    expect(form.currentState!.validateAndBuild(), isEmpty);
  });

  testWidgets('omission, false, zero and empty array remain distinct', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('enabled', {'type': 'boolean'}),
      _parameter('count', {'type': 'integer', 'default': 0}),
      _parameter('items', {
        'type': 'array',
        'items': {'type': 'string'},
      }),
      _parameter('optional', {
        'type': 'string',
        'default': 'server default',
      }, required: false),
    ]);
    expect(form.currentState!.validateAndBuild(), [false, 0, []]);
    await _tap(tester, 'admin-include-optional');
    expect(form.currentState!.validateAndBuild(), [
      false,
      0,
      [],
      'server default',
    ]);
    await tester.enterText(_key('admin-value-optional'), '');
    expect(form.currentState!.validateAndBuild(), [false, 0, [], '']);
  });

  testWidgets(
    'interior omitted supported default preserves argument positions',
    (tester) async {
      final form = await _pump(tester, [
        _parameter('first', {'type': 'integer', 'default': 7}, required: false),
        _parameter('second', {'type': 'string'}, required: false),
      ]);
      await _tap(tester, 'admin-include-second');
      await tester.enterText(_key('admin-value-second'), 'value');
      expect(form.currentState!.validateAndBuild(), [7, 'value']);
    },
  );

  testWidgets('interior omission without a valid default blocks submission', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('first', {'type': 'integer'}, required: false),
      _parameter('second', {'type': 'string'}, required: false),
    ]);
    await _tap(tester, 'admin-include-second');
    expect(form.currentState!.validateAndBuild(), isNull);
    await tester.pump();
    expect(
      find.textContaining('before setting later arguments'),
      findsOneWidget,
    );
  });

  testWidgets('nullable is explicit, not empty text or an omitted argument', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('comment', {
        'type': 'string',
        'nullable': true,
      }, required: false),
    ]);
    expect(form.currentState!.validateAndBuild(), []);
    await _tap(tester, 'admin-include-comment');
    expect(form.currentState!.validateAndBuild(), ['']);
    await _tap(tester, 'admin-null-comment');
    expect(form.currentState!.validateAndBuild(), [null]);
  });

  testWidgets('integer input rejects decimals and non-finite numbers', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('count', {'type': 'integer', 'minimum': 1, 'maximum': 20}),
      _parameter('ratio', {'type': 'number'}),
    ]);
    await tester.enterText(_key('admin-value-count'), '1.5');
    await tester.enterText(_key('admin-value-ratio'), 'NaN');
    expect(form.currentState!.validateAndBuild(), isNull);
    await tester.enterText(_key('admin-value-count'), '0');
    await tester.enterText(_key('admin-value-ratio'), 'Infinity');
    expect(form.currentState!.validateAndBuild(), isNull);
    await tester.enterText(_key('admin-value-count'), '12');
    await tester.enterText(_key('admin-value-ratio'), '-0.5');
    expect(form.currentState!.validateAndBuild(), [12, -0.5]);
  });

  testWidgets('enum starts unselected and offers only server values', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('mode', {
        'type': 'string',
        'enum': ['START', 'STOP'],
      }),
    ]);
    expect(form.currentState!.validateAndBuild(), isNull);
    await _tap(tester, 'admin-value-mode');
    expect(find.text('RESTRAT'), findsNothing);
    await tester.tap(find.text('STOP').last);
    await tester.pumpAndSettle();
    expect(form.currentState!.validateAndBuild(), ['STOP']);
  });

  testWidgets('nested object fields and array items build typed values', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('data', {
        'type': 'object',
        'required': ['name', 'ports'],
        'properties': {
          'name': {'type': 'string', 'minLength': 2},
          'comment': {'type': 'string'},
          'ports': {
            'type': 'array',
            'items': {'type': 'integer', 'minimum': 1},
          },
        },
      }),
    ]);
    await tester.enterText(_key('admin-value-data.name'), 'Media');
    await _tap(tester, 'admin-add-data.ports');
    await tester.enterText(_key('admin-value-data.ports[0]'), '445');
    expect(form.currentState!.validateAndBuild(), [
      {
        'name': 'Media',
        'ports': [445],
      },
    ]);
    await _tap(tester, 'admin-remove-data.ports[0]');
    expect(form.currentState!.validateAndBuild(), [
      {'name': 'Media', 'ports': []},
    ]);
  });

  testWidgets('array uniqueness and minItems use server validation', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('ports', {
        'type': 'array',
        'items': {'type': 'integer'},
        'minItems': 1,
        'uniqueItems': true,
      }),
    ]);
    expect(form.currentState!.validateAndBuild(), isNull);
    await _tap(tester, 'admin-add-ports');
    await tester.enterText(_key('admin-value-ports[0]'), '443');
    await _tap(tester, 'admin-add-ports');
    await tester.enterText(_key('admin-value-ports[1]'), '443');
    expect(form.currentState!.validateAndBuild(), isNull);
    await tester.enterText(_key('admin-value-ports[1]'), '445');
    expect(form.currentState!.validateAndBuild(), [
      [443, 445],
    ]);
  });

  testWidgets('secret defaults are not shown or sent and can be erased', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('password', {
        'type': 'string',
        'default': 'never-prefill-this-secret',
        'secret': true,
        'minLength': 1,
      }, required: false),
    ]);
    expect(form.currentState!.validateAndBuild(), []);
    expect(find.textContaining('never-prefill-this-secret'), findsNothing);
    await _tap(tester, 'admin-include-password');
    final field = tester.widget<TextField>(_key('admin-value-password'));
    expect(field.obscureText, isTrue);
    expect(field.enableSuggestions, isFalse);
    expect(field.autofillHints, isEmpty);
    expect(field.controller!.text, isEmpty);
    await tester.enterText(_key('admin-value-password'), 'new-password');
    expect(form.currentState!.hasSensitiveValues, isTrue);
    expect(form.currentState!.validateAndBuild(), ['new-password']);
    form.currentState!.clearSensitiveValues();
    await tester.pump();
    expect(form.currentState!.hasSensitiveValues, isFalse);
    expect(form.currentState!.validateAndBuild(), []);
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('name-based secrets never become implicit positional defaults', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('api_key', {
        'type': 'string',
        'default': 'sensitive',
      }, required: false),
      _parameter('enabled', {'type': 'boolean'}, required: false),
    ]);
    await _tap(tester, 'admin-include-enabled');
    expect(form.currentState!.validateAndBuild(), isNull);
    expect(find.textContaining('sensitive'), findsNothing);
  });

  testWidgets(
    'unsupported required schema fails closed without a JSON editor',
    (tester) async {
      final form = await _pump(tester, [
        _parameter('unknown', {r'$ref': '#/not/available'}),
      ]);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('cannot be submitted safely'), findsOneWidget);
      expect(form.currentState!.validateAndBuild(), isNull);
    },
  );

  testWidgets('unsupported optional schema is omitted and cannot be enabled', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('filters', {'type': 'array', 'default': []}, required: false),
    ]);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(form.currentState!.validateAndBuild(), []);
  });

  testWidgets('unsupported optional defaults cannot fill positional gaps', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('filters', {'type': 'array', 'default': []}, required: false),
      _parameter('options', {
        'type': 'object',
        'properties': {},
      }, required: false),
    ]);
    await _tap(tester, 'admin-include-options');
    expect(form.currentState!.validateAndBuild(), isNull);
  });

  testWidgets('union selection emits the selected native type only', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('value', {
        'oneOf': [
          {'type': 'integer', 'minimum': 1},
          {'type': 'string', 'minLength': 1},
        ],
      }),
    ]);
    await tester.enterText(_key('admin-value-value.variant0'), '5');
    expect(form.currentState!.validateAndBuild(), [5]);
    await _tap(tester, 'admin-variant-value');
    await tester.tap(find.text('string').last);
    await tester.pumpAndSettle();
    await tester.enterText(_key('admin-value-value.variant1'), 'five');
    expect(form.currentState!.validateAndBuild(), ['five']);
    expect(
      find.byKey(const ValueKey('admin-value-value.variant0')),
      findsNothing,
    );
  });

  testWidgets('const discriminator is read-only and submitted exactly', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('type', {'type': 'string', 'const': 'FILESYSTEM'}),
    ]);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('FILESYSTEM · fixed value'), findsOneWidget);
    expect(form.currentState!.validateAndBuild(), ['FILESYSTEM']);
  });

  testWidgets(
    'object content in array defaults is preserved without dropped keys',
    (tester) async {
      final form = await _pump(tester, [
        _parameter('rules', {
          'type': 'array',
          'default': [
            {'name': 'media', 'enabled': true},
          ],
          'items': {
            'type': 'object',
            'required': ['name'],
            'properties': {
              'name': {'type': 'string'},
              'enabled': {'type': 'boolean'},
              'comment': {'type': 'string', 'default': 'not explicitly set'},
            },
          },
        }),
      ]);
      expect(form.currentState!.validateAndBuild(), [
        [
          {'name': 'media', 'enabled': true},
        ],
      ]);
      expect(
        tester
            .widget<CheckboxListTile>(_key('admin-include-rules[0].enabled'))
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<CheckboxListTile>(_key('admin-include-rules[0].comment'))
            .value,
        isFalse,
      );
    },
  );

  testWidgets(
    'union default chooses its matching native type without coercion',
    (tester) async {
      final form = await _pump(tester, [
        _parameter('limit', {
          'default': 'automatic',
          'oneOf': [
            {'type': 'integer'},
            {'type': 'string'},
          ],
        }),
      ]);
      expect(form.currentState!.validateAndBuild(), ['automatic']);
      expect(_key('admin-value-limit.variant1'), findsOneWidget);
    },
  );

  testWidgets(
    'oversized array default is blocked instead of silently truncated',
    (tester) async {
      final form = await _pump(tester, [
        _parameter('rules', {
          'type': 'array',
          'items': {'type': 'integer'},
          'default': List.generate(101, (index) => index),
        }),
      ]);
      expect(form.currentState!.validateAndBuild(), isNull);
    },
  );

  testWidgets('disabled form cannot validate arguments for dispatch', (
    tester,
  ) async {
    final form = await _pump(tester, [
      _parameter('name', {'type': 'string'}),
    ], enabled: false);
    expect(tester.widget<TextField>(_key('admin-value-name')).enabled, isFalse);
    expect(form.currentState!.validateAndBuild(), isNull);
  });

  testWidgets('reset clears values before changing operation', (tester) async {
    final form = await _pump(tester, [
      _parameter('name', {'type': 'string'}),
    ]);
    await tester.enterText(_key('admin-value-name'), 'previous');
    form.currentState!.reset();
    await tester.pump();
    expect(form.currentState!.validateAndBuild(), ['']);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('narrow form handles 2x text in ${dark ? 'dark' : 'light'}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(
        tester,
        [
          _parameter('configuration', {
            'type': 'object',
            'required': ['long_name', 'nullable_value'],
            'properties': {
              'long_name': {
                'type': 'string',
                'description': 'A readable description for this setting.',
              },
              'nullable_value': {'type': 'boolean', 'nullable': true},
              'optional_setting': {'type': 'integer'},
            },
          }),
        ],
        dark: dark,
        scale: 2,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

AdminParameter _parameter(
  String name,
  Map<String, Object?> schema, {
  bool required = true,
}) => AdminParameter(
  name: name,
  schema: AdminSchema.fromJson(schema),
  required: required,
);

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

Future<GlobalKey<AdminSchemaFormState>> _pump(
  WidgetTester tester,
  List<AdminParameter> parameters, {
  bool enabled = true,
  bool dark = false,
  double scale = 1,
}) async {
  final key = GlobalKey<AdminSchemaFormState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? TrueNavoTheme.dark() : TrueNavoTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AdminSchemaForm(
              key: key,
              parameters: parameters,
              enabled: enabled,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}
