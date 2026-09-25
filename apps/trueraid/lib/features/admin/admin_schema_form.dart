import 'package:flutter/material.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

/// Native, schema-validated arguments for reviewed TrueNAS operations.
///
/// Nothing in this widget sends a request. Optional values are absent until the
/// user explicitly includes them; absent, null, empty, zero and false differ.
class AdminSchemaForm extends StatefulWidget {
  const AdminSchemaForm({
    required this.parameters,
    this.enabled = true,
    super.key,
  });

  final List<AdminParameter> parameters;
  final bool enabled;

  @override
  State<AdminSchemaForm> createState() => AdminSchemaFormState();
}

class AdminSchemaFormState extends State<AdminSchemaForm> {
  late List<_FieldValue> _fields = _makeFields();
  String? _error;
  int _revision = 0;

  List<_FieldValue> _makeFields() => [
    for (final parameter in widget.parameters)
      _FieldValue(
        schema: parameter.schema,
        name: parameter.name,
        path: parameter.name,
        required: parameter.required,
      ),
  ];

  /// Returns validated positional arguments, or null without sending anything.
  List<Object?>? validateAndBuild() {
    if (!widget.enabled) return null;
    final values = <Object?>[];
    var valid = true;
    _error = null;
    for (final field in _fields) {
      final result = field.read(validate: true);
      if (identical(result, _invalid)) valid = false;
      values.add(result);
    }
    while (values.isNotEmpty && identical(values.last, _omitted)) {
      values.removeLast();
    }
    for (var index = 0; index < values.length; index++) {
      if (!identical(values[index], _omitted)) continue;
      final field = _fields[index];
      if (field.schema.supported &&
          field.schema.hasDefault &&
          !field.containsSecret &&
          field.schema.validate(field.schema.defaultValue) == null) {
        values[index] = field.schema.defaultValue;
      } else {
        field.error = 'Include this argument before setting later arguments.';
        valid = false;
      }
    }
    if (!valid) _error = 'Check the highlighted fields. No request was sent.';
    setState(() {});
    return valid ? values : null;
  }

  bool get hasSensitiveValues => _fields.any((field) => field.hasSecretValue);

  /// Erases secret text immediately after a submitted or cancelled operation.
  void clearSensitiveValues() {
    for (final field in _fields) {
      field.clearSecrets();
    }
    _revision++;
    if (mounted) setState(() {});
  }

  void reset() {
    for (final field in _fields) {
      field.dispose();
    }
    _fields = _makeFields();
    _error = null;
    _revision++;
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant AdminSchemaForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.parameters, widget.parameters)) reset();
  }

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey('admin-schema-revision-$_revision'),
    child: Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_fields.isEmpty)
            const Text('This operation does not require any arguments.'),
          for (final field in _fields) ...[
            _field(context, field),
            const SizedBox(height: TdSpacing.component),
          ],
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: context.tdTheme.statusCritical),
              ),
            ),
        ],
      ),
    ),
  );

  void _change(VoidCallback callback) => setState(() {
    callback();
    _error = null;
  });

  Widget _field(BuildContext context, _FieldValue field) {
    final schema = field.schema;
    final td = context.tdTheme;
    final label = _safeText(schema.title ?? field.name, 120);
    final description = _safeText(schema.description ?? '', 600);
    if (!schema.supported) {
      return Container(
        key: ValueKey('admin-unsupported-${field.path}'),
        padding: const EdgeInsets.all(TdSpacing.related),
        decoration: BoxDecoration(
          color: td.surfaceRaised,
          borderRadius: BorderRadius.circular(TdRadius.control),
          border: Border.all(color: td.borderSubtle),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TdTypography.titleSmall),
            const SizedBox(height: TdSpacing.inline),
            Text(
              field.required
                  ? 'This required field uses an unsupported schema. '
                        'This operation cannot be submitted safely.'
                  : 'This optional field uses an unsupported schema and is '
                        'not sent. Server defaults remain in effect.',
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!field.required)
          CheckboxListTile(
            key: ValueKey('admin-include-${field.path}'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('Include $label'),
            subtitle: const Text('Optional · omitted unless enabled'),
            value: field.included,
            onChanged: widget.enabled
                ? (value) => _change(() {
                    field.included = value ?? false;
                    field.error = null;
                    if (!field.included) field.clearSecrets();
                  })
                : null,
          ),
        if (field.included) ...[
          if (description.isNotEmpty) ...[
            Text(description, style: TextStyle(color: td.textSecondary)),
            const SizedBox(height: TdSpacing.related),
          ],
          if (schema.nullable && schema.type != 'null')
            SwitchListTile(
              key: ValueKey('admin-null-${field.path}'),
              contentPadding: EdgeInsets.zero,
              title: Text('Set $label to null'),
              subtitle: const Text(
                'An explicit null is different from omission.',
              ),
              value: field.isNull,
              onChanged: widget.enabled
                  ? (value) => _change(() {
                      field.isNull = value;
                      field.error = null;
                    })
                  : null,
            ),
          if (!field.isNull) _editor(context, field, label),
          if (field.error != null && !field.hasInlineError)
            Text(field.error!, style: TextStyle(color: td.statusCritical)),
        ],
        if (!field.included && field.error != null)
          Text(field.error!, style: TextStyle(color: td.statusCritical)),
      ],
    );
  }

  Widget _editor(BuildContext context, _FieldValue field, String label) {
    final schema = field.schema;
    if (schema.raw.containsKey('const') && !field.secret) {
      return InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text(
          '${_safeText('${schema.raw['const']}', 160)} · fixed value',
        ),
      );
    }
    if (schema.variants.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<int>(
            key: ValueKey('admin-variant-${field.path}'),
            initialValue: field.variantIndex,
            isExpanded: true,
            decoration: InputDecoration(labelText: '$label format'),
            items: [
              for (var index = 0; index < schema.variants.length; index++)
                DropdownMenuItem(
                  value: index,
                  child: Text(
                    _safeText(
                      schema.variants[index].title ??
                          schema.variants[index].type ??
                          'Option ${index + 1}',
                      120,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: widget.enabled
                ? (index) => _change(() {
                    if (index == null) return;
                    field.selectVariant(index);
                    field.error = null;
                  })
                : null,
          ),
          const SizedBox(height: TdSpacing.related),
          _field(context, field.variant!),
        ],
      );
    }
    final enumValues = schema.enumValues;
    if (enumValues != null && enumValues.isNotEmpty) {
      return DropdownButtonFormField<int>(
        key: ValueKey('admin-value-${field.path}'),
        initialValue: field.enumIndex,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, errorText: field.error),
        items: [
          for (var index = 0; index < enumValues.length; index++)
            DropdownMenuItem(
              value: index,
              child: Text(
                field.secret
                    ? 'Protected option ${index + 1}'
                    : _safeText('${enumValues[index]}', 120),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: widget.enabled
            ? (index) => _change(() {
                field.enumIndex = index;
                field.error = null;
              })
            : null,
      );
    }
    switch (schema.type) {
      case 'object':
        return _group(context, label, [
          if (field.properties.isEmpty)
            const Text('No editable properties. Sends an empty object.'),
          for (final child in field.properties.values) ...[
            _field(context, child),
            const SizedBox(height: TdSpacing.related),
          ],
        ]);
      case 'array':
        final maxItems = schema.raw['maxItems'];
        final limit = maxItems is int && maxItems < 100 ? maxItems : 100;
        return _group(context, '$label · ${field.items.length} items', [
          for (var index = 0; index < field.items.length; index++) ...[
            Row(
              children: [
                Expanded(child: Text('Item ${index + 1}')),
                IconButton(
                  key: ValueKey('admin-remove-${field.items[index].path}'),
                  tooltip: 'Remove item ${index + 1}',
                  onPressed: widget.enabled
                      ? () => _change(() {
                          field.items.removeAt(index).dispose();
                          field.error = null;
                        })
                      : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
            _field(context, field.items[index]),
            const SizedBox(height: TdSpacing.related),
          ],
          if (field.items.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: TdSpacing.related),
              child: Text('Empty array. Add items if needed.'),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: ValueKey('admin-add-${field.path}'),
              onPressed: widget.enabled && field.items.length < limit
                  ? () => _change(() {
                      field.addItem();
                      field.error = null;
                    })
                  : null,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add item'),
            ),
          ),
        ]);
      case 'boolean':
        return SwitchListTile(
          key: ValueKey('admin-value-${field.path}'),
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          subtitle: Text(field.boolean ? 'True' : 'False'),
          value: field.boolean,
          onChanged: widget.enabled
              ? (value) => _change(() {
                  field.boolean = value;
                  field.error = null;
                })
              : null,
        );
      case 'null':
        return Text('$label: null');
      default:
        final numeric = schema.type == 'integer' || schema.type == 'number';
        return TextField(
          key: ValueKey('admin-value-${field.path}'),
          controller: field.text,
          enabled: widget.enabled,
          obscureText: field.secret,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [],
          keyboardType: numeric
              ? TextInputType.numberWithOptions(
                  signed: true,
                  decimal: schema.type == 'number',
                )
              : field.secret
              ? TextInputType.visiblePassword
              : TextInputType.text,
          decoration: InputDecoration(
            labelText: label,
            helperText: field.secret
                ? 'Protected value · never included in the confirmation summary'
                : numeric
                ? schema.type == 'integer'
                      ? 'Whole number'
                      : 'Number'
                : null,
            helperMaxLines: 3,
            errorText: field.error,
            errorMaxLines: 4,
          ),
          onChanged: (_) => _change(() => field.error = null),
        );
    }
  }

  Widget _group(BuildContext context, String title, List<Widget> children) =>
      Material(
        color: context.tdTheme.surfaceRaised,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: context.tdTheme.borderSubtle),
          borderRadius: BorderRadius.circular(TdRadius.card),
        ),
        child: Padding(
          padding: const EdgeInsets.all(TdSpacing.related),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: TdTypography.titleSmall),
              const SizedBox(height: TdSpacing.related),
              ...children,
            ],
          ),
        ),
      );
}

enum _Sentinel { omitted, invalid }

const _omitted = _Sentinel.omitted;
const _invalid = _Sentinel.invalid;

class _FieldValue {
  _FieldValue({
    required this.schema,
    required this.name,
    required this.path,
    required this.required,
    Object? initial = _omitted,
    bool protectedParent = false,
  }) : secret = protectedParent || schema.secret || _isSecretName(name),
       included = required,
       text = TextEditingController() {
    final seed = !identical(initial, _omitted)
        ? initial
        : schema.hasDefault
        ? schema.defaultValue
        : _omitted;
    if (!secret &&
        (seed is Map || seed is List) &&
        schema.validate(seed) != null) {
      // Do not silently truncate or drop unsupported content in a default.
      initializationError = true;
    }
    if (!secret && !identical(seed, _omitted)) {
      isNull = seed == null && schema.nullable;
      if (seed is String || seed is num) text.text = '$seed';
      if (seed is bool) boolean = seed;
      if (schema.enumValues != null) {
        final match = schema.enumValues!.indexOf(seed);
        if (match >= 0) enumIndex = match;
      }
    }
    for (final entry in schema.properties.entries) {
      final childInitial = !secret && seed is Map && seed.containsKey(entry.key)
          ? seed[entry.key]
          : _omitted;
      final child = _FieldValue(
        schema: entry.value,
        name: entry.key,
        path: '$path.${entry.key}',
        required: schema.requiredProperties.contains(entry.key),
        initial: childInitial,
        protectedParent: secret,
      );
      // Preserve explicit object/array default content exactly and visibly.
      // Independently defaulted optional properties remain omitted.
      if (!identical(childInitial, _omitted) &&
          !child.secret &&
          child.schema.supported) {
        child.included = true;
      }
      properties[entry.key] = child;
    }
    if (schema.variants.isNotEmpty) {
      final matchingDefault = !secret && !identical(seed, _omitted)
          ? schema.variants.indexWhere((item) => item.validate(seed) == null)
          : -1;
      selectVariant(
        matchingDefault < 0 ? 0 : matchingDefault,
        matchingDefault < 0 ? _omitted : seed,
      );
    }
    if (!secret && seed is List && schema.items != null) {
      if (seed.length > 100) initializationError = true;
      for (final item in seed.length > 100 ? const [] : seed) {
        addItem(item);
      }
    }
  }

  final AdminSchema schema;
  final String name;
  final String path;
  final bool required;
  final bool secret;
  bool included;
  bool isNull = false;
  bool boolean = false;
  int? enumIndex;
  int variantIndex = 0;
  int _itemSerial = 0;
  String? error;
  bool initializationError = false;
  final TextEditingController text;
  final Map<String, _FieldValue> properties = {};
  final List<_FieldValue> items = [];
  _FieldValue? variant;

  bool get hasInlineError =>
      !schema.raw.containsKey('const') &&
      schema.variants.isEmpty &&
      (schema.enumValues != null ||
          {'string', 'integer', 'number'}.contains(schema.type));

  bool get containsSecret =>
      secret ||
      properties.values.any((field) => field.containsSecret) ||
      items.any((field) => field.containsSecret) ||
      (variant?.containsSecret ?? false);

  bool get hasSecretValue =>
      included &&
      !isNull &&
      ((secret && text.text.isNotEmpty) ||
          properties.values.any((field) => field.hasSecretValue) ||
          items.any((field) => field.hasSecretValue) ||
          (variant?.hasSecretValue ?? false));

  void addItem([Object? initial = _omitted]) {
    final itemSchema = schema.items;
    if (itemSchema == null) return;
    items.add(
      _FieldValue(
        schema: itemSchema,
        name: 'Value',
        path: '$path[${_itemSerial++}]',
        required: true,
        initial: initial,
        protectedParent: secret,
      ),
    );
  }

  void selectVariant(int index, [Object? initial = _omitted]) {
    variant?.dispose();
    variantIndex = index;
    variant = _FieldValue(
      schema: schema.variants[index],
      name: name,
      path: '$path.variant$index',
      required: true,
      initial: initial,
      protectedParent: secret,
    );
  }

  Object? read({required bool validate}) {
    error = null;
    if (!included) return _omitted;
    if (!schema.supported || initializationError) {
      error = 'This field cannot be edited safely.';
      return _invalid;
    }
    Object? value;
    if (schema.raw.containsKey('const') && !secret) {
      value = schema.raw['const'];
    } else if (isNull || schema.type == 'null') {
      value = null;
    } else if (variant != null) {
      value = variant!.read(validate: validate);
    } else if (schema.enumValues != null) {
      value = enumIndex == null ? _invalid : schema.enumValues![enumIndex!];
    } else {
      switch (schema.type) {
        case 'object':
          final object = <String, Object?>{};
          var valid = true;
          for (final entry in properties.entries) {
            final item = entry.value.read(validate: validate);
            if (identical(item, _invalid)) valid = false;
            if (!identical(item, _omitted)) object[entry.key] = item;
          }
          value = valid ? object : _invalid;
        case 'array':
          final values = [
            for (final item in items) item.read(validate: validate),
          ];
          value = values.any((item) => identical(item, _invalid))
              ? _invalid
              : values;
        case 'boolean':
          value = boolean;
        case 'integer':
          value = int.tryParse(text.text.trim()) ?? _invalid;
        case 'number':
          final parsed = num.tryParse(text.text.trim());
          value = parsed != null && parsed.isFinite ? parsed : _invalid;
        case 'string':
          value = text.text;
        default:
          value = _invalid;
      }
    }
    if (identical(value, _invalid)) {
      error = schema.enumValues != null
          ? 'Choose an available option.'
          : schema.type == 'integer'
          ? 'Enter a whole number.'
          : schema.type == 'number'
          ? 'Enter a finite number.'
          : 'Check the values in this field.';
      return _invalid;
    }
    if (validate) {
      // Validation messages are schema-independent so server text or entered
      // passwords cannot leak through errors.
      if (schema.validate(value) != null) {
        error = 'This value does not meet the server field requirements.';
        return _invalid;
      }
    }
    return value;
  }

  void clearSecrets() {
    if (secret) {
      text.clear();
      enumIndex = null;
      boolean = false;
      if (!required) included = false;
    }
    for (final field in properties.values) {
      field.clearSecrets();
    }
    for (final field in items) {
      field.clearSecrets();
    }
    variant?.clearSecrets();
  }

  void dispose() {
    text.clear();
    text.dispose();
    for (final field in properties.values) {
      field.dispose();
    }
    for (final field in items) {
      field.dispose();
    }
    variant?.dispose();
  }
}

bool _isSecretName(String value) => RegExp(
  r'password|passwd|passphrase|secret|token|private[_-]?key|api[_-]?key',
  caseSensitive: false,
).hasMatch(value);

String _safeText(String value, int limit) {
  final clean = value.replaceAll(
    RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'),
    ' ',
  );
  return clean.length <= limit ? clean : '${clean.substring(0, limit)}…';
}
