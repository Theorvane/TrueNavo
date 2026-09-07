// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $ServerProfilesTable extends ServerProfiles
    with TableInfo<$ServerProfilesTable, StoredServerProfile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ServerProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (length(id) BETWEEN 1 AND 128)',
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints:
        'NOT NULL CHECK (length(display_name) BETWEEN 1 AND 256)',
  );
  static const VerificationMeta _originalHostInputMeta = const VerificationMeta(
    'originalHostInput',
  );
  @override
  late final GeneratedColumn<String> originalHostInput =
      GeneratedColumn<String>(
        'original_host_input',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
        $customConstraints:
            'NOT NULL CHECK (length(original_host_input) BETWEEN 1 AND 2048)',
      );
  static const VerificationMeta _normalizedEndpointMeta =
      const VerificationMeta('normalizedEndpoint');
  @override
  late final GeneratedColumn<String> normalizedEndpoint =
      GeneratedColumn<String>(
        'normalized_endpoint',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
        $customConstraints: 'NOT NULL UNIQUE CHECK (length(normalized_endpoint) BETWEEN 1 AND 2048)',
      );
  static const VerificationMeta _lastKnownVersionMeta = const VerificationMeta(
    'lastKnownVersion',
  );
  @override
  late final GeneratedColumn<String> lastKnownVersion = GeneratedColumn<String>(
    'last_known_version',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints:
        'NOT NULL CHECK (length(last_known_version) BETWEEN 1 AND 128)',
  );
  static const VerificationMeta _createdAtMsMeta = const VerificationMeta(
    'createdAtMs',
  );
  @override
  late final GeneratedColumn<int> createdAtMs = GeneratedColumn<int>(
    'created_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMsMeta = const VerificationMeta(
    'updatedAtMs',
  );
  @override
  late final GeneratedColumn<int> updatedAtMs = GeneratedColumn<int>(
    'updated_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL UNIQUE CHECK (sort_order >= 0)',
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    displayName,
    originalHostInput,
    normalizedEndpoint,
    lastKnownVersion,
    createdAtMs,
    updatedAtMs,
    sortOrder,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'server_profiles';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredServerProfile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('original_host_input')) {
      context.handle(
        _originalHostInputMeta,
        originalHostInput.isAcceptableOrUnknown(
          data['original_host_input']!,
          _originalHostInputMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_originalHostInputMeta);
    }
    if (data.containsKey('normalized_endpoint')) {
      context.handle(
        _normalizedEndpointMeta,
        normalizedEndpoint.isAcceptableOrUnknown(
          data['normalized_endpoint']!,
          _normalizedEndpointMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_normalizedEndpointMeta);
    }
    if (data.containsKey('last_known_version')) {
      context.handle(
        _lastKnownVersionMeta,
        lastKnownVersion.isAcceptableOrUnknown(
          data['last_known_version']!,
          _lastKnownVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastKnownVersionMeta);
    }
    if (data.containsKey('created_at_ms')) {
      context.handle(
        _createdAtMsMeta,
        createdAtMs.isAcceptableOrUnknown(
          data['created_at_ms']!,
          _createdAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createdAtMsMeta);
    }
    if (data.containsKey('updated_at_ms')) {
      context.handle(
        _updatedAtMsMeta,
        updatedAtMs.isAcceptableOrUnknown(
          data['updated_at_ms']!,
          _updatedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMsMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    } else if (isInserting) {
      context.missing(_sortOrderMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StoredServerProfile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredServerProfile(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      originalHostInput: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}original_host_input'],
      )!,
      normalizedEndpoint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}normalized_endpoint'],
      )!,
      lastKnownVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_known_version'],
      )!,
      createdAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_ms'],
      )!,
      updatedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_ms'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $ServerProfilesTable createAlias(String alias) {
    return $ServerProfilesTable(attachedDatabase, alias);
  }
}

class StoredServerProfile extends DataClass
    implements Insertable<StoredServerProfile> {
  final String id;
  final String displayName;
  final String originalHostInput;
  final String normalizedEndpoint;
  final String lastKnownVersion;
  final int createdAtMs;
  final int updatedAtMs;
  final int sortOrder;
  const StoredServerProfile({
    required this.id,
    required this.displayName,
    required this.originalHostInput,
    required this.normalizedEndpoint,
    required this.lastKnownVersion,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['display_name'] = Variable<String>(displayName);
    map['original_host_input'] = Variable<String>(originalHostInput);
    map['normalized_endpoint'] = Variable<String>(normalizedEndpoint);
    map['last_known_version'] = Variable<String>(lastKnownVersion);
    map['created_at_ms'] = Variable<int>(createdAtMs);
    map['updated_at_ms'] = Variable<int>(updatedAtMs);
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  ServerProfilesCompanion toCompanion(bool nullToAbsent) {
    return ServerProfilesCompanion(
      id: Value(id),
      displayName: Value(displayName),
      originalHostInput: Value(originalHostInput),
      normalizedEndpoint: Value(normalizedEndpoint),
      lastKnownVersion: Value(lastKnownVersion),
      createdAtMs: Value(createdAtMs),
      updatedAtMs: Value(updatedAtMs),
      sortOrder: Value(sortOrder),
    );
  }

  factory StoredServerProfile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredServerProfile(
      id: serializer.fromJson<String>(json['id']),
      displayName: serializer.fromJson<String>(json['displayName']),
      originalHostInput: serializer.fromJson<String>(json['originalHostInput']),
      normalizedEndpoint: serializer.fromJson<String>(
        json['normalizedEndpoint'],
      ),
      lastKnownVersion: serializer.fromJson<String>(json['lastKnownVersion']),
      createdAtMs: serializer.fromJson<int>(json['createdAtMs']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'displayName': serializer.toJson<String>(displayName),
      'originalHostInput': serializer.toJson<String>(originalHostInput),
      'normalizedEndpoint': serializer.toJson<String>(normalizedEndpoint),
      'lastKnownVersion': serializer.toJson<String>(lastKnownVersion),
      'createdAtMs': serializer.toJson<int>(createdAtMs),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  StoredServerProfile copyWith({
    String? id,
    String? displayName,
    String? originalHostInput,
    String? normalizedEndpoint,
    String? lastKnownVersion,
    int? createdAtMs,
    int? updatedAtMs,
    int? sortOrder,
  }) => StoredServerProfile(
    id: id ?? this.id,
    displayName: displayName ?? this.displayName,
    originalHostInput: originalHostInput ?? this.originalHostInput,
    normalizedEndpoint: normalizedEndpoint ?? this.normalizedEndpoint,
    lastKnownVersion: lastKnownVersion ?? this.lastKnownVersion,
    createdAtMs: createdAtMs ?? this.createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  StoredServerProfile copyWithCompanion(ServerProfilesCompanion data) {
    return StoredServerProfile(
      id: data.id.present ? data.id.value : this.id,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      originalHostInput: data.originalHostInput.present
          ? data.originalHostInput.value
          : this.originalHostInput,
      normalizedEndpoint: data.normalizedEndpoint.present
          ? data.normalizedEndpoint.value
          : this.normalizedEndpoint,
      lastKnownVersion: data.lastKnownVersion.present
          ? data.lastKnownVersion.value
          : this.lastKnownVersion,
      createdAtMs: data.createdAtMs.present
          ? data.createdAtMs.value
          : this.createdAtMs,
      updatedAtMs: data.updatedAtMs.present
          ? data.updatedAtMs.value
          : this.updatedAtMs,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredServerProfile(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('originalHostInput: $originalHostInput, ')
          ..write('normalizedEndpoint: $normalizedEndpoint, ')
          ..write('lastKnownVersion: $lastKnownVersion, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    originalHostInput,
    normalizedEndpoint,
    lastKnownVersion,
    createdAtMs,
    updatedAtMs,
    sortOrder,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredServerProfile &&
          other.id == this.id &&
          other.displayName == this.displayName &&
          other.originalHostInput == this.originalHostInput &&
          other.normalizedEndpoint == this.normalizedEndpoint &&
          other.lastKnownVersion == this.lastKnownVersion &&
          other.createdAtMs == this.createdAtMs &&
          other.updatedAtMs == this.updatedAtMs &&
          other.sortOrder == this.sortOrder);
}

class ServerProfilesCompanion extends UpdateCompanion<StoredServerProfile> {
  final Value<String> id;
  final Value<String> displayName;
  final Value<String> originalHostInput;
  final Value<String> normalizedEndpoint;
  final Value<String> lastKnownVersion;
  final Value<int> createdAtMs;
  final Value<int> updatedAtMs;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const ServerProfilesCompanion({
    this.id = const Value.absent(),
    this.displayName = const Value.absent(),
    this.originalHostInput = const Value.absent(),
    this.normalizedEndpoint = const Value.absent(),
    this.lastKnownVersion = const Value.absent(),
    this.createdAtMs = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ServerProfilesCompanion.insert({
    required String id,
    required String displayName,
    required String originalHostInput,
    required String normalizedEndpoint,
    required String lastKnownVersion,
    required int createdAtMs,
    required int updatedAtMs,
    required int sortOrder,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       displayName = Value(displayName),
       originalHostInput = Value(originalHostInput),
       normalizedEndpoint = Value(normalizedEndpoint),
       lastKnownVersion = Value(lastKnownVersion),
       createdAtMs = Value(createdAtMs),
       updatedAtMs = Value(updatedAtMs),
       sortOrder = Value(sortOrder);
  static Insertable<StoredServerProfile> custom({
    Expression<String>? id,
    Expression<String>? displayName,
    Expression<String>? originalHostInput,
    Expression<String>? normalizedEndpoint,
    Expression<String>? lastKnownVersion,
    Expression<int>? createdAtMs,
    Expression<int>? updatedAtMs,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (displayName != null) 'display_name': displayName,
      if (originalHostInput != null) 'original_host_input': originalHostInput,
      if (normalizedEndpoint != null) 'normalized_endpoint': normalizedEndpoint,
      if (lastKnownVersion != null) 'last_known_version': lastKnownVersion,
      if (createdAtMs != null) 'created_at_ms': createdAtMs,
      if (updatedAtMs != null) 'updated_at_ms': updatedAtMs,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ServerProfilesCompanion copyWith({
    Value<String>? id,
    Value<String>? displayName,
    Value<String>? originalHostInput,
    Value<String>? normalizedEndpoint,
    Value<String>? lastKnownVersion,
    Value<int>? createdAtMs,
    Value<int>? updatedAtMs,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return ServerProfilesCompanion(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      originalHostInput: originalHostInput ?? this.originalHostInput,
      normalizedEndpoint: normalizedEndpoint ?? this.normalizedEndpoint,
      lastKnownVersion: lastKnownVersion ?? this.lastKnownVersion,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (originalHostInput.present) {
      map['original_host_input'] = Variable<String>(originalHostInput.value);
    }
    if (normalizedEndpoint.present) {
      map['normalized_endpoint'] = Variable<String>(normalizedEndpoint.value);
    }
    if (lastKnownVersion.present) {
      map['last_known_version'] = Variable<String>(lastKnownVersion.value);
    }
    if (createdAtMs.present) {
      map['created_at_ms'] = Variable<int>(createdAtMs.value);
    }
    if (updatedAtMs.present) {
      map['updated_at_ms'] = Variable<int>(updatedAtMs.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ServerProfilesCompanion(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('originalHostInput: $originalHostInput, ')
          ..write('normalizedEndpoint: $normalizedEndpoint, ')
          ..write('lastKnownVersion: $lastKnownVersion, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppSelectionTable extends AppSelection
    with TableInfo<$AppSelectionTable, AppSelectionData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppSelectionTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _singletonIdMeta = const VerificationMeta(
    'singletonId',
  );
  @override
  late final GeneratedColumn<int> singletonId = GeneratedColumn<int>(
    'singleton_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL CHECK (singleton_id = 1)',
  );
  static const VerificationMeta _selectedProfileIdMeta = const VerificationMeta(
    'selectedProfileId',
  );
  @override
  late final GeneratedColumn<String> selectedProfileId =
      GeneratedColumn<String>(
        'selected_profile_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES server_profiles (id) ON DELETE SET NULL',
        ),
      );
  @override
  List<GeneratedColumn> get $columns => [singletonId, selectedProfileId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_selection';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppSelectionData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('singleton_id')) {
      context.handle(
        _singletonIdMeta,
        singletonId.isAcceptableOrUnknown(
          data['singleton_id']!,
          _singletonIdMeta,
        ),
      );
    }
    if (data.containsKey('selected_profile_id')) {
      context.handle(
        _selectedProfileIdMeta,
        selectedProfileId.isAcceptableOrUnknown(
          data['selected_profile_id']!,
          _selectedProfileIdMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {singletonId};
  @override
  AppSelectionData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppSelectionData(
      singletonId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}singleton_id'],
      )!,
      selectedProfileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}selected_profile_id'],
      ),
    );
  }

  @override
  $AppSelectionTable createAlias(String alias) {
    return $AppSelectionTable(attachedDatabase, alias);
  }
}

class AppSelectionData extends DataClass
    implements Insertable<AppSelectionData> {
  final int singletonId;
  final String? selectedProfileId;
  const AppSelectionData({required this.singletonId, this.selectedProfileId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['singleton_id'] = Variable<int>(singletonId);
    if (!nullToAbsent || selectedProfileId != null) {
      map['selected_profile_id'] = Variable<String>(selectedProfileId);
    }
    return map;
  }

  AppSelectionCompanion toCompanion(bool nullToAbsent) {
    return AppSelectionCompanion(
      singletonId: Value(singletonId),
      selectedProfileId: selectedProfileId == null && nullToAbsent
          ? const Value.absent()
          : Value(selectedProfileId),
    );
  }

  factory AppSelectionData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppSelectionData(
      singletonId: serializer.fromJson<int>(json['singletonId']),
      selectedProfileId: serializer.fromJson<String?>(
        json['selectedProfileId'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'singletonId': serializer.toJson<int>(singletonId),
      'selectedProfileId': serializer.toJson<String?>(selectedProfileId),
    };
  }

  AppSelectionData copyWith({
    int? singletonId,
    Value<String?> selectedProfileId = const Value.absent(),
  }) => AppSelectionData(
    singletonId: singletonId ?? this.singletonId,
    selectedProfileId: selectedProfileId.present
        ? selectedProfileId.value
        : this.selectedProfileId,
  );
  AppSelectionData copyWithCompanion(AppSelectionCompanion data) {
    return AppSelectionData(
      singletonId: data.singletonId.present
          ? data.singletonId.value
          : this.singletonId,
      selectedProfileId: data.selectedProfileId.present
          ? data.selectedProfileId.value
          : this.selectedProfileId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppSelectionData(')
          ..write('singletonId: $singletonId, ')
          ..write('selectedProfileId: $selectedProfileId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(singletonId, selectedProfileId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppSelectionData &&
          other.singletonId == this.singletonId &&
          other.selectedProfileId == this.selectedProfileId);
}

class AppSelectionCompanion extends UpdateCompanion<AppSelectionData> {
  final Value<int> singletonId;
  final Value<String?> selectedProfileId;
  const AppSelectionCompanion({
    this.singletonId = const Value.absent(),
    this.selectedProfileId = const Value.absent(),
  });
  AppSelectionCompanion.insert({
    this.singletonId = const Value.absent(),
    this.selectedProfileId = const Value.absent(),
  });
  static Insertable<AppSelectionData> custom({
    Expression<int>? singletonId,
    Expression<String>? selectedProfileId,
  }) {
    return RawValuesInsertable({
      if (singletonId != null) 'singleton_id': singletonId,
      if (selectedProfileId != null) 'selected_profile_id': selectedProfileId,
    });
  }

  AppSelectionCompanion copyWith({
    Value<int>? singletonId,
    Value<String?>? selectedProfileId,
  }) {
    return AppSelectionCompanion(
      singletonId: singletonId ?? this.singletonId,
      selectedProfileId: selectedProfileId ?? this.selectedProfileId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (singletonId.present) {
      map['singleton_id'] = Variable<int>(singletonId.value);
    }
    if (selectedProfileId.present) {
      map['selected_profile_id'] = Variable<String>(selectedProfileId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppSelectionCompanion(')
          ..write('singletonId: $singletonId, ')
          ..write('selectedProfileId: $selectedProfileId')
          ..write(')'))
        .toString();
  }
}

class $ProfileCapabilitiesTable extends ProfileCapabilities
    with TableInfo<$ProfileCapabilitiesTable, ProfileCapability> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfileCapabilitiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES server_profiles (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _methodNameMeta = const VerificationMeta(
    'methodName',
  );
  @override
  late final GeneratedColumn<String> methodName = GeneratedColumn<String>(
    'method_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (length(method_name) BETWEEN 1 AND 255 AND method_name NOT GLOB \'*[^A-Za-z0-9_.]*\' AND method_name NOT GLOB \'.*\' AND method_name NOT GLOB \'*.\' AND method_name NOT GLOB \'*..*\')',
  );
  static const VerificationMeta _observedAtMsMeta = const VerificationMeta(
    'observedAtMs',
  );
  @override
  late final GeneratedColumn<int> observedAtMs = GeneratedColumn<int>(
    'observed_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMsMeta = const VerificationMeta(
    'expiresAtMs',
  );
  @override
  late final GeneratedColumn<int> expiresAtMs = GeneratedColumn<int>(
    'expires_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL CHECK (expires_at_ms > observed_at_ms)',
  );
  @override
  List<GeneratedColumn> get $columns => [
    profileId,
    methodName,
    observedAtMs,
    expiresAtMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profile_capabilities';
  @override
  VerificationContext validateIntegrity(
    Insertable<ProfileCapability> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('method_name')) {
      context.handle(
        _methodNameMeta,
        methodName.isAcceptableOrUnknown(data['method_name']!, _methodNameMeta),
      );
    } else if (isInserting) {
      context.missing(_methodNameMeta);
    }
    if (data.containsKey('observed_at_ms')) {
      context.handle(
        _observedAtMsMeta,
        observedAtMs.isAcceptableOrUnknown(
          data['observed_at_ms']!,
          _observedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_observedAtMsMeta);
    }
    if (data.containsKey('expires_at_ms')) {
      context.handle(
        _expiresAtMsMeta,
        expiresAtMs.isAcceptableOrUnknown(
          data['expires_at_ms']!,
          _expiresAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId, methodName};
  @override
  ProfileCapability map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProfileCapability(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      methodName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}method_name'],
      )!,
      observedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}observed_at_ms'],
      )!,
      expiresAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}expires_at_ms'],
      )!,
    );
  }

  @override
  $ProfileCapabilitiesTable createAlias(String alias) {
    return $ProfileCapabilitiesTable(attachedDatabase, alias);
  }
}

class ProfileCapability extends DataClass
    implements Insertable<ProfileCapability> {
  final String profileId;
  final String methodName;
  final int observedAtMs;
  final int expiresAtMs;
  const ProfileCapability({
    required this.profileId,
    required this.methodName,
    required this.observedAtMs,
    required this.expiresAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['method_name'] = Variable<String>(methodName);
    map['observed_at_ms'] = Variable<int>(observedAtMs);
    map['expires_at_ms'] = Variable<int>(expiresAtMs);
    return map;
  }

  ProfileCapabilitiesCompanion toCompanion(bool nullToAbsent) {
    return ProfileCapabilitiesCompanion(
      profileId: Value(profileId),
      methodName: Value(methodName),
      observedAtMs: Value(observedAtMs),
      expiresAtMs: Value(expiresAtMs),
    );
  }

  factory ProfileCapability.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProfileCapability(
      profileId: serializer.fromJson<String>(json['profileId']),
      methodName: serializer.fromJson<String>(json['methodName']),
      observedAtMs: serializer.fromJson<int>(json['observedAtMs']),
      expiresAtMs: serializer.fromJson<int>(json['expiresAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'methodName': serializer.toJson<String>(methodName),
      'observedAtMs': serializer.toJson<int>(observedAtMs),
      'expiresAtMs': serializer.toJson<int>(expiresAtMs),
    };
  }

  ProfileCapability copyWith({
    String? profileId,
    String? methodName,
    int? observedAtMs,
    int? expiresAtMs,
  }) => ProfileCapability(
    profileId: profileId ?? this.profileId,
    methodName: methodName ?? this.methodName,
    observedAtMs: observedAtMs ?? this.observedAtMs,
    expiresAtMs: expiresAtMs ?? this.expiresAtMs,
  );
  ProfileCapability copyWithCompanion(ProfileCapabilitiesCompanion data) {
    return ProfileCapability(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      methodName: data.methodName.present
          ? data.methodName.value
          : this.methodName,
      observedAtMs: data.observedAtMs.present
          ? data.observedAtMs.value
          : this.observedAtMs,
      expiresAtMs: data.expiresAtMs.present
          ? data.expiresAtMs.value
          : this.expiresAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProfileCapability(')
          ..write('profileId: $profileId, ')
          ..write('methodName: $methodName, ')
          ..write('observedAtMs: $observedAtMs, ')
          ..write('expiresAtMs: $expiresAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(profileId, methodName, observedAtMs, expiresAtMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProfileCapability &&
          other.profileId == this.profileId &&
          other.methodName == this.methodName &&
          other.observedAtMs == this.observedAtMs &&
          other.expiresAtMs == this.expiresAtMs);
}

class ProfileCapabilitiesCompanion extends UpdateCompanion<ProfileCapability> {
  final Value<String> profileId;
  final Value<String> methodName;
  final Value<int> observedAtMs;
  final Value<int> expiresAtMs;
  final Value<int> rowid;
  const ProfileCapabilitiesCompanion({
    this.profileId = const Value.absent(),
    this.methodName = const Value.absent(),
    this.observedAtMs = const Value.absent(),
    this.expiresAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProfileCapabilitiesCompanion.insert({
    required String profileId,
    required String methodName,
    required int observedAtMs,
    required int expiresAtMs,
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       methodName = Value(methodName),
       observedAtMs = Value(observedAtMs),
       expiresAtMs = Value(expiresAtMs);
  static Insertable<ProfileCapability> custom({
    Expression<String>? profileId,
    Expression<String>? methodName,
    Expression<int>? observedAtMs,
    Expression<int>? expiresAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (methodName != null) 'method_name': methodName,
      if (observedAtMs != null) 'observed_at_ms': observedAtMs,
      if (expiresAtMs != null) 'expires_at_ms': expiresAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProfileCapabilitiesCompanion copyWith({
    Value<String>? profileId,
    Value<String>? methodName,
    Value<int>? observedAtMs,
    Value<int>? expiresAtMs,
    Value<int>? rowid,
  }) {
    return ProfileCapabilitiesCompanion(
      profileId: profileId ?? this.profileId,
      methodName: methodName ?? this.methodName,
      observedAtMs: observedAtMs ?? this.observedAtMs,
      expiresAtMs: expiresAtMs ?? this.expiresAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (methodName.present) {
      map['method_name'] = Variable<String>(methodName.value);
    }
    if (observedAtMs.present) {
      map['observed_at_ms'] = Variable<int>(observedAtMs.value);
    }
    if (expiresAtMs.present) {
      map['expires_at_ms'] = Variable<int>(expiresAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfileCapabilitiesCompanion(')
          ..write('profileId: $profileId, ')
          ..write('methodName: $methodName, ')
          ..write('observedAtMs: $observedAtMs, ')
          ..write('expiresAtMs: $expiresAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ServerProfilesTable serverProfiles = $ServerProfilesTable(this);
  late final $AppSelectionTable appSelection = $AppSelectionTable(this);
  late final $ProfileCapabilitiesTable profileCapabilities =
      $ProfileCapabilitiesTable(this);
  late final Index profileCapabilitiesExpiryIdx = Index(
    'profile_capabilities_expiry_idx',
    'CREATE INDEX profile_capabilities_expiry_idx ON profile_capabilities (profile_id, expires_at_ms)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    serverProfiles,
    appSelection,
    profileCapabilities,
    profileCapabilitiesExpiryIdx,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'server_profiles',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('app_selection', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'server_profiles',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('profile_capabilities', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$ServerProfilesTableCreateCompanionBuilder =
    ServerProfilesCompanion Function({
      required String id,
      required String displayName,
      required String originalHostInput,
      required String normalizedEndpoint,
      required String lastKnownVersion,
      required int createdAtMs,
      required int updatedAtMs,
      required int sortOrder,
      Value<int> rowid,
    });
typedef $$ServerProfilesTableUpdateCompanionBuilder =
    ServerProfilesCompanion Function({
      Value<String> id,
      Value<String> displayName,
      Value<String> originalHostInput,
      Value<String> normalizedEndpoint,
      Value<String> lastKnownVersion,
      Value<int> createdAtMs,
      Value<int> updatedAtMs,
      Value<int> sortOrder,
      Value<int> rowid,
    });

final class $$ServerProfilesTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $ServerProfilesTable,
          StoredServerProfile
        > {
  $$ServerProfilesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$AppSelectionTable, List<AppSelectionData>>
  _appSelectionRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.appSelection,
    aliasName: 'server_profiles__id__app_selection__selected_profile_id',
  );

  $$AppSelectionTableProcessedTableManager get appSelectionRefs {
    final manager = $$AppSelectionTableTableManager($_db, $_db.appSelection)
        .filter(
          (f) => f.selectedProfileId.id.sqlEquals($_itemColumn<String>('id')!),
        );

    final cache = $_typedResult.readTableOrNull(_appSelectionRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ProfileCapabilitiesTable, List<ProfileCapability>>
  _profileCapabilitiesRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.profileCapabilities,
        aliasName: 'server_profiles__id__profile_capabilities__profile_id',
      );

  $$ProfileCapabilitiesTableProcessedTableManager get profileCapabilitiesRefs {
    final manager = $$ProfileCapabilitiesTableTableManager(
      $_db,
      $_db.profileCapabilities,
    ).filter((f) => f.profileId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _profileCapabilitiesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ServerProfilesTableFilterComposer
    extends Composer<_$AppDatabase, $ServerProfilesTable> {
  $$ServerProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get originalHostInput => $composableBuilder(
    column: $table.originalHostInput,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get normalizedEndpoint => $composableBuilder(
    column: $table.normalizedEndpoint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastKnownVersion => $composableBuilder(
    column: $table.lastKnownVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> appSelectionRefs(
    Expression<bool> Function($$AppSelectionTableFilterComposer f) f,
  ) {
    final $$AppSelectionTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.appSelection,
      getReferencedColumn: (t) => t.selectedProfileId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AppSelectionTableFilterComposer(
            $db: $db,
            $table: $db.appSelection,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> profileCapabilitiesRefs(
    Expression<bool> Function($$ProfileCapabilitiesTableFilterComposer f) f,
  ) {
    final $$ProfileCapabilitiesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.profileCapabilities,
      getReferencedColumn: (t) => t.profileId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProfileCapabilitiesTableFilterComposer(
            $db: $db,
            $table: $db.profileCapabilities,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ServerProfilesTableOrderingComposer
    extends Composer<_$AppDatabase, $ServerProfilesTable> {
  $$ServerProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get originalHostInput => $composableBuilder(
    column: $table.originalHostInput,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get normalizedEndpoint => $composableBuilder(
    column: $table.normalizedEndpoint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastKnownVersion => $composableBuilder(
    column: $table.lastKnownVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ServerProfilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ServerProfilesTable> {
  $$ServerProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get originalHostInput => $composableBuilder(
    column: $table.originalHostInput,
    builder: (column) => column,
  );

  GeneratedColumn<String> get normalizedEndpoint => $composableBuilder(
    column: $table.normalizedEndpoint,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastKnownVersion => $composableBuilder(
    column: $table.lastKnownVersion,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAtMs => $composableBuilder(
    column: $table.createdAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  Expression<T> appSelectionRefs<T extends Object>(
    Expression<T> Function($$AppSelectionTableAnnotationComposer a) f,
  ) {
    final $$AppSelectionTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.appSelection,
      getReferencedColumn: (t) => t.selectedProfileId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AppSelectionTableAnnotationComposer(
            $db: $db,
            $table: $db.appSelection,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> profileCapabilitiesRefs<T extends Object>(
    Expression<T> Function($$ProfileCapabilitiesTableAnnotationComposer a) f,
  ) {
    final $$ProfileCapabilitiesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.profileCapabilities,
          getReferencedColumn: (t) => t.profileId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ProfileCapabilitiesTableAnnotationComposer(
                $db: $db,
                $table: $db.profileCapabilities,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$ServerProfilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ServerProfilesTable,
          StoredServerProfile,
          $$ServerProfilesTableFilterComposer,
          $$ServerProfilesTableOrderingComposer,
          $$ServerProfilesTableAnnotationComposer,
          $$ServerProfilesTableCreateCompanionBuilder,
          $$ServerProfilesTableUpdateCompanionBuilder,
          (StoredServerProfile, $$ServerProfilesTableReferences),
          StoredServerProfile,
          PrefetchHooks Function({
            bool appSelectionRefs,
            bool profileCapabilitiesRefs,
          })
        > {
  $$ServerProfilesTableTableManager(
    _$AppDatabase db,
    $ServerProfilesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ServerProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ServerProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ServerProfilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> originalHostInput = const Value.absent(),
                Value<String> normalizedEndpoint = const Value.absent(),
                Value<String> lastKnownVersion = const Value.absent(),
                Value<int> createdAtMs = const Value.absent(),
                Value<int> updatedAtMs = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ServerProfilesCompanion(
                id: id,
                displayName: displayName,
                originalHostInput: originalHostInput,
                normalizedEndpoint: normalizedEndpoint,
                lastKnownVersion: lastKnownVersion,
                createdAtMs: createdAtMs,
                updatedAtMs: updatedAtMs,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String displayName,
                required String originalHostInput,
                required String normalizedEndpoint,
                required String lastKnownVersion,
                required int createdAtMs,
                required int updatedAtMs,
                required int sortOrder,
                Value<int> rowid = const Value.absent(),
              }) => ServerProfilesCompanion.insert(
                id: id,
                displayName: displayName,
                originalHostInput: originalHostInput,
                normalizedEndpoint: normalizedEndpoint,
                lastKnownVersion: lastKnownVersion,
                createdAtMs: createdAtMs,
                updatedAtMs: updatedAtMs,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ServerProfilesTable, StoredServerProfile>(table),
                  $$ServerProfilesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({appSelectionRefs = false, profileCapabilitiesRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (appSelectionRefs) db.appSelection,
                    if (profileCapabilitiesRefs) db.profileCapabilities,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (appSelectionRefs)
                        await $_getPrefetchedData<
                          StoredServerProfile,
                          $ServerProfilesTable,
                          AppSelectionData
                        >(
                          currentTable: table,
                          referencedTable: $$ServerProfilesTableReferences
                              ._appSelectionRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ServerProfilesTableReferences(
                                db,
                                table,
                                p0,
                              ).appSelectionRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.selectedProfileId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (profileCapabilitiesRefs)
                        await $_getPrefetchedData<
                          StoredServerProfile,
                          $ServerProfilesTable,
                          ProfileCapability
                        >(
                          currentTable: table,
                          referencedTable: $$ServerProfilesTableReferences
                              ._profileCapabilitiesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ServerProfilesTableReferences(
                                db,
                                table,
                                p0,
                              ).profileCapabilitiesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.profileId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$ServerProfilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ServerProfilesTable,
      StoredServerProfile,
      $$ServerProfilesTableFilterComposer,
      $$ServerProfilesTableOrderingComposer,
      $$ServerProfilesTableAnnotationComposer,
      $$ServerProfilesTableCreateCompanionBuilder,
      $$ServerProfilesTableUpdateCompanionBuilder,
      (StoredServerProfile, $$ServerProfilesTableReferences),
      StoredServerProfile,
      PrefetchHooks Function({
        bool appSelectionRefs,
        bool profileCapabilitiesRefs,
      })
    >;
typedef $$AppSelectionTableCreateCompanionBuilder =
    AppSelectionCompanion Function({
      Value<int> singletonId,
      Value<String?> selectedProfileId,
    });
typedef $$AppSelectionTableUpdateCompanionBuilder =
    AppSelectionCompanion Function({
      Value<int> singletonId,
      Value<String?> selectedProfileId,
    });

final class $$AppSelectionTableReferences
    extends
        BaseReferences<_$AppDatabase, $AppSelectionTable, AppSelectionData> {
  $$AppSelectionTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ServerProfilesTable _selectedProfileIdTable(_$AppDatabase db) => db
      .serverProfiles
      .createAlias('app_selection__selected_profile_id__server_profiles__id');

  $$ServerProfilesTableProcessedTableManager? get selectedProfileId {
    final $_column = $_itemColumn<String>('selected_profile_id');
    if ($_column == null) return null;
    final manager = $$ServerProfilesTableTableManager(
      $_db,
      $_db.serverProfiles,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_selectedProfileIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$AppSelectionTableFilterComposer
    extends Composer<_$AppDatabase, $AppSelectionTable> {
  $$AppSelectionTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get singletonId => $composableBuilder(
    column: $table.singletonId,
    builder: (column) => ColumnFilters(column),
  );

  $$ServerProfilesTableFilterComposer get selectedProfileId {
    final $$ServerProfilesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.selectedProfileId,
      referencedTable: $db.serverProfiles,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerProfilesTableFilterComposer(
            $db: $db,
            $table: $db.serverProfiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AppSelectionTableOrderingComposer
    extends Composer<_$AppDatabase, $AppSelectionTable> {
  $$AppSelectionTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get singletonId => $composableBuilder(
    column: $table.singletonId,
    builder: (column) => ColumnOrderings(column),
  );

  $$ServerProfilesTableOrderingComposer get selectedProfileId {
    final $$ServerProfilesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.selectedProfileId,
      referencedTable: $db.serverProfiles,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerProfilesTableOrderingComposer(
            $db: $db,
            $table: $db.serverProfiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AppSelectionTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppSelectionTable> {
  $$AppSelectionTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get singletonId => $composableBuilder(
    column: $table.singletonId,
    builder: (column) => column,
  );

  $$ServerProfilesTableAnnotationComposer get selectedProfileId {
    final $$ServerProfilesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.selectedProfileId,
      referencedTable: $db.serverProfiles,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerProfilesTableAnnotationComposer(
            $db: $db,
            $table: $db.serverProfiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AppSelectionTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppSelectionTable,
          AppSelectionData,
          $$AppSelectionTableFilterComposer,
          $$AppSelectionTableOrderingComposer,
          $$AppSelectionTableAnnotationComposer,
          $$AppSelectionTableCreateCompanionBuilder,
          $$AppSelectionTableUpdateCompanionBuilder,
          (AppSelectionData, $$AppSelectionTableReferences),
          AppSelectionData,
          PrefetchHooks Function({bool selectedProfileId})
        > {
  $$AppSelectionTableTableManager(_$AppDatabase db, $AppSelectionTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppSelectionTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppSelectionTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppSelectionTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> singletonId = const Value.absent(),
                Value<String?> selectedProfileId = const Value.absent(),
              }) => AppSelectionCompanion(
                singletonId: singletonId,
                selectedProfileId: selectedProfileId,
              ),
          createCompanionCallback:
              ({
                Value<int> singletonId = const Value.absent(),
                Value<String?> selectedProfileId = const Value.absent(),
              }) => AppSelectionCompanion.insert(
                singletonId: singletonId,
                selectedProfileId: selectedProfileId,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AppSelectionTable, AppSelectionData>(table),
                  $$AppSelectionTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({selectedProfileId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (selectedProfileId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.selectedProfileId,
                        referencedTable: $$AppSelectionTableReferences
                            ._selectedProfileIdTable(db),
                        referencedColumn: $$AppSelectionTableReferences
                            ._selectedProfileIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$AppSelectionTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppSelectionTable,
      AppSelectionData,
      $$AppSelectionTableFilterComposer,
      $$AppSelectionTableOrderingComposer,
      $$AppSelectionTableAnnotationComposer,
      $$AppSelectionTableCreateCompanionBuilder,
      $$AppSelectionTableUpdateCompanionBuilder,
      (AppSelectionData, $$AppSelectionTableReferences),
      AppSelectionData,
      PrefetchHooks Function({bool selectedProfileId})
    >;
typedef $$ProfileCapabilitiesTableCreateCompanionBuilder =
    ProfileCapabilitiesCompanion Function({
      required String profileId,
      required String methodName,
      required int observedAtMs,
      required int expiresAtMs,
      Value<int> rowid,
    });
typedef $$ProfileCapabilitiesTableUpdateCompanionBuilder =
    ProfileCapabilitiesCompanion Function({
      Value<String> profileId,
      Value<String> methodName,
      Value<int> observedAtMs,
      Value<int> expiresAtMs,
      Value<int> rowid,
    });

final class $$ProfileCapabilitiesTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $ProfileCapabilitiesTable,
          ProfileCapability
        > {
  $$ProfileCapabilitiesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $ServerProfilesTable _profileIdTable(_$AppDatabase db) => db
      .serverProfiles
      .createAlias('profile_capabilities__profile_id__server_profiles__id');

  $$ServerProfilesTableProcessedTableManager get profileId {
    final $_column = $_itemColumn<String>('profile_id')!;

    final manager = $$ServerProfilesTableTableManager(
      $_db,
      $_db.serverProfiles,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_profileIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ProfileCapabilitiesTableFilterComposer
    extends Composer<_$AppDatabase, $ProfileCapabilitiesTable> {
  $$ProfileCapabilitiesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get methodName => $composableBuilder(
    column: $table.methodName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get observedAtMs => $composableBuilder(
    column: $table.observedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get expiresAtMs => $composableBuilder(
    column: $table.expiresAtMs,
    builder: (column) => ColumnFilters(column),
  );

  $$ServerProfilesTableFilterComposer get profileId {
    final $$ServerProfilesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.profileId,
      referencedTable: $db.serverProfiles,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerProfilesTableFilterComposer(
            $db: $db,
            $table: $db.serverProfiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProfileCapabilitiesTableOrderingComposer
    extends Composer<_$AppDatabase, $ProfileCapabilitiesTable> {
  $$ProfileCapabilitiesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get methodName => $composableBuilder(
    column: $table.methodName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get observedAtMs => $composableBuilder(
    column: $table.observedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get expiresAtMs => $composableBuilder(
    column: $table.expiresAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  $$ServerProfilesTableOrderingComposer get profileId {
    final $$ServerProfilesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.profileId,
      referencedTable: $db.serverProfiles,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerProfilesTableOrderingComposer(
            $db: $db,
            $table: $db.serverProfiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProfileCapabilitiesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProfileCapabilitiesTable> {
  $$ProfileCapabilitiesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get methodName => $composableBuilder(
    column: $table.methodName,
    builder: (column) => column,
  );

  GeneratedColumn<int> get observedAtMs => $composableBuilder(
    column: $table.observedAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get expiresAtMs => $composableBuilder(
    column: $table.expiresAtMs,
    builder: (column) => column,
  );

  $$ServerProfilesTableAnnotationComposer get profileId {
    final $$ServerProfilesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.profileId,
      referencedTable: $db.serverProfiles,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerProfilesTableAnnotationComposer(
            $db: $db,
            $table: $db.serverProfiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProfileCapabilitiesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProfileCapabilitiesTable,
          ProfileCapability,
          $$ProfileCapabilitiesTableFilterComposer,
          $$ProfileCapabilitiesTableOrderingComposer,
          $$ProfileCapabilitiesTableAnnotationComposer,
          $$ProfileCapabilitiesTableCreateCompanionBuilder,
          $$ProfileCapabilitiesTableUpdateCompanionBuilder,
          (ProfileCapability, $$ProfileCapabilitiesTableReferences),
          ProfileCapability,
          PrefetchHooks Function({bool profileId})
        > {
  $$ProfileCapabilitiesTableTableManager(
    _$AppDatabase db,
    $ProfileCapabilitiesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProfileCapabilitiesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProfileCapabilitiesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ProfileCapabilitiesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<String> methodName = const Value.absent(),
                Value<int> observedAtMs = const Value.absent(),
                Value<int> expiresAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfileCapabilitiesCompanion(
                profileId: profileId,
                methodName: methodName,
                observedAtMs: observedAtMs,
                expiresAtMs: expiresAtMs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required String methodName,
                required int observedAtMs,
                required int expiresAtMs,
                Value<int> rowid = const Value.absent(),
              }) => ProfileCapabilitiesCompanion.insert(
                profileId: profileId,
                methodName: methodName,
                observedAtMs: observedAtMs,
                expiresAtMs: expiresAtMs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ProfileCapabilitiesTable, ProfileCapability>(
                    table,
                  ),
                  $$ProfileCapabilitiesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({profileId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (profileId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.profileId,
                        referencedTable: $$ProfileCapabilitiesTableReferences
                            ._profileIdTable(db),
                        referencedColumn: $$ProfileCapabilitiesTableReferences
                            ._profileIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ProfileCapabilitiesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProfileCapabilitiesTable,
      ProfileCapability,
      $$ProfileCapabilitiesTableFilterComposer,
      $$ProfileCapabilitiesTableOrderingComposer,
      $$ProfileCapabilitiesTableAnnotationComposer,
      $$ProfileCapabilitiesTableCreateCompanionBuilder,
      $$ProfileCapabilitiesTableUpdateCompanionBuilder,
      (ProfileCapability, $$ProfileCapabilitiesTableReferences),
      ProfileCapability,
      PrefetchHooks Function({bool profileId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ServerProfilesTableTableManager get serverProfiles =>
      $$ServerProfilesTableTableManager(_db, _db.serverProfiles);
  $$AppSelectionTableTableManager get appSelection =>
      $$AppSelectionTableTableManager(_db, _db.appSelection);
  $$ProfileCapabilitiesTableTableManager get profileCapabilities =>
      $$ProfileCapabilitiesTableTableManager(_db, _db.profileCapabilities);
}
