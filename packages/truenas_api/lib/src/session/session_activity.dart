part of 'true_nas_session_repository.dart';

/// Activity exposes only an explicit safe projection, never job arguments,
/// results, credentials, log excerpts or audit event/service payloads.
abstract interface class AuthenticatedActivitySession {
  ActivityCapabilities get activityCapabilities;
  Future<JobPage> loadActivityJobs(JobQuery query);
  Future<AuditPage> loadAuditEvents(AuditQuery query);
  Future<JobCancelResult> cancelActivityJob(
    ActivityJob job,
    String confirmation,
  );
  Future<JobCancelResult> checkActivityCancellation(ActivityJob job);
}

final class ActivityCapabilities {
  const ActivityCapabilities({
    required this.supported,
    required this.canReadJobs,
    required this.canCancelJobs,
    required this.canReadAudit,
  });
  const ActivityCapabilities.disconnected()
    : supported = false,
      canReadJobs = false,
      canCancelJobs = false,
      canReadAudit = false;
  final bool supported, canReadJobs, canCancelJobs, canReadAudit;
}

enum ActivityJobState { waiting, running, success, failed, aborted }

final class ActivityJob {
  const ActivityJob({
    required this.id,
    required this.method,
    required this.state,
    required this.abortable,
    this.progressPercent,
    this.startedAt,
    this.finishedAt,
  });
  final int id;
  final String method;
  final ActivityJobState state;
  final bool abortable;
  final double? progressPercent;
  final DateTime? startedAt, finishedAt;
  bool get active =>
      state == ActivityJobState.waiting || state == ActivityJobState.running;
  bool get canCancel => active && abortable && startedAt != null;
  String get confirmation => 'job $id';
}

final class JobQuery {
  const JobQuery({this.state, this.method = '', this.page = 0});
  final ActivityJobState? state;
  final String method;
  final int page;
  bool get valid =>
      page >= 0 && page < 40 && (method.isEmpty || _activityMethod(method));
  @override
  bool operator ==(Object other) =>
      other is JobQuery &&
      state == other.state &&
      method == other.method &&
      page == other.page;
  @override
  int get hashCode => Object.hash(state, method, page);
}

final class JobPage {
  JobPage({required List<ActivityJob> entries, required this.hasMore})
    : entries = List.unmodifiable(entries);
  final List<ActivityJob> entries;
  final bool hasMore;
}

enum AuditService { middleware, smb, sudo, system }

/// A fixed UTC interval keeps new events from shifting later pages. Audit
/// retention may still remove old rows; the UI never describes this as a total.
final class AuditQuery {
  const AuditQuery({
    required this.from,
    required this.until,
    this.service = AuditService.middleware,
    this.username = '',
    this.success,
    this.page = 0,
  });
  final DateTime from, until;
  final AuditService service;
  final String username;
  final bool? success;
  final int page;
  bool get valid =>
      from.isUtc &&
      until.isUtc &&
      from.millisecondsSinceEpoch >= 0 &&
      until.isAfter(from) &&
      until.difference(from) <= const Duration(days: 31) &&
      username.length <= 64 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(username) &&
      page >= 0 &&
      page < 40;
  @override
  bool operator ==(Object other) =>
      other is AuditQuery &&
      from == other.from &&
      until == other.until &&
      service == other.service &&
      username == other.username &&
      success == other.success &&
      page == other.page;
  @override
  int get hashCode =>
      Object.hash(from, until, service, username, success, page);
}

final class AuditEvent {
  const AuditEvent({
    required this.id,
    required this.timestamp,
    required this.username,
    required this.address,
    required this.service,
    required this.event,
    required this.success,
    this.method,
  });
  final String id, username, address, event;
  final String? method;
  final DateTime timestamp;
  final AuditService service;
  final bool success;
}

final class AuditPage {
  AuditPage({required List<AuditEvent> entries, required this.hasMore})
    : entries = List.unmodifiable(entries);
  final List<AuditEvent> entries;
  final bool hasMore;
}

enum JobCancelOutcome { pending, verified, rejected, unknown }

final class JobCancelResult {
  const JobCancelResult(this.outcome, this.message, {this.job});
  final JobCancelOutcome outcome;
  final String message;
  final ActivityJob? job;
}

enum ActivityExceptionReason { disconnected, unavailable, busy, invalid, stale }

final class ActivityException implements Exception {
  const ActivityException(this.reason);
  final ActivityExceptionReason reason;
  String get userMessage => switch (reason) {
    ActivityExceptionReason.disconnected =>
      'Connect to a supported stable TrueNAS 25.10 server.',
    ActivityExceptionReason.unavailable => 'Activity could not be loaded with this account. Remote details are withheld.',
    ActivityExceptionReason.busy =>
      'Another change or unresolved cancellation is in progress.',
    ActivityExceptionReason.invalid =>
      'The activity query or server response could not be verified.',
    ActivityExceptionReason.stale => 'This job changed or belongs to a previous inventory. Reload and review again.',
  };
  @override
  String toString() => userMessage;
}

const _activityJobFields = [
  'id',
  'method',
  'state',
  'abortable',
  'progress.percent',
  'time_started',
  'time_finished',
];
const _activityAuditFields = [
  'audit_id',
  'message_timestamp',
  'timestamp',
  'username',
  'address',
  'service',
  'event',
  'success',
];

final class _SessionActivity {
  _SessionActivity({
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
  final bool Function() isCurrent, isOtherBusy;
  final Duration requestTimeout;
  final bool versionSupported;
  final Set<String> methods;
  final Set<ActivityJob> _issued = {};
  bool _submitting = false, _loading = false, _unknown = false;
  ActivityJob? _pending;
  bool get isBusy => _submitting || _unknown || _pending != null;
  ActivityCapabilities get capabilities {
    final supported = isCurrent() && versionSupported;
    return ActivityCapabilities(
      supported: supported,
      canReadJobs: supported && methods.contains('core.get_jobs'),
      canCancelJobs:
          supported && methods.containsAll(['core.get_jobs', 'core.job_abort']),
      canReadAudit: supported && methods.contains('audit.query'),
    );
  }

  void _guard(String method) {
    if (!isCurrent() || !versionSupported) {
      throw const ActivityException(ActivityExceptionReason.disconnected);
    }
    if (!methods.contains(method)) {
      throw const ActivityException(ActivityExceptionReason.unavailable);
    }
  }

  Future<Object?> _call(String method, List<Object?> params) async {
    _guard(method);
    final result = await client
        .call(method, params: params, id: nextId())
        .timeout(requestTimeout);
    _guard(method);
    return result;
  }

  Future<JobPage> jobs(JobQuery query) async {
    _guard('core.get_jobs');
    if (!query.valid) {
      throw const ActivityException(ActivityExceptionReason.invalid);
    }
    if (_loading || _submitting) {
      throw const ActivityException(ActivityExceptionReason.busy);
    }
    _loading = true;
    _issued.clear();
    try {
      final raw = await _call('core.get_jobs', [
        [
          if (query.state != null)
            ['state', '=', query.state!.name.toUpperCase()],
          if (query.method.isNotEmpty) ['method', '=', query.method],
        ],
        {
          'select': _activityJobFields,
          'extra': {'raw_result': false},
          'order_by': ['-id'],
          'offset': query.page * 25,
          'limit': 26,
        },
      ]);
      if (raw is! List || raw.length > 26) _activityInvalid();
      final rows = raw.map(_activityJob).toList();
      final ids = <int>{};
      for (final row in rows) {
        if (!ids.add(row.id) ||
            (query.state != null && row.state != query.state) ||
            (query.method.isNotEmpty && row.method != query.method)) {
          _activityInvalid();
        }
      }
      final visible = rows.take(25).toList();
      _issued.addAll(visible);
      return JobPage(entries: visible, hasMore: rows.length > 25);
    } on ActivityException {
      rethrow;
    } on Object {
      throw const ActivityException(ActivityExceptionReason.unavailable);
    } finally {
      _loading = false;
    }
  }

  Future<AuditPage> audit(AuditQuery query) async {
    _guard('audit.query');
    if (!query.valid) {
      throw const ActivityException(ActivityExceptionReason.invalid);
    }
    try {
      final from = query.from.millisecondsSinceEpoch ~/ 1000;
      final until = query.until.millisecondsSinceEpoch ~/ 1000;
      final raw = await _call('audit.query', [
        {
          'services': [query.service.name.toUpperCase()],
          'remote_controller': false,
          'query-filters': [
            ['message_timestamp', '>=', from],
            ['message_timestamp', '<', until],
            if (query.username.isNotEmpty) ['username', '=', query.username],
            if (query.success != null) ['success', '=', query.success],
          ],
          'query-options': {
            'select': [
              ..._activityAuditFields,
              if (query.service == AuditService.middleware)
                ['event_data.method', 'method'],
            ],
            'order_by': ['-message_timestamp', '-audit_id'],
            'offset': query.page * 25,
            'limit': 26,
            'force_sql_filters': true,
          },
        },
      ]);
      if (raw is! List || raw.length > 26) _activityInvalid();
      final rows = <AuditEvent>[];
      final ids = <String>{};
      for (final value in raw) {
        if (value is! Map ||
            value['message_timestamp'] is! int ||
            value['success'] is! bool ||
            value['service'] != query.service.name.toUpperCase()) {
          _activityInvalid();
        }
        final seconds = value['message_timestamp'] as int;
        final rawId = value['audit_id'];
        final id = rawId == null
            ? 'Unavailable'
            : rawId is int && rawId >= 0 && rawId <= 9007199254740991
            ? rawId.toString()
            : _activityText(rawId, 128);
        final username = _activityText(
          value['username'],
          256,
          allowEmpty: true,
        );
        if (seconds < from ||
            seconds >= until ||
            (rawId != null && !ids.add(id)) ||
            (query.username.isNotEmpty && username != query.username) ||
            (query.success != null && value['success'] != query.success)) {
          _activityInvalid();
        }
        final timestamp = _activityTime(value['timestamp']);
        if (timestamp == null) _activityInvalid();
        rows.add(
          AuditEvent(
            id: id,
            timestamp: timestamp,
            username: username,
            address: _activityText(value['address'], 128, allowEmpty: true),
            service: query.service,
            event: _activityText(value['event'], 128),
            success: value['success'] as bool,
            method:
                query.service == AuditService.middleware &&
                    value['event'] == 'METHOD_CALL' &&
                    value['method'] is String &&
                    _activityMethod(value['method'] as String)
                ? value['method'] as String
                : null,
          ),
        );
      }
      return AuditPage(
        entries: rows.take(25).toList(),
        hasMore: rows.length > 25,
      );
    } on ActivityException {
      rethrow;
    } on Object {
      throw const ActivityException(ActivityExceptionReason.unavailable);
    }
  }

  Future<ActivityJob?> _exact(ActivityJob job) async {
    final raw = await _call('core.get_jobs', [
      [
        ['id', '=', job.id],
      ],
      {
        'select': _activityJobFields,
        'limit': 2,
        'extra': {'raw_result': false},
      },
    ]);
    if (raw is! List || raw.length > 1) _activityInvalid();
    if (raw.isEmpty) return null;
    final fresh = _activityJob(raw.single);
    if (fresh.id != job.id ||
        fresh.method != job.method ||
        fresh.startedAt != job.startedAt) {
      throw const ActivityException(ActivityExceptionReason.stale);
    }
    return fresh;
  }

  Future<JobCancelResult> cancel(ActivityJob job, String confirmation) async {
    _guard('core.job_abort');
    _guard('core.get_jobs');
    if (isBusy || isOtherBusy() || _loading) {
      throw const ActivityException(ActivityExceptionReason.busy);
    }
    if (!_issued.contains(job) ||
        !job.canCancel ||
        confirmation != job.confirmation) {
      throw const ActivityException(ActivityExceptionReason.stale);
    }
    _submitting = true;
    var sent = false;
    try {
      final fresh = await _exact(job);
      if (fresh == null || !fresh.canCancel) {
        throw const ActivityException(ActivityExceptionReason.stale);
      }
      _guard('core.job_abort');
      if (isOtherBusy()) {
        throw const ActivityException(ActivityExceptionReason.busy);
      }
      _issued.remove(job);
      sent = true;
      final receipt = await _call('core.job_abort', [job.id]);
      if (receipt != null) return _uncertain();
      _pending = job;
      return await _readCancellation(job);
    } on Object {
      return sent
          ? _uncertain()
          : const JobCancelResult(
              JobCancelOutcome.rejected,
              'The job could not be revalidated. No cancellation was sent.',
            );
    } finally {
      _submitting = false;
    }
  }

  Future<JobCancelResult> check(ActivityJob job) async {
    _guard('core.get_jobs');
    if (!identical(job, _pending) || _unknown) {
      throw const ActivityException(ActivityExceptionReason.stale);
    }
    if (_submitting || isOtherBusy()) {
      throw const ActivityException(ActivityExceptionReason.busy);
    }
    _submitting = true;
    try {
      return await _readCancellation(job);
    } on Object {
      return _uncertain();
    } finally {
      _submitting = false;
    }
  }

  Future<JobCancelResult> _readCancellation(ActivityJob job) async {
    final after = await _exact(job);
    if (after == null) return _uncertain();
    if (after.active) {
      return JobCancelResult(
        JobCancelOutcome.pending,
        'Cancellation requested. The job is still ${after.state.name}. Check status; do not send another cancellation.',
        job: job,
      );
    }
    _pending = null;
    return JobCancelResult(
      JobCancelOutcome.verified,
      after.state == ActivityJobState.aborted
          ? 'The job is now ABORTED. Work already performed is not rolled back. Verify the affected service; this does not prove that all external or threaded side effects stopped.'
          : 'The job finished as ${after.state.name.toUpperCase()} before cancellation was observed. Work already performed is not rolled back.',
    );
  }

  JobCancelResult _uncertain() {
    _unknown = true;
    return const JobCancelResult(
      JobCancelOutcome.unknown,
      'Cancellation outcome is unknown. Do not retry. Inspect the original server and reconnect before making more changes.',
    );
  }
}

Never _activityInvalid() =>
    throw const ActivityException(ActivityExceptionReason.invalid);
bool _activityMethod(String value) =>
    value.length <= 160 &&
    RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)+$')
        .hasMatch(value);
String _activityText(Object? value, int max, {bool allowEmpty = false}) {
  if (value is! String ||
      value.length > max ||
      (!allowEmpty && value.isEmpty) ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    _activityInvalid();
  }
  return value;
}

DateTime? _activityTime(Object? value) {
  if (value == null) return null;
  // TrueNAS wire dates are extended JSON or ISO-8601, never local-time guesses.
  if (value is Map && value.length == 1 && value[r'$date'] is int) {
    final ms = value[r'$date'] as int;
    if (ms < 0 || ms > 253402300799999) _activityInvalid();
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
  if (value is! String ||
      value.length > 40 ||
      !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value)) {
    _activityInvalid();
  }
  final date = DateTime.tryParse(value);
  if (date == null || date.year < 1970 || date.year > 9999) _activityInvalid();
  return date.toUtc();
}

ActivityJob _activityJob(Object? value) {
  if (value is! Map || value['id'] is! int || value['abortable'] is! bool) {
    _activityInvalid();
  }
  final id = value['id'] as int;
  if (id <= 0 || id > 9007199254740991) _activityInvalid();
  final method = _activityText(value['method'], 160);
  if (!_activityMethod(method)) _activityInvalid();
  final state = ActivityJobState.values
      .where((s) => s.name.toUpperCase() == value['state'])
      .firstOrNull;
  if (state == null) _activityInvalid();
  final progress = value['progress'];
  final percent = progress is Map ? progress['percent'] : null;
  if (percent != null &&
      (percent is! num || !percent.isFinite || percent < 0 || percent > 100)) {
    _activityInvalid();
  }
  return ActivityJob(
    id: id,
    method: method,
    state: state,
    abortable: value['abortable'] as bool,
    progressPercent: (percent as num?)?.toDouble(),
    startedAt: _activityTime(value['time_started']),
    finishedAt: _activityTime(value['time_finished']),
  );
}
