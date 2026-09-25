# Native Accounts

Implemented against public TrueNAS middleware tag `TS-25.10.1`. Development and tests use synthetic transports only: no NAS connection, credentials, or mutation was used.

## Delivered workflows

- Bounded user/group inventory, detailed local/directory/built-in identity status, group membership, and privilege-to-local-GID mapping.
- Create local users with explicit primary and supplementary groups, full name, optional email, selected server-issued shell, password or disabled-password state, and SMB access. Creation fixes `home=/var/empty`, `home_create=false`, `group_create=false`, `random_password=false`, empty sudo commands, and disabled SSH password access. It never creates or adjusts home directories.
- Edit supported profile/email/shell, SMB, account lock, password authentication, SSH password access, primary/supplementary groups, and explicit private password replacement. Unselected fields are omitted.
- Replace one structured Ed25519/RSA/ECDSA public key in an existing regular `authorized_keys` file, or explicitly clear authorized keys. First-key creation is not supported: public stat/listdir omit dangling symlinks, so an apparently absent key cannot safely authorize `open(..., 'w')`. Existing keys are never shown or retained in the public model. Options/commands, private keys, multiline input, malformed SSH binary structure, and undersized RSA key structures are rejected. Replacement is limited to a unique configured home below `/mnt/<pool>/...`; administrator key changes require another working administrator.
- Every non-`/var/empty` user update verifies an existing owned home and each ancestor component through `filesystem.stat` (at most 16 components), because stat alone does not resolve ancestor symlinks. Identity metadata is rechecked before and after the operation. The tagged middleware can recreate missing homes and invokes key normalization even without an explicit key patch. For no-key edits, a present `.ssh` requires an existing regular key already matching target ownership/modes; an unresolved `.ssh` permits only harmless cleanup below a missing target. Visible links, hardlinked key files, ACLs, group/world-write access, visible extra files, shared homes, and nested SSH mounts are rejected.
- Nonempty key replacement reviews recursive ACL stripping and ownership/mode changes within `.ssh` (directory mode 700, key mode 600). Child listing uses metadata-only fields to avoid opening unrelated special files; it is not an exhaustive listing because dangling links are omitted by the server. The pinned recursive permission tool skips symlink entries, so invisible dangling siblings cannot redirect these permission changes. Clear explicitly authorizes unlink of the exact `authorized_keys` entry, including a dangling link. Deletion reviews removal of the whole `.ssh` subtree, including dangling entries; readback verifies unchanged home/ancestor identity and no resolvable SSH tree, not absolute absence of every dangling link. Deleting a configured SMB guest also resets the service guest to `nobody`.
- Updates with the shared default home `/var/empty` require root ownership, ancestor checks and no resolvable `.ssh`, because the update implementation still invokes SSH cleanup there. An invisible dangling `.ssh` has no resolvable child and cleanup is a no-op. Creation and deletion explicitly skip default-home SSH filesystem operations in the tagged source.
- Create/rename groups, toggle SMB group mapping, and manage supplemental membership. Reviews show group names, Unix GIDs, associated roles, and elevated-command access.
- Delete non-built-in users with `delete_group=false`; delete empty, unprivileged groups with `delete_users=false`. User deletion explicitly reviews the exact `<home>/.ssh` removal. Other home files and primary groups are retained. Shared, pool-root, or unsafe home paths prevent deletion.

## Wire contracts and safety

`user.create/update` return user entries, including a potentially echoed password; only receipt identity is examined and the result is discarded. `user.delete` and group CRUD return API IDs. These methods are synchronous RPC operations, not externally tracked jobs. Every successful write requires fresh readback. Password changes additionally require a changed non-null password-change timestamp; a same-timestamp response stays unknown rather than claiming authentication was tested.

User/group API IDs are distinct from UID/GID. User `group`/`groups` and group `users` use API IDs. Privilege `local_groups` and `group.has_password_enabled_user` use Unix GIDs. The privilege response expands local groups into group objects.

Source-defined SMB normalization is explicit: creation adds `builtin_users` to supplementary groups. Enabling SMB on an existing non-SMB user requires a new password; the tagged update implementation does not append that membership. Reviews and readback follow these separate contracts.

Targets and creation inventories are issued by one authenticated connection. Before every mutation the adapter reloads the full bounded inventory and compares an opaque structural fingerprint, including private SSH-key state but never password hashes. It rejects drift, invented handles, duplicate in-flight work, invalid IDs, and numbers outside the exact JSON integer range. Inventory limits are 512 users, groups, or privileges; truncation cannot silently weaken dependency checks.

Built-in, immutable, and directory-service identities cannot be mutated. Active-session users cannot be deleted, locked, password-disabled, or have membership changed. API-key-bearing users cannot be deleted. Primary group members and protected user memberships cannot be removed through group editing. Privilege-referenced groups cannot be deleted.

Access-reducing administrator changes require a remaining unlocked password-enabled local `FULL_ADMIN` candidate, plus fresh `group.has_password_enabled_user` proof without requesting password hashes. Group and privilege mappings are reread. Middleware has its own deletion/password/lock guards, but public account RPC does not offer an atomic compare-and-set transaction against unrelated concurrent administrators; the client performs immediate preflight and post-write verification.

Any error, disconnect, timeout, mismatched receipt, or inconsistent readback after dispatch becomes **unknown**, holds the shared mutation lock, and is never automatically retried. Remote messages and echoed secrets are not displayed. The UI supports exact-target confirmation, a bounded complete review, 320px/200% layouts, session-change hiding, and clearing new private entries after cancellation/submission.

## Explicit remaining scope

- Privilege discovery/mapping is available, but creating, editing, or deleting privilege definitions and assigning sudo commands are not part of this bounded identity editor. Existing role grants can be managed through reviewed group membership.
- Home creation/migration, general recursive ownership or ACL reassignment, UID/GID changes, user-namespace mappings, directory-service identity mutations, and built-in account changes need dedicated workflows. The explicit bounded SSH normalization above is the only supported recursive permission side effect. Existing complex/ACL-protected SSH trees and unprovable home paths prevent user updates or deletion. The metadata preflight is not an atomic filesystem transaction; an external concurrent actor can still change a path after proof, which cannot be eliminated through these public account RPCs.
- First-key creation, multiple/new SSH key algorithms, hardware-backed security keys, key options, and authorized-command rules need dedicated key management. Existing opaque key lists remain intact unless an explicit replacement/clear is confirmed.
- Global two-factor/security policy, password policy, SSH service configuration, and filesystem access can still cause server rejection. No authentication attempt is made to test a changed password.
- Deleting an identity does not rewrite all filesystem owners, ACL entries, remote shares, or external task references. The native review explains these effects; known membership, API-key, privilege, shared-home, and administrator dependencies are checked.

## Primary sources

- [User API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/user.py)
- [Group API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/group.py)
- [Account CRUD, shell validation, SMB normalization, and SSH/home side effects](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/account.py)
- [Privilege API and local-GID mappings](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/privilege.py)
- [Privilege dependency and administrator guards](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/account_/privilege.py)
- [Password-enabled administrator proof](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/account_/builtin_administrator.py)
- [Filesystem stat and directory-list API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/filesystem.py)
- [Filesystem stat lexical realpath and listing behavior](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/filesystem.py)
- [Dangling-link stat omission](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/filesystem/stat_x.py)
- [Recursive ACL tool skips symlink entries](https://github.com/truenas/nfs4xdr-acl-tools/blob/ee7b2d3389280ebc15e13cdb9e3889b732ecac96/nfs4xdr_winacl/nfs4xdr_winacl.c#L841)
