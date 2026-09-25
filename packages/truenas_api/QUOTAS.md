# Native user/group quotas (TD-031)

This bounded native workspace supports stable TrueNAS 25.10, researched against
the public **TS-25.10.1** contracts. It manages USER/GROUP byte and object limits
on existing, unencrypted, unmanaged filesystem dataset roots. Project quotas,
dataset quota/refquota edits, recursion, account creation, and Zvol quotas are
outside this slice. Verification uses synthetic transports and Flutter fixtures
only: no NAS, credentials, or real-server quota writes are used.

## Exact public wire contracts

| Operation | Arguments | Result |
| --- | --- | --- |
| User quota inventory | `pool.dataset.get_quota [dataset,"USER",[],{"limit":513}]` | At most 512 admitted USER rows |
| Group quota inventory | `pool.dataset.get_quota [dataset,"GROUP",[],{"limit":513}]` | At most 512 admitted GROUP rows |
| Numeric user lookup | `user.get_user_obj [{"uid":id,"sid_info":true,"get_groups":false}]` | Public passwd identity object |
| Numeric group lookup | `group.get_group_obj [{"gid":id,"sid_info":true}]` | Public group identity object |
| Apply selected limits | `pool.dataset.set_quota [dataset,[quotaEntry,...]]` | Synchronous `null`, followed by independent reads |

An outgoing quota entry contains only `quota_type`, numeric **string** `id`, and
integer `quota_value`. Byte limits use `USER`/`GROUP`; object-count limits use
`USEROBJ`/`GROUPOBJ`. One review targets one resolved identity and sends at most
two changed entries in one call. It never converts an object count into bytes.
Zero explicitly removes that one limit; the server converts zero to `None`.
Client-side null means leave that dimension unchanged and sends no entry.
UID/GID zero is prohibited by the server, including quota removal, and is never
admitted by this client. [Pinned quota service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_quota.py),
[request/response models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/pool_dataset.py),
[upstream quota integration tests](https://github.com/truenas/middleware/blob/TS-25.10.1/tests/api2/test_quotas.py).

Numeric UID/GID input is restricted to 1 through 4294967294. Limits are exact,
nonnegative integers through 9007199254740991, preserving native/web integer
interoperability. Fractions, negatives, overflow, no-op dimensions, and unresolved
identities cannot produce a review. No name is submitted to `set_quota`, even
when a resolved name is displayed to the user.

## Sparse inventory and honest usage bars

The source accumulates byte usage, byte quota, object usage, and object quota
through four separate userspace iterations. A row need not contain every field.
The public model identifies absent `quota`/`obj_quota` as not set; missing or zero
limits therefore display **Unlimited**. In contrast, absent
`used_bytes`/`obj_used` remain **Unknown**, not fabricated zero usage. Explicit
null, malformed, fractional, or negative numeric fields are rejected.

A usage bar is drawn only when usage is known and the corresponding limit is
positive. Byte and object bars have independent denominators. Unlimited and
unknown states have text, not invented percentages or indeterminate activity.
Reported usage at/above a limit remains numerically intact; visual fill can stop
at the end of the bar while limit/over-limit status remains explicit. These are
ownership quota observations, not pool capacity, free space, reservation, or
application health. Usage can lag; displayed headroom does not guarantee the
next write will succeed. [Quota entry model and usage caveats](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/pool_dataset.py).

A resolved identity with no existing quota row can receive limits. Its
unreported usage stays unknown. Removing both limits may remove the row entirely;
independent absence then verifies unlimited limits without claiming zero usage.
Unrelated zero-only usage rows can appear/disappear without invalidating a review,
while any unrelated positive quota-limit change invalidates it.

## Dataset, account, and service admission

Discovery requests only filesystems, with a nonempty type filter so the pinned
query traverses descendants despite `retrieve_children:false`. It admits at most
256 returned roots and selects bounded identity/configuration properties plus
the `user_properties.managedby` alias. A target and every ancestor must be
visible, writable, unencrypted/unlocked, and mounted at `/mnt/<dataset>`. System
datasets and clones are outside this slice. Only absent/empty/`-` managed markers
mean unmanaged: a literal manager name such as `none` is not an absence marker.
GUIDs must be nonzero uint64 values; creation/configuration/property-source
information must be well formed. [Pinned dataset query normalization](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_query_utils.py).

Discovery and quota inventories are session-issued, immutable handles. Refreshing
discovery invalidates old handles. The detail provider obtains a fresh issued
handle with the same dataset ID and GUID; it does not silently substitute a newly
created dataset with the same name. The selected account's numeric ID, resolved
name, source, local flag, SID when available, and user primary GID are checked
again before submission and after acknowledgment. Other passwd fields and group
member lists are not copied into public models or reviews. [Numeric user model](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/user.py),
[numeric group model](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/group.py),
[lookup implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/account.py).

Existing service attachments are allowed because quotas are useful on shared
datasets. Their bounded normalized fingerprint must remain unchanged across
review, preflight, and readback; no consumer is stopped or detached. The review
discloses the reported attachment count and that clients can be affected.
`pool.dataset.attachments` checks enabled delegates only; it is not complete
discovery of disabled services, arbitrary processes, or external consumers. This
is an explicit limitation, not a claim that the dataset is unused.
[Attachment implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_attachments.py).

Read capability requires advertised dataset/query methods. USER/GROUP write
capabilities additionally require the corresponding numeric resolver, attachment
reads, and public authenticated non-job/non-upload/non-download metadata for
`set_quota`. Missing methods, permission failures, malformed data, and exceeded
bounds fail closed with sanitized messages. Advertisement does not prove that
every preflight is authorized. Response limits bound admitted client data; the
source enumerates userspace before applying its returned-list limit, so they are
not a server-side work budget. No legacy/private fallback is used.

## Review, verification, and uncertainty

Reviews are session-issued and single-use, with exact typed confirmation of
`dataset USER|GROUP numericId` plus a write-denial acknowledgment in the UI.
Incorrect confirmation consumes the review. Each review lists only selected
changes and warns that finite limits can deny writes/object creation. Setting
below reported usage is allowed through this explicit review and warns of
immediate denial; it does not delete existing data. Unknown usage also receives a
warning. Limits do not reserve storage, change owners/ACLs, extend guest
filesystems, or apply recursively to child datasets.

Dataset identity/configuration proofs enclose quota reads and repeat after slow
account/dependency checks. The complete USER/GROUP positive-limit map is checked
again immediately before dispatch. After the synchronous `null` receipt, fresh
dataset, account, attachment, and quota reads must show the exact selected result
and preserve every unselected quota dimension/identity. Acknowledgment alone is
never proof of success.

Shared SDK and app mutation locks exclude conflicting local operations. Timeout,
remote error, an unexpected job-like receipt, disconnect after submission, or
inconsistent readback becomes **unknown**, retaining the lock and original
server/target. It is never automatically retried, polled as a guessed job, rolled
back, or replayed. Changing sessions clears old inventory and forms; it does not
relabel an uncertain old operation as current-server success. Inspect the
original server and reconnect before acknowledging uncertainty. Fresh reads
alone do not clear it. Before-send failure is rejected without a quota write.

There is no atomic compare-and-swap for dataset identity, account mappings,
attachments, or limits. Rechecks narrow but cannot eliminate external races.
Local/LDAP numeric IDs can be reused, and absent SID information supplies no
immutable account-generation identity. Usage can also change during review.
Keep other administrators idle; this is not a server-wide maintenance lock or a
transactional guarantee.

Static preview fixtures exercise supported, unlimited, unknown, and over-limit
states and reject reviews/mutations. Synthetic SDK/controller/widget tests are
implementation evidence only. Live quota-write acceptance, project quotas,
recursive/bulk operations, dataset-wide quota edits, and complete WebUI parity
remain outside this slice.

## Focused verification

`fvm dart test test/session/session_quotas_test.dart` in `packages/truenas_api`
passes 110 fake-wire tests. `fvm flutter test test/features/quotas` in
`apps/trueraid` passes 35 controller/widget/preview tests. Owned Dart files pass
static analysis and formatting checks. Regressions cover all four quota types,
independent limit removal, sparse/unknown usage, identity and quota drift,
slow-read dataset replacement, shared mutation exclusion, unknown outcomes,
stale-session form disposal, and 320px width with 200% text scaling.
