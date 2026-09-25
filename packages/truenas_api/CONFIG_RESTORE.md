# Configuration restore: bounded native upload and recovery fence

This partial adapter implements one explicit configuration restore, **not a dry
run**. A successful server restore can replace access settings and automatically
reboot TrueNAS. Factory reset uses a [separate guarded adapter](CONFIG_RESET.md),
never this upload workflow. Implementation and tests used only
public pinned source and synthetic fixtures: no appliance, credentials or live
restore/write calls were used.

## Verified source contract

Reference tag: **TS-25.10.1**, not the current remote branch.

- [Configuration service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/config.py)
  and [schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/config.py):
  `config.upload` is a FULL_ADMIN input-pipe job with no method arguments. The
  input limit is 10,485,760 bytes. Its server-side migration and pending-file
  replacement are followed by `system.reboot` with reason `Configuration upload`
  and delay 10. There is no no-reboot option. Startup installs the uploaded DB and
  removes an existing password seed or admin/truenas_admin/root authorized-key
  file when its corresponding uploaded member is absent.
- [File HTTP application](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/apps/file_app.py):
  `POST /_upload` requires the `data` JSON part first and the `file` part second.
  The helper authorizes the method, starts its input-pipe job and copies the
  upload. HTTP 200 with `{"job_id": N}` acknowledges acceptance, not successful
  migration, reboot or recovery. The adapter sends exactly one file.
- [REST authentication](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/restful.py):
  `Authorization: Token <value>` means a generated authentication token.
  `Authorization: Bearer <value>` instead means an API key and is **not** used.
- [Token implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/auth.py):
  the adapter requests `auth.generate_token [60, {}, true, true]`. Empty
  attributes are required for token action authentication. Origin matching and
  single-use are enabled; parent session authorization is checked. This token
  inherits session privileges and is not restricted to `config.upload`.
  Its lifetime is inactivity-based, not a claimed independent wall-clock
  revocation guarantee. The API can reject unsupported authentication policies.

## Public API and file ownership

`AuthenticatedConfigurationRestoreSession` provides capabilities, local file
preparation, readiness load, review and execution. Upload is enabled only for
stable 25.10 and complete public, authenticated method metadata. `config.upload`
must explicitly be job/uploadable, not downloadable. All other required methods
must explicitly be non-job and non-file methods. A normal WebSocket transport
does not enable restore: the successful authenticated session's exact transport
must implement `ConfigurationRestoreUploadTransport`.

`prepareConfigurationRestore(Uint8List)` is local: it performs no RPC or upload,
consumes/wipes the supplied mutable buffer and retains a separate private copy.
`ConfigurationRestoreFile` exposes only SHA-256, byte length, DB/TAR format,
actual password-seed member presence and actual allowed authorized-key member
names. It provides `dispose()` but no raw-byte getter. A new prepared file
disposes the old one. Connect/close also dispose issued capsules. The public
inspection factory is useful for connector-free fixtures, but a real session
only accepts file identities issued by its own preparation method.

The file bound is 512 bytes through **10 MiB**, inclusive. The existing backup
download permits 16 MiB, so a larger backup is deliberately not admitted for
restore. Shared SQLite/TAR envelope checks verify page alignment, magic/version,
archive checksums, bounded safe regular-file members, limited numeric-time PAX
headers and termination. There is no extraction or database execution. A TAR
must contain `freenas-v1.db`; alternate legacy archive database names, compressed
archives, links, sparse files and unknown members remain unsupported.

These checks **do not validate** a TrueNAS schema, database integrity, source
server/version, authenticity, migration compatibility, seed/database matching or
recoverability. Actual member presence is not a completeness claim. A raw DB or
archive without seed/key files is admitted only with explicit app warnings and
additional risk acknowledgement, because the server may remove existing
recovery/access material. Users must know and trust the selected file.

Stored dataset encryption keys, SSH private keys and other secrets may be present
inside the database and may be decryptable with an included secret seed. This is
not a separate or complete key export, and missing-seed input can lose the ability
to decrypt those values. Storage contents, application/VM data and snapshots are
not restored by the configuration upload. Independent recovery material remains
necessary.

## Readiness, review and dispatch

The adapter reuses only the existing power adapter's source-audited public read
projection, never its execution methods. Required checks include endpoint,
permanent public host ID, boot ID, exact stable version, READY state, no HA
license, healthy online boot pool without scanning, identical current/next
bootable environment, bounded visible active-job headers and reboot-reason
codes. FULL_ADMIN role is read before and after that projection. Mixed
host/boot/state/privilege reads fail closed. Visible jobs must be idle.

Readiness and the file hash are bound to a repository-issued one-use review for
five minutes. The confirmation is `RESTORE <full-host-id>`; the UI separately
shows the full file SHA-256. Reloaded readiness, a replaced/disposed capsule,
changed connection/boot/readiness, backwards clock or failed execution attempt
invalidates the lease. The user must acknowledge automatic reboot, access loss,
file compatibility, missing recovery files and independent recovery access.

`executeConfigurationRestore` requires the caller's `isCurrent` callback. That
foreground/session/file authorization is checked throughout preflight and again
after token generation. After all awaited preflight reads, the SDK rechecks
readiness, age, private bytes and their SHA-256. There is no further awaited gap
between final authorization and invoking the upload transport.

Token strings accept only 32–512 URL-safe ASCII characters. No endpoint, path,
method, filename or token may come from the file. The platform fixes the upload
path, parts and method. It must verify the same approved certificate/authority
before sending the token or bytes, reject redirects/retries and never cache,
log, display or return the token. No broad TLS trust fallback is enabled.

Cancelling before upload yields `rejected`: no configuration upload was sent.
An already generated token may remain valid until its inactivity limit or
session invalidation; no explicit token revocation is claimed. Once native
upload is invoked, every exception/timeout/invalid receipt becomes `unknown`,
because server mutation and automatic reboot may already have begun. A positive
safe integer receipt yields `accepted`, never `completed` or `restored`.

## Transfer lifetime and recovery

The SDK gives native upload a dedicated private-buffer copy. Disposing the UI
capsule cannot modify bytes already being transmitted. A transport must consume
and wipe that copy on settlement. The SDK adds settlement cleanup as a defense;
it must not wipe the transport-owned copy merely because `Future.timeout` has
expired while native code may still be reading it. Native session cancellation
is responsible for stopping the HTTP request. Late outcomes never automatically
retry the request or remove a recovery fence. VM/platform copies cannot be
guaranteed erased; the app must not persist these bytes.

Accepted and unknown uploads fence this SDK session and the app's shared
management lock. No automatic job polling, cancellation, reboot RPC, reconnect,
reset, endpoint discovery or restore replay occurs. The app separately requires
independent recovery inspection and an explicit newly authenticated connection.
Configuration may change the endpoint or certificate: any new address is entered
manually and requires normal TLS approval, then explicit public-host identity
comparison and extra changed-address acknowledgement. A public host identifier
is not cryptographic attestation; no automatic endpoint migration is implied.

Free-space sufficiency, workload quiescence, server-side atomicity, all external
writers, restored data/services, HA recovery and durable process-death recovery
remain unverified/unsupported. Network and credential settings may prevent this
app from reconnecting at all. Keep independent console/physical access and a
recovery plan before choosing to restore.

All SDK verification uses synthetic RPC frames, local fixture bytes and fake
native upload transports. No uploaded test fixture was sent to a real NAS.
