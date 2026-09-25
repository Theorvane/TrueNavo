# Time settings: timezone and bounded NTP configuration

This adapter implements timezone selection and NTP configuration-row creation,
editing and deletion. It does **not** set the wall clock directly, measure time
accuracy, inspect live peers or provide an NTP health monitor. All development
and verification used public pinned source and synthetic transports. No real NAS,
credentials, remote-source probe or appliance mutation was used.

## Pinned source contract

Reference tag: **TS-25.10.1**, not a moving branch.

- [NTP service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/ntp.py)
  and [NTP schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/system_ntpserver.py):
  `system.ntpserver.create/update/delete` are ordinary authenticated CRUD methods,
  not jobs or file methods, under `NETWORK_GENERAL` roles. Create and update
  invoke `clean` before the datastore write. With `force: false`, this performs
  an actual server-originated NTP probe, including for an options-only update.
  Deletion does not run that explicit validation probe. Every mutation writes
  the datastore and then restarts `ntpd` before returning. A service failure can
  therefore occur after the configuration already changed.
- [Pinned NTP client](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/ntp_/client.py)
  uses an IPv4 UDP socket and port 123, so creation/editing admit IPv4 or DNS
  names only; the name must resolve to a reachable IPv4 source. The app never
  calls private `system.ntpserver.test_ntp_server` or private `peers` directly.
- [Pinned NTP form](https://github.com/truenas/webui/blob/TS-25.10.1/src/app/pages/system/advanced/ntp-servers/ntp-servers-form/ntp-servers-form.component.ts)
  requires `4 <= minpoll < maxpoll <= 17`; the adapter matches these edit bounds.
  The API fields themselves are unconstrained integers and the service checks
  only `maxpoll > minpoll`. These values are exponents: 6 means 64 seconds and
  10 means 1,024 seconds. They are not literal interval seconds.
- [Chrony configuration](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/etc_files/chrony/chrony.conf.mako)
  interpolates configured addresses into `server` directives. It also includes
  DHCP and `sources.d` entries. API NTP rows therefore are **not** a complete
  inventory of effective or active time sources. Burst increases traffic and
  should be used only with a personally controlled source, not public servers.
- [System general service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/system_general/update.py)
  and [schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/system_general.py):
  `system.general.update` with only `timezone` still writes configuration before
  updating replication timezone configuration, reloading time services,
  restarting cron and unconditionally starting SSL service. A response can
  contain nested `ui_certificate` private-key material; only its timezone is
  privately projected and retained by this adapter.
- [Timezone choices](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/system_general/timezone.py)
  come from [tzdata Z/L entries](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/timezone_choices.py)
  as a map whose keys equal their values. Only exact advertised choices are
  allowed, bounded to 2,048 entries with 120-character plain identifiers.

`system.general.checkin_waiting` is a public read requiring the
`SYSTEM_GENERAL_WRITE` role. Null means no pending timer under the API contract;
an integer, including zero, means pending. The service truncates a positive
sub-second remainder to zero. This adapter conservatively refuses timezone
changes while rollback is pending or unprovable, because connectivity may change.
The pinned rollback implementation restores only `stg_gui` fields, not timezone;
no claim is made that GUI rollback undoes the timezone update. A timer read is
not an atomic guarantee that a delayed rollback or external change cannot occur.

## Public API and safe view

`AuthenticatedTimeSettingsSession` exposes `timeSettingsCapabilities`,
`loadTimeSettings`, `reviewTimeSettings(TimeSettingsRequest)` and
`executeTimeSettings(review, confirmation, {required isCurrent})`.
Actions are `timezone`, `createNtp`, `updateNtp` and `deleteNtp`; results are
`completed`, `rejected` or `unknown`, with a fixed sanitized message only.

Base read capability is independent of advertised write methods. Metadata must
explicitly identify authenticated, non-job, non-file methods; private methods,
unsafe pipe markers and malformed flags are rejected. The timezone action also
requires an advertised safe `checkin_waiting` method. A read-only session can
inspect base inventory but does **not** call that write-role read, even when its
metadata is advertised. `guiRollbackKnown: false` then disables timezone edits.
If an attempted rollback-status read fails or is malformed, the entire fresh
projection fails closed rather than presenting a trustworthy clear status.

The only system-general value retained in inventory or readback is the validated
timezone. Raw general-config responses, certificate objects, private keys,
authentication private fields and remote exception details never enter a DTO,
UI message, log or generic result. Timezone choices and NTP rows are immutable.
The query explicitly requests at most 129 rows with only id, address, burst,
iburst, prefer, minpoll and maxpoll; more than 128 rows fail closed.

Editing admits a bounded ASCII DNS name or IPv4 address of at most 120
characters. URLs, ports, whitespace, control characters, shell/config syntax,
scoped/bracketed IPv6 and malformed numerical IPv4 forms are rejected without
any probe or RPC mutation. Existing unscoped IPv6 and bounded legacy poll values
can remain visible and be deleted while unsafe new/update settings are blocked.
The legacy projection bounds each exponent to -64 through 64; larger or malformed
values require the TrueNAS workflow. No legacy row is silently normalized.

Create/update send the six complete source settings plus fixed `force: false`.
There is no force override, standalone test button, dry run, bulk update or
arbitrary options map. An unchanged update is rejected because even that would
probe the source and restart NTP. Case-insensitive duplicate configured addresses
are rejected. Delete takes one exact issued row ID and must leave at least one
other configured row; that does not prove the remaining source is usable.

The only timezone write is `system.general.update [{"timezone": choice}]`.
No certificate, networking, keyboard, GUI configuration, rollback timeout,
check-in, GUI restart or other general-settings field is submitted.

## Review, dispatch and readback

The adapter reuses only the power adapter's public readiness projection. This
conservatively requires stable 25.10, exact endpoint/host/boot identity, FULL_ADMIN,
READY standalone state, no visible active/waiting jobs, a healthy online boot
pool without scanning and an unchanged current/next bootable environment.
These extra app guards are not claimed server API prerequisites or proof of
workload quiescence. Identity, privilege and state are rechecked after the time
configuration reads, not only before them.

Immutable repository-issued inventory, full safe configuration and readiness
proofs are bound to a one-use five-minute review. Each attempt consumes its lease,
including busy, malformed confirmation, stale session, expiry and foreground
rejection. Confirmation includes the action, full permanent host identifier and
exact timezone or NTP identity/address. A new review, refreshed inventory or
new connection invalidates old reviews. Public DTO copies do not forge leases.

The caller must explicitly acknowledge service/scheduling impact. Creation and
editing additionally require consent for the actual server-originated remote
probe; enabling burst requires acknowledgement that the source is personally
controlled. Deletion requires acknowledgement that configured remaining rows
are not health evidence. UI consent is distinct from SDK structural validation.

The required `isCurrent` callback must reflect active foreground/route, session,
inventory and consent context. False or throwing callbacks fail closed before
and after awaited preflight operations. Full proof and age are checked again
after all awaits, with no further await before invoking the fixed mutation.
No inventory or review operation invokes a mutation or private NTP probe.

After dispatch the adapter validates the expected response and takes **one**
independent, bounded fresh projection. The resulting timezone and complete
configured-row set must match the requested change exactly: no missing/extra
rows or changes to unrelated source settings are accepted. Fresh host/boot,
readiness, choices and rollback-presence proof must also match. Row order is
normalized by ID, but content is not guessed or repaired.

`completed` means only that expected receipt and saved configuration matched.
It does not prove synchronization, clock correctness, source trust/reachability,
service health, schedule behavior, application consistency or absence of external
races. There is no polling loop, arbitrary delay, retry, job inspection or private
peer query. Unexpected post-dispatch responses, errors, timeouts, lifecycle/session
loss or mismatched readback produce `unknown`, never rollback or permission to retry.

## Shared fence and recovery

Time operations join the existing SDK management busy lock in both directions.
An unknown result permanently fences further writes in that SDK session across
time, reset, restore, backup, power, boot/update and other mutation workspaces.
A fully matched completed result permits a new deliberate review; its prior
inventory/review is invalidated. Late responses never retry or clear a fence.

The app separately preserves its management fence across reconnects. Recovery
requires a deliberately new authenticated session at the original endpoint,
fresh matching original public-host readiness and explicit independent inspection
acknowledgement. Reconnection alone is not verification. Public host IDs are not
cryptographic attestation. This workflow does not automatically change endpoints,
trust certificates, reconnect, restart anything or reapply uncertain changes.

All tests are synthetic. They exercise strict metadata, bounded/secret-safe
projections, fixed parameters, no-probe reviews, lease/lifecycle races, exact
readback, malformed/late outcomes and cross-workspace exclusion without contacting
an appliance or sending a real NTP packet.
