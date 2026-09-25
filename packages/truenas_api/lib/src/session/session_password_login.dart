part of 'true_nas_session_repository.dart';

/// Additive capability: legacy API-key repositories need not accept passwords.
abstract interface class PasswordSessionRepository {
  Future<ServerSummary> connectWithPassword({
    required String serverInput,
    required String password,
    required String username,
    PasswordOtpResponder? onOtpRequired,
    bool Function()? isConnectionCurrent,
  });
}

typedef PasswordOtpResponder = Future<String?> Function(
  PasswordOtpChallenge challenge,
);

/// Display-safe, memory-only challenge for the same authenticated TLS channel.
/// Contains no password, OTP, redirect URLs or unfiltered server message.
final class PasswordOtpChallenge {
  const PasswordOtpChallenge({
    required this.endpoint,
    required this.username,
    required this.attempt,
    required this.expiresAt,
  });
  final String endpoint, username;
  final int attempt;
  final DateTime expiresAt;
}

enum PasswordLoginFailure {
  invalidPassword,
  invalidOtp,
  rejected,
  expired,
  cancelled,
  timeout,
  redirect,
  unsupported,
}

final class PasswordLoginException implements Exception {
  const PasswordLoginException(this.reason);
  final PasswordLoginFailure reason;
  String get userMessage => switch (reason) {
    PasswordLoginFailure.invalidPassword =>
      'Enter a password between 1 and 1024 characters. It is never stored.',
    PasswordLoginFailure.invalidOtp =>
      'Enter the exact 6–8 digit authenticator code, without spaces.',
    PasswordLoginFailure.rejected => 'Password or authenticator sign-in was rejected. Check the account and server authentication policy.',
    PasswordLoginFailure.expired =>
      'The password or authentication challenge expired. Start a new sign-in.',
    PasswordLoginFailure.cancelled => 'Authenticator sign-in was cancelled. No authenticated session was published.',
    PasswordLoginFailure.timeout => 'Sign-in timed out. The connection was closed; credentials were not retried.',
    PasswordLoginFailure.redirect => 'This server requires sign-in at another address. Credentials were not forwarded; enter the trusted active server address yourself.',
    PasswordLoginFailure.unsupported => 'This password/OTP response or release is not supported. No authenticated session was published.',
  };
  @override
  String toString() => userMessage;
}

void validateTrueNasPassword(String password) {
  if (password.isEmpty || password.length > 1024) {
    throw const PasswordLoginException(PasswordLoginFailure.invalidPassword);
  }
}

bool validTrueNasOtp(String value) => RegExp(r'^[0-9]{6,8}$').hasMatch(value);

Future<void> _passwordLogin({
  required JsonRpcClient client,
  required String Function() nextId,
  required void Function() requireCurrent,
  required String endpoint,
  required String username,
  required String password,
  required Duration requestTimeout,
  required Duration challengeTimeout,
  required PasswordOtpResponder? responder,
}) async {
  Future<Object?> call(String method, Map<String, Object?> payload) async {
    requireCurrent();
    final result = await client
        .call(method, id: nextId(), params: [payload])
        .timeout(requestTimeout);
    requireCurrent();
    if (!client.isOpen) {
      throw const PasswordLoginException(PasswordLoginFailure.cancelled);
    }
    return result;
  }

  try {
    var response = await call('auth.login_ex', {
      'mechanism': 'PASSWORD_PLAIN',
      'username': username,
      'password': password,
      'login_options': {'user_info': false},
    });
    String? challengeAccount;
    var attempt = 0;
    while (true) {
      if (response is! Map || response['response_type'] is! String) {
        throw const PasswordLoginException(PasswordLoginFailure.unsupported);
      }
      switch (response['response_type']) {
        case 'SUCCESS':
          // This reports the server assurance policy, not whether this user
          // just completed OTP. LEVEL_1 with an account's OTP is valid.
          if (!{'LEVEL_1', 'LEVEL_2'}.contains(response['authenticator'])) {
            throw const PasswordLoginException(
              PasswordLoginFailure.unsupported,
            );
          }
          return;
        case 'OTP_REQUIRED':
          if (responder == null || ++attempt > 3) {
            throw const PasswordLoginException(PasswordLoginFailure.rejected);
          }
          final rawAccount = response['username'];
          if (rawAccount is! String) {
            throw const PasswordLoginException(
              PasswordLoginFailure.unsupported,
            );
          }
          String normalized;
          try {
            normalized = validateTrueNasAccountName(rawAccount);
          } on Object {
            throw const PasswordLoginException(
              PasswordLoginFailure.unsupported,
            );
          }
          if (challengeAccount != null && challengeAccount != normalized) {
            throw const PasswordLoginException(
              PasswordLoginFailure.unsupported,
            );
          }
          challengeAccount = normalized;
          final token = await responder(
            PasswordOtpChallenge(
              endpoint: endpoint,
              username: normalized,
              attempt: attempt,
              expiresAt: DateTime.now().toUtc().add(challengeTimeout),
            ),
          ).timeout(challengeTimeout);
          requireCurrent();
          if (token == null) {
            throw const PasswordLoginException(PasswordLoginFailure.cancelled);
          }
          if (!validTrueNasOtp(token)) {
            throw const PasswordLoginException(PasswordLoginFailure.invalidOtp);
          }
          response = await call('auth.login_ex_continue', {
            'mechanism': 'OTP_TOKEN',
            'otp_token': token,
            'login_options': {'user_info': false},
          });
        case 'AUTH_ERR':
          throw const PasswordLoginException(PasswordLoginFailure.rejected);
        case 'EXPIRED':
          throw const PasswordLoginException(PasswordLoginFailure.expired);
        case 'REDIRECT':
          throw const PasswordLoginException(PasswordLoginFailure.redirect);
        default:
          throw const PasswordLoginException(PasswordLoginFailure.unsupported);
      }
    }
  } on PasswordLoginException {
    rethrow;
  } on CredentialUnavailableException {
    rethrow;
  } on TimeoutException {
    throw const PasswordLoginException(PasswordLoginFailure.timeout);
  } on JsonRpcRemoteException {
    throw const PasswordLoginException(PasswordLoginFailure.rejected);
  } on Object {
    throw const PasswordLoginException(PasswordLoginFailure.unsupported);
  }
}
