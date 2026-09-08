enum AuthenticationState {
  otpRequired,
  authenticationFailed,
  expired,
  redirect,
  unknown,
}

final class AuthenticationStateException implements Exception {
  const AuthenticationStateException(this.state);
  final AuthenticationState state;

  String get userMessage => switch (state) {
    AuthenticationState.otpRequired =>
      'This server requires an OTP flow, which M0 does not support yet.',
    AuthenticationState.authenticationFailed =>
      'The server rejected the API key.',
    AuthenticationState.expired => 'The API key has expired.',
    AuthenticationState.redirect =>
      'This server requested a redirect, which M0 does not support yet.',
    AuthenticationState.unknown =>
      'The server returned an unsupported authentication state.',
  };

  @override
  String toString() => userMessage;
}

final class TlsCertificateException implements Exception {
  const TlsCertificateException();
  String get userMessage =>
      'A trusted TLS certificate is required in this M0 slice. Certificate trust settings are not available yet.';
  @override
  String toString() => userMessage;
}

/// A deliberately credential-free account-name validation failure.
///
/// The account name is submitted alongside the API key, so this message must
/// never quote the value it rejected.
final class AccountNameValidationException implements Exception {
  const AccountNameValidationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Accepts the account-name shapes TrueNAS itself allows, including the
/// `name@REALM` form used by directory accounts, and rejects anything that
/// could smuggle whitespace or control characters into the login payload.
///
/// This is shared so a caller can refuse an unusable account name before it
/// opens a connection, while the repository still validates what it sends.
String validateTrueNasAccountName(String? value) {
  final account = value ?? '';
  if (account.isEmpty) {
    throw const AccountNameValidationException(
      'A TrueNAS user name is required with an API key.',
    );
  }
  if (account.length > 128 ||
      account != account.trim() ||
      !RegExp(r'^[A-Za-z0-9._@$-]+$').hasMatch(account)) {
    throw const AccountNameValidationException(
      'The user name is not a valid TrueNAS account name.',
    );
  }
  return account;
}
