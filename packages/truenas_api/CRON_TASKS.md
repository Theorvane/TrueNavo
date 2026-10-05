# Native scheduled cron task lifecycle

This bounded workspace creates **disabled** cron tasks, edits disabled tasks,
enables or disables one selected task, and deletes a disabled task. Commands are
write-only replacement capsules; existing command text never appears in global
inventory, editor fields, reviews, result messages or logs. No manual run, shell,
command validation probe, job abort, execution log viewer or full WebUI parity is
implemented. Development uses public TS-25.10.1 source and synthetic fixtures only:
no NAS, credentials, appliance contact, command execution or server writes.

## Verified source contract

The [public cron schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/cronjob.py)
defines ordinary authenticated SYSTEM_CRON CRUD methods. `cronjob.update` accepts
a partial object. Create defaults enabled to true, so the native payload always
sets `enabled:false` explicitly. `stdout:true` and `stderr:true` mean **suppress**
that output, not capture it. The UI defaults both to suppressed for a new task;
existing values are preserved unless explicitly changed.

The [implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/cron.py)
validates the selected user using `user.get_user_obj`, requires a nonempty command,
converts the schedule and writes the database before waiting on
`service.control('RESTART', 'cron')`. Updates merge old data and regenerate only
when the stored values differ. Delete also changes the database before regeneration.
This control addresses a [pseudo-service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/service_/services/pseudo/misc.py)
whose `restart()` is empty and whose `etc` files include cron. It is global cron
configuration regeneration, **not evidence of an OS cron daemon restart or child
process cancellation**.

The [cron generator](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/etc_files/cron.d/middlewared.mako)
emits a root scheduler wrapper `midclt call cronjob.run <id> true` for enabled
tasks. Regeneration also handles other scheduler entries such as rsync, cloud
sync/backup, scrubs and update downloads, and can generate/remove locked-task
alerts. Saving a disabled cron task is therefore still a real global scheduling
configuration change, not a dry run.

The scheduled wrapper runs the stored command under the configured account using
[`sudo -H -u <user> sh -c <command>`](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/user_context.py).
Cron supplies no execution timeout. The run job has a per-task lock and a queue
size of one; this does not establish once-only execution or safe cancellation.
Root commands have appliance-wide privileges, and other accounts retain their
actual filesystem/network privileges. The app does not verify shell syntax,
executable paths, privilege sufficiency, output behavior or command safety.

Commands/output/failures can reach middleware job logs and the selected user's
configured email destination. The source email body includes original command
text and output; nonzero-exit errors also contain command text. Hiding stdout or
stderr is **not a command-secrecy or no-output guarantee**, especially with arbitrary
shell composition. It does not prevent network requests, file changes, notifications
or other effects performed by the command. The native adapter never reads raw
jobs/logs, account email addresses or stored command text into public state.

## Scheduling and admitted accounts

[`CronModel`](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/common.py)
and [cron parsing](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/cron.py)
validate five fields. The native editor supports numeric single values, lists,
ranges and one `*/step` or `range/step` expression per field. Each field is bounded
to 100 characters. Minute is 0–59, hour 0–23, calendar day 1–31, month 1–12 and
weekday 0–7 (Sunday 0 or 7). Names/macros/whitespace are rejected. To avoid ambiguous
day matching, this increment allows restricting either calendar day or weekday,
not both. Impossible calendar-day/month combinations are rejected. No per-task
timezone, jitter, timeout or exact next-run prediction is offered.

Schedules use the server scheduler clock. Only `timezone` is projected from
`system.info`; other system/license details are discarded from this workspace.
Clock corrections and daylight-saving transitions can affect execution. Saved
configuration does not establish when, whether or how often a command actually ran.

Local identities are explicitly selected with:

```text
user.query [ [[local, =, true]], {
  limit: 1025, select: [id, uid, username, local, locked]
} ]
```

The exact top-level local filter is important: the pinned
[account query](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/account.py)
recognizes it before directory-service status/cache inclusion. No broad user record,
password hash, home, email, SSH key or sudo configuration is requested. Local
query internals still perform normal server-local account extension work; this is
not a claim of no local I/O. Only unlocked local accounts with bounded supported
usernames become choices, including a verified root account when present. A root
account is not assumed to exist or selected automatically for a new draft. User
ID, UID, username, locality and lock state are included in the private dependency
proof, not merely the displayed username. Returned accounts are bounded to 1,024
rows and the stricter shared structured-proof bounds below.

Create, edit and enable/disable additionally require a disabled, unconfigured
directory profile: `enable:false`, null service type, credential, configuration
and Kerberos realm. This also gates delete conservatively in this increment.
`directoryservices.config` is immediately projected to a safe boolean plus a
private HMAC proof; raw credentials/configuration never leave the helper. No
directory status, health or direct NSS/user-object probe is called by the app.
Backend create/update validation still resolves the specified local account; the
app cannot transactionally prevent account/directory changes by another actor.

## Header projection and selected-row preservation

Global inventory is limited to 256 tasks (requesting 257 detects truncation):

```text
cronjob.query [ [], {
  limit: 257,
  select: [id, enabled, description, user, schedule, stdout, stderr]
} ]
```

The complete safe five-field schedule is selected; `command` is not. Descriptions
are list-visible operator metadata and must not be used to store secrets. At
review and final preflight, only the selected task is read in full using an exact
ID filter with `get:true`. Private command and extra-field HMAC fingerprints are
computed immediately; no plaintext command is retained in inventory/review DTOs.
Commands up to 65,536 characters can be privately compared for legacy preservation;
unsupported multiline/long commands cannot be enabled by this editor. Known legacy
content can remain unchanged in a disabled edit or be deleted when the other
guards pass. Canonical redaction placeholders are unknown, not trustworthy command
content, and block selected-row mutation rather than being saved or enabled.

Each session uses a random keyed SHA-256 proof, never a public or unkeyed command
hash. Complete selected extra fields and DS configuration are bounded and compared
privately; unrelated hidden command bodies are deliberately not fetched. Only
safe headers of unrelated tasks are verified unchanged. Shared proof bounds are
12 nesting levels, 4,096 nodes, 256 map entries, 1,024 list entries, 256-character
keys, 131,072 characters per string and 262,144 total string characters. Responses
beyond a bound fail closed rather than becoming partial authority.

Create submits all reviewed settings, one manually entered command and explicit
disabled state. Edit submits only changed settings and an optional explicit
replacement command; null replacement means omission/preservation, not clearing.
Enable/disable submit only `{enabled:true/false}`. Delete submits only the selected
ID and requires a literal true receipt. Unknown protected fields are never resent.
Selected state and all preservation proofs must match again on an independent
readback. Create additionally requires a fresh positive unique ID and exactly one
expected new header; delete requires exactly the selected header to disappear.

## Command ownership, reviews and uncertainty

`AuthenticatedCronTasksSession` exposes `cronTasksCapabilities`, `loadCronTasks`,
`reviewCronTasks` and `executeCronTasks`. `CronTaskCommand.fromText` accepts a
nonempty, single-line command up to 4,096 UTF-8 bytes without ASCII control
characters or canonical mask placeholders. It exposes byte length, disposal
state and `dispose()`, but no plaintext getter. Shell operators are not treated as
safe or unsafe automatically: the operator is responsible for the whole command.

The SDK adopts command capsules for accepted/pending reviews and wipes them on
failure, review replacement/reload, session replacement/close, execution settlement
and uncertain outcomes. Fresh invalid-review capsules are discarded; a duplicate
busy invocation does not erase a capsule already owned by the pending operation.
Callers also dispose abandoned drafts. The app stores plaintext only in the local
obscured editor, clears actual buffers at handoff/cancel/context expiration, and
keeps capsules/reviews outside public provider state. Temporary encoded buffers
and per-session keys are zeroed. Immutable incoming Dart strings and serialized
RPC frames cannot be promised physical memory erasure; there is no command vault,
clipboard export or persisted command file in this feature.

Inventory/reviews are immutable session-issued objects. Review is single-use with
a five-minute lease and exact target `CREATE CRON <full host ID>` or
`<ACTION> CRON <full host ID> #<task ID>`. Final age, protected body, task/account/DS
proofs and required `isCurrent` callback are checked after all preflight awaits.
Stable 25.10, strict public method metadata, FULL_ADMIN before/after, same endpoint,
host and boot, READY standalone state, visible job idleness, no reboot reasons,
healthy boot configuration and matching current/next environment are conservative
requirements. They do not guarantee workload safety, scheduler idleness or atomicity.

All actions require global-regeneration/noncancellation consent. Create/edit and
enable require command/account/schedule risk acknowledgement. Enable separately
requires automatic-execution authorization and command/output/mail disclosure
consent, including independently inspecting the withheld stored command. No
activation is bundled with a save. Normal modal closure waits for
`DialogRoute.completed`; covered routes, backgrounding, session/inventory changes
and expiry clear local buffers and invalidate authority. Controls are inline and
do not open transient dropdown routes.

After a mutation RPC is invoked, every error, timeout, cancelled context, malformed
receipt or readback mismatch is **unknown**, not rollback. Completed means expected
saved configuration was verified, not command success, schedule timing, output
privacy, email delivery or process cancellation. Disabling/deleting does not abort
already-running, already-fetched, queued or separately invoked work; a queued
wrapper may independently recheck disabled/missing state, which is not a cancellation
guarantee supplied by this app. No automatic retry, polling, reconnect or replay.

Unknown outcomes retain the SDK terminal mutation fence and app cross-workspace
lock. Recovery requires a manually reconnected fresh session at the original
endpoint, the same claimed host and baseline readiness, then independent operator
inspection acknowledgement. This releases only the app lock, not the old SDK
session's fence. A still-pending old future prevents acknowledgement; host matching
is not cryptographic attestation. Public configuration reads are ordinary server
reads, not proof that all server internals are pure or that no missing-row default
initialization can occur.

## Synthetic verification

Run SDK protocol/safety tests from `packages/truenas_api` and UI tests from
`apps/truenavo`:

```bash
fvm dart test test/session/session_cron_tasks_test.dart test/session/session_cron_tasks_safety_test.dart
fvm flutter test test/features/cron_tasks
```

Coverage includes five exact lifecycle payloads, command privacy/disposal,
redaction/legacy bounds, local identity and DS drift, one-use/expiry/current races,
receipt/readback uncertainty, cross-workspace exclusion, explicit consent and
recovery. UI checks cover normal modal transitions, actual buffer clearing,
configured-only charts, empty/error states, 320px/200% text and keyboard insets.
