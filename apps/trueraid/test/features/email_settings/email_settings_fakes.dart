import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/email_settings/email_settings_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const emailEndpoint = 'wss://sample.example/api/current';
const emailHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const emailCaps = EmailSettingsCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canConfigure: true,
  canTest: true,
);
const emailSmtp = EmailSmtpSettings(
  fromEmail: 'nas@example.test',
  fromName: 'NAS Alerts',
  outgoingServer: 'smtp.example.test',
  username: 'smtp-user',
);
EmailSettingsInventory emailInventory({
  String endpoint = emailEndpoint,
  String hostId = emailHost,
  bool admin = true,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  String state = 'READY',
  bool nextChanged = false,
  bool oauth = false,
  bool? passwordPresent = true,
  EmailSmtpSettings settings = emailSmtp,
}) => EmailSettingsInventory(
  endpoint: endpoint,
  hostId: hostId,
  bootId: '12345678-1234-4234-8234-123456789abc',
  currentVersion: '25.10.1',
  state: state,
  fullAdmin: admin,
  failoverLicensed: ha,
  conflictingJob: jobs,
  bootPool: 'boot-pool',
  bootHealthy: healthy,
  config: EmailConfigSnapshot(
    id: 1,
    settings: settings,
    passwordPresent: passwordPresent,
    oauthPresent: oauth,
  ),
  environments: [
    BootEnvironmentSnapshot(
      id: '25.10.1',
      dataset: 'boot-pool/ROOT/25.10.1',
      created: '2026-09-01T10:00:00',
      usedBytes: 512,
      active: true,
      activated: !nextChanged,
      keep: true,
      canActivate: true,
    ),
    if (nextChanged)
      const BootEnvironmentSnapshot(
        id: '25.10.2',
        dataset: 'boot-pool/ROOT/25.10.2',
        created: '2026-09-10T10:00:00',
        usedBytes: 512,
        active: false,
        activated: true,
        keep: true,
        canActivate: true,
      ),
  ],
);
EmailSettingsRequest emailRequest(
  EmailSettingsInventory inventory,
  EmailSettingsAction action, {
  EmailPasswordChange password = const EmailPasswordChange.keep(),
  String recipient = 'recipient@example.test',
}) => EmailSettingsRequest(
  inventory: inventory,
  action: action,
  settings: action == EmailSettingsAction.configure
      ? EmailSmtpSettings(
          fromEmail: 'nas@example.test',
          fromName: 'Updated Alerts',
          outgoingServer: 'smtp-new.example.test',
          smtpAuth: password.action != EmailPasswordAction.clear,
          username: password.action == EmailPasswordAction.clear
              ? ''
              : 'smtp-user',
        )
      : null,
  password: password,
  recipient: action == EmailSettingsAction.test ? recipient : null,
);

class EmailFake
    implements SessionRepository, AuthenticatedEmailSettingsSession {
  EmailFake({EmailSettingsInventory? inventory, this.caps = emailCaps})
    : inventory = inventory ?? emailInventory();
  EmailSettingsInventory inventory;
  EmailSettingsCapabilities caps;
  int reads = 0, mutations = 0;
  final reviews = <EmailSettingsRequest>[],
      executes = <EmailSettingsReview>[],
      checks = <int>[];
  Future<EmailSettingsInventory> Function()? onLoad;
  Future<EmailSettingsReview> Function(EmailSettingsRequest)? onReview;
  Future<EmailSettingsResult> Function(EmailSettingsReview, bool Function())?
  onExecute;
  Future<EmailSettingsResult> Function(int, bool Function())? onCheck;
  @override
  EmailSettingsCapabilities get emailSettingsCapabilities => caps;
  @override
  Future<EmailSettingsInventory> loadEmailSettings() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<EmailSettingsReview> reviewEmailSettings(
    EmailSettingsRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        EmailSettingsReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const [
            'Synthetic review only. No actual SMTP configuration or transmission.',
          ],
        );
  }

  @override
  Future<EmailSettingsResult> executeEmailSettings(
    EmailSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    executes.add(review);
    try {
      if (onExecute != null) return await onExecute!(review, isCurrent);
      if (isCurrent()) mutations++;
      return EmailSettingsResult(
        review.action == EmailSettingsAction.test
            ? EmailSettingsOutcome.pending
            : EmailSettingsOutcome.completed,
        'Synthetic result',
        jobId: review.action == EmailSettingsAction.test ? 51 : null,
      );
    } finally {
      review.request.password.dispose();
    }
  }

  @override
  Future<EmailSettingsResult> checkEmailSettingsJob(
    int jobId, {
    required bool Function() isCurrent,
  }) async {
    checks.add(jobId);
    if (onCheck != null) return onCheck!(jobId, isCurrent);
    return EmailSettingsResult(
      isCurrent()
          ? EmailSettingsOutcome.completed
          : EmailSettingsOutcome.unknown,
      'Synthetic owned job result',
      jobId: jobId,
    );
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnsupportedError('No connector in email fixtures.');
}

class EmailHarness {
  EmailHarness({EmailFake? fake}) : api = fake ?? EmailFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final EmailFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = emailEndpoint}) =>
      AuthenticatedSession(
        profileId: 'sample',
        repository: api,
        availableMethodNames: const {},
        version: '25.10.1',
        endpoint: endpoint,
      );
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  Future<void> load() => container.read(emailSettingsInventoryProvider.future);
  void dispose() => container.dispose();
}
