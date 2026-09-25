# Native configuration backup (bounded partial workflow)

This adapter implements configuration export only, for stable TrueNAS 25.10 and a
session-owned `ConfigurationBackupDownloadTransport`. It is not a general file
download, configuration restore/reset, database-integrity check or recovery test.
No real NAS or supplied credentials were used to implement or verify this adapter.

## Pinned source contract

The reference implementation is middleware tag **TS-25.10.1**, not a live server:

- [Configuration service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/config.py)
  and [configuration schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/config.py):
  `config.save` is an output-pipe job requiring FULL_ADMIN. Database-only export
  returns SQLite; either optional flag selects a tar archive. The seed member is
  `pwenc_secret`; available admin/truenas_admin/root authorized-key files are
  optional. `pool_keys` is ignored on SCALE. Upload has no no-reboot option: it
  schedules a reboot, and absent uploaded seed/authorized-key files are removed
  on startup. Upload/reset remain blocked outside this adapter.
- [Core download service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/service/core_service.py)
  and [core schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/core.py):
  the non-job helper returns `[jobId, relativeUrl]`, creates an origin-bound,
  single-use token with a 300-second lifetime, and authorizes the underlying job.
- [File HTTP handler](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/apps/file_app.py):
  an unbuffered transfer must begin within its 60-second registration window.
  HTTP 200 does not prove job success; the output stream is copied separately.
- [Authentication implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/auth.py)
  and [privilege composition](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/account_/privilege.py):
  `auth.me` exposes `privilege.roles`; the adapter retains only whether the
  bounded role list contains `FULL_ADMIN`, never other account fields.
- [Dataset database model](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset.py)
  stores `storage_encrypteddataset.encryption_key` as encrypted text;
  [encryption operations](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_encryption_operations.py)
  persist non-passphrase keys there. The raw configuration database can therefore
  contain stored dataset keys, decryptable with the password secret seed.
  [Keychain storage](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/keychain.py)
  can similarly hold encrypted SSH private-key attributes. Optional export flags
  do not sanitize secrets or key records from the database.

## Public contract and ownership

`AuthenticatedConfigurationBackupSession` exposes capabilities, readiness load,
review and execution. Capability metadata must explicitly identify authenticated,
public, non-upload methods; only `config.save` is job/downloadable. Merely listing
a method name does not enable this workflow. A regular WebSocket transport has no
file capability. The exact transport returned by the successful connection is
passed privately into this adapter; it never opens another connector.

The initial and repeated readiness checks bind endpoint, full 64-hex permanent
host ID, unchanged version, READY state, standalone status, FULL_ADMIN privilege
and no visible active/waiting jobs. Job headers are limited to 128 rows with
unique safe IDs. Repeated host/version/state/privilege reads reject mixed
snapshots. This is not an atomic server transaction and does not stop another
administrator changing configuration after the final read.

The request fixes two booleans: `includeSecretSeed` and `includeAuthorizedKeys`.
Both default false. Review text distinguishes a sensitive database export from
a seed-bearing export. Storage contents are not backed up, but stored dataset
encryption keys and other secrets may be present in the configuration database.
This is not a separate or complete encryption-key export; maintain independent
recovery material. The typed confirmation is `BACKUP <full-host-id>`.
Reviews are repository-issued, one-use, session-bound and valid for five minutes;
backwards clock movement, a new inventory, changed readiness or failed execution
attempt consumes/rejects the old lease. Expiry is rechecked after preflight awaits.

The sole submission is:

```text
core.download(
  "config.save",
  [{"secretseed": <selected>, "pool_keys": false,
    "root_authorized_keys": <selected>}],
  "truenas-configuration.db" or "truenas-configuration.tar",
  false
)
```

The helper receipt must be a two-element list, with a positive safe integer job
ID and exactly `/_download/<same-id>?auth_token=<token>`. Tokens admit only 32–512
URL-safe ASCII characters. Absolute/scheme-relative URLs, percent escapes,
fragments, duplicate/extra query parameters, path changes and control characters
are rejected before HTTP. The native transfer independently enforces exact
authority/certificate trust, no redirect/retry/cache/cookies, status 200,
uncompressed bytes and the 16 MiB hard body bound.

After EOF, a single projected exact-ID `core.get_jobs` read must return one
`config.save` job with `SUCCESS`, explicit null error and explicit null result.
WAITING/RUNNING, missing or malformed completion is unknown, not success, and no
automatic polling, transfer retry or job cancellation is issued. FAILED/ABORTED
is a known rejected export. Host/version/state/FULL_ADMIN are checked again before
releasing an artifact. No raw token, URL, remote error, job result or archive
contents is exposed in public results or exception strings.

## File envelope checks and limits

Files are held transiently in memory and limited to 16 MiB. SQLite checks include
the 16-byte magic, a supported page size, page alignment and read/write format
versions; these are envelope checks, not database integrity or consistency.
Tar checks validate checksums, bounds, termination, exact allowed regular-file
members and the embedded SQLite envelope. A requested seed is required; requested
authorized-key files may be absent. Links, traversal, sparse/unknown members,
duplicate members and path/size PAX overrides are rejected. Only bounded numeric
mtime/atime/ctime PAX records are supported, matching Python's normal tar output.
Unsupported archive variants fail closed; no extraction occurs.

`ConfigurationBackupArtifact` owns one mutable byte buffer. `takeBytes()`
transfers ownership once; the saver must wipe it after use. `dispose()` wipes an
unconsumed buffer. Rejected, stale and unknown responses wipe their buffers,
including late platform results after a timeout. VM/platform copies and storage
provider behavior cannot be guaranteed erased. The UI must not retain artifacts
in persistent state, logs, caches, clipboard, screenshots or saved preferences.

## Shared operation safety and remaining work

Read/review/export participate in the existing repository mutation exclusion,
including disks, pools, rsync, power, generic administration, storage, credentials
and compute. An uncertain submitted export fences this SDK session from further
mutations and new backups until deliberate reconnect; pre-existing passive
workspace reads may remain available. Independent original-server job inspection
is required; disconnect alone is not proof of completion. App recovery/fencing and
document-provider saving are separate platform responsibilities.

This partial implementation does not add upload, reset, manual firmware upload,
audit export, backup encryption, restore validation, HA recovery, multi-file
transfer, durable process-death recovery or other-platform file transfers. A
successful export job does not establish that a user-selected destination saved
the file, that it is confidential there, or that the NAS can be restored.

All adapter tests use synthetic RPC frames, synthetic SQLite/tar bytes and fake
download transports. Production NAS export or write execution remains untested
by explicit user instruction.
