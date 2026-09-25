# Init / Shutdown command-task lifecycle

This bounded native workspace implements public `initshutdownscript.query`,
`create`, `update` and `delete` using the pinned **TS-25.10.1** schema. It is
configuration management, not a terminal, execution test or complete WebUI
replacement. All implementation verification uses synthetic fixtures; no real
NAS, credentials, command execution, filesystem probe, service command, reboot
or shutdown is invoked.

## Supported workflow

| Action | Native admission and wire payload |
| --- | --- |
| Create | New COMMAND with explicit `enabled: false`, empty `script` and `comment`, new body, phase and wait budget. |
| Replace | An already-disabled COMMAND only; a complete new body plus phase/wait budget. Partial update contains only `command`, `when`, `timeout`. |
| Enable | A disabled, privately verifiable COMMAND with a supported body and wait budget; update is only `enabled: true`. |
| Disable | An enabled, privately verifiable COMMAND; update is only `enabled: false`. |
| Delete | An already-disabled, privately verifiable COMMAND; delete the reviewed ID. |

No action converts task type or implicitly disables/enables a task. Existing
comments are preserved privately and are not edited or displayed. The inactive
`script` field must be null or empty, and the exact representation is preserved.
Nonempty dormant script fields are protected. All SCRIPT tasks are header-only,
because their source validation calls `filesystem.stat` and their execution uses
different path semantics. The app does not validate files, change permissions or
offer a file-backed replacement.

New/replacement commands are manually authored, single-line, nonempty printable
ASCII up to 300 characters. No example command is injected automatically. The
app accepts shell syntax as text; it does not evaluate syntax, commands or
dependencies. Existing body text is never loaded into the editor. Enabling also
requires this bounded body subset. Supported legacy bodies outside that subset
may be disabled/deleted or replaced while disabled, provided the selected row
can be privately verified. Masked, missing, oversized or unsupported private
row shapes fail closed.

Phases are PREINIT, POSTINIT and SHUTDOWN. The native wait-budget subset is
**1–300 seconds**, not a server-schema limit: the pinned public integer has no
minimum/maximum validator. Legacy wait budgets are displayed exactly but do not
permit enabling until replaced in the supported range. Disabled cleanup does
not rewrite such values.

## Execution semantics: timeout is not a kill deadline

The plugin runs COMMAND tasks using `sh -c`, inheriting middleware privileges.
The pinned middleware and lifecycle systemd units have no alternate `User=`;
this is root execution, not a selected unprivileged account.

PREINIT is ordered before `network-pre.target` and after `ix-zfs.service`.
POSTINIT runs after `multi-user.target`; SHUTDOWN is invoked by the shutdown
unit's stop action. These phase names do not establish that a network, dataset,
key, external endpoint or application is ready. The enabled-task query has no
explicit order; the app does not infer a user-controlled ordering guarantee.

The execution job snapshots enabled tasks once and awaits them sequentially.
`asyncio.wait_for` limits each awaited coroutine, but the underlying utility
awaits `subprocess.run` in a thread executor **without a subprocess timeout**.
Cancelling that await does not reliably kill an already-running process or its
descendants. A command can continue and overlap later tasks after the wait
expires. The pinned shutdown unit has `TimeoutStopSec=0`; the app does not repeat
the plugin/schema docstring's inaccurate implication of an added finite OS
termination limit.

Disabling or deleting cannot cancel a task already in the job's snapshot,
in-flight commands or descendants. It is not a kill switch. Enabling may result
in data/security changes, external connections, credential disclosure, lost
access, or delayed/failed boot and shutdown. The UI requires separate explicit
acknowledgements for root execution, independent inspection of the exact body
and recovery access, and the wait-budget/continued-process risk. Disable/delete
requires a separate no-cancellation acknowledgement. Configuration consent is
required for every action and is enforced again by the controller.

The CRUD COMMAND path validates the merged command is nonempty, writes the
database and reads back the instance. It does not itself execute a command,
restart a service, regenerate lifecycle units or schedule a reboot. Generic CRUD
events/hooks and later lifecycle processing still exist: a response error after
the database operation is not rollback.

## Privacy and safe projection

Inventory queries select only `id`, `type`, `when`, `enabled` and `timeout`,
bounded to 128 rows. Existing command bodies, script paths and comments are never
public DTO fields, state-provider values, list labels, review text or logs.
Tasks are identified by numeric ID and lifecycle metadata, not by potentially
sensitive comments. A selected COMMAND query is filtered by its exact ID and
type; its complete eight-field row remains invocation-local and is protected by
a per-session HMAC for drift and preservation checks. No other task body is
read. The workflow never subscribes to task query events.

The selected command reference is an opaque, keyed per-session 64-hex value,
not a plain command hash, body preview, identity attestation or safety verdict.
It binds the review without exposing text or enabling straightforward unkeyed
dictionary comparison. The UI checks its shape before showing an adapter-issued
review. An existing body must be inspected independently through a trusted
TrueNAS/console workflow before enabling.

New bodies use a write-only, single-use `InitShutdownTaskCommand` capsule with
private mutable bytes, no value getter and a redacted string representation.
Input controllers disable autofill, suggestions and personalized learning and
obscure body text. Their actual values are cleared on hand-off, dismissal,
background, route coverage or connection change. Capsule bytes are cleared on
abandonment, failed review, every execution attempt, refresh and session
close/replacement. Late capsule disposal invalidates the final dispatch guard
even when the caller's route callback still returns true. Zeroing is best effort:
immutable strings and UI/platform/JSON/transport copies cannot be guaranteed
erased.

This app's privacy handling is **not** a claim that TrueNAS treats these fields
as secret. Command and script are ordinary schema strings. TrueNAS stores rows,
generic CRUD query events can carry complete result rows, and execution failures
or wait-timeouts can log command text and output. Users should not casually put
credentials into commands or comments. No raw RPC response or exception is
returned as a UI error.

## Authorization, readback and recovery

Repository-issued immutable inventory and five-minute single-use review leases
bind the endpoint, full host identifier, boot ID, version, full-admin status,
non-HA READY state, healthy non-scanning boot pool, unchanged bootable next
environment and absence of visible conflicting jobs. Selected private content
and complete projected headers are rechecked before dispatch. These are bounded,
non-atomic checks; concurrent administrators and lifecycle transitions can race
them.

The exact confirmation target is
`<ACTION> INIT TASK <full 64-hex host ID> <NEW or task ID>`.
All awaited preflight calls and the final dispatch check require a current
session/route and unexpired command authorization. There is no public call to
`execute_init_tasks`, shell, run-now, service control, filesystem validation,
job polling, automatic retry or reconnect.

A successful create/update response must match the full expected private row;
fresh bounded inventory and selected-row readback must preserve the intended
headers and private fields. Delete requires true plus verified row absence.
`completed` means **configuration matched**, not execution success, process
termination, safe root behavior or availability.

Any failure after the mutation RPC is invoked is `unknown`, including timeouts,
lost context, false receipts or mismatched private readback. The SDK session
remains terminal for further mutations, and the app's shared write fence
survives route and connection changes. Recovery requires manual fresh-session
connection to the original address with normal authentication/certificate trust,
one explicit same-host readiness read, and independent inspection acknowledgement
after the old invocation settles. This releases only the app fence. It does not
prove the previous operation or run it again; claimed host identity is not
remote attestation.

The UI uses inline phase controls and explicit owned-dialog closing flags. Ordinary
confirmation/cancellation animations do not invalidate the hand-off, while
unrelated route coverage, background, session or inventory changes do. Consumed
or expired inventory and charts are hidden until an explicit refresh. Charts
show configured enablement, type and phase counts only—not running processes,
execution success, duration, health or the absence of other startup code. Empty
inventory has no invented percentage.

## Pinned primary sources and verification

- [Public schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/initshutdownscript.py)
- [CRUD validation and execution job](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/init_shutdown_script.py)
- [Thread-executor subprocess utility](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/__init__.py)
- [CRUD result events and hooks](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/service/crud_service.py)
- [Middleware service unit](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/debian/middlewared.service)
- [PREINIT unit](https://github.com/truenas/middleware/blob/TS-25.10.1/debian/debian/ix-preinit.service), [POSTINIT unit](https://github.com/truenas/middleware/blob/TS-25.10.1/debian/debian/ix-postinit.service), [SHUTDOWN unit](https://github.com/truenas/middleware/blob/TS-25.10.1/debian/debian/ix-shutdown.service)

Synthetic SDK coverage is in `session_init_shutdown_tasks_test.dart` and the
independent `session_init_shutdown_tasks_safety_test.dart`. Native controller and
widget tests live under `test/features/init_shutdown_tasks/`, including all
lifecycle actions, secret disposal, held asynchronous context changes, exact
consents, normal dialog submission, shared fences and 320/430/1100 light/dark
layouts at 200% text with the keyboard open.
