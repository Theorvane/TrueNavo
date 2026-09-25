# Native dataset permissions

This SDK implements a real, bounded TrueNAS 25.10 permissions workflow. Development and verification used public pinned source and synthetic JSON-RPC transports only: no NAS connection, credentials, or filesystem mutations were used.

## Supported scope

- Read the advanced numeric POSIX.1e or NFSv4 ACL, current owner/group, ordinary mode, and ACL-wide flags for an existing filesystem dataset root.
- Edit complete POSIX access/default entries with explicit masks; add/remove named UID/GID entries. Numeric identity lookup uses `user.query` by UID or `group.query` by GID, not account row IDs. Newly introduced named principals are looked up again before dispatch.
- Edit the complete ordered NFSv4 ACE list, including ALLOW/DENY, all 14 advanced permissions and five inheritance flags. Special principals are ALLOW-only. Inherit-only and no-propagate require file or directory inheritance. Client and server canonicalization are disabled, preserving reviewed order.
- Change three-digit ordinary mode only on a trivial POSIX ACL or an ACL-disabled filesystem. The server normalizes/removes the trivial ACL while applying that mode; this is not offered for extended POSIX or any NFSv4 ACL.
- Submit exactly one nonrecursive `filesystem.setacl` or `filesystem.setperm` job, and independently verify its result. Ownership is not editable.

These are authorization-sensitive operations. Removing access can lock users out; broader grants can expose data. Nonrecursive means that existing descendants are not rewritten, **not** that access to them is unaffected: changing root traversal can change effective descendant access, and default/inheritable ACEs affect future children. Server effective-ACL validation is an ancestor traversal check, not a guarantee that the operator retains access.

## Wire and preservation rules

ACL reads use `filesystem.getacl(path, false, false)` so permission/flag maps remain advanced and identities remain numeric. Unknown, incomplete, malformed, duplicate POSIX, or unsupported metadata is not silently discarded. POSIX access/default base entries and explicit masks are validated. POSIX readback is compared semantically; NFSv4 order remains significant.

`filesystem.setacl` receives `path`, complete `dacl`, exact `acltype`, `uid:-1`, `gid:-1`, null owner/group names, false NFSv4 ACL-wide flags, and options `recursive:false`, `traverse:false`, `stripacl:false`, `canonicalize:false`, `validate_effective_acl:true`. The pinned middleware does not forward the API's `nfs41_flags` to its ACL-writing tool, whose missing flags default to zero. Therefore any existing true ACL-wide flag makes the review read-only; existing flags are never knowingly reset by this editor.

`filesystem.setperm` receives `path`, the explicit three-digit `mode`, null owner/group IDs and names, and `recursive:false`, `traverse:false`, `stripacl:false`. Its implementation still strips a trivial ACL before applying mode. The editor does not claim to preserve an extended ACL through this call. Both setters invoke ownership handling even when ownership is unchanged, which can clear special mode bits; roots with setuid/setgid/sticky bits are read-only here. ACL writes may legitimately derive ordinary mode and update timestamps. POSIX-derived mode is verified; NFSv4 derived mode is not incorrectly required to equal the old mode. UID/GID remain exact.

## Target and job proof

Dataset queries use nonempty filesystem/exact-ID filters, bounded results, explicit native properties, and the nested `user_properties.managedby` projection with user-property retrieval enabled. This avoids treating the user property as an unavailable native property. An omitted projected marker means unset; a present malformed or nonempty marker blocks editing. Pool roots, system-managed paths, locked/read-only datasets, nonstandard mountpoints and unsupported versions remain protected.

Every path component from `/` through the dataset root must independently stat as the exact directory, with bounded depth and safe integer metadata. This prevents relying on a final component's `realpath` to prove that its ancestors are not symlinks. The target must be a mountpoint; `filesystem.statfs` must bind the ZFS mount source, destination and filesystem identity to the reviewed dataset. No directory-listing absence proof is used. Dataset GUID/creation/properties, path identities, ACL, mode and flags are re-read after identity lookup immediately before dispatch, then verified after completion.

Review/dataset/job objects are issued by one authenticated session; fabricated or cross-session handles are rejected. The writer shares repository mutation exclusion. A job is owned only when its ID, method, exact submitted arguments, and original message ID match. Mutation request IDs include a secure per-session nonce, so identical job numbers and arguments from another session cannot establish ownership. The legacy job-ID receipt is required; unexpected modern direct results are uncertain, never retried. Job results are not used as an ACL readback.

`WAITING`/`RUNNING` remains pending. Only a matching successful job plus fresh independent target/ACL verification is verified. Failed, aborted, missing, malformed, timed-out or mismatched jobs/readback leave the operation unknown and retain mutation exclusion: POSIX replacement strips the old ACL before installing the new one, so a failed job cannot be assumed unchanged. No automatic write retry or rollback occurs. Reconnection ends the old session's local lock; it is not evidence that the remote outcome is known.

## Deliberately remaining

Recursive changes, arbitrary directories/files, mount crossing, ownership changes, stripping an extended ACL, ACL-wide flag changes, changing ACL type, templates and ACL attachment/consumer-specific policy are not implemented. Public path checks and fresh reads cannot make a multi-RPC filesystem operation atomic against concurrent external administrators; the final readback detects observed drift but cannot eliminate every time-of-check/time-of-use race. No guarantee of self-lockout prevention or universal effective-access simulation is made.

## Primary contracts

- [25.10 ACL API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/acl.py), [filesystem API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/filesystem.py).
- [ACL read/write, ownership, stripping, canonicalization and job behavior](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/filesystem_/acl.py), [POSIX and NFSv4 helpers](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/filesystem_/utils.py), [effective ancestor access checks](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/filesystem/access.py).
- [Dataset query/user-property normalization](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_query_utils.py), [select aliases](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/filter_list.py).
- [Public stat/statfs](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/filesystem.py), [statx symlink behavior](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/filesystem/stat_x.py).
- [Job message ownership and argument encoding](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/job.py), [legacy job protocol default](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/base/server/app.py).
- [NFSv4 tool ACL-wide default flags](https://github.com/truenas/nfs4xdr-acl-tools/blob/TS-25.10.1/libnfs4acl/nfs4_json_to_acl.c#L661), [ZFS ACL-derived mode](https://github.com/truenas/zfs/blob/TS-25.10.1/module/os/linux/zfs/zfs_acl.c#L1356).
