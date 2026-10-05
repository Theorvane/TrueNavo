# Native SMB shares (TD-034, bounded partial)

This workspace implements real, authenticated `sharing.smb.create`, `update`, and `delete` request paths. Development and verification use public source and connector-free fake transports only: no NAS, credentials, or live writes were used.

## Supported workflow

- Inventory of configured shares, enabled/disabled counts, and public `service.query` SMB state/boot-enable status. Counts are configuration counts, **not** sessions, traffic, or proof of client availability.
- Create a `DEFAULT_SHARE` on an existing standard `/mnt/pool/dataset` filesystem root; choose name, single-line comment, SMB read-only, and enabled. The client does not create the path or apply a filesystem ACL.
- Edit comment, SMB read-only, or enabled for an eligible existing default-purpose share. Only changed top-level fields are submitted; path, purpose, name, audit, browsing, enumeration, and options are not implicitly sent as defaults on update.
- Delete the selected share configuration, with an explicit client-disconnection/share-ACL warning. No dataset deletion or file deletion is requested.
- Typed exact-target, single-use impact review; fresh session, configuration, dataset/ancestor identity, dependency, and filesystem-permission checks; independent post-readback; unknown outcomes are locked against retry.

The Flutter workspace and synthetic preview are implemented alongside this SDK. Preview mutations always reject without invoking a transport.

## Pinned wire contracts

Source is the official middleware tag **TS-25.10.1**, especially [the 25.10.1 SMB models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/smb.py) and [SMB service implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/smb.py). New SMB fields are `readonly`, not legacy `ro`, and purpose-discriminated `options`.

| Method | Parameters | Receipt |
| --- | --- | --- |
| `sharing.smb.query` | `[[], {limit:257, extra:{retrieve_locked_info:true}}]` | Share-entry list, at most 256 admitted |
| `sharing.smb.presets` | `[]` | Purpose → `{verbose_name:...}`, **not** preset option dictionaries |
| `sharing.smb.share_precheck` | `[{}]` | `null`; requires directory services or an existing local SMB user |
| `sharing.smb.create` | `[{name,path,purpose:"DEFAULT_SHARE",options,comment,readonly,enabled,browsable,access_based_share_enumeration,audit}]` | Complete share entry |
| `sharing.smb.update` | `[id,{only_changed_public_fields}]` | Complete share entry |
| `sharing.smb.delete` | `[id]` | Literal `true` |

CRUD methods are synchronous public RPCs, not client-owned jobs. Any job-shaped or mismatched receipt is unknown, not polled or replayed. Method metadata must affirm non-job, authenticated, non-upload/download, non-private semantics for mutations **and all safety methods**. Version capability is bounded to stable 25.10; wire behavior and source verification are specifically 25.10.1.

Explicit create defaults are `options:{aapl_name_mangling:false,hostsallow:[],hostsdeny:[]}`, browsing on, access-based enumeration off, and auditing off with empty watch/ignore lists. The review discloses SMB exposure and permission implications before submission.

## Source-specific side effects and limitations

Default-share create/update regenerate/reload SMB configuration; an enabled change also reloads mDNS. Disabling closes the share and can disconnect clients. The native client never separately starts/stops the global service. HA is excluded (`failover.licensed` must return false), because service changes can otherwise propagate to another controller. Guest/home paths requiring global restart are not admitted.

Delete removes the share database record and closes active clients. TrueNAS removes an active share's share-level ACL record; inactive ACL records may remain. Existing files, dataset properties, and filesystem ACLs are not deletion targets. Configuration verification is not proof that clients have reconnected.

**No `sharing.smb.getacl` call is made**, even during review: its supposedly read-like implementation [can create `share_info.tdb` and initialize its version](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/smb_/sharesec.py). No private `smb.status`, share session method, share ACL mutation, or command execution is used.

The default when a name-keyed SMB share ACL is absent is Everyone/FULL at the share layer; filesystem permissions still apply. Previously used names can retain a server share ACL. Creation review explicitly discloses this; this client does not read, reset, or verify share-level ACLs. Inspect permissions in the TrueNAS share ACL workspace before enabling a reused name when its history is uncertain.

Renaming is deliberately not exposed on edit: source `apply_share_changes` invokes `flush_share_info`, which can rewrite ACL records for **all** configured shares from private stored ACL copies. Public fields cannot prove this safe. Choose a name during creation; use the dedicated TrueNAS share ACL workflow for renames.

Source `compress` normalizes private legacy flags to preset defaults even when changing an ordinary public field. Public fields are preserved/compared; this SDK **does not promise byte-for-byte preservation of private database fields** and discloses server normalization. Legacy/home/private/Time Machine/multiprotocol/external/Veeam purposes, host restrictions, audit settings, Apple name mangling, and unknown public options remain inventory-only.

## Safety boundaries

Dataset selection requires a non-pool-root, existing writable/unlocked/unencrypted/non-cloned standard filesystem mount, supported ACL/xattr properties, exact nonzero uint64 GUID string, creation value, unmanaged ancestry, and an explicit `filesystem_count=0`. All filesystem ancestors must be visible. Malformed properties, managed markers, hidden child count, unsupported topology, or unavailable proofs fail closed. Filesystem identities stat every path prefix, including `/`, because a leaf `realpath` alone does not prove ancestor canonicalization. No directory listing is used as an absence proof; the pinned listing can omit dangling links.

The proof compares mount identity, owner/group/mode/ACL, and directory device/inode/mount IDs before/after. It checks all public SMB configurations, presets, global SMB configuration, service state, HA state, public enabled dataset attachments, and both enabled/disabled NFS exports. NFS ancestor/subtree overlaps and path aliases are protected; unrelated NFS paths must have verified nonsymlink ancestors. Dataset attachments alone are insufficient: the [pinned implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_attachments.py) omits disabled and parent exports. Exact SMB attachment type is `SMB Share` with service `cifs`.

Limits: 256 share/filesystem inventory entries, 128 NFS rows, 256 NFS path-prefix checks, 256 total attachments, 16 path components, bounded JSON depth/numbers/strings, one issued review lease. Remote errors are replaced with fixed safe messages. Raw auxiliary configuration is never returned through public models, review text, or errors. Public JSON numbers outside the exact safe integer range are rejected; GUIDs use the exact raw string, ignoring redundant numeric `parsed` metadata, and are never submitted.

The API does not provide atomic compare-and-write. Local processes, filesystem content/symlinks inside a share, arbitrary consumers, hidden private settings, and concurrent external changes cannot all be proved absent. Keep other administrators idle; the review makes this residual race explicit. Unknown outcomes require inspection and a fresh connection, never automatic replay. SMB ACL/session/preset editor parity, encrypted/HA/recursive-dataset roots, protocol-wide configuration, custom restrictions, and rename remain outside this slice.

## Verification

`fvm dart test test/session/session_smb_shares_test.dart` exercises synthetic pinned-shape receipts and exact payloads, capability metadata, stale/single-use/forged handles, malformed identities, ancestor links, hidden children, HA, disabled/ancestor NFS conflicts, protected presets/options, secret-safe errors, post-dispatch uncertainty, and no side-effecting ACL/private probes. Flutter controller/widget/preview coverage is in `apps/truenavo/test/features/smb_shares/`.
