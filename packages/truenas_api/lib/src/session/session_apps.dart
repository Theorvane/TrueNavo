part of 'true_nas_session_repository.dart';

/// Native catalogue operations, deliberately separate from generic RPC access.
abstract interface class AuthenticatedAppsSession {
  AppsCapabilities get appsCapabilities;
  Future<AppsInventory> loadAppsInventory();
  Future<InstalledAppDetails> loadInstalledAppDetails(InstalledApp app);
  Future<List<String>> loadOutdatedAppImages(InstalledApp app);
  Future<List<CatalogApp>> loadAppsCatalog({bool cachedOnly = false});
  Future<List<String>> loadAppVersions(CatalogApp app);
  Future<AppVersionDetails> loadAppVersionDetails(
    CatalogApp app,
    String version,
  );
  Future<AppOperationResult> installApp(AppInstallRequest request);
  Future<AppOperationResult> changeAppState(
    InstalledApp app,
    AppLifecycleAction action,
  );
  Future<AppOperationResult> upgradeApp(AppUpgradeRequest request);
  Future<AppUpgradeReview> loadAppUpgradeReview(
    InstalledApp app,
    AppVersionDetails details,
  );
  Future<AppOperationResult> uninstallApp(AppUninstallRequest request);
  Future<AppConfigReview> loadAppConfigReview(InstalledApp app);
  Future<AppOperationResult> updateApp(AppConfigUpdateRequest request);
  Future<AppOperationResult> pollAppJob(AppJob job);
}

/// Optional, read-only catalogue settings for servers exposing both methods.
abstract interface class AuthenticatedCatalogOverviewSession {
  Future<CatalogOverview> loadCatalogOverview();
  Future<AppOperationResult> syncCatalog(CatalogOverview overview);
  Future<AppOperationResult> updateCatalogPreferredTrains(
    CatalogOverview overview,
    List<String> preferredTrains,
  );
}

final class CatalogOverview {
  CatalogOverview({
    required List<String> availableTrains,
    required List<String> preferredTrains,
  }) : availableTrains = List.unmodifiable(availableTrains),
       preferredTrains = List.unmodifiable(preferredTrains);

  final List<String> availableTrains;
  final List<String> preferredTrains;
}

final class AppsCapabilities {
  const AppsCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
  });
  const AppsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false;
  final bool connected;
  final bool versionSupported;
  final bool available;
  bool get supported => connected && versionSupported && available;
  String? get blockedReason => !connected
      ? 'Connect to a TrueNAS server to manage applications.'
      : !versionSupported
      ? 'Native application management requires a stable TrueNAS 25.10 release.'
      : !available
      ? 'This account does not expose the required application discovery and job methods.'
      : null;
}

final class AppsInventory {
  AppsInventory({
    required List<InstalledApp> apps,
    required this.pool,
    required this.dockerStatus,
    this.blockedReason,
  }) : apps = List.unmodifiable(apps);
  final List<InstalledApp> apps;
  final String? pool;
  final String dockerStatus;
  final String? blockedReason;
  bool get ready =>
      pool != null && dockerStatus == 'RUNNING' && blockedReason == null;
}

final class InstalledApp {
  const InstalledApp({
    required this.id,
    required this.name,
    required this.state,
    required this.version,
    required this.catalogApp,
    required this.train,
    required this.customApp,
    this.upgradeAvailable = false,
    this.latestVersion,
    this.imageUpdatesAvailable = false,
  });
  final String id;
  final String name;
  final String state;
  final String version;
  final String? catalogApp;
  final String? train;
  final bool customApp;
  final bool upgradeAvailable;
  final String? latestVersion;
  final bool imageUpdatesAvailable;
}

final class InstalledAppDetails {
  InstalledAppDetails({
    required this.app,
    required this.notes,
    required Map<String, String> portals,
    required this.workloads,
  }) : portals = Map.unmodifiable(portals);
  final InstalledApp app;
  final String? notes;
  final Map<String, String> portals;
  final InstalledAppWorkloads workloads;
}

final class InstalledAppWorkloads {
  const InstalledAppWorkloads({
    required this.runningContainers,
    required this.portMappings,
    required this.volumes,
    required this.images,
  });
  final int runningContainers;
  final int portMappings;
  final int volumes;
  final int images;
}

final class CatalogApp {
  CatalogApp({
    required this.name,
    required this.train,
    required this.title,
    required this.description,
    List<String> versions = const [],
    List<String> categories = const [],
    List<String> tags = const [],
    this.recommended = false,
    required this.healthy,
    required this.supported,
  }) : versions = List.unmodifiable(versions),
       categories = List.unmodifiable(categories),
       tags = List.unmodifiable(tags);
  final String name;
  final String train;
  final String title;
  final String description;
  final List<String> versions;
  final List<String> categories;
  final List<String> tags;
  final bool recommended;
  final bool healthy;
  final bool supported;
}

final class AppVersionDetails {
  AppVersionDetails({
    required this.app,
    required this.version,
    required this.humanVersion,
    required this.formSchema,
    required List<String> warnings,
    this.blockedReason,
  }) : warnings = List.unmodifiable(warnings);
  final CatalogApp app;
  final String version;
  final String humanVersion;
  final AppFormSchema formSchema;
  final List<String> warnings;
  final String? blockedReason;
  List<AdminParameter> get parameters => formSchema.parameters;
  AdminSchema get valuesSchema => formSchema.valuesSchema;
  bool get supported => blockedReason == null && formSchema.supported;
  bool get upgradeSupported => blockedReason == null;
}

/// A migration target and release notes issued for one installed application.
final class AppUpgradeReview {
  const AppUpgradeReview({
    required this.app,
    required this.details,
    required this.changelog,
    required this.humanVersion,
  });
  final InstalledApp app;
  final AppVersionDetails details;
  final String changelog;
  final String humanVersion;
}

final class AppInstallRequest {
  AppInstallRequest({
    required this.details,
    required this.appName,
    required Map<String, Object?> values,
  }) : values = _appsValues(values);
  final AppVersionDetails details;
  final String appName;
  final Map<String, Object?> values;
  @override
  String toString() => 'AppInstallRequest([redacted])';
}

final class AppUpgradeRequest {
  AppUpgradeRequest({
    required this.app,
    required this.details,
    this.review,
    Map<String, Object?> values = const {},
  }) : values = _appsValues(values);
  final InstalledApp app;
  final AppVersionDetails details;
  final AppUpgradeReview? review;
  final Map<String, Object?> values;
  @override
  String toString() => 'AppUpgradeRequest([redacted])';
}

final class AppUninstallRequest {
  const AppUninstallRequest({required this.app, required this.confirmedName});
  final InstalledApp app;
  final String confirmedName;
}

/// Only sanitized field metadata and non-secret current scalar values leave
/// the gateway. The raw app.config response is never attached to this review.
final class AppConfigReview {
  AppConfigReview({
    required this.app,
    required this.schema,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final InstalledApp app;
  final AppConfigSchema schema;
  final List<String> warnings;
  @override
  String toString() => 'AppConfigReview([redacted])';
}

final class AppConfigUpdateRequest {
  AppConfigUpdateRequest({
    required this.review,
    required List<AppConfigPatch> patches,
  }) : patches = List.unmodifiable(patches) {
    if (patches.isEmpty || patches.length > 128) {
      throw const AppsException(AppsExceptionReason.invalidInput);
    }
  }
  final AppConfigReview review;
  final List<AppConfigPatch> patches;
  @override
  String toString() => 'AppConfigUpdateRequest([redacted])';
}

enum AppLifecycleAction { start, stop, redeploy }

enum AppOperationOutcome {
  submitted,
  running,
  verified,
  failed,
  rejected,
  unknown,
}

/// Only the exact object issued by the active connection can be polled.
/// A job never retains configuration values, job results, logs or RPC errors.
final class AppJob {
  const AppJob({
    required this.id,
    required this.appName,
    required this.operation,
  });
  final int id;
  final String appName;
  final String operation;
}

final class AppOperationResult {
  const AppOperationResult({
    required this.outcome,
    this.job,
    this.progressPercent,
  });
  final AppOperationOutcome outcome;
  final AppJob? job;
  final double? progressPercent;
  String get userMessage => switch (outcome) {
    AppOperationOutcome.submitted => 'The server accepted the application job. Its result still needs verification.',
    AppOperationOutcome.running =>
      'The application operation is still running or settling on the server.',
    AppOperationOutcome.verified =>
      job == null
          ? 'The server settings change was confirmed by a fresh read.'
          : 'The server completed the job and the requested application state was verified.',
    AppOperationOutcome.failed => 'The server reported that the application job failed or was aborted. Reload its current state before another change.',
    AppOperationOutcome.rejected => 'The application, catalogue, form or application pool changed. Reload and review again.',
    AppOperationOutcome.unknown => 'The outcome could not be confirmed. Do not repeat the operation. Check TrueNAS, then reconnect before making another change.',
  };
}

enum AppsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  invalidInput,
  invalidResponse,
  staleSnapshot,
  busy,
  unavailable,
}

final class AppsException implements Exception {
  const AppsException(this.reason);
  final AppsExceptionReason reason;
  String get userMessage => switch (reason) {
    AppsExceptionReason.notAuthenticated =>
      'Reconnect before managing applications.',
    AppsExceptionReason.unsupportedVersion =>
      'Application management requires a stable TrueNAS 25.10 release.',
    AppsExceptionReason.unavailableMethod =>
      'The required application method is unavailable to this account.',
    AppsExceptionReason.invalidInput => 'Review a supported application version and valid configuration before continuing.',
    AppsExceptionReason.invalidResponse => 'The application identity or catalogue response could not be verified safely.',
    AppsExceptionReason.staleSnapshot => 'The connection or reviewed application changed. Reload and review again.',
    AppsExceptionReason.busy => 'Another server operation or an unconfirmed application job is in progress.',
    AppsExceptionReason.unavailable => 'Application data could not be loaded. Remote details have been withheld.',
  };
  @override
  String toString() => userMessage;
}

const _appsReadMethods = {
  'app.query',
  'catalog.apps',
  'catalog.get_app_details',
  'docker.status',
  'docker.config',
  'core.get_jobs',
  'app.used_ports',
};
const _appsReservedValues = {
  'ix_context',
  'ix_volumes',
  'ix_certificates',
  'ix_certificate_authorities',
};

final class _SessionApps {
  _SessionApps({
    required this.client,
    required ServerSummary summary,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherBusy,
    required this.requestTimeout,
  }) : versionSupported =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       methods = Set.unmodifiable(summary.availableMethodNames);
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent;
  final bool Function() isOtherBusy;
  final Duration requestTimeout;
  final bool versionSupported;
  final Set<String> methods;
  bool _reading = false;
  int _queuedReads = 0;
  Future<void> _readTail = Future<void>.value();
  bool _submitting = false;
  bool _polling = false;
  bool _uncertain = false;
  AppJob? _active;
  bool get isBusy => _submitting || _active != null || _uncertain;
  final _installed = <InstalledApp, _AppsEnvironment>{};
  final _catalog = <CatalogApp>{};
  final _catalogOverviews = <CatalogOverview, (String, String)>{};
  bool _catalogCachedOnly = false;
  final _versions = <AppVersionDetails, _AppsVersionObservation>{};
  final _upgradeReviews = <AppUpgradeReview, String>{};
  final _configReviews = <AppConfigReview, _AppsConfigObservation>{};
  final _jobs = <AppJob, _AppsJobObservation>{};
  final _catalogSyncJobs = <AppJob, AppOperationResult?>{};
  final _submitted = Expando<bool>();

  AppsCapabilities get capabilities => AppsCapabilities(
    connected: isCurrent(),
    versionSupported: versionSupported,
    available: methods.containsAll(_appsReadMethods),
  );

  void _guard([String? method]) {
    if (!isCurrent()) {
      throw const AppsException(AppsExceptionReason.notAuthenticated);
    }
    if (!versionSupported) {
      throw const AppsException(AppsExceptionReason.unsupportedVersion);
    }
    if (!methods.containsAll(_appsReadMethods) ||
        (method != null && !methods.contains(method))) {
      throw const AppsException(AppsExceptionReason.unavailableMethod);
    }
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    _guard(method);
    final result = await client
        .call(method, id: nextId(), params: args)
        .timeout(requestTimeout);
    if (!isCurrent()) {
      throw const AppsException(AppsExceptionReason.notAuthenticated);
    }
    return result;
  }

  Future<T> _read<T>(Future<T> Function() action) async {
    _guard();
    if (_submitting || _polling || _queuedReads >= 8) {
      throw const AppsException(AppsExceptionReason.busy);
    }
    _queuedReads++;
    final preceding = _readTail;
    final completed = Completer<void>();
    _readTail = completed.future;
    await preceding;
    try {
      _guard();
      if (_submitting || _polling) {
        throw const AppsException(AppsExceptionReason.busy);
      }
      _reading = true;
      return await action();
    } on AppsException {
      rethrow;
    } on Object {
      throw const AppsException(AppsExceptionReason.unavailable);
    } finally {
      _reading = false;
      _queuedReads--;
      completed.complete();
    }
  }

  Future<AppsInventory> loadInventory() => _read(() async {
    final environment = await _environment();
    final apps = await _inventory();
    _installed.clear();
    for (final app in apps) {
      _installed[app] = environment;
    }
    return AppsInventory(
      apps: apps,
      pool: environment.pool,
      dockerStatus: environment.status,
      blockedReason: environment.ready ? null : 'Configure an application pool and wait for the application service to be running in TrueNAS.',
    );
  });

  Future<InstalledAppDetails> loadInstalledDetails(InstalledApp app) =>
      _read(() async {
        if (!_installed.containsKey(app)) {
          throw const AppsException(AppsExceptionReason.staleSnapshot);
        }
        final raw = await _call('app.query', [
          [
            ['id', '=', app.id],
          ],
          {
            'limit': 2,
            'select': [
              'id',
              'name',
              'version',
              'notes',
              'portals',
              'active_workloads',
            ],
            'extra': {'retrieve_config': false, 'include_app_schema': false},
          },
        ]);
        if (raw is! List || raw.length != 1 || raw.single is! Map) {
          throw const AppsException(AppsExceptionReason.invalidResponse);
        }
        final row = raw.single as Map;
        if (row['id'] != app.id ||
            row['name'] != app.name ||
            row['version'] != app.version) {
          throw const AppsException(AppsExceptionReason.staleSnapshot);
        }
        final notes = row['notes'];
        if (notes != null && !_appsNotes(notes)) {
          throw const AppsException(AppsExceptionReason.invalidResponse);
        }
        final rawPortals = row['portals'];
        if (rawPortals is! Map || rawPortals.length > 8) {
          throw const AppsException(AppsExceptionReason.invalidResponse);
        }
        final portals = <String, String>{};
        for (final entry in rawPortals.entries) {
          if (!_appsText(entry.key, 64) || !_appsPortalUrl(entry.value)) {
            throw const AppsException(AppsExceptionReason.invalidResponse);
          }
          portals[entry.key as String] = entry.value as String;
        }
        final rawWorkloads = row['active_workloads'];
        if (rawWorkloads is! Map ||
            rawWorkloads['containers'] is! int ||
            (rawWorkloads['containers'] as int) < 0 ||
            (rawWorkloads['containers'] as int) > 1024 ||
            !_appsBoundedList(rawWorkloads['used_ports'], 2048) ||
            !_appsBoundedList(rawWorkloads['volumes'], 2048) ||
            !_appsBoundedList(rawWorkloads['images'], 512) ||
            !(rawWorkloads['used_ports'] as List).every((v) => v is Map) ||
            !(rawWorkloads['volumes'] as List).every((v) => v is Map) ||
            !(rawWorkloads['images'] as List).every((v) => _appsText(v, 512))) {
          throw const AppsException(AppsExceptionReason.invalidResponse);
        }
        return InstalledAppDetails(
          app: app,
          notes: notes as String?,
          portals: portals,
          workloads: InstalledAppWorkloads(
            runningContainers: rawWorkloads['containers'] as int,
            portMappings: (rawWorkloads['used_ports'] as List).length,
            volumes: (rawWorkloads['volumes'] as List).length,
            images: (rawWorkloads['images'] as List).length,
          ),
        );
      });

  Future<List<String>> loadOutdatedImages(InstalledApp app) => _read(() async {
    _guard('app.outdated_docker_images');
    if (!_installed.containsKey(app)) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    final current = await _call('app.query', [
      [
        ['id', '=', app.id],
      ],
      {
        'limit': 2,
        'select': ['id', 'name', 'version', 'image_updates_available'],
        'extra': {'retrieve_config': false, 'include_app_schema': false},
      },
    ]);
    if (current is! List ||
        current.length != 1 ||
        current.single is! Map ||
        (current.single as Map)['id'] != app.id ||
        (current.single as Map)['name'] != app.name ||
        (current.single as Map)['version'] != app.version ||
        (current.single as Map)['image_updates_available'] != true) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    final raw = await _call('app.outdated_docker_images', [app.name]);
    if (raw is! List || raw.length > 64) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    final images = <String>[];
    final seen = <String>{};
    for (final value in raw) {
      if (!_appsText(value, 512) || !seen.add(value as String)) {
        throw const AppsException(AppsExceptionReason.invalidResponse);
      }
      images.add(value);
    }
    return List.unmodifiable(images);
  });

  Future<List<CatalogApp>> loadCatalog({bool cachedOnly = false}) =>
      _read(() async {
        final raw = await _call('catalog.apps', [
          {
            'cache': true,
            'cache_only': cachedOnly,
            'retrieve_all_trains': true,
            'trains': <String>[],
          },
        ]);
        if (raw is! Map || raw.length > 32) {
          throw const AppsException(AppsExceptionReason.invalidResponse);
        }
        final result = <CatalogApp>[];
        for (final train in raw.entries) {
          if (!_appsToken(train.key, 64) || train.value is! Map) {
            throw const AppsException(AppsExceptionReason.invalidResponse);
          }
          for (final entry in (train.value as Map).entries) {
            if (result.length >= 2048 ||
                !_appsToken(entry.key, 128) ||
                entry.value is! Map) {
              throw const AppsException(AppsExceptionReason.invalidResponse);
            }
            final row = entry.value as Map;
            if (row['name'] != null && row['name'] != entry.key) {
              throw const AppsException(AppsExceptionReason.invalidResponse);
            }
            result.add(
              CatalogApp(
                name: entry.key as String,
                train: train.key as String,
                title: _appsDisplay(row['title'], 256) ?? entry.key as String,
                description: _appsDisplay(row['description'], 4096) ?? '',
                categories: _appsCatalogLabels(row['categories'], 16),
                tags: _appsCatalogLabels(row['tags'], 32),
                recommended: switch (row['recommended']) {
                  null => false,
                  bool value => value,
                  _ => throw const AppsException(
                    AppsExceptionReason.invalidResponse,
                  ),
                },
                healthy: row['healthy'] == true,
                supported: row['supported'] != false,
              ),
            );
          }
        }
        if ({for (final app in result) ...app.categories}.length > 64) {
          throw const AppsException(AppsExceptionReason.invalidResponse);
        }
        result.sort((a, b) {
          final title = a.title.compareTo(b.title);
          return title != 0 ? title : a.train.compareTo(b.train);
        });
        _catalog
          ..clear()
          ..addAll(result);
        _catalogCachedOnly = cachedOnly;
        _versions.clear();
        _upgradeReviews.clear();
        return List.unmodifiable(result);
      });

  Future<CatalogOverview> loadCatalogOverview() => _read(() async {
    final (overview, fingerprint, identity) = await _readCatalogOverview();
    _catalogOverviews.clear();
    _catalogOverviews[overview] = (fingerprint, identity);
    return overview;
  });

  Future<(CatalogOverview, String, String)> _readCatalogOverview() async {
    _guard('catalog.trains');
    _guard('catalog.config');
    final rawTrains = await _call('catalog.trains', []);
    final rawConfig = await _call('catalog.config', []);
    if (rawTrains is! List ||
        rawConfig is! Map ||
        !_appsToken(rawConfig['id'], 64) ||
        !_appsToken(rawConfig['label'], 64) ||
        !_appsText(rawConfig['location'], 2048) ||
        rawConfig['preferred_trains'] is! List) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    final trains = _catalogTrainList(rawTrains);
    final preferred = _catalogTrainList(rawConfig['preferred_trains'] as List);
    return (
      CatalogOverview(availableTrains: trains, preferredTrains: preferred),
      _appsFingerprint([
        rawConfig['id'],
        rawConfig['label'],
        rawConfig['location'],
        trains,
        preferred,
      ]),
      _appsFingerprint([
        rawConfig['id'],
        rawConfig['label'],
        rawConfig['location'],
      ]),
    );
  }

  Future<AppOperationResult> updatePreferredTrains(
    CatalogOverview overview,
    List<String> desired,
  ) async {
    final observed = _catalogOverviews[overview];
    if (observed == null ||
        desired.length > 32 ||
        desired.toSet().length != desired.length ||
        desired.any((train) => !overview.availableTrains.contains(train)) ||
        _appsFingerprint(desired) ==
            _appsFingerprint(overview.preferredTrains)) {
      return _rejected;
    }
    _begin(overview, 'catalog.update');
    var dispatched = false;
    try {
      final (fresh, fingerprint, _) = await _readCatalogOverview();
      if (fingerprint != observed.$1 ||
          desired.any((train) => !fresh.availableTrains.contains(train))) {
        return _rejected;
      }
      // A timeout or transport error after this point may still have applied
      // the update. Never replay it on this connection.
      dispatched = true;
      final raw = await _call('catalog.update', [
        {'preferred_trains': List<String>.of(desired)},
      ]);
      if (raw is! Map ||
          !_appsToken(raw['id'], 64) ||
          !_appsToken(raw['label'], 64) ||
          !_appsText(raw['location'], 2048) ||
          raw['preferred_trains'] is! List ||
          _appsFingerprint([raw['id'], raw['label'], raw['location']]) !=
              observed.$2 ||
          !_sameStrings(
            _catalogTrainList(raw['preferred_trains'] as List),
            desired,
          )) {
        return _unknown();
      }
      final (readback, _, readbackIdentity) = await _readCatalogOverview();
      if (!_sameStrings(readback.preferredTrains, desired) ||
          !_sameStrings(readback.availableTrains, fresh.availableTrains) ||
          readbackIdentity != observed.$2) {
        return _unknown();
      }
      _catalogOverviews.clear();
      _catalog.clear();
      _versions.clear();
      _upgradeReviews.clear();
      return const AppOperationResult(outcome: AppOperationOutcome.verified);
    } on AppsException {
      return dispatched ? _unknown() : _rejected;
    } on Object {
      return dispatched ? _unknown() : _rejected;
    } finally {
      _submitting = false;
    }
  }

  Future<AppOperationResult> syncCatalog(CatalogOverview overview) async {
    final observed = _catalogOverviews[overview];
    if (observed == null) return _rejected;
    _begin(overview, 'catalog.sync');
    var dispatched = false;
    try {
      final (_, fingerprint, _) = await _readCatalogOverview();
      if (fingerprint != observed.$1 || !isCurrent() || isOtherBusy()) {
        return _rejected;
      }
      dispatched = true;
      final raw = await _call('catalog.sync', []);
      if (raw is! int || raw < 1 || raw > 9007199254740991) {
        return _unknown();
      }
      final job = AppJob(
        id: raw,
        appName: 'catalog',
        operation: 'catalog.sync',
      );
      if (_catalogSyncJobs.length >= 64) {
        _catalogSyncJobs.remove(_catalogSyncJobs.keys.first);
      }
      _catalogSyncJobs[job] = null;
      _active = job;
      return AppOperationResult(
        outcome: AppOperationOutcome.submitted,
        job: job,
      );
    } on Object {
      return dispatched ? _unknown() : _rejected;
    } finally {
      _submitting = false;
    }
  }

  Future<AppOperationResult> _pollCatalogSync(AppJob job) async {
    if (!_catalogSyncJobs.containsKey(job) || !isCurrent()) {
      return const AppOperationResult(outcome: AppOperationOutcome.unknown);
    }
    final terminal = _catalogSyncJobs[job];
    if (terminal != null) return terminal;
    if (_uncertain) return _unknown(job);
    if (_polling || _submitting || _reading) {
      throw const AppsException(AppsExceptionReason.busy);
    }
    _polling = true;
    try {
      final raw = await _call('core.get_jobs', [
        [
          ['id', '=', job.id],
        ],
        {
          'limit': 2,
          'select': ['id', 'method', 'arguments', 'state', 'progress'],
          'extra': {'raw_result': false},
        },
      ]);
      if (raw is! List || raw.length != 1 || raw.single is! Map) {
        return _unknown(job);
      }
      final row = raw.single as Map;
      if (row['id'] != job.id ||
          row['method'] != 'catalog.sync' ||
          row['arguments'] is! List ||
          (row['arguments'] as List).isNotEmpty) {
        return _unknown(job);
      }
      final progress = row['progress'];
      final percent = progress is Map ? progress['percent'] : null;
      final safePercent =
          percent is num && percent.isFinite && percent >= 0 && percent <= 100
          ? percent.toDouble()
          : null;
      if (row['state'] == 'WAITING' || row['state'] == 'RUNNING') {
        return AppOperationResult(
          outcome: AppOperationOutcome.running,
          job: job,
          progressPercent: safePercent,
        );
      }
      if (row['state'] != 'SUCCESS' &&
          row['state'] != 'FAILED' &&
          row['state'] != 'ABORTED') {
        return _unknown(job);
      }
      if (row['state'] == 'SUCCESS') {
        // Job success is only exposed after a fresh, bounded catalogue read.
        await _readCatalogOverview();
      }
      _catalogOverviews.clear();
      _catalog.clear();
      _versions.clear();
      _upgradeReviews.clear();
      _active = null;
      return _catalogSyncJobs[job] = AppOperationResult(
        outcome: row['state'] == 'SUCCESS'
            ? AppOperationOutcome.verified
            : AppOperationOutcome.failed,
        job: job,
        progressPercent: row['state'] == 'SUCCESS' ? 100 : safePercent,
      );
    } on Object {
      return _unknown(job);
    } finally {
      _polling = false;
    }
  }

  Future<Map<String, Object?>> _catalogDetails(CatalogApp app) async {
    if (!_catalog.contains(app)) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    if (_catalogCachedOnly) {
      throw const AppsException(AppsExceptionReason.invalidInput);
    }
    final raw = await _call('catalog.get_app_details', [
      app.name,
      {'train': app.train},
    ]);
    if (raw is! Map ||
        (raw['name'] != null && raw['name'] != app.name) ||
        (raw['train'] != null && raw['train'] != app.train) ||
        raw['versions'] is! Map) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    final versions = raw['versions'] as Map;
    if (versions.isEmpty ||
        versions.length > 256 ||
        versions.keys.any((key) => !_appsVersion(key))) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    return Map<String, Object?>.from(versions);
  }

  Future<List<String>> versions(CatalogApp app) => _read(() async {
    final raw = await _catalogDetails(app);
    final result = raw.keys.toList()..sort((a, b) => _appsCompareVersion(b, a));
    return List.unmodifiable(result);
  });

  Future<AppVersionDetails> versionDetails(
    CatalogApp app,
    String version,
  ) => _read(() async {
    if (!_appsVersion(version)) {
      throw const AppsException(AppsExceptionReason.invalidInput);
    }
    final versions = await _catalogDetails(app);
    final raw = _versionRow(versions, version, app);
    final form = AppFormSchema.fromVersionDetails(raw);
    final blocked = raw['healthy'] != true || raw['supported'] != true
        ? 'This catalogue version is unhealthy or unsupported by this server.'
        : null;
    final result = AppVersionDetails(
      app: app,
      version: version,
      humanVersion: _appsDisplay(raw['human_version'], 256) ?? version,
      formSchema: form,
      warnings: [
        'Installing or upgrading an application can create datasets, expose network ports and run third-party containers.',
        ...form.warnings,
      ],
      blockedReason: blocked,
    );
    if (_versions.length >= 64) _versions.remove(_versions.keys.first);
    _versions[result] = _AppsVersionObservation(
      _appsFingerprint(raw),
      await _environment(),
    );
    return result;
  });

  Map<String, Object?> _versionRow(
    Map<String, Object?> versions,
    String version,
    CatalogApp app,
  ) {
    final raw = versions[version];
    if (raw is! Map || raw['version'] != version || raw['schema'] is! Map) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    final metadata = raw['app_metadata'];
    if (metadata is! Map ||
        metadata['name'] != app.name ||
        metadata['train'] != app.train ||
        metadata['version'] != version) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    return Map<String, Object?>.from(raw);
  }

  Future<_AppsEnvironment> _environment() async {
    final status = await _call('docker.status', const []);
    final config = await _call('docker.config', const []);
    if (status is! Map ||
        !const {
          'PENDING',
          'RUNNING',
          'STOPPED',
          'INITIALIZING',
          'STOPPING',
          'UNCONFIGURED',
          'FAILED',
        }.contains(status['status']) ||
        config is! Map ||
        (config['pool'] != null && !_appsText(config['pool'], 256))) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    return _AppsEnvironment(
      config['pool'] as String?,
      status['status'] as String,
    );
  }

  Future<List<InstalledApp>> _inventory({String? id}) async {
    final raw = await _call('app.query', [
      if (id == null)
        <Object?>[]
      else
        [
          ['id', '=', id],
        ],
      {
        'limit': id == null ? 1025 : 2,
        'select': [
          'id',
          'name',
          'state',
          'version',
          'custom_app',
          'metadata',
          'upgrade_available',
          'latest_version',
          'image_updates_available',
        ],
        'extra': {'retrieve_config': false, 'include_app_schema': false},
      },
    ]);
    if (raw is! List || raw.length > (id == null ? 1024 : 1)) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    final seen = <String>{};
    final result = <InstalledApp>[];
    for (final value in raw) {
      if (value is! Map ||
          !_appsName(value['id']) ||
          value['name'] != value['id'] ||
          !seen.add(value['id'] as String) ||
          !_appsVersion(value['version']) ||
          value['custom_app'] is! bool ||
          value['upgrade_available'] is! bool ||
          (value['latest_version'] != null &&
              !_appsVersion(value['latest_version'])) ||
          value['image_updates_available'] is! bool ||
          !const {
            'RUNNING',
            'STOPPED',
            'DEPLOYING',
            'CRASHED',
            'STOPPING',
          }.contains(value['state'])) {
        throw const AppsException(AppsExceptionReason.invalidResponse);
      }
      if (id != null && value['id'] != id) {
        throw const AppsException(AppsExceptionReason.invalidResponse);
      }
      final metadata = value['metadata'];
      final custom = value['custom_app'] == true;
      if (!custom &&
          (metadata is! Map ||
              !_appsToken(metadata['name'], 128) ||
              !_appsToken(metadata['train'], 64))) {
        throw const AppsException(AppsExceptionReason.invalidResponse);
      }
      result.add(
        InstalledApp(
          id: value['id'] as String,
          name: value['name'] as String,
          state: value['state'] as String,
          version: value['version'] as String,
          catalogApp: !custom ? (metadata as Map)['name'] as String : null,
          train: !custom ? (metadata as Map)['train'] as String : null,
          customApp: custom,
          upgradeAvailable: value['upgrade_available'] as bool,
          latestVersion: value['latest_version'] as String?,
          imageUpdatesAvailable: value['image_updates_available'] as bool,
        ),
      );
    }
    return result;
  }

  void _begin(Object handle, String method) {
    _guard(method);
    if (isBusy || isOtherBusy() || _queuedReads != 0 || _polling) {
      throw const AppsException(AppsExceptionReason.busy);
    }
    if (_submitted[handle] == true) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    _submitted[handle] = true;
    _submitting = true;
  }

  Future<bool> _freshVersion(
    AppVersionDetails details, {
    bool requireForm = true,
  }) async {
    final observation = _versions[details];
    if (observation == null ||
        !(requireForm ? details.supported : details.upgradeSupported) ||
        !_catalog.contains(details.app) ||
        !observation.environment.ready) {
      return false;
    }
    final environment = await _environment();
    if (!environment.ready ||
        environment.pool != observation.environment.pool) {
      return false;
    }
    final raw = _versionRow(
      await _catalogDetails(details.app),
      details.version,
      details.app,
    );
    return raw['healthy'] == true &&
        raw['supported'] == true &&
        observation.fingerprint == _appsFingerprint(raw);
  }

  Future<bool> _freshApp(InstalledApp app) async {
    final environment = _installed[app];
    if (environment == null || !environment.ready) return false;
    final currentEnvironment = await _environment();
    if (!currentEnvironment.ready ||
        currentEnvironment.pool != environment.pool) {
      return false;
    }
    final current = await _inventory(id: app.id);
    return current.length == 1 && _appsSameApp(app, current.single);
  }

  Map<String, Object?> _prepare(
    AppVersionDetails details,
    Map<String, Object?> values,
  ) {
    if (!details.supported ||
        values.keys.any(_appsReservedValues.contains) ||
        details.formSchema.validate(values) != null) {
      throw const AppsException(AppsExceptionReason.invalidInput);
    }
    try {
      return _appsValues(details.formSchema.buildValues(values));
    } on Object {
      throw const AppsException(AppsExceptionReason.invalidInput);
    }
  }

  Future<AppOperationResult> install(AppInstallRequest request) async {
    if (!_appsName(request.appName) ||
        !_versions.containsKey(request.details)) {
      throw const AppsException(AppsExceptionReason.invalidInput);
    }
    final values = _prepare(request.details, request.values);
    _begin(request, 'app.create');
    try {
      final environment = await _environment();
      final before = await _inventory();
      if (!environment.ready ||
          before.any((app) => app.id == request.appName) ||
          !await _freshVersion(request.details)) {
        return _rejected;
      }
      final ports = await _call('app.used_ports', const []);
      if (ports is! List ||
          ports.length > 65536 ||
          ports.any((port) => port is! int || port < 1 || port > 65535)) {
        return _rejected;
      }
      if (request.details.formSchema.portsFor(values).any(ports.contains)) {
        return _rejected;
      }
      final rechecked = await _environment();
      if (!rechecked.ready ||
          rechecked.pool != environment.pool ||
          (await _inventory(id: request.appName)).isNotEmpty) {
        return _rejected;
      }
      return await _submit(
        'app.create',
        request.appName,
        [
          {
            'app_name': request.appName,
            'catalog_app': request.details.app.name,
            'train': request.details.app.train,
            'version': request.details.version,
            'values': values,
            'custom_app': false,
          },
        ],
        _AppsJobObservation(
          pool: environment.pool!,
          version: request.details.version,
          catalogApp: request.details.app.name,
          train: request.details.app.train,
          state: 'RUNNING',
        ),
      );
    } on Object {
      return _rejected;
    } finally {
      _submitting = false;
    }
  }

  Future<AppOperationResult> changeState(
    InstalledApp app,
    AppLifecycleAction action,
  ) async {
    if (!_installed.containsKey(app)) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    final method = switch (action) {
      AppLifecycleAction.start => 'app.start',
      AppLifecycleAction.stop => 'app.stop',
      AppLifecycleAction.redeploy => 'app.redeploy',
    };
    final permitted = switch (action) {
      AppLifecycleAction.start => app.state == 'STOPPED',
      AppLifecycleAction.stop =>
        app.state == 'RUNNING' || app.state == 'CRASHED',
      AppLifecycleAction.redeploy =>
        app.state == 'RUNNING' || app.state == 'CRASHED',
    };
    if (!permitted) throw const AppsException(AppsExceptionReason.invalidInput);
    _begin(app, method);
    try {
      if (!await _freshApp(app)) return _rejected;
      return await _submit(
        method,
        app.id,
        [app.id],
        _AppsJobObservation(
          pool: _installed[app]!.pool!,
          version: app.version,
          catalogApp: app.catalogApp,
          train: app.train,
          customApp: app.customApp,
          state: action == AppLifecycleAction.stop ? 'STOPPED' : 'RUNNING',
        ),
      );
    } on Object {
      return _rejected;
    } finally {
      _submitting = false;
    }
  }

  void _configEligible(InstalledApp app) {
    if (!_installed.containsKey(app)) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    if (app.customApp || !const {'RUNNING', 'STOPPED'}.contains(app.state)) {
      throw const AppsException(AppsExceptionReason.invalidInput);
    }
    _guard('app.config');
  }

  Future<Map<String, Object?>> _installedSchema(InstalledApp app) async {
    final raw = await _call('app.query', [
      [
        ['id', '=', app.id],
      ],
      {
        'limit': 2,
        'select': [
          'id',
          'name',
          'state',
          'version',
          'custom_app',
          'metadata',
          'upgrade_available',
          'version_details',
        ],
        'extra': {'retrieve_config': false, 'include_app_schema': true},
      },
    ]);
    if (raw is! List || raw.length != 1 || raw.single is! Map) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    final row = raw.single as Map;
    final metadata = row['metadata'];
    if (row['id'] != app.id ||
        row['name'] != app.name ||
        row['state'] != app.state ||
        row['version'] != app.version ||
        row['custom_app'] != false ||
        row['upgrade_available'] != app.upgradeAvailable ||
        metadata is! Map ||
        metadata['name'] != app.catalogApp ||
        metadata['train'] != app.train) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    final catalogue = CatalogApp(
      name: app.catalogApp!,
      train: app.train!,
      title: app.catalogApp!,
      description: '',
      healthy: true,
      supported: true,
    );
    final details = _versionRow(
      {app.version: row['version_details']},
      app.version,
      catalogue,
    );
    if (details['healthy'] != true || details['supported'] != true) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    return details;
  }

  Future<Map<String, Object?>> _readConfig(String name) async {
    final raw = await _call('app.config', [name]);
    if (raw is! Map || raw.keys.any((key) => key is! String)) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    // These four server-owned normalization outputs are never editable input.
    final values = _appsValues({
      for (final entry in raw.entries)
        if (!_appsReservedValues.contains(entry.key))
          entry.key as String: entry.value,
    });
    if (!_appsExactConfigNumbers(values)) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    return values;
  }

  Future<AppConfigReview> configReview(InstalledApp app) => _read(() async {
    _configEligible(app);
    if (!await _freshApp(app)) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    final details = await _installedSchema(app);
    final values = await _readConfig(app.id);
    if (!await _freshApp(app)) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    final schema = AppConfigSchema.fromVersionDetails(
      details,
      currentValues: values,
    );
    final review = AppConfigReview(
      app: app,
      schema: schema,
      warnings: [
        'Changing settings can recreate running containers and interrupt the application.',
        'Only reviewed scalar settings can be changed. Stored secrets are never displayed, and unchanged settings are preserved.',
        'Avoid changing this app in other clients while applying settings. TrueNAS has no atomic configuration revision check.',
        ...schema.warnings,
        if (app.state == 'STOPPED') 'This application is stopped and will remain stopped after the configuration update.',
      ],
    );
    if (_configReviews.length >= 64) {
      _configReviews.remove(_configReviews.keys.first);
    }
    _configReviews[review] = _AppsConfigObservation(
      schema: _appsFingerprint(details),
      config: _appsFingerprint(values),
      pool: _installed[app]!.pool!,
    );
    return review;
  });

  Future<AppOperationResult> update(AppConfigUpdateRequest request) async {
    final review = request.review;
    final app = review.app;
    final observation = _configReviews[review];
    _configEligible(app);
    if (observation == null) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    if (!review.schema.supported ||
        review.schema.validatePatches(request.patches) != null) {
      throw const AppsException(AppsExceptionReason.invalidInput);
    }
    _begin(request, 'app.update');
    try {
      if (!await _freshApp(app) ||
          _appsFingerprint(await _installedSchema(app)) != observation.schema ||
          !await _freshApp(app)) {
        return _rejected;
      }
      final proposedPorts = review.schema.changedPorts(request.patches);
      if (proposedPorts.length != proposedPorts.toSet().length) {
        return _rejected;
      }
      if (proposedPorts.isNotEmpty) {
        final used = await _call('app.used_ports', const []);
        if (used is! List ||
            used.length > 65536 ||
            used.any((port) => port is! int || port < 1 || port > 65535) ||
            proposedPorts.any(used.contains)) {
          return _rejected;
        }
      }
      // This final read supplies both the freshness proof and the complete
      // original touched subtrees. Installer defaults are never merged here.
      final fresh = await _readConfig(app.id);
      if (_appsFingerprint(fresh) != observation.config) return _rejected;
      final changed = _appsValues(
        review.schema.applyPatches(fresh, request.patches),
      );
      if (changed.isEmpty ||
          changed.keys.any(_appsReservedValues.contains) ||
          !_appsExactConfigNumbers(changed)) {
        return _rejected;
      }
      final expected = _appsFingerprint({...fresh, ...changed});
      return await _submit(
        'app.update',
        app.id,
        [
          app.id,
          {'values': changed},
        ],
        _AppsJobObservation(
          pool: observation.pool,
          version: app.version,
          catalogApp: app.catalogApp,
          train: app.train,
          state: app.state,
          expectedConfig: expected,
        ),
      );
    } on Object {
      return _rejected;
    } finally {
      _submitting = false;
    }
  }

  void _upgradeEligible(InstalledApp app, AppVersionDetails details) {
    if (!_installed.containsKey(app) || !_versions.containsKey(details)) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    if (app.customApp ||
        !app.upgradeAvailable ||
        app.state != 'RUNNING' ||
        !details.upgradeSupported ||
        app.catalogApp != details.app.name ||
        app.train != details.app.train ||
        _appsCompareVersion(details.version, app.version) <= 0) {
      throw const AppsException(AppsExceptionReason.invalidInput);
    }
  }

  Future<Map<String, Object?>> _upgradeSummary(
    InstalledApp app,
    AppVersionDetails details,
  ) async {
    final raw = await _call('app.upgrade_summary', [
      app.id,
      {'app_version': details.version},
    ]);
    if (raw is! Map ||
        raw['upgrade_version'] != details.version ||
        !_appsVersion(raw['latest_version']) ||
        !_appsText(raw['upgrade_human_version'], 256) ||
        !_appsText(raw['latest_human_version'], 256) ||
        raw['available_versions_for_upgrade'] is! List ||
        !_appsReleaseNotes(raw['changelog'])) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    final available = raw['available_versions_for_upgrade'] as List;
    if (available.isEmpty ||
        available.length > 256 ||
        available.any(
          (item) =>
              item is! Map ||
              !_appsVersion(item['version']) ||
              !_appsText(item['human_version'], 256),
        ) ||
        !available.any((item) => (item as Map)['version'] == details.version)) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    return Map<String, Object?>.from(raw);
  }

  Future<AppUpgradeReview> upgradeReview(
    InstalledApp app,
    AppVersionDetails details,
  ) => _read(() async {
    _upgradeEligible(app, details);
    if (!await _freshApp(app) ||
        !await _freshVersion(details, requireForm: false)) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    final summary = await _upgradeSummary(app, details);
    final review = AppUpgradeReview(
      app: app,
      details: details,
      changelog: summary['changelog'] as String? ?? '',
      humanVersion: summary['upgrade_human_version'] as String,
    );
    if (_upgradeReviews.length >= 64) {
      _upgradeReviews.remove(_upgradeReviews.keys.first);
    }
    _upgradeReviews[review] = _appsFingerprint(summary);
    return review;
  });

  Future<AppOperationResult> upgrade(AppUpgradeRequest request) async {
    final app = request.app;
    final details = request.details;
    _upgradeEligible(app, details);
    if (request.values.isNotEmpty) {
      throw const AppsException(AppsExceptionReason.invalidInput);
    }
    final review = request.review;
    final summaryIdentity = _upgradeReviews[review];
    if (review == null ||
        summaryIdentity == null ||
        !identical(review.app, app) ||
        !identical(review.details, details)) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    _begin(request, 'app.upgrade');
    try {
      if (!await _freshApp(app) ||
          !await _freshVersion(details, requireForm: false) ||
          _appsFingerprint(await _upgradeSummary(app, details)) !=
              summaryIdentity ||
          !await _freshApp(app)) {
        return _rejected;
      }
      return await _submit(
        'app.upgrade',
        app.id,
        [
          app.id,
          {
            'app_version': details.version,
            // Middleware migrates existing configuration. Installer defaults
            // must never replace persisted nested storage or secret settings.
            'values': <String, Object?>{},
            'snapshot_hostpaths': false,
          },
        ],
        _AppsJobObservation(
          pool: _installed[app]!.pool!,
          version: details.version,
          catalogApp: app.catalogApp,
          train: app.train,
          state: 'RUNNING',
        ),
      );
    } on Object {
      return _rejected;
    } finally {
      _submitting = false;
    }
  }

  Future<AppOperationResult> uninstall(AppUninstallRequest request) async {
    final app = request.app;
    if (!_installed.containsKey(app)) {
      throw const AppsException(AppsExceptionReason.staleSnapshot);
    }
    if (request.confirmedName != app.name ||
        !{'RUNNING', 'STOPPED', 'CRASHED'}.contains(app.state)) {
      throw const AppsException(AppsExceptionReason.invalidInput);
    }
    _begin(request, 'app.delete');
    try {
      if (!await _freshApp(app)) return _rejected;
      return await _submit(
        'app.delete',
        app.id,
        [
          app.id,
          {
            'remove_images': false,
            'remove_ix_volumes': false,
            'force_remove_ix_volumes': false,
            'force_remove_custom_app': false,
          },
        ],
        _AppsJobObservation(
          pool: _installed[app]!.pool!,
          version: app.version,
          catalogApp: app.catalogApp,
          train: app.train,
          customApp: app.customApp,
          deleted: true,
        ),
      );
    } on Object {
      return _rejected;
    } finally {
      _submitting = false;
    }
  }

  Future<AppOperationResult> _submit(
    String method,
    String name,
    List<Object?> arguments,
    _AppsJobObservation observation,
  ) async {
    try {
      if (!isCurrent() || isOtherBusy()) return _rejected;
      final result = await _call(method, arguments);
      if (result is! int || result < 1 || result > 9007199254740991) {
        return _unknown();
      }
      final job = AppJob(id: result, appName: name, operation: method);
      if (_jobs.length >= 64) _jobs.remove(_jobs.keys.first);
      _jobs[job] = observation;
      _active = job;
      return AppOperationResult(
        outcome: AppOperationOutcome.submitted,
        job: job,
      );
    } on Object {
      return _unknown();
    }
  }

  Future<AppOperationResult> poll(AppJob job) async {
    if (job.operation == 'catalog.sync') return _pollCatalogSync(job);
    final observation = _jobs[job];
    if (observation == null || !isCurrent()) {
      return const AppOperationResult(outcome: AppOperationOutcome.unknown);
    }
    if (observation.terminal != null) return observation.terminal!;
    if (_uncertain) return _unknown(job);
    if (_polling || _submitting || _reading) {
      throw const AppsException(AppsExceptionReason.busy);
    }
    _polling = true;
    try {
      final raw = await _call('core.get_jobs', [
        [
          ['id', '=', job.id],
        ],
        {
          'limit': 2,
          'select': ['id', 'method', 'arguments', 'state', 'progress'],
          'extra': {'raw_result': false},
        },
      ]);
      if (raw is! List || raw.length != 1 || raw.single is! Map) {
        return _unknown(job);
      }
      final row = raw.single as Map;
      final args = row['arguments'];
      if (row['id'] != job.id ||
          row['method'] != job.operation ||
          !_appsJobArgumentsMatch(job, observation, args)) {
        return _unknown(job);
      }
      final progress = row['progress'];
      final percent = progress is Map ? progress['percent'] : null;
      final safePercent =
          percent is num && percent.isFinite && percent >= 0 && percent <= 100
          ? percent.toDouble()
          : null;
      if (row['state'] == 'WAITING' || row['state'] == 'RUNNING') {
        return AppOperationResult(
          outcome: AppOperationOutcome.running,
          job: job,
          progressPercent: safePercent,
        );
      }
      if (row['state'] == 'FAILED' || row['state'] == 'ABORTED') {
        // app.update persists configuration before rendering/recreating its
        // containers. A failed job can therefore have partially applied it.
        if (job.operation == 'app.update') return _unknown(job);
        _installed.clear();
        _active = null;
        return observation.terminal = AppOperationResult(
          outcome: AppOperationOutcome.failed,
          job: job,
        );
      }
      if (row['state'] != 'SUCCESS') return _unknown(job);
      final environment = await _environment();
      if (!environment.ready || environment.pool != observation.pool) {
        return _unknown(job);
      }
      final apps = await _inventory(id: job.appName);
      final identityMatches =
          apps.length == 1 &&
          apps.single.version == observation.version &&
          apps.single.catalogApp == observation.catalogApp &&
          apps.single.train == observation.train &&
          apps.single.customApp == observation.customApp;
      if (!observation.deleted &&
          identityMatches &&
          const {'DEPLOYING', 'STOPPING'}.contains(apps.single.state)) {
        return AppOperationResult(
          outcome: AppOperationOutcome.running,
          job: job,
          progressPercent: safePercent,
        );
      }
      final verified = observation.deleted
          ? apps.isEmpty
          : identityMatches &&
                (observation.state == null ||
                    apps.single.state == observation.state);
      if (!verified) return _unknown(job);
      if (observation.expectedConfig != null &&
          _appsFingerprint(await _readConfig(job.appName)) !=
              observation.expectedConfig) {
        return _unknown(job);
      }
      _active = null;
      _installed.clear();
      _configReviews.clear();
      return observation.terminal = AppOperationResult(
        outcome: AppOperationOutcome.verified,
        job: job,
        progressPercent: 100,
      );
    } on Object {
      return _unknown(job);
    } finally {
      _polling = false;
    }
  }

  AppOperationResult _unknown([AppJob? job]) {
    _uncertain = true;
    return AppOperationResult(outcome: AppOperationOutcome.unknown, job: job);
  }

  static const _rejected = AppOperationResult(
    outcome: AppOperationOutcome.rejected,
  );
}

final class _AppsEnvironment {
  const _AppsEnvironment(this.pool, this.status);
  final String? pool;
  final String status;
  bool get ready => pool != null && pool!.isNotEmpty && status == 'RUNNING';
}

final class _AppsVersionObservation {
  const _AppsVersionObservation(this.fingerprint, this.environment);
  final String fingerprint;
  final _AppsEnvironment environment;
}

final class _AppsConfigObservation {
  const _AppsConfigObservation({
    required this.schema,
    required this.config,
    required this.pool,
  });
  final String schema;
  final String config;
  final String pool;
}

final class _AppsJobObservation {
  _AppsJobObservation({
    required this.pool,
    required this.version,
    required this.catalogApp,
    required this.train,
    this.customApp = false,
    this.state,
    this.deleted = false,
    this.expectedConfig,
  });
  final String pool;
  final String version;
  final String? catalogApp;
  final String? train;
  final bool customApp;
  final String? state;
  final bool deleted;
  final String? expectedConfig;
  AppOperationResult? terminal;
}

bool _appsSameApp(InstalledApp a, InstalledApp b) =>
    a.id == b.id &&
    a.name == b.name &&
    a.state == b.state &&
    a.version == b.version &&
    a.catalogApp == b.catalogApp &&
    a.train == b.train &&
    a.customApp == b.customApp &&
    a.upgradeAvailable == b.upgradeAvailable;

bool _appsExactConfigNumbers(Object? value) {
  if (value is num) {
    return value.isFinite &&
        value >= -9007199254740991 &&
        value <= 9007199254740991;
  }
  if (value is Map) return value.values.every(_appsExactConfigNumbers);
  if (value is List) return value.every(_appsExactConfigNumbers);
  return true;
}

bool _appsReleaseNotes(Object? value) =>
    value == null ||
    value is String &&
        value.length <= 32768 &&
        !RegExp(
          r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]',
        ).hasMatch(value);
bool _appsJobArgumentsMatch(
  AppJob job,
  _AppsJobObservation observation,
  Object? arguments,
) {
  if (arguments is! List || arguments.isEmpty) return false;
  if (job.operation == 'app.create') {
    if (arguments.length != 1 || arguments.single is! Map) return false;
    final options = arguments.single as Map;
    return options['app_name'] == job.appName &&
        options['catalog_app'] == observation.catalogApp &&
        options['train'] == observation.train &&
        options['version'] == observation.version &&
        options['custom_app'] == false;
  }
  if (arguments.first != job.appName) return false;
  if (job.operation == 'app.update') {
    // Middleware may redact the Secret[dict] values, but not app identity.
    return arguments.length == 2 &&
        arguments[1] is Map &&
        (arguments[1] as Map).keys.toSet().difference({'values'}).isEmpty &&
        ((arguments[1] as Map)['values'] is Map ||
            (arguments[1] as Map)['values'] == '********');
  }
  if (job.operation == 'app.upgrade') {
    if (arguments.length != 2 || arguments[1] is! Map) return false;
    final options = arguments[1] as Map;
    return options['app_version'] == observation.version &&
        options['snapshot_hostpaths'] == false;
  }
  if (job.operation == 'app.delete') {
    if (arguments.length != 2 || arguments[1] is! Map) return false;
    final options = arguments[1] as Map;
    return const [
      'remove_images',
      'remove_ix_volumes',
      'force_remove_ix_volumes',
      'force_remove_custom_app',
    ].every((key) => options[key] == false);
  }
  return arguments.length == 1;
}

bool _appsText(Object? value, int max) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]')
        .hasMatch(value);
bool _appsNotes(Object? value) =>
    value is String &&
    value.length <= 4096 &&
    !RegExp(
      r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]',
    ).hasMatch(value);
bool _appsBoundedList(Object? value, int max) =>
    value is List && value.length <= max;
bool _appsPortalUrl(Object? value) {
  if (!_appsText(value, 2048)) return false;
  final uri = Uri.tryParse(value as String);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.hasAuthority &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

String? _appsDisplay(Object? value, int max) =>
    _appsText(value, max) ? value as String : null;
List<String> _catalogTrainList(List raw) {
  if (raw.length > 32) {
    throw const AppsException(AppsExceptionReason.invalidResponse);
  }
  final trains = <String>[];
  for (final value in raw) {
    if (!_appsToken(value, 64) || trains.contains(value)) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    trains.add(value as String);
  }
  return List.unmodifiable(trains);
}

bool _sameStrings(List<String> a, List<String> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => a[i] == b[i]).every((same) => same);

List<String> _appsCatalogLabels(Object? raw, int maximum) {
  if (raw == null) return const [];
  if (raw is! List || raw.length > maximum) {
    throw const AppsException(AppsExceptionReason.invalidResponse);
  }
  final labels = <String>[];
  for (final value in raw) {
    if (!_appsText(value, 64)) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    final label = value as String;
    if (!labels.contains(label)) labels.add(label);
  }
  return List.unmodifiable(labels);
}

bool _appsToken(Object? value, int max) =>
    _appsText(value, max) &&
    RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(value as String);
bool _appsName(Object? value) =>
    value is String &&
    value.length <= 40 &&
    RegExp(r'^[a-z]([-a-z0-9]*[a-z0-9])?$').hasMatch(value);
bool _appsVersion(Object? value) =>
    value is String &&
    value.length <= 64 &&
    RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value);
int _appsCompareVersion(String a, String b) {
  final aa = a.split('.').map(BigInt.parse).toList();
  final bb = b.split('.').map(BigInt.parse).toList();
  for (var i = 0; i < 3; i++) {
    final difference = aa[i].compareTo(bb[i]);
    if (difference != 0) return difference;
  }
  return 0;
}

Map<String, Object?> _appsValues(Map<String, Object?> values) {
  try {
    return (_adminRequestArguments([values]).single as Map)
        .cast<String, Object?>();
  } on Object {
    throw const AppsException(AppsExceptionReason.invalidInput);
  }
}

/// Bounded, opaque structural identity. No raw schema defaults or submitted
/// secrets are retained in version/job observations. Key order is irrelevant.
String _appsFingerprint(Object? value) {
  var first = 2166136261;
  var second = 5381;
  var nodes = 0;
  var characters = 0;
  void feed(String text) {
    if ((characters += text.length) > 262144) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    for (final unit in text.codeUnits) {
      first = ((first ^ unit) * 16777619) & 0xffffffff;
      second = ((second * 33) ^ unit) & 0xffffffff;
    }
  }

  void visit(Object? item, int depth) {
    if (++nodes > 16384 || depth > 24) {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
    if (item is Map) {
      if (item.keys.any((key) => key is! String)) {
        throw const AppsException(AppsExceptionReason.invalidResponse);
      }
      feed('{');
      final keys = item.keys.cast<String>().toList()..sort();
      for (final key in keys) {
        feed('${key.length}:$key');
        visit(item[key], depth + 1);
      }
      feed('}');
    } else if (item is List) {
      feed('[');
      for (final child in item) {
        visit(child, depth + 1);
      }
      feed(']');
    } else if (item == null || item is String || item is bool || item is num) {
      feed('${item.runtimeType}:${item.toString().length}:$item;');
    } else {
      throw const AppsException(AppsExceptionReason.invalidResponse);
    }
  }

  visit(value, 0);
  return '$first:$second:$nodes:$characters';
}
