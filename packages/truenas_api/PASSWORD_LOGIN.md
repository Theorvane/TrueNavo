# Password sign-in and OTP continuation

This native flow targets stable TrueNAS 25.10, using public contracts pinned to
TS-25.10.1. It is a partial sign-in implementation, not two-factor enrollment,
recovery-code management, password reset or a claim of full WebUI parity.
No appliance, supplied credential or live authentication was used to implement
or test this increment. Test secrets and transports are synthetic.

## Exact contract

- Initial request: `auth.login_ex` with one object containing
  `mechanism: PASSWORD_PLAIN`, account, exact password and
  `login_options: {user_info: false}`.
- An `OTP_REQUIRED` response supplies the normalized account shown to the user.
  A manually entered 6–8 digit code continues on the **same TLS/WebSocket** using
  `auth.login_ex_continue` with `mechanism: OTP_TOKEN`, `otp_token` and the same
  login-options object. Passwords are not resent with codes.
- At most three manual code submissions are admitted; prompts time out after
  two minutes by default. RPC authentication/summary reads time out after
  30 seconds. There is no automatic credential replay, redirect forwarding or
  fallback to a different authentication method or unverified connection.
- `SUCCESS` must carry a supported authenticator policy (`LEVEL_1` or `LEVEL_2`).
  This is the server's global assurance policy, **not a count of factors**.
  OTP can legitimately complete under LEVEL_1. Errors, expiry and unknown
  responses fail closed with fixed safe messages, never remote diagnostics.
- Only successful authentication followed by `auth.me`, `system.info` and
  `core.get_methods` can publish a session. `pw_name` is recognized as the
  authenticated identity. An unsupported release does not publish management
  capabilities. General inventory queries stay unavailable during login.

## Credential and lifecycle boundaries

`PasswordSessionRepository` is additive; existing API-key repositories retain
their interface. Password sign-in never reads, writes or deletes API-key vault
entries, even if the old UI's remember-key intent was set. Password whitespace
is preserved; empty or over-1024-character inputs are rejected before handoff.

The UI stores new password/code input only in transient local text controllers;
challenge state contains display-safe endpoint, account, attempt and expiry.
Passwords clear on OTP, failure and success; codes clear on submit/dispose.
Secret fields disable suggestions, autocorrect and personalized IME learning.
Profile persistence contains safe metadata only. This is not a physical-memory
zeroization, screenshot-prevention or operating-system keyboard guarantee.

Native certificate probing and explicit pin approval happen before credentials
are handed to the repository. Password approval/retry uses the same one-shot
verified transport as API keys. Cancellation, disposal and repository/session
replacement invalidate the attempt. Late responses cannot publish a session or
submit a code, and old cleanup cannot cancel a newer challenge.

## Verification

Fake-wire tests cover exact payloads, vault nonaccess, error redaction, policy
levels, manual retry bounds, malformed replies, timeouts and stale challenges.
Controller/widget tests cover safe profile publication, forged/late OTPs,
cancel/reconnect races and narrow 320/430px layouts at 200% text with keyboard.
No live password/OTP acceptance is claimed. Authentication itself can have
server-side audit/session effects and must not be mistaken for passive reading.

## Primary sources

- [25.10 auth request and response models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/auth.py)
- [Authentication service and OTP continuation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/auth.py)

Remaining work includes two-factor setup/replacement/disclosure, recovery,
redirect/HA handoff with new explicit trust, older/newer release adapters and
real-server read/write acceptance authorized separately by the user.
