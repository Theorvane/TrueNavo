# SMTP configuration and explicit one-recipient test

This native adapter supports bounded basic SMTP settings and an explicitly
requested test using the saved configuration. It does not enroll/clear OAuth,
provide a mail composer or inspect delivery receipts. Development and tests used
public pinned source and synthetic transports only: no NAS credentials, appliance
connection, host probe, SMTP connection or real test message was used.

## Verified source contract

Reference tag: **TS-25.10.1**.

- [Mail service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/mail.py)
  and [schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/mail.py):
  `mail.config` and the `mail.update` response contain secret password and OAuth
  fields. `mail.update` is a normal authenticated config method under the ALERT
  role family. It merges the patch, validates it, writes the datastore, then
  invokes Gmail initialization and alert cleanup. A later error is not rollback.
  Omitted `pass` preserves the secret; explicit null clears it.
- `mail.send` requires MAIL_WRITE and is a job with an optional input pipe:
  `@job(pipes=['input'], check_pipes=False)`. The pinned
  [metadata projection](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/service/core_service.py)
  therefore advertises job=true, uploadable=true, downloadable=false and
  check_pipes=false. The adapter requires that exact combination; attachments
  remain false and no pipe/upload is used.
- Default recipients would be local administrators and default queueing would
  permit retries. This adapter instead supplies exactly one explicit recipient,
  queue=false and interval=0. The fixed plain-text message has html=null, no CC,
  no attachments, no extra headers, and timeout=30 seconds. Its second config
  argument is exactly `{}`, so it cannot override saved SMTP settings.
- TrueNAS prepends its product name and network-global hostname/domain to the
  subject. Its system hostname is used for SMTP EHLO, and sender, recipient,
  Message-ID and connection metadata also leave the NAS. The app does not invent
  or claim to have read the complete final subject or those private identities.
- TrueNAS returns false when network activity policy denies mail. SUCCESS with
  result=true is the only supported positive job result, and even that does not
  prove recipient delivery. A job ID only acknowledges acceptance.

Existing failed messages can already be in TrueNAS's internal queue, retried
every 600 seconds up to three attempts using the **current** configuration and
sender. A configuration change can therefore affect older queued messages. The
public adapter cannot inspect or cancel that queue. queue=false applies only to
this new test; it does not suppress existing queued or unrelated background mail.

## SMTP transport risk

Only TLS (STARTTLS) and SSL (implicit TLS) settings are admitted for changes and
tests. Existing PLAIN settings can be viewed and changed to this bounded subset.
This is **not** an authenticated SMTP identity guarantee: the pinned TrueNAS
implementation does not supply certificate/hostname-verifying SSL contexts to
Python's SMTP_SSL or starttls calls. The standard Python context path can be
unverified; see [smtplib](https://github.com/python/cpython/blob/v3.11.9/Lib/smtplib.py)
and [SSL compatibility context](https://github.com/python/cpython/blob/v3.11.9/Lib/ssl.py).
The user must independently verify and explicitly accept the destination and
credential/message disclosure risk. TrueRAID's separate TrueNAS API certificate
pinning does not secure the NAS-to-SMTP connection.

## Public API and private data ownership

`AuthenticatedEmailSettingsSession` exposes capabilities, `loadEmailSettings`,
`reviewEmailSettings`, `executeEmailSettings` and explicit
`checkEmailSettingsJob(jobId, {required isCurrent})`. Configure and test
capabilities are separate; missing test metadata does not remove the safe view
or configuration action. No generic invocation or raw `mail.config` result is
exposed by this workflow.

`EmailConfigSnapshot` contains only config ID, bounded SMTP metadata,
passwordPresent (true/false/null for unknown) and OAuth presence. Raw password,
OAuth fields/tokens and remote exception strings are never placed in an inventory,
review warning, result, log or UI state. Secret-bearing responses are immediately
projected privately. Masked, malformed or unprovable password data is not
interpreted as a reusable password and blocks configuration/tests.

Null and an exact empty OAuth object both mean no OAuth under the pinned API and
backend. Both are preserved by **omitting** the field; their different original
forms are bound privately to the review and readback. Nonempty, masked or unknown
OAuth stays display-only. No provider switching or implicit token deletion occurs.

Private HMAC proofs bind the exact stored password using a per-session random
key. Neither the secret nor its fingerprint is public. The proof also preserves
the difference between a null username and an empty username, even though both
display as an empty field. Updates send only **changed** safe fields, avoiding
unrequested normalization. Password Keep omits `pass`; Replace sends only the
newly entered value; Clear sends explicit null. No stored/masked password is
ever copied into an outbound update or test override.

`EmailPasswordChange.replace(String)` stores a private mutable byte capsule and
exposes action, validationError, isDisposed and dispose only. Replacement input
is 1–1,024 printable 7-bit ASCII characters, matching the server's ASCII
limitation with an intentionally tighter no-control bound. Invalid input gets a
fixed validation error. Keep and Clear carry no secret bytes. The UI clears its
obscured editor at handoff/abandonment and disposes capsules on cancellation,
session/lifecycle loss or route exit. The SDK also disposes reviewed capsules on
reload, superseding review, execute attempt and repository close/reconnect.
Immutable Dart strings, JSON/transport copies and platform memory cannot be
guaranteed erased; no persistence or complete-memory-erasure claim is made.

Enabling authentication requires an explicit username and a known saved password
kept or a fresh replacement. Disabling authentication while a password exists
requires explicit Clear; the SDK never silently erases it. Replacement while
authentication is off and clearing while authentication is on are rejected.
The review separately acknowledges authentication/credential changes. Sender and
recipient use a conservative single ASCII mailbox subset up to 120 characters;
header injection, controls, multiple recipients, display-name recipient syntax,
URLs and arbitrary message headers are not supported.

## Readiness, review and execution

Public host/boot identity, stable 25.10 version, FULL_ADMIN, READY standalone
state, idle visible jobs and healthy unchanged boot-environment checks are reused
from the existing power read projection. Identity and privilege are checked again
after the mail projection. These are conservative app guards, not server API
prerequisites, proof of workload quiescence or an atomic lock against other
administrators and background mail.

An immutable repository-issued inventory and private credential proof are bound
to a five-minute, one-use review. Configure confirmation includes the full public
host ID and SMTP host/port; test confirmation includes full public host ID and the
exact single recipient. Inventory reload, a new review, connection/identity or
credential drift, expiry, backwards clock or disposed replacement invalidates
the lease. Every execution attempt consumes its lease and disposes its capsule.

`isCurrent` must track foreground, route, session, inventory and consent context.
False/throwing callbacks fail closed around awaited preflight calls. The SDK
checks proof, capsule and age after all awaits, immediately before the fixed
mutation. Reads and review never open an SMTP connection or send mail.

For configure, the expected update response and **one** fresh independent saved
configuration/credential readback must match exactly, including preservation of
unmodified fields and the null/empty username/OAuth forms. `completed` means
saved configuration matched, not that SMTP connectivity or delivery was tested.
Any post-dispatch error, timeout, malformed response or mismatch is unknown and
fences the session; a database write may already have occurred.

For test, a positive JavaScript-safe job ID yields `pending` and owns an ongoing
management fence. There is no automatic job read, poll, retry, abort or resend.
Only an explicit `checkEmailSettingsJob` for the exact outstanding job in that
same authenticated session is admitted. The check validates fresh original
identity and saved configuration proof, then reads at most one matching
`mail.send` job with only id/method/state/result. Other job arguments, errors and
message details are not projected. Visible job activity is ignored only for this
read-only owned-job inspection, because the owned test itself can be running.

WAITING/RUNNING stays pending. SUCCESS with exact boolean true yields completed
with the same job ID and reports server-side success only, not recipient receipt
or reading. False, missing/duplicate/wrong jobs, FAILED/ABORTED, unknown states,
read errors, timeout or identity/config drift yields unknown. An unowned job check
is rejected without RPC and cannot clear the existing fence. Completed ownership
is consumed; no stale job ID can be reused as proof for another test.

## Shared fence and recovery

Configure, pending tests, explicit checks and unknown outcomes participate in
the shared SDK mutation lock with time, reset, restore, backup, power and other
management workspaces. Completed verified operations allow a new deliberate
review. Unknown is terminal for that SDK session; late results never retry or
release it. The app also retains its separate recovery fence across reconnects.

Recovery requires deliberate reconnection to the original endpoint, fresh same
public-host baseline readiness and independent original-server/configuration/job
inspection acknowledgement. `readinessBlockedReason` separates those baseline
checks from editability: a manually protected OAuth/redacted-password configuration
can still be inspected for recovery without enabling SMTP edits. Reconnection
alone does not prove what happened, and public host ID is not cryptographic
attestation. This app does not migrate endpoints, change certificate trust,
automatically resend tests or promise durable recovery state after process death.

Synthetic tests cover secret-safe projection, changed-field patches, capsule
disposal, lease/lifecycle races, private credential drift, exact message payload,
owned-job checks, ambiguous results and cross-workspace fences. No synthetic test
message or credential was sent to a real NAS or mail server.
