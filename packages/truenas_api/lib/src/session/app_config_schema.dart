part of 'true_nas_session_repository.dart';

/// A bounded editor for existing scalar leaves, not an installation form.
/// No configuration or schema defaults are retained by this public model.
/// Middleware shallow-merges update.values, so [applyPatches] returns complete
/// copies of changed top-level roots, preserving every untouched descendant.
final class AppConfigSchema {
  factory AppConfigSchema.fromVersionDetails(
    Map<String, Object?> details, {
    required Map<String, Object?> currentValues,
  }) {
    try {
      final raw = details['schema'];
      final questions = _appQuestions(raw is Map ? raw['questions'] : null, 0, [
        0,
      ]);
      final selectors = <String>{};
      String? globalReason =
          _appConfigLegacyConditions(raw is Map ? raw['questions'] : null)
          ? _appConfigConditionalBlock
          : null;
      var visits = 0;

      void inspect(
        List<_AppQuestion> nodes,
        Map values,
        List<String> parent, {
        bool privateDefaults = false,
      }) {
        for (final q in nodes) {
          if (++visits > 20000 || !_appConfigSafeText(q.name, 128)) {
            throw const FormatException('Unsupported configuration schema.');
          }
          final path = [...parent, q.name];
          if (q.condition != null) {
            if (!_appConditionSupported(q.condition)) {
              globalReason ??= _appConfigConditionalBlock;
            } else {
              void collect(List rules) {
                for (final rule in rules.cast<List>()) {
                  if (rule.length == 2) {
                    collect(rule[1] as List);
                  } else {
                    selectors.add(
                      _appConfigId([
                        ...parent,
                        ...(rule[0] as String).split('.'),
                      ]),
                    );
                  }
                }
              }

              collect(q.condition as List);
            }
          }
          if (q.refs.any((ref) => !_appKnownRefs.contains(ref))) {
            globalReason ??= _appConfigNormalizationBlock;
          }
          final value = values.containsKey(q.name)
              ? values[q.name]
              : q.hasDefault
              ? q.defaultValue
              : _appAbsent;
          final available = !identical(value, _appAbsent);
          // Normalization visits provided values even if show_if is false.
          // Also inspect defaults because update revalidates the entire config.
          if ((available || q.secret || privateDefaults || q.type == 'dict') &&
              q.refs.any(
                {
                  'definitions/gpu_configuration',
                  'normalize/ix_volume',
                }.contains,
              )) {
            globalReason ??= _appConfigNormalizationBlock;
          }
          if (q.refs.contains('normalize/acl')) {
            final noAction =
                available &&
                !q.secret &&
                !privateDefaults &&
                (value == null ||
                    (value is Map &&
                        (value.isEmpty && q.children.isEmpty ||
                            value['entries'] is List &&
                                (value['entries'] as List).isEmpty ||
                            value['path'] == '')));
            if (!noAction) globalReason ??= _appConfigNormalizationBlock;
          }
          if (q.type == 'dict') {
            inspect(
              q.children,
              value is Map ? value : const {},
              path,
              privateDefaults: privateDefaults || q.secret,
            );
          } else if (q.item != null) {
            if (privateDefaults || q.secret || q.item!.secret) {
              // Private defaults are absent from the shared parser. Their
              // normalization therefore cannot be proved inert.
              inspect([q.item!], const {}, path, privateDefaults: true);
            }
            if (value is List) {
              if (value.length > 1024) {
                throw const FormatException('Configuration is too large.');
              }
              for (final item in value) {
                inspect([q.item!], {q.item!.name: item}, path);
              }
            } else {
              // Detect unknown normalizers and conditional assertions even in
              // empty lists. Their elements are never editable in this editor.
              inspect([q.item!], const {}, path);
            }
          }
        }
      }

      inspect(questions, currentValues, const []);
      final fields = <AppConfigField>[];
      void describe(
        List<_AppQuestion> nodes,
        Map values,
        List<String> parent, {
        bool privateParent = false,
        bool hiddenParent = false,
        bool immutableParent = false,
        bool unsupportedParent = false,
        bool activeParent = true,
      }) {
        for (final q in nodes) {
          final path = [...parent, q.name];
          final id = _appConfigId(path);
          final secret = privateParent || q.secret;
          final hidden = hiddenParent || q.hidden;
          final immutable = immutableParent || q.immutable;
          final unsupported =
              unsupportedParent ||
              q.unsupported ||
              _appConfigProtectedNames.contains(q.name.toLowerCase()) ||
              (q.type == 'dict' && q.refs.isNotEmpty);
          final active =
              activeParent &&
              (q.condition == null ||
                  _appConditionSupported(q.condition) &&
                      _appCondition(q.condition, values));
          final present = values.containsKey(q.name);
          final value = values[q.name];
          if (q.type == 'dict' && !secret && !hidden) {
            describe(
              q.children,
              value is Map ? value : const {},
              path,
              immutableParent: immutable,
              unsupportedParent: unsupported,
              activeParent: active,
            );
            continue;
          }
          if (fields.length >= 256) {
            throw const FormatException('Configuration has too many fields.');
          }
          final scalar = {'string', 'text', 'int', 'boolean'}.contains(q.type);
          final label = _appConfigSafeText(q.title, 600)
              ? q.title
              : 'Application setting';
          final schema = AdminSchema.fromJson({
            'type': switch (q.type) {
              'int' => 'integer',
              'boolean' => 'boolean',
              _ => 'string',
            },
            'title': label,
            if (secret || hidden) 'secret': true,
            if (q.nullable) 'nullable': true,
            if (scalar && !secret && !hidden) ..._appConfigConstraints(q),
          });
          final safeValue =
              scalar &&
              !secret &&
              !hidden &&
              present &&
              schema.validate(value) == null &&
              _appConfigNumberSafe(value);
          final selector = selectors.any(
            (other) =>
                other == id ||
                other.startsWith('$id/') ||
                id.startsWith('$other/'),
          );
          final reason =
              globalReason ??
              (secret || hidden
                  ? 'Protected values are preserved and cannot be displayed or changed.'
                  : immutable
                  ? 'This setting is immutable after installation.'
                  : selector
                  ? 'This setting controls conditional configuration and is read-only.'
                  : !active
                  ? 'This setting is inactive and will be preserved unchanged.'
                  : !present
                  ? 'Missing settings cannot be added by this editor.'
                  : !scalar ||
                        !_appConfigSafeRefs(q) ||
                        unsupported ||
                        !_appConfigConstraintsSupported(q)
                  ? 'This setting requires a dedicated editor and is preserved unchanged.'
                  : !safeValue
                  ? 'This value cannot be represented safely by a scalar control.'
                  : null);
          fields.add(
            AppConfigField._(
              id: id,
              path: List.unmodifiable(path),
              label: label,
              schema: schema,
              isPort:
                  q.type == 'int' &&
                  (q.refs.contains('definitions/port') ||
                      _appPublishedPort(q, nodes, values)),
              currentValue: safeValue ? value : null,
              valueVisible: safeValue,
              present: present,
              secret: secret || hidden,
              editable: reason == null,
              blockedReason: reason,
            ),
          );
        }
      }

      describe(questions, currentValues, const []);
      return AppConfigSchema._(
        fields,
        globalReason ??
            (fields.any((field) => field.editable)
                ? null
                : 'This application has no safely editable existing scalar settings.'),
      );
    } on Object {
      return AppConfigSchema._(
        const [],
        'This application has no supported bounded configuration schema.',
      );
    }
  }

  AppConfigSchema._(List<AppConfigField> fields, this.blockedReason)
    : fields = List.unmodifiable(fields),
      parameters = List.unmodifiable([
        for (final field in fields)
          if (field.editable)
            AdminParameter(
              name: field.id,
              schema: field.schema,
              required: false,
            ),
      ]);

  final List<AppConfigField> fields;
  final List<AdminParameter> parameters;
  final String? blockedReason;
  bool get supported => blockedReason == null;
  List<String> get warnings => const [
    'Only explicitly selected scalar settings are changed. Hidden, private, immutable, list, and unknown settings are preserved.',
    'Conditional selectors and storage, permission, and device settings require a dedicated editor.',
  ];

  String? validatePatches(List<AppConfigPatch> patches) {
    if (!supported) return blockedReason;
    if (patches.isEmpty || patches.length > 64) {
      return 'Select between one and 64 explicit setting changes.';
    }
    final ids = <String>{};
    final ports = <int>{};
    for (final patch in patches) {
      final field = fields
          .where((field) => field.id == patch.fieldId)
          .firstOrNull;
      if (field == null || !field.editable || !ids.add(patch.fieldId)) {
        return 'Only distinct, editable, server-issued setting paths can be changed.';
      }
      if (field.schema.validate(patch.value) != null ||
          !_appConfigNumberSafe(patch.value)) {
        return 'A selected value does not match its supported setting constraints.';
      }
      if (field.isPort &&
          (patch.value is! int || !ports.add(patch.value as int))) {
        return 'Select distinct valid published port numbers.';
      }
      if (_adminEqual(field.currentValue, patch.value)) {
        return 'Each selected setting must differ from its current value.';
      }
    }
    return null;
  }

  /// Only changed, schema-identified published ports require conflict checks.
  /// Unselected values and unrelated integers are deliberately not inspected.
  List<int> changedPorts(List<AppConfigPatch> patches) {
    final error = validatePatches(patches);
    if (error != null) throw FormatException(error);
    return List.unmodifiable([
      for (final patch in patches)
        if (fields.firstWhere((field) => field.id == patch.fieldId).isPort)
          patch.value as int,
    ]);
  }

  /// Returns changed roots only. Callers must freshly verify the complete
  /// configuration/schema identity before calling this and sending app.update.
  Map<String, Object?> applyPatches(
    Map<String, Object?> freshRawConfig,
    List<AppConfigPatch> patches,
  ) {
    final error = validatePatches(patches);
    if (error != null) throw FormatException(error);
    final roots = <String, Object?>{};
    final budget = [0];
    for (final patch in patches) {
      final field = fields.firstWhere((field) => field.id == patch.fieldId);
      Object? old = freshRawConfig;
      for (final component in field.path) {
        if (old is! Map || !old.containsKey(component)) {
          throw const FormatException(
            'The existing configuration has changed.',
          );
        }
        old = old[component];
      }
      if (!_adminEqual(old, field.currentValue)) {
        throw const FormatException('The existing configuration has changed.');
      }
      final root = field.path.first;
      if (field.path.length == 1) {
        roots[root] = patch.value;
        continue;
      }
      if (!roots.containsKey(root)) {
        roots[root] = _appConfigCopy(freshRawConfig[root], budget, 0);
      }
      Object? parent = roots[root];
      for (final component in field.path.skip(1).take(field.path.length - 2)) {
        if (parent is! Map) {
          throw const FormatException(
            'The existing configuration has changed.',
          );
        }
        parent = parent[component];
      }
      if (parent is! Map<String, Object?>) {
        throw const FormatException('The existing configuration has changed.');
      }
      parent[field.path.last] = patch.value;
    }
    return Map.unmodifiable(roots);
  }
}

final class AppConfigField {
  const AppConfigField._({
    required this.id,
    required this.path,
    required this.label,
    required this.schema,
    required this.isPort,
    required this.currentValue,
    required this.valueVisible,
    required this.present,
    required this.secret,
    required this.editable,
    required this.blockedReason,
  });
  final String id;
  final List<String> path;
  final String label;
  final AdminSchema schema;
  final bool isPort;
  final Object? currentValue;
  final bool valueVisible;
  final bool present;
  final bool secret;
  final bool editable;
  final String? blockedReason;
}

final class AppConfigPatch {
  const AppConfigPatch({required this.fieldId, required this.value});
  final String fieldId;
  final Object? value;
  @override
  String toString() => 'AppConfigPatch([redacted])';
}

const _appConfigNormalizationBlock =
    'Updating this application can normalize storage, permissions, or device settings. A dedicated review is required before any configuration change.';
const _appConfigConditionalBlock =
    'This application uses conditional settings that cannot be safely preserved by this editor.';

// These canonical catalog fields carry storage, identity, permission, or device
// authority even when their wire type is an ordinary scalar. This is an exact
// bounded set, not substring inspection of arbitrary user values.
const _appConfigProtectedNames = {
  'storage',
  'run_as',
  'run_as_context',
  'security_context',
  'security',
  'privileged',
  'capabilities',
  'cap_add',
  'cap_drop',
  'uid',
  'gid',
  'user',
  'group',
  'user_id',
  'group_id',
  'permissions',
  'permission',
  'acl',
  'acl_entries',
  'enable_acl',
  'read_only',
  'readonly',
  'host_path',
  'hostpath',
  'host_path_config',
  'ix_volume_config',
  'host_device',
  'container_device',
  'acl_enable',
  'mount_path',
  'mountpath',
  'dataset_name',
  'devices',
  'device',
  'gpu_configuration',
  'gpus',
  'gpu',
  'nvidia_gpu_selection',
  'use_all_gpus',
  'kfd_device_exists',
  'usb_devices',
  'host_network',
  'host_pid',
  'host_ipc',
  'host_user_namespace',
  'allow_privilege_escalation',
  'run_as_user',
  'run_as_group',
  'fs_group',
  'supplemental_groups',
  'sysctls',
  'sysctl',
  'umask',
  'puid',
  'pgid',
  'ix_context',
  'ix_volumes',
  'ix_certificates',
  'ix_certificate_authorities',
};

String _appConfigId(List<String> path) =>
    '/${path.map((part) => part.replaceAll('~', '~0').replaceAll('/', '~1')).join('/')}';

bool _appConfigNumberSafe(Object? value) =>
    value is! num ||
    value.isFinite && value >= -9007199254740991 && value <= 9007199254740991;

bool _appConfigSafeText(String value, int max) =>
    value.length <= max &&
    !RegExp(r'[\x00-\x1F\x7F\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]')
        .hasMatch(value);

bool _appConfigSafeRefs(_AppQuestion q) => q.refs.every(
  (ref) =>
      ref == 'definitions/port' &&
          q.type == 'int' &&
          q.constraints['minimum'] is num &&
          (q.constraints['minimum'] as num) >= 1 &&
          q.constraints['maximum'] is num &&
          (q.constraints['maximum'] as num) <= 65535 ||
      ref == 'definitions/timezone' &&
          q.type == 'string' &&
          q.constraints['enum'] is List,
);

bool _appConfigConstraintsSupported(_AppQuestion q) {
  final allowed = switch (q.type) {
    'string' || 'text' => {'minLength', 'maxLength', 'pattern', 'enum'},
    'int' => {'minimum', 'maximum', 'enum'},
    'boolean' => {'enum'},
    _ => <String>{},
  };
  return q.constraints.keys.every(allowed.contains) &&
      (q.constraints['enum'] is! List ||
          (q.constraints['enum'] as List).every(
            (value) =>
                value is String && _appConfigSafeText(value, 8192) ||
                value is int ||
                value is bool ||
                value == null,
          ));
}

Map<String, Object?> _appConfigConstraints(_AppQuestion q) =>
    _appConfigConstraintsSupported(q) ? q.constraints : const {};

bool _appConfigLegacyConditions(Object? questions) {
  if (questions is! List) return false;
  for (final question in questions) {
    if (question is! Map || question['schema'] is! Map) continue;
    final schema = question['schema'] as Map;
    if (schema.containsKey('show_subquestions_if') ||
        schema['subquestions'] is List &&
            (schema['subquestions'] as List).isNotEmpty ||
        _appConfigLegacyConditions(schema['attrs']) ||
        _appConfigLegacyConditions(schema['items']) ||
        schema['type'] == 'list' &&
            (schema['items'] is! List ||
                (schema['items'] as List).length > 1)) {
      return true;
    }
  }
  return false;
}

Object? _appConfigCopy(Object? value, List<int> budget, int depth) {
  if (++budget[0] > 100000 || depth > 32) {
    throw const FormatException(
      'The configuration exceeds safe editing limits.',
    );
  }
  if (value == null ||
      value is bool ||
      value is String ||
      value is num && value.isFinite) {
    return value;
  }
  if (value is List) {
    return [
      for (final child in value) _appConfigCopy(child, budget, depth + 1),
    ];
  }
  if (value is Map && value.keys.every((key) => key is String)) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key as String: _appConfigCopy(entry.value, budget, depth + 1),
    };
  }
  throw const FormatException('The configuration contains unsupported data.');
}
