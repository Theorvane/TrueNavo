# Native NFS shares — stable TrueNAS 25.10

This bounded adapter provides inventory, native create/update/enable/read-only
configuration and guarded export deletion. It is not a complete replacement for
all NFS configuration in the WebUI. Tests use in-memory RPC transports only;
the connector-free Flutter preview rejects every execution request.

## Contract and scope

`AuthenticatedNfsSharesSession` provides `loadNfsShares`,
`reviewNfsShare(request)`, and `executeNfsShare(review, exactTarget)`.
Read and write capabilities are separate. Stable 25.10 plus authenticated,
public, synchronous, non-upload/download method metadata is required. Missing
write proofs leave a read-only inventory. Denied or malformed optional proofs
also leave it read-only, but a changed connection never returns old inventory.

Paths must be existing standard filesystem dataset roots. Every ancestor is
checked for GUID/creation, encryption, locks, ownership by system/external
managers, clone origin, mountpoint, readonly and native ZFS export properties.
Root pools, system datasets, encrypted/cloned ancestry, arbitrary subdirectories
and path moves are unavailable. No mkdir/chown/ACL setter, force flag, service
start/stop or client disconnect is issued.

The native editor accepts at most 16 canonical unicast IPv4 host addresses and
16 nonoverlapping canonical CIDRs, with prefix 1–32. A client may not be
duplicated across hosts and networks. Lists are alternatives (OR); both empty
means all clients. Hostnames, wildcard/netgroups and IPv6 are visibly outside
this bounded workflow. AUTH_SYS is not encryption or strong authentication.

Maproot or mapall may use a plain local user and optional local group. Exact
nonzero uint32 IDs, name, local/source flags, primary group and nullable validated
SID are resolved through public identity methods, then bound across review,
preflight and readback. Local accounts with valid SMB SIDs are supported.
Directory-service identities and ID 0/no-root-squash are unavailable. Ownership
on disk does not change. An old mapping removed by the request is still checked.

Existing aliases, Kerberos security variants, snapshot exposure, global
Kerberos/SPN, RDMA and HA configurations block writes. Existing supported hidden
settings are preserved: updates send only changed keys, never default-filled
replacement dictionaries. Null and empty mapping names remain distinct. Creates
explicitly request empty aliases, SYS security and no snapshot exposure. These
fields and synchronous CRUD contracts come from the pinned
[public NFS models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/nfs.py).

## Service impact is global

Each share CRUD method saves/deletes its database row and then requests NFS
reload. A failed response may therefore follow a real configuration change;
it is never treated as a retryable rejected write. Share delete targets the
export record, not the dataset or files. Legacy aliases are cleared during
validation, which is why exports containing aliases are not edited. See the
[pinned share implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/nfs.py).

The export renderer regenerates **all** exports. It may remove manual files in
`/etc/exports.d`, disable their ZFS `sharenfs` properties, and set directory
immutability. We require a standard empty immutable directory: public `stat`
checks `/`, `/etc`, and `/etc/exports.d` identity and rejects symlink ancestors;
public `listdir` uses no filters and a one-entry limit with minimal name/path/type
projection, so any visible entry blocks writes. This reduces risk but cannot
eliminate races or promise that global renderer effects will not occur.
[Renderer source](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/etc_files/exports.mako),
[public filesystem contracts](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/filesystem.py).

Every review warns that existing clients and pending I/O can be affected. Clients
should quiesce and flush writes first. No connected-client count, write durability
or connectivity is invented. Configured enablement counts are not service health.
NFS state and start-at-boot are read separately; saving does not start a stopped
service. The service is reloadable; no app-initiated restart is substituted.
[Service implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/service_/services/nfs.py).

## Leases, dependencies and outcomes

Inventory and review objects are immutable session-issued handles. There is one
active single-use review; replacement, failed confirmation or failed preflight
consumes it. Every dispatch rereads the complete bounded export/config/dataset
snapshot and target path/statfs/identity/dependency proofs. Directory proofs bind
device, inode and mount ID, not merely a path string. Discovery or validation
failure sends nothing. Administrators must remain idle: middleware exposes no
atomic compare-and-swap for this operation.

Public dataset attachments report enabled consumers at/below the selected root,
not disabled or ancestor attachments. The complete NFS share inventory additionally
retains parent and disabled export configurations. Attachment type `NFS Share`,
service `nfs`, and exact enabled descendant paths are checked. Only the reviewed
path's enabled-state delta is admitted after mutation; every non-NFS attachment
and unselected path remains identical. No claim of all consumer discovery is
made. [Dataset attachment source](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_attachments.py),
[attachment delegate source](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/common/attachment/__init__.py).

Success requires a complete expected typed receipt plus independent full
configuration readback and repeat identity/path proofs. Unexpected receipts,
timeouts, reload errors, post-write drift and disconnects produce `unknown` and
retain the shared server mutation guard. Raw remote errors are not displayed.
No automatic retry, polling or replay occurs. Flutter retains uncertain origin
across routes/sessions and hides stale editors immediately. Manual acknowledgement
after a fresh same-endpoint connection does not certify prior completion.

Bounds: 256 exports, 256 filesystem datasets, 32 attachment groups/256 attachment
names, bounded path components and bounded strings/metadata. Limit-plus-one
queries reject truncation. Readback proves configuration only, not live export
usability, kernel cache convergence, client I/O completion or filesystem data
durability.
