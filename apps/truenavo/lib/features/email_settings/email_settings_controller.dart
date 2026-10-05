import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final emailSettingsSessionProvider =
    Provider<AuthenticatedEmailSettingsSession?>((ref) {
      final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repo is AuthenticatedEmailSettingsSession
          ? repo as AuthenticatedEmailSettingsSession
          : null;
    });
final emailSettingsInventoryProvider = FutureProvider<EmailSettingsInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider),
      api = ref.watch(emailSettingsSessionProvider);
  if (session?.endpoint == null ||
      api == null ||
      ref.read(emailSettingsControllerProvider).locked) {
    throw StateError('Current email configuration is unavailable.');
  }
  final inventory = await api.loadEmailSettings();
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      inventory.endpoint != session!.endpoint) {
    throw StateError('Email settings connection changed.');
  }
  return inventory;
}, retry: (_, _) => null);

enum EmailSettingsStatus {
  idle,
  reviewing,
  executing,
  pending,
  checking,
  completed,
  rejected,
  unknown,
}

final class EmailSettingsState {
  const EmailSettingsState({
    this.status = EmailSettingsStatus.idle,
    this.action,
    this.message,
    this.server,
    this.hostId,
    this.jobId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
  });
  final EmailSettingsStatus status;
  final EmailSettingsAction? action;
  final String? message, server, hostId, verificationMessage;
  final int? jobId;
  final bool connectionCurrent, verifying, hostVerified;
  bool get busy =>
      status == EmailSettingsStatus.reviewing ||
      status == EmailSettingsStatus.executing ||
      status == EmailSettingsStatus.checking;
  bool get pendingJob => status == EmailSettingsStatus.pending;
  bool get unresolved => status == EmailSettingsStatus.unknown;
  bool get locked =>
      status == EmailSettingsStatus.executing ||
      status == EmailSettingsStatus.checking ||
      pendingJob ||
      unresolved;
  EmailSettingsState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
  }) => EmailSettingsState(
    status: status,
    action: action,
    message: this.message,
    server: server,
    hostId: hostId,
    jobId: jobId,
    connectionCurrent: connectionCurrent,
    verifying: verifying,
    hostVerified: verified,
    verificationMessage: message,
  );
}

final emailSettingsControllerProvider =
    NotifierProvider<EmailSettingsController, EmailSettingsState>(
      EmailSettingsController.new,
    );

class EmailSettingsController extends Notifier<EmailSettingsState> {
  AuthenticatedSession? _reviewSession, _operationSession, _verifiedSession;
  EmailPasswordChange? _password;
  EmailSettingsInventory? _jobInventory;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0, _verificationGeneration = 0;
  bool _pending = false;
  final _issued = Expando<int>(), _used = Expando<bool>();
  bool isReviewCurrent(EmailSettingsReview review) =>
      _issued[review] == _generation &&
      _used[review] != true &&
      (review.request.password.action != EmailPasswordAction.replace ||
          !review.request.password.isDisposed);
  bool get _active =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool _route(bool Function() check) {
    try {
      return check();
    } on Object {
      return false;
    }
  }

  @override
  EmailSettingsState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expireContext();
      },
    );
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      expireContext();
      if (state.unresolved) {
        state = EmailSettingsState(
          status: EmailSettingsStatus.unknown,
          action: state.action,
          server: state.server,
          hostId: state.hostId,
          jobId: state.jobId,
          connectionCurrent: identical(_operationSession, next),
          message: 'The connection changed after an unverified email operation. Inspect the original server independently. No settings, password or test message is replayed. SMTP acceptance is not recipient delivery.',
        );
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _disposePassword();
      _release();
    });
    return const EmailSettingsState();
  }

  void _disposePassword() {
    _password?.dispose();
    _password = null;
  }

  EmailSettingsState _expiredState() => state.locked || _pending
      ? EmailSettingsState(
          status: EmailSettingsStatus.unknown,
          action: state.action,
          server: state.server,
          hostId: state.hostId,
          jobId: state.jobId,
          connectionCurrent: state.connectionCurrent,
          message: 'Email-operation authorization expired. Settings, authentication or message transmission may already have changed or started. New password input was discarded. Inspect the original server; do not resend or repeat the write.',
        )
      : const EmailSettingsState(
          status: EmailSettingsStatus.rejected,
          message: 'The email review expired and new password input was discarded. Reload and review again. Nothing is sent automatically.',
        );
  void expireContext() {
    if (!ref.mounted) return;
    _generation++;
    _verificationGeneration++;
    _verifiedSession = null;
    _reviewSession = null;
    _disposePassword();
    state = _expiredState();
  }

  void abandonRoute() {
    if (!ref.mounted) return;
    final generation = ++_generation;
    _verificationGeneration++;
    _verifiedSession = null;
    _reviewSession = null;
    _disposePassword();
    final next = _expiredState();
    scheduleMicrotask(() {
      if (ref.mounted && generation == _generation) state = next;
    });
  }

  void refreshConfiguration() {
    if (!ref.mounted || state.busy || state.locked) return;
    _generation++;
    _verificationGeneration++;
    _reviewSession = null;
    _verifiedSession = null;
    _disposePassword();
    _jobInventory = null;
    state = const EmailSettingsState();
    ref.invalidate(emailSettingsInventoryProvider);
  }

  Future<EmailSettingsReview?> review({
    required AuthenticatedSession expectedSession,
    required EmailSettingsRequest request,
    required bool Function() isRouteCurrent,
  }) async {
    final snapshot = ref.read(emailSettingsInventoryProvider),
        api = expectedSession.repository;
    if (state.busy ||
        state.locked ||
        !_active ||
        !_route(isRouteCurrent) ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, request.inventory) ||
        request.inventory.endpoint != expectedSession.endpoint ||
        request.validationError != null ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedEmailSettingsSession ||
        !(api as AuthenticatedEmailSettingsSession).emailSettingsCapabilities
            .supports(request.action)) {
      if (!identical(request.password, _password)) request.password.dispose();
      return null;
    }
    _disposePassword();
    _password = request.password;
    final generation = ++_generation;
    _reviewSession = expectedSession;
    state = const EmailSettingsState(
      status: EmailSettingsStatus.reviewing,
      message: 'Reviewing email configuration and readiness. No SMTP test or configuration write has started.',
    );
    try {
      final review = await (api as AuthenticatedEmailSettingsSession)
          .reviewEmailSettings(request);
      if (!ref.mounted || generation != _generation) {
        request.password.dispose();
        return null;
      }
      final current = ref.read(emailSettingsInventoryProvider);
      if (!_active ||
          !_route(isRouteCurrent) ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          ) ||
          current.isLoading ||
          !identical(current.asData?.value, request.inventory)) {
        expireContext();
        return null;
      }
      if (!identical(review.request, request) ||
          review.endpoint != expectedSession.endpoint ||
          request.password.action == EmailPasswordAction.replace &&
              request.password.isDisposed) {
        throw StateError('Mismatched email review.');
      }
      _issued[review] = generation;
      state = const EmailSettingsState();
      return review;
    } on Object {
      request.password.dispose();
      if (ref.mounted && generation == _generation) {
        _generation++;
        _reviewSession = null;
        _disposePassword();
        state = const EmailSettingsState(
          status: EmailSettingsStatus.rejected,
          message: 'Email-settings review could not be verified. Remote details were withheld and new password input was discarded. Reload before a new review.',
        );
      }
      return null;
    }
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required EmailSettingsReview review,
    required String confirmation,
    required bool serverContactAccepted,
    required bool queuedMailImpactAccepted,
    required bool passwordClearAccepted,
    required bool testDisclosureAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    if (state.locked || state.busy || !isReviewCurrent(review)) return;
    final snapshot = ref.read(emailSettingsInventoryProvider),
        api = expectedSession.repository,
        action = review.request.action;
    if (!_active ||
        !_route(isRouteCurrent) ||
        !serverContactAccepted ||
        action == EmailSettingsAction.configure && !queuedMailImpactAccepted ||
        action == EmailSettingsAction.configure &&
            review.request.password.action == EmailPasswordAction.clear &&
            !passwordClearAccepted ||
        action == EmailSettingsAction.test && !testDisclosureAccepted ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, review.request.inventory) ||
        !identical(_reviewSession, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedEmailSettingsSession ||
        !(api as AuthenticatedEmailSettingsSession).emailSettingsCapabilities
            .supports(action)) {
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      expireContext();
      state = const EmailSettingsState(
        status: EmailSettingsStatus.rejected,
        message: 'Another management operation is unresolved. No email write or test was sent; new password input was discarded.',
      );
      return;
    }
    _used[review] = true;
    _pending = true;
    _operationSession = expectedSession;
    _jobInventory = review.request.inventory;
    final generation = ++_generation,
        server = expectedSession.endpoint,
        hostId = review.request.inventory.hostId;
    state = EmailSettingsState(
      status: EmailSettingsStatus.executing,
      action: action,
      server: server,
      hostId: hostId,
      message: action == EmailSettingsAction.test
          ? 'Submitting one explicit test using saved email settings. Network authentication and message transmission may begin. This is not a dry run.'
          : 'Submitting the reviewed SMTP settings. Database changes can precede later service or alert errors. This action does not itself send a test email.',
    );
    bool current() {
      if (!ref.mounted || generation != _generation) return false;
      final inventory = ref.read(emailSettingsInventoryProvider);
      if (!_active ||
          !_route(isRouteCurrent) ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          ) ||
          inventory.isLoading ||
          !identical(inventory.asData?.value, review.request.inventory)) {
        expireContext();
        return false;
      }
      return generation == _generation;
    }

    try {
      final result = await (api as AuthenticatedEmailSettingsSession)
          .executeEmailSettings(review, confirmation, isCurrent: current);
      if (!current()) return;
      final pending =
          action == EmailSettingsAction.test &&
          result.outcome == EmailSettingsOutcome.pending &&
          _validJob(result.jobId);
      final completed =
          result.outcome == EmailSettingsOutcome.completed &&
          action == EmailSettingsAction.configure &&
          result.jobId == null;
      final rejected = result.outcome == EmailSettingsOutcome.rejected;
      state = EmailSettingsState(
        status: pending
            ? EmailSettingsStatus.pending
            : completed
            ? EmailSettingsStatus.completed
            : rejected
            ? EmailSettingsStatus.rejected
            : EmailSettingsStatus.unknown,
        action: action,
        server: server,
        hostId: hostId,
        jobId: pending ? result.jobId : null,
        message: pending
            ? 'Test job accepted; SMTP success and recipient delivery are unverified. Check only this owned job explicitly. No automatic polling, retries, queueing or resend is performed by this test.'
            : completed
            ? 'Saved public SMTP fields were verified. The password is never returned or displayed. This is not an SMTP connectivity, certificate-validation or delivery test. Read fresh configuration explicitly before another action.'
            : rejected
            ? 'The reviewed email operation was rejected. No successful settings change, SMTP acceptance or delivery is claimed. Reload before another review.'
            : 'The email-operation outcome is unverified. Settings or message transmission may already have changed or started. Inspect the original server; do not repeat the write or resend.',
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = EmailSettingsState(
          status: EmailSettingsStatus.unknown,
          action: action,
          server: server,
          hostId: hostId,
          message: 'Email submission could not be verified. Details were withheld. Settings, SMTP authentication or transmission may already have occurred. Inspect the original server; do not retry or resend.',
        );
      }
    } finally {
      _pending = false;
      _reviewSession = null;
      _disposePassword();
      _settled();
    }
  }

  bool _validJob(int? job) => job != null && job > 0 && job <= 9007199254740991;
  void _settled() {
    if (!ref.mounted) return;
    if (!state.locked) {
      _release();
      _jobInventory = null;
    } else {
      state = state.verification(
        verifying: state.verifying,
        verified: state.hostVerified,
        message: state.verificationMessage,
      );
    }
  }

  bool get canCheckJob =>
      state.pendingJob &&
      !_pending &&
      state.connectionCurrent &&
      _validJob(state.jobId) &&
      identical(_operationSession, ref.read(dashboardActiveSessionProvider));
  Future<void> checkJob({required bool Function() isRouteCurrent}) async {
    if (!canCheckJob || !_active || !_route(isRouteCurrent)) return;
    final session = _operationSession!,
        jobId = state.jobId!,
        api = ref.read(emailSettingsSessionProvider);
    if (api == null) return;
    final generation = ++_generation,
        server = state.server,
        hostId = state.hostId;
    _pending = true;
    state = EmailSettingsState(
      status: EmailSettingsStatus.checking,
      action: EmailSettingsAction.test,
      server: server,
      hostId: hostId,
      jobId: jobId,
      message: 'Reading the one owned test job once. No message is resent.',
    );
    bool current() {
      if (!ref.mounted || generation != _generation) return false;
      final inventory = ref.read(emailSettingsInventoryProvider);
      if (!_active ||
          !_route(isRouteCurrent) ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          inventory.isLoading ||
          !identical(inventory.asData?.value, _jobInventory)) {
        expireContext();
        return false;
      }
      return generation == _generation;
    }

    try {
      final result = await api.checkEmailSettingsJob(jobId, isCurrent: current);
      if (!current()) return;
      final matched = result.jobId == jobId;
      final pending = matched && result.outcome == EmailSettingsOutcome.pending;
      final completed =
          matched && result.outcome == EmailSettingsOutcome.completed;
      state = EmailSettingsState(
        status: pending
            ? EmailSettingsStatus.pending
            : completed
            ? EmailSettingsStatus.completed
            : EmailSettingsStatus.unknown,
        action: EmailSettingsAction.test,
        server: server,
        hostId: hostId,
        jobId: jobId,
        message: pending
            ? 'The owned test job is still pending. No automatic check or resend occurs.'
            : completed
            ? 'The owned SMTP test job reported success. This is not proof of recipient delivery, inbox placement or a validated SMTP certificate. No message is resent automatically.'
            : 'The owned test-job outcome is unverified. A message may already have left the server. Inspect the original server and recipient independently; do not resend.',
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = EmailSettingsState(
          status: EmailSettingsStatus.unknown,
          action: EmailSettingsAction.test,
          server: server,
          hostId: hostId,
          jobId: jobId,
          message: 'The owned email job could not be verified. Details were withheld. No retry, polling loop or resend is started. Inspect the original server independently.',
        );
      }
    } finally {
      _pending = false;
      _settled();
    }
  }

  bool get canVerifyReconnectedServer {
    final current = ref.read(dashboardActiveSessionProvider);
    return state.unresolved &&
        !state.verifying &&
        !state.connectionCurrent &&
        current?.endpoint == state.server &&
        !identical(current, _operationSession);
  }

  Future<void> verifyReconnectedServer() async {
    if (!canVerifyReconnectedServer || !_active) return;
    final session = ref.read(dashboardActiveSessionProvider)!,
        api = ref.read(emailSettingsSessionProvider);
    if (api == null) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    EmailSettingsInventory? inventory;
    try {
      inventory = await api.loadEmailSettings();
    } on Object {
      /* Fixed public result. */
    }
    if (!ref.mounted ||
        generation != _verificationGeneration ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final verified =
        inventory?.hostId == state.hostId &&
        inventory?.endpoint == state.server &&
        inventory?.readinessBlockedReason == null;
    _verifiedSession = verified ? session : null;
    state = state.verification(
      verified: verified,
      message: verified
          ? 'The claimed original host identifier and readiness match. This is not remote attestation, proof of the prior settings write or confirmation of email delivery. Inspect the configuration and any test-message effects independently.'
          : 'Original-host identity and readiness could not be verified. Details were withheld; management writes remain locked.',
    );
  }

  bool get canAcknowledge =>
      !_pending &&
      canVerifyReconnectedServer &&
      state.hostVerified &&
      identical(_verifiedSession, ref.read(dashboardActiveSessionProvider));
  void acknowledgeAfterReconnect() {
    if (!canAcknowledge || !_active) return;
    _release();
    _operationSession = null;
    _verifiedSession = null;
    _jobInventory = null;
    state = const EmailSettingsState(
      status: EmailSettingsStatus.rejected,
      message: 'Independent original-server inspection acknowledged. The prior operation remains unverified; no password, settings or test message is replayed.',
    );
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
