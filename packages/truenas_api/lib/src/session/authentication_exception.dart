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
