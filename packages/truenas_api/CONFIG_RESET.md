# Factory configuration reset: fixed destructive action and recovery fence

This adapter implements one deliberately destructive configuration reset for a
standalone stable TrueNAS 25.10 server. It is not a dry run, disk wipe, secure
erase or an alternative configuration-restore path. All implementation and
verification used public pinned source and synthetic RPC fixtures; no real NAS,
credentials, login, reset, reboot or other appliance write was used.

## Verified source contract

Reference tag: **TS-25.10.1**, not a moving branch.

- [Configuration service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/config.py)
  and [schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/config.py):
  `config.reset` is a FULL_ADMIN, authenticated job, locked as `config_reset`,
  with job logs. It copies `/data/factory-v1.db` directly over the live
  configuration database **before** running `config.on_upload` hooks and HA
  propagation. When `reboot` is true it requests `system.reboot` with reason
  `Configuration reset` and delay 10. The job's eventual result is null; the
  initial RPC returns its job ID. A later error does not undo the database copy.
- [Boot hook](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/boot.py),
  [migration hook](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/migration.py),
  [security hook](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/security/update.py)
  and [service hook](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/service_/on_config_upload.py)
  can also affect boot files, migration state, security configuration and service
  enablement. `reboot: false` would still perform writes, so it is neither
  exposed nor used as a test or dry-run option.
- The same configuration service's startup `setup` processes a pre-existing
  `/data/uploaded.db` and uploaded sidecars. **Reset does not clear these pending
  restore files.** Startup can therefore install a previously uploaded
  configuration instead of leaving factory defaults. The public readiness reads
  cannot prove pending restoration is absent. The app requires independent
  operator verification; this adapter does not inspect or remove private files.
- [Pinned web reset task](https://github.com/truenas/webui/blob/TS-25.10.1/src/app/pages/system-tasks/config-reset/config-reset.component.ts)
  likewise sends `config.reset` with `[{"reboot": true}]`. This bounded adapter
  refuses HA rather than attempting peer propagation/recovery.

## Public API and exact dispatch

`AuthenticatedConfigurationResetSession` exposes
`configurationResetCapabilities`, `loadConfigurationReset`,
`reviewConfigurationReset(ConfigurationResetRequest)` and
`executeConfigurationReset(review, confirmation, {required isCurrent})`.
There is no generic method name, argument editor, optional reboot flag, file
transport, upload token, file picker or data-erasure option.

Capabilities require stable 25.10 and explicit public authenticated metadata for
`config.reset` plus every maintenance readiness method. Reset must be a job and
must not be uploadable or downloadable. Reads must explicitly be non-job,
non-file methods. Missing, private or contradictory metadata fails closed.

The only destructive invocation is:

```text
config.reset [{"reboot": true}]
```

No `config.upload`, `config.save`, HTTP upload/download, separate `system.reboot`,
job abortion, polling, retry, automatic reconnect or automatic endpoint migration
is performed. Configuration backup and restore have separate guarded workflows.

## Readiness and one-use review

The adapter reuses only the power adapter's public read projection. It validates
the exact endpoint, permanent public host ID, current boot ID, exact stable
version, READY state, standalone licensing, healthy online boot pool without an
active scan, identical current and next-boot bootable environment, bounded
visible RUNNING/WAITING job headers and reboot-reason codes. FULL_ADMIN role is
validated before and after this projection. Raw `auth.me` private fields and
remote error details are never exposed in an inventory or message.

`ConfigurationResetInventory` is immutable and repository-issued. Review takes
`ConfigurationResetRequest(inventory: inventory)` and compares a fresh readiness
projection. The issued review binds identity, boot, privilege and readiness for
at most five minutes, including time spent awaiting the final preflight. The
exact confirmation is `RESET <full permanent host ID>`.

Every execution attempt consumes its lease, including incorrect confirmation,
busy/session/lifecycle rejection and failed preflight. Reloading readiness,
issuing a new review, closing/reconnecting, changed public proof, expiry or a
backwards clock invalidates the old review. Publicly constructed DTO copies
cannot forge an issued inventory or lease.

The required `isCurrent` callback represents caller foreground, route, session
and consent authorization. False or throwing callbacks fail closed. It is
checked before and after awaited preflight operations and after all awaits,
immediately before invoking the fixed reset RPC. Pre-dispatch failure is
`rejected` and does not submit a reset. Callers must abandon authorization when
the page, app lifecycle, connection or relevant consent state changes.

Once the reset RPC is invoked, any error, timeout, malformed receipt, session
change or lost foreground authorization is `unknown`: configuration could
already have changed. A positive JavaScript-safe integer job ID is `accepted`,
not `completed`, `factory defaults reached`, `rebooted` or `recovered`. The SDK
never interprets a failed job or disconnected socket as rollback or permission
to retry. Late responses do not change a returned result or remove its fence.

## Recovery and limits

In-flight reset shares the existing management busy lock with backup, restore,
power, boot/update, disk/pool and other mutation families. Accepted and unknown
submissions permanently fence further management writes in that SDK session.
Connect/close replace that session state; the app must preserve its independent
management recovery fence across reconnects and must not treat a new connection
alone as recovery. There is no durable process-death recovery guarantee.

Configuration can change accounts, passwords, API keys, certificates, network
addresses, shares, apps/VM definitions and service settings. Stored encryption
keys and other secrets may become inaccessible. Keep a current independently
secured configuration backup, required secret seed, separate dataset encryption
keys/passphrases and tested console or physical recovery access before resetting.
Do not assume storage, imports, mounts, shares or applications will remain usable.

Reset is not a storage-data wipe or secure erase and does not prove removal of
all database copies, keys, seed files, authorized keys or sensitive material.
Equally, it offers no preservation or recovery guarantee. Public readiness cannot
prove hidden/pending uploaded configuration absence, all active work, sufficient
free space, application consistency, workload quiescence or atomicity against
other administrators. Independently rule out pending restoration before reset.

The app's recovery workflow requires independent original-machine inspection and
explicit newly authenticated readiness. If the address or certificate changed,
the user must enter the new endpoint manually, pass normal certificate approval,
compare the same permanent public host ID and separately acknowledge the changed
address. Public host ID comparison is not cryptographic attestation. Neither an
accepted job ID, elapsed time, READY state nor a new boot ID proves factory
defaults, successful service recovery or absence of pending restoration.

## Synthetic verification

The tests use in-memory fake transports only. They cover strict metadata and
version gates, bounded public projections, FULL_ADMIN and host/boot drift,
immutable issued review identity, one-use/expiry/lifecycle races, exact fixed
parameters, invalid/error/late receipts, terminal fences, cross-workspace
exclusion and rejection of generic `config.reset` bypasses. No fixture ever
contacts an appliance or exercises real reset hooks.
