# Native boot environments

This adapter is admitted for stable TrueNAS 25.10 only. It uses public
`boot.environment.*` methods from the **TS-25.10.1** source and API models:

- [Service implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/boot_/environments.py)
- [25.10.1 request and response models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/boot_environments.py)
- [Upstream integration tests](https://github.com/truenas/middleware/blob/TS-25.10.1/tests/api2/test_boot_environments.py)

## Wire contract

| Operation | Arguments | Result |
| --- | --- | --- |
| Inventory | `boot.environment.query [[], {"limit":129}]` | At most 128 admitted entries |
| Clone selected source | `boot.environment.clone [{"id":source,"target":newName}]` | New entry |
| Protect from automatic cleanup | `boot.environment.keep [{"id":target,"value":boolean}]` | Updated entry |
| Select next boot | `boot.environment.activate [{"id":target}]` | Updated entry |
| Delete | `boot.environment.destroy [{"id":target}]` | `null` |

The entry has `id`, `dataset`, `active`, `activated`, `created`, `used_bytes`,
`used`, `keep`, and `can_activate`. Display uses validated integer `used_bytes`,
not untrusted human-readable `used`. Clone usage overlaps: sums are not physical
boot-pool usage. The service creates its timestamp from UTC; naive ISO creation
strings are retained exactly for identity comparison.

There is **no public rename or standalone create method** in this version.
The screen provides creation through a reviewed clone and explains unavailable
rename. It never substitutes legacy `bootenv`, shell, dataset rename, or private
ZFS operations. Activation only changes the next-boot selection and never sends
reboot, shutdown, or failover commands.

## Safety and outcome verification

- Reads also inspect `failover.licensed` and at most 128 waiting/running jobs
  using `core.get_jobs`, projecting only `id`, `method`, and `state`. HA and
  concurrent boot, update, failover, reboot, or shutdown work block mutation.
- Read and write capabilities are separate. Mutation requires advertised public,
  authenticated, non-upload/download, **non-job** metadata for that exact method.
- Inventory is immutable and session-issued. Reviews are privately issued,
  single-use, and invalidated by refresh, another review, or a connection change.
  Target/source names, dataset identity, creation value, current/next-boot flags,
  keep, kernel support, and the complete environment set are checked again before
  submission. Volatile used-space counts are not mistaken for identity changes.
- Delete refuses current, next-boot, kept, and unsupported environments. The
  TS-25.10.1 service itself only explicitly checks current before calling zectl;
  this adapter enforces the additional protections independently. Protected
  entries require a separate reviewed keep change before deletion.
- Clone uses the selected source with a non-existing validated new name, without
  activating it. The server's ordinary dependency checks remain intact; no force,
  recursive-delete, promotion, or bypass flag is sent.
- Every acknowledged operation is independently read back. Other environment
  identities and flags must remain unchanged, except the previous next-boot flag
  when selecting a new one. The acknowledgement must agree with the fresh entry.
- All four methods are synchronous in the verified source. A job-looking integer
  is not an owned job and is never polled, guessed, retried, or cancelled. The UI
  shows in-flight work while awaiting the synchronous response.
- Any timeout, transport error, malformed acknowledgement, disconnect after
  submission, or inconsistent readback yields **unknown**, retaining the original
  server/target and holding the mutation lock. A fresh read never clears this
  state or authorizes retry. The user must inspect the original server and
  reconnect. Before-send failures are rejected without a mutation.

The API supplies no GUID/compare-and-swap token or public clone dependency graph
for these entries. Identity therefore uses the exact public name, dataset, and
creation value, and the server remains the final dependency authority. Fresh
checks cannot make concurrent external administration atomic; this workflow is
not a maintenance lock against other clients. Job visibility also depends on the
authenticated account's server-side permissions.

Validation uses synthetic fake-wire, controller, and widget fixtures only.
No real boot environment was created, kept, activated, deleted, or renamed during
implementation. Live mutation acceptance and release-wide certification remain
unverified.
