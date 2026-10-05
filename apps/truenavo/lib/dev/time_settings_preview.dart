import 'package:truenas_api/truenas_api.dart';

/// Synthetic configuration only. No connector, clock read, probe or writer.
mixin TimeSettingsPreviewAdapter implements AuthenticatedTimeSettingsSession {
  static final _inventory = TimeSettingsInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    hostId: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    bootId: '12345678-1234-4234-8234-123456789abc',
    currentVersion: '25.10.1',
    state: 'READY',
    fullAdmin: true,
    failoverLicensed: false,
    conflictingJob: false,
    bootPool: 'boot-pool',
    bootHealthy: true,
    environments: const [
      BootEnvironmentSnapshot(
        id: '25.10.1',
        dataset: 'boot-pool/ROOT/25.10.1',
        created: '2026-09-01T10:00:00',
        usedBytes: 4294967296,
        active: true,
        activated: true,
        keep: true,
        canActivate: true,
      ),
    ],
    timezone: 'Asia/Seoul',
    timezones: const [
      'America/Los_Angeles',
      'Asia/Seoul',
      'Europe/London',
      'UTC',
    ],
    guiRollbackKnown: true,
    servers: const [
      NtpServerSnapshot(
        id: 1,
        settings: NtpServerSettings(address: 'time-a.example', prefer: true),
      ),
      NtpServerSnapshot(
        id: 2,
        settings: NtpServerSettings(
          address: 'time-b.example',
          minPoll: 7,
          maxPoll: 11,
        ),
      ),
      NtpServerSnapshot(
        id: 3,
        settings: NtpServerSettings(
          address: 'time-c.example',
          minPoll: 8,
          maxPoll: 12,
        ),
      ),
    ],
  );

  @override
  TimeSettingsCapabilities get timeSettingsCapabilities =>
      const TimeSettingsCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canChangeTimezone: true,
        canCreateNtp: true,
        canUpdateNtp: true,
        canDeleteNtp: true,
      );

  @override
  Future<TimeSettingsInventory> loadTimeSettings() async => _inventory;

  @override
  Future<TimeSettingsReview> reviewTimeSettings(
    TimeSettingsRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const TimeSettingsException(
        TimeSettingsExceptionReason.invalidRequest,
      );
    }
    return TimeSettingsReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: [
        'SAMPLE ONLY. No server connection, DNS lookup, NTP probe, clock change or service restart occurs.',
        if (request.action == TimeSettingsAction.timezone)
          'Real timezone changes affect scheduled work, replication timezone configuration and local timestamp interpretation. TrueNAS reloads time services, restarts cron and starts SSL service after writing configuration.'
        else if (request.action == TimeSettingsAction.deleteNtp)
          'Real deletion removes this configured source and restarts ntpd. Another configured row is not proof of a working time source.'
        else
          'Real creation or update always makes TrueNAS probe the destination over IPv4, even for options-only edits, and then restarts ntpd. Force is false. Burst is intended only for controlled/private time servers.',
        'Charts describe configured API rows and nominal polling intervals, not live synchronization or complete effective sources; DHCP and sources.d entries are not included.',
        'A post-dispatch error can follow a saved change. Do not retry an uncertain action; independently inspect the original server.',
      ],
    );
  }

  @override
  Future<TimeSettingsResult> executeTimeSettings(
    TimeSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => const TimeSettingsResult(
    TimeSettingsOutcome.rejected,
    'Sample preview: no time settings, destination probe or service change was performed.',
  );
}
