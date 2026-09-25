part of 'true_nas_session_repository.dart';

/// Restricted filesystem properties. No arbitrary update dictionaries cross
/// this interface, and a review must use a snapshot issued by this session.
abstract interface class AuthenticatedDatasetPropertiesSession {
  DatasetPropertiesCapabilities get datasetPropertiesCapabilities;
  Future<List<DatasetPropertySnapshot>> loadDatasetProperties();
  Future<DatasetPropertyResult> updateDatasetProperties(
    DatasetPropertyUpdate request,
  );
}

final class DatasetPropertiesCapabilities {
  const DatasetPropertiesCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
  });
  const DatasetPropertiesCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false;
  final bool connected;
  final bool versionSupported;
  final bool available;
  bool get supported => connected && versionSupported && available;
  String? get blockedReason => !connected
      ? 'Connect to a server to edit dataset properties.'
      : !versionSupported
      ? 'This editor requires a stable TrueNAS 25.10 release.'
      : !available
      ? 'The required dataset methods are unavailable to this account.'
      : null;
}

const datasetByteProperties = [
  'quota',
  'refquota',
  'reservation',
  'refreservation',
];
const datasetInheritedProperties = ['compression', 'atime', 'readonly'];
final List<String> datasetCompressionChoices = List.unmodifiable([
  'ON',
  'OFF',
  'LZ4',
  'GZIP',
  'GZIP-1',
  'GZIP-9',
  'ZSTD',
  'ZSTD-FAST',
  'ZLE',
  'LZJB',
  for (var i = 1; i <= 19; i++) 'ZSTD-$i',
  // FAST-1 serializes back as FAST in OpenZFS. Offer its canonical choice once.
  for (var i = 2; i <= 10; i++) 'ZSTD-FAST-$i',
  for (var i = 20; i <= 100; i += 10) 'ZSTD-FAST-$i',
  'ZSTD-FAST-500',
  'ZSTD-FAST-1000',
]);

final class DatasetPropertyValue {
  const DatasetPropertyValue({
    required this.value,
    required this.source,
    this.sourceDataset,
  });

  /// Exact bytes for size properties; uppercase wire token for settings.
  final Object value;
  final String source;
  final String? sourceDataset;
  String get description =>
      '$value · $source${sourceDataset == null ? '' : ' from $sourceDataset'}';
}

final class DatasetPropertySnapshot {
  DatasetPropertySnapshot({
    required this.id,
    required this.guid,
    required this.usedBytes,
    required this.referencedBytes,
    required this.availableBytes,
    required Map<String, DatasetPropertyValue> properties,
    required Map<String, DatasetPropertyValue> parentProperties,
    required this.parentAvailableBytes,
    required List<String> descendants,
    this.descendantCount,
    this.blockedReason,
  }) : properties = Map.unmodifiable(properties),
       parentProperties = Map.unmodifiable(parentProperties),
       descendants = List.unmodifiable(descendants);
  final String id;
  final String guid;
  final int usedBytes;
  final int referencedBytes;
  final int availableBytes;
  final int parentAvailableBytes;
  final Map<String, DatasetPropertyValue> properties;
  final Map<String, DatasetPropertyValue> parentProperties;
  final List<String> descendants;

  /// Null when filesystem_count tracking is unavailable. Public query hides
  /// internal datasets, so an empty visible list alone is not a leaf proof.
  final int? descendantCount;
  bool get verifiedLeaf => descendantCount == 0 && descendants.isEmpty;
  final String? blockedReason;
  bool get editable => blockedReason == null;
}

final class DatasetPropertyUpdate {
  DatasetPropertyUpdate({
    required this.snapshot,
    required Map<String, Object> changes,
  }) : changes = Map.unmodifiable(changes);
  final DatasetPropertySnapshot snapshot;
  final Map<String, Object> changes;
  Object effective(String key) => changes[key] == 'INHERIT'
      ? snapshot.parentProperties[key]!.value
      : changes[key] ?? snapshot.properties[key]!.value;
  String? get validationError {
    if (!snapshot.editable) return snapshot.blockedReason;
    if (changes.isEmpty) {
      return 'Change at least one property before reviewing.';
    }
    for (final entry in changes.entries) {
      if (datasetByteProperties.contains(entry.key)) {
        final value = entry.value;
        if (value is! int || value < 0 || value > 9007199254740991) {
          return 'Enter exact non-negative byte values within the supported range.';
        }
        if ((entry.key == 'quota' || entry.key == 'refquota') &&
            value != 0 &&
            value < 1073741824) {
          return 'A quota must be 0 (unlimited) or at least 1 GiB (1073741824 bytes).';
        }
      } else if (datasetInheritedProperties.contains(entry.key)) {
        final value = entry.value;
        if (value == 'INHERIT') {
          if (!snapshot.parentProperties.containsKey(entry.key)) {
            return 'The parent property must be loaded before inheritance.';
          }
        } else if (!(entry.key == 'compression'
                ? datasetCompressionChoices
                : const ['ON', 'OFF'])
            .contains(value)) {
          return 'Choose a supported property value.';
        }
      } else {
        return 'This property is outside the native editor.';
      }
    }
    if (!snapshot.verifiedLeaf &&
        datasetInheritedProperties.any(changes.containsKey)) {
      return 'Behavior changes require a verified leaf: the server must report filesystem_count 0 with no visible descendants. Use TrueNAS when this count is unavailable or nonzero.';
    }
    final quota = effective('quota') as int;
    final refquota = effective('refquota') as int;
    final reservation = effective('reservation') as int;
    final refreservation = effective('refreservation') as int;
    if (quota != 0 && quota < snapshot.usedBytes) {
      return 'The quota cannot be below currently used space.';
    }
    if (refquota != 0 && refquota < snapshot.referencedBytes) {
      return 'The reference quota cannot be below referenced space.';
    }
    if (quota != 0 && (reservation > quota || refreservation > quota)) {
      return 'Reservations cannot exceed a finite dataset quota.';
    }
    if (refquota != 0 && refreservation > refquota) {
      return 'The reference reservation cannot exceed a finite reference quota.';
    }
    final addedReservation =
        reservation - (snapshot.properties['reservation']!.value as int);
    final addedRefreservation =
        refreservation - (snapshot.properties['refreservation']!.value as int);
    if ((addedReservation > 0 ? addedReservation : 0) +
            (addedRefreservation > 0 ? addedRefreservation : 0) >
        snapshot.parentAvailableBytes) {
      return 'The increased reservations exceed currently available parent space.';
    }
    return null;
  }
}

enum DatasetPropertyOutcome { verified, rejected, unknown }

final class DatasetPropertyResult {
  const DatasetPropertyResult({required this.outcome, required this.message});
  final DatasetPropertyOutcome outcome;
  final String message;
}

enum DatasetPropertiesExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleSnapshot,
  invalidResponse,
  unavailable,
  invalidRequest,
  attachedDataset,
}

final class DatasetPropertiesException implements Exception {
  const DatasetPropertiesException(this.reason);
  final DatasetPropertiesExceptionReason reason;
  String get userMessage => switch (reason) {
    DatasetPropertiesExceptionReason.notAuthenticated =>
      'Reconnect before editing dataset properties.',
    DatasetPropertiesExceptionReason.unsupportedVersion =>
      'Dataset editing is not verified for this server version.',
    DatasetPropertiesExceptionReason.unavailableMethod =>
      'Required dataset methods are unavailable to this account.',
    DatasetPropertiesExceptionReason.busy =>
      'Another server change or an unresolved dataset update is in progress.',
    DatasetPropertiesExceptionReason.staleSnapshot => 'The dataset, parent, descendants or connection changed. Reload and review again.',
    DatasetPropertiesExceptionReason.invalidResponse =>
      'Dataset identity, properties or capacity could not be verified.',
    DatasetPropertiesExceptionReason.unavailable =>
      'Dataset data could not be loaded. Remote details have been withheld.',
    DatasetPropertiesExceptionReason.invalidRequest =>
      'Review valid dataset properties before applying.',
    DatasetPropertiesExceptionReason.attachedDataset => 'Read-only changes for datasets with service attachments require the TrueNAS web interface.',
  };
  @override
  String toString() => userMessage;
}

const _datasetRequiredMethods = {
  'pool.dataset.query',
  'pool.dataset.update',
  'pool.dataset.attachments',
};
const _datasetZfsProperties = [
  'guid',
  'creation',
  'used',
  'referenced',
  'available',
  'quota',
  'refquota',
  'reservation',
  'refreservation',
  'compression',
  'atime',
  'readonly',
  'mountpoint',
  'encryption',
  'encryptionroot',
  'keystatus',
  'acltype',
  'aclmode',
  'filesystem_count',
];

final class _SessionDatasetProperties {
  _SessionDatasetProperties({
    required this.client,
    required ServerSummary summary,
    required this.nextId,
    required this.isCurrent,
    required this.requestTimeout,
    required this.isOtherMutationBusy,
  }) : versionSupported =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       methods = Set.unmodifiable(summary.availableMethodNames);
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent;
  final bool Function() isOtherMutationBusy;
  final Duration requestTimeout;
  final bool versionSupported;
  final Set<String> methods;
  bool _submitting = false;
  bool _loading = false;
  bool _uncertain = false;
  bool get isBusy => _submitting || _uncertain;
  final Map<DatasetPropertySnapshot, Map<String, _DatasetRow>> _issued = {};
  DatasetPropertiesCapabilities get capabilities =>
      DatasetPropertiesCapabilities(
        connected: isCurrent(),
        versionSupported: versionSupported,
        available: methods.containsAll(_datasetRequiredMethods),
      );
  void _guard() {
    if (!isCurrent()) {
      throw const DatasetPropertiesException(
        DatasetPropertiesExceptionReason.notAuthenticated,
      );
    }
    if (!versionSupported) {
      throw const DatasetPropertiesException(
        DatasetPropertiesExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.available) {
      throw const DatasetPropertiesException(
        DatasetPropertiesExceptionReason.unavailableMethod,
      );
    }
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    _guard();
    final value = await client
        .call(method, id: nextId(), params: args)
        .timeout(requestTimeout);
    _guard();
    return value;
  }

  Future<Map<String, _DatasetRow>> _read() async {
    final value = await _call('pool.dataset.query', [
      [
        [
          'type',
          'in',
          ['FILESYSTEM', 'VOLUME'],
        ],
      ],
      {
        'limit': 1025,
        'select': [
          'id',
          'name',
          'type',
          'encrypted',
          'locked',
          ..._datasetZfsProperties,
          ['user_properties.managedby', 'managedby'],
        ],
        'extra': {
          'flat': true,
          'retrieve_children': false,
          'retrieve_user_props': true,
          'properties': _datasetZfsProperties,
        },
      },
    ]);
    if (value is! List || value.length > 1024) _datasetInvalid();
    final rows = <String, _DatasetRow>{};
    for (final raw in value) {
      final row = _DatasetRow.parse(raw);
      if (rows.containsKey(row.id)) _datasetInvalid();
      rows[row.id] = row;
    }
    return rows;
  }

  Future<List<DatasetPropertySnapshot>> load() async {
    _guard();
    if (_submitting || _loading) {
      throw const DatasetPropertiesException(
        DatasetPropertiesExceptionReason.busy,
      );
    }
    _issued.clear();
    _loading = true;
    try {
      final rows = await _read();
      final result = <DatasetPropertySnapshot>[];
      for (final row in rows.values) {
        if (!row.filesystem) continue;
        final parent = rows[row.parentId];
        final snapshot = row.snapshot(rows);
        result.add(snapshot);
        if (parent != null) _issued[snapshot] = rows;
      }
      // A read never resolves an uncertain write or enables automatic retry.
      return List.unmodifiable(result);
    } on DatasetPropertiesException {
      rethrow;
    } on Object {
      throw const DatasetPropertiesException(
        DatasetPropertiesExceptionReason.unavailable,
      );
    } finally {
      _loading = false;
    }
  }

  Future<DatasetPropertyResult> update(DatasetPropertyUpdate request) async {
    _guard();
    if (isBusy || _loading || isOtherMutationBusy()) {
      throw const DatasetPropertiesException(
        DatasetPropertiesExceptionReason.busy,
      );
    }
    final baseline = _issued[request.snapshot];
    if (baseline == null) {
      throw const DatasetPropertiesException(
        DatasetPropertiesExceptionReason.staleSnapshot,
      );
    }
    if (request.validationError != null) {
      throw const DatasetPropertiesException(
        DatasetPropertiesExceptionReason.invalidRequest,
      );
    }
    _submitting = true;
    var sent = false;
    try {
      final rows = await _read();
      final original = baseline[request.snapshot.id]!;
      if (!_datasetRelevantEqual(baseline, rows, original.id)) {
        throw const DatasetPropertiesException(
          DatasetPropertiesExceptionReason.staleSnapshot,
        );
      }
      final current = rows[original.id]!.snapshot(rows);
      if (DatasetPropertyUpdate(
            snapshot: current,
            changes: request.changes,
          ).validationError !=
          null) {
        throw const DatasetPropertiesException(
          DatasetPropertiesExceptionReason.invalidRequest,
        );
      }
      if (request.effective('readonly') !=
          request.snapshot.properties['readonly']!.value) {
        final attachments = await _call('pool.dataset.attachments', [
          original.id,
        ]);
        if (attachments is! List) _datasetInvalid();
        if (attachments.isNotEmpty || current.descendants.isNotEmpty) {
          throw const DatasetPropertiesException(
            DatasetPropertiesExceptionReason.attachedDataset,
          );
        }
        // The attachment read is not an ownership token. Check config again.
        final latest = await _read();
        if (!_datasetRelevantEqual(rows, latest, original.id)) {
          throw const DatasetPropertiesException(
            DatasetPropertiesExceptionReason.staleSnapshot,
          );
        }
        if (DatasetPropertyUpdate(
              snapshot: latest[original.id]!.snapshot(latest),
              changes: request.changes,
            ).validationError !=
            null) {
          throw const DatasetPropertiesException(
            DatasetPropertiesExceptionReason.invalidRequest,
          );
        }
      }
      _guard();
      sent = true;
      await _call('pool.dataset.update', [original.id, request.changes]);
      final after = await _read();
      final actual = after[original.id];
      if (actual == null ||
          actual.identity != original.identity ||
          !_datasetRelatedEqual(rows, after, original.id) ||
          actual.blockedReason != original.blockedReason) {
        return _unknown();
      }
      for (final key in [
        ...datasetByteProperties,
        ...datasetInheritedProperties,
      ]) {
        final value = actual.properties[key]!;
        if (value.value != request.effective(key)) return _unknown();
        if (request.changes.containsKey(key)) {
          if (request.changes[key] == 'INHERIT'
              ? !{'INHERITED', 'DEFAULT'}.contains(value.source)
              : value.source != 'LOCAL' &&
                    !(value.value == 0 && value.source == 'DEFAULT')) {
            return _unknown();
          }
          if (request.changes[key] == 'INHERIT') {
            final parentValue = request.snapshot.parentProperties[key]!;
            final expectedSource = parentValue.source == 'INHERITED'
                ? parentValue.sourceDataset
                : original.parentId;
            if (value.source == 'INHERITED'
                ? value.sourceDataset != expectedSource
                : parentValue.source != 'DEFAULT') {
              return _unknown();
            }
          }
        } else if (!_datasetPropertyEqual(value, original.properties[key]!)) {
          return _unknown();
        }
      }
      _issued.clear();
      return const DatasetPropertyResult(
        outcome: DatasetPropertyOutcome.verified,
        message: 'The updated properties were read back and verified on this server.',
      );
    } on DatasetPropertiesException catch (error) {
      if (sent) return _unknown();
      return DatasetPropertyResult(
        outcome: DatasetPropertyOutcome.rejected,
        message: error.userMessage,
      );
    } on Object {
      if (sent) return _unknown();
      return const DatasetPropertyResult(
        outcome: DatasetPropertyOutcome.rejected,
        message: 'Preflight checks failed. No dataset update was sent.',
      );
    } finally {
      _submitting = false;
    }
  }

  DatasetPropertyResult _unknown() {
    _uncertain = true;
    _issued.clear();
    return const DatasetPropertyResult(
      outcome: DatasetPropertyOutcome.unknown,
      message: 'The update may have applied, but its outcome could not be verified. Do not retry. Inspect the dataset in TrueNAS and reconnect before further changes.',
    );
  }
}

final class _DatasetRow {
  _DatasetRow(
    this.id,
    this.filesystem,
    this.guid,
    this.used,
    this.referenced,
    this.available,
    this.properties,
    this.identity,
    this.blockedReason,
    this.descendantCount,
  );
  final String id;
  final bool filesystem;
  final String guid;
  final int used;
  final int referenced;
  final int available;
  final Map<String, DatasetPropertyValue> properties;
  final String identity;
  final String? blockedReason;
  final int? descendantCount;
  String? get parentId =>
      id.contains('/') ? id.substring(0, id.lastIndexOf('/')) : null;
  static _DatasetRow parse(Object? raw) {
    if (raw is! Map ||
        !{'FILESYSTEM', 'VOLUME'}.contains(raw['type']) ||
        !_datasetText(raw['id'], 200) ||
        raw['encrypted'] is! bool ||
        raw['locked'] is! bool) {
      _datasetInvalid();
    }
    final id = raw['id'] as String;
    final filesystem = raw['type'] == 'FILESYSTEM';
    if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.:/ -]*$').hasMatch(id) ||
        id.contains('//') ||
        id.endsWith('/') ||
        id.split('/').any((p) => p == '.' || p == '..')) {
      _datasetInvalid();
    }
    final guid = _datasetRaw(raw['guid']);
    if (!RegExp(r'^[0-9]{1,20}$').hasMatch(guid)) _datasetInvalid();
    final properties = <String, DatasetPropertyValue>{};
    for (final key
        in filesystem
            ? [...datasetByteProperties, ...datasetInheritedProperties]
            : const [
                'reservation',
                'refreservation',
                'compression',
                'readonly',
              ]) {
      final prop = raw[key];
      if (prop is! Map ||
          prop['source'] is! String ||
          !{
            'LOCAL',
            'DEFAULT',
            'INHERITED',
            'RECEIVED',
          }.contains(prop['source'])) {
        _datasetInvalid();
      }
      final sourceInfo = prop['source_info'];
      if (sourceInfo != null &&
          sourceInfo != '' &&
          !_datasetText(sourceInfo, 200)) {
        _datasetInvalid();
      }
      if (prop['source'] == 'INHERITED' &&
          (sourceInfo is! String ||
              sourceInfo.isEmpty ||
              !id.startsWith('$sourceInfo/'))) {
        _datasetInvalid();
      }
      final token = _datasetRaw(prop);
      final Object value = datasetByteProperties.contains(key)
          ? _datasetBytes(prop)
          : token.toUpperCase();
      if (key == 'compression' && !_datasetText(value, 64)) {
        _datasetInvalid();
      }
      if ((key == 'atime' || key == 'readonly') &&
          !{'ON', 'OFF'}.contains(value)) {
        _datasetInvalid();
      }
      properties[key] = DatasetPropertyValue(
        value: value,
        source: prop['source'] as String,
        sourceDataset: sourceInfo == '' ? null : sourceInfo as String?,
      );
    }
    final mount = raw['mountpoint'];
    final creation = _datasetRaw(raw['creation']);
    final acltype = filesystem ? _datasetRaw(raw['acltype']) : null;
    final aclmode = filesystem ? _datasetRaw(raw['aclmode']) : null;
    final managed = raw['managedby'];
    final managedValue = managed == null ? '' : _datasetRaw(managed);
    final countProperty = raw['filesystem_count'];
    final countRaw = countProperty is Map ? countProperty['rawvalue'] : null;
    final count = countRaw is String ? int.tryParse(countRaw) : null;
    final descendantCount =
        count != null && count >= 0 && count <= 9007199254740991 ? count : null;
    final blocked = !filesystem
        ? 'ZVOL editing is outside this filesystem workflow.'
        : !datasetCompressionChoices.contains(properties['compression']!.value)
        ? 'The current compression value requires a specialized editor.'
        : !id.contains('/')
        ? 'Pool-root properties require the TrueNAS web interface.'
        : raw['locked'] == true || raw['encrypted'] == true
        ? 'Encrypted datasets require a dedicated verified workflow.'
        : mount != '/mnt/$id'
        ? 'Nonstandard mountpoints are outside this editor.'
        : id
                  .split('/')
                  .any(
                    (p) => {
                      '.system',
                      'ix-apps',
                      'ix-applications',
                      '.ix-virt',
                    }.contains(p),
                  ) ||
              !{'', '-', 'none'}.contains(managedValue.toLowerCase())
        ? 'System-managed datasets cannot be edited here.'
        : null;
    return _DatasetRow(
      id,
      filesystem,
      guid,
      _datasetBytes(raw['used']),
      _datasetBytes(raw['referenced']),
      _datasetBytes(raw['available']),
      Map.unmodifiable(properties),
      '${raw['type']}|$guid|$creation|$mount|${raw['encrypted']}|${raw['locked']}|$acltype|$aclmode|$managedValue|$descendantCount',
      blocked,
      descendantCount,
    );
  }

  DatasetPropertySnapshot snapshot(Map<String, _DatasetRow> rows) =>
      DatasetPropertySnapshot(
        id: id,
        guid: guid,
        usedBytes: used,
        referencedBytes: referenced,
        availableBytes: available,
        properties: properties,
        parentProperties: rows[parentId]?.properties ?? const {},
        parentAvailableBytes: rows[parentId]?.available ?? 0,
        descendants: [
          for (final key in rows.keys)
            if (key.startsWith('$id/')) key,
        ]..sort(),
        descendantCount: descendantCount,
        blockedReason:
            blockedReason ??
            (rows[parentId] == null
                ? 'The parent dataset is unavailable.'
                : null),
      );
}

bool _datasetPropertyEqual(DatasetPropertyValue a, DatasetPropertyValue b) =>
    a.value == b.value &&
    a.source == b.source &&
    a.sourceDataset == b.sourceDataset;
bool _datasetRowEqual(_DatasetRow a, _DatasetRow b) =>
    a.identity == b.identity &&
    a.properties.keys.every(
      (k) => _datasetPropertyEqual(a.properties[k]!, b.properties[k]!),
    );
bool _datasetRelatedEqual(
  Map<String, _DatasetRow> a,
  Map<String, _DatasetRow> b,
  String id,
) {
  final parent = a[id]!.parentId;
  final keys = {
    ?parent,
    for (final key in a.keys)
      if (key.startsWith('$id/')) key,
  };
  final other = {
    ?parent,
    for (final key in b.keys)
      if (key.startsWith('$id/')) key,
  };
  return keys.length == other.length &&
      keys.containsAll(other) &&
      keys.every(
        (key) =>
            a[key] != null &&
            b[key] != null &&
            _datasetRowEqual(a[key]!, b[key]!),
      );
}

bool _datasetRelevantEqual(
  Map<String, _DatasetRow> a,
  Map<String, _DatasetRow> b,
  String id,
) =>
    a[id] != null &&
    b[id] != null &&
    _datasetRowEqual(a[id]!, b[id]!) &&
    _datasetRelatedEqual(a, b, id);
bool _datasetText(Object? value, int max) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
String _datasetRaw(Object? prop) {
  if (prop is! Map || prop['rawvalue'] is! String) _datasetInvalid();
  return prop['rawvalue'] as String;
}

int _datasetBytes(Object? prop) {
  final raw = _datasetRaw(prop);
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 0 || parsed > 9007199254740991) {
    _datasetInvalid();
  }
  return parsed;
}

Never _datasetInvalid() => throw const DatasetPropertiesException(
  DatasetPropertiesExceptionReason.invalidResponse,
);
