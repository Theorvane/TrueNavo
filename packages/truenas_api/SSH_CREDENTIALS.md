# Native SSH credentials: bounded TrueNAS 25.10 contract

This workspace adds projected keypair/SSH-connection inventory, write-only import of an unencrypted OpenSSH private key, explicitly reviewed RSA generation **and storage**, manual SSH connection configuration with independently verified host keys, name-only edits of unused records, and non-cascading deletion of unused records. It does not provide full WebUI SSH parity.

Development used pinned public `TS-25.10.1` middleware source and synthetic transports/widgets only. No NAS contact, user credential access, real SSH connection, remote host scan, remote authentication or real mutation was used for development or verification.

## Projection is type-sensitive

The API declares the whole `attributes` object as secret. The native client intentionally reads bounded connection configuration and public key material, **not stored private-key material**. Those are different claims: endpoint/username/host trust remain potentially sensitive configuration, so raw objects and remote errors are not displayed or logged. [Public keychain models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/keychain.py).

`attributes.private_key` has two incompatible meanings: the private key string on an `SSH_KEY_PAIR`, but an integer keychain reference on an `SSH_CREDENTIALS` record. Consequently the client sends two separate type-filtered queries, never a combined query that projects that field from both types:

| Read | Exact parameters / interpretation |
| --- | --- |
| Public keypairs | `keychaincredential.query [[["type","=","SSH_KEY_PAIR"]], {"limit":33,"select":["id","name","type","attributes.public_key"]}]` |
| SSH configuration | `keychaincredential.query [[["type","=","SSH_CREDENTIALS"]], {"limit":33,"select":["id","name","type","attributes.host","attributes.port","attributes.username","attributes.private_key","attributes.remote_host_key","attributes.connect_timeout"]}]` |
| Dependency count | `keychaincredential.used_by [id]` for each displayed credential; at most 256 bounded title/action entries, with only the count retained. |
| Active jobs | `core.get_jobs [[["state","in",["WAITING","RUNNING"]]], {"limit":129,"select":["id","method","state"]}]`; any active job blocks a new credential change. |

The server filters before applying nested-field projection. Every response must match its requested type; a keypair-shaped response in the connection query is rejected before the private-key field is interpreted. Public-key/host-key fields must contain structurally valid supported public keys; a misplaced private block or arbitrary raw string fails closed. There is no fallback to full attributes, `get_of_type`, private-key retrieval, logs or secret-bearing raw JSON. [Nested projection implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/filter_list.py).

The native limit is 32 keypairs plus 32 connections. It refuses a larger inventory and refuses creating a 33rd entry of either type. This bounds dependency fan-out rather than silently truncating it. At most 128 active jobs are accepted; missing/malformed dependency or job data is not treated as zero.

## Public write contracts and effects

| Native operation | Exact RPC shape | Side effects and interpretation |
| --- | --- | --- |
| Import keypair | `keychaincredential.create [{"name":name,"type":"SSH_KEY_PAIR","attributes":{"private_key":newPrivate,"public_key":optionalPublicOrNull}}]` | TrueNAS writes temporary mode-0600 files, uses local `ssh-keygen` to validate/derive/match public identity, then stores the credential encrypted in its database. |
| Generate and store | `keychaincredential.generate_ssh_key_pair []`, safe-state reread, then the same create RPC with the generated pair | **Two explicitly reviewed operations.** Generation invokes local `ssh-keygen -t rsa` in a temporary directory but does not itself create a keychain record. Private material remains in short-lived SDK memory, never the Flutter UI. |
| Manual connection | `keychaincredential.create [{"name":name,"type":"SSH_CREDENTIALS","attributes":{"host":host,"port":port,"username":username,"private_key":existingId,"remote_host_key":verifiedPublicKeys,"connect_timeout":seconds}}]` | Stores local configuration only. The implementation does not connect, authenticate, scan host keys or confirm keypair usability. |
| Rename unused record | `keychaincredential.update [id,{"name":newName}]` | Server-side shallow merge retains old attributes. Even this path revalidates keypairs using temporary files and invokes `zettarepl.update_tasks`; therefore native rename requires zero dependencies and no active jobs. |
| Delete unused record | `keychaincredential.delete [id,{"cascade":false}]` | Requires an unused entry, deletes the record, and returns **null**, not true. No cascade, unbinding, schedule disabling or remote revocation is authorized. |

These behaviors were checked against [keychain implementation and delegates](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/keychain.py). A create/update response can contain private attributes. The SDK reads only its bounded ID/name/type, discards those attributes, then performs separate projected inventory/dependency reads to verify the visible result. For import/generation, the result's public key is taken from that safe verification inventory, not delivered from a raw credential response.

## Key format and host trust

Imported private material is restricted to an unencrypted, single-key OpenSSH container no larger than 64 KiB. Encrypted keys, PEM formats, multiple-key containers and public-only imports are outside this native flow. The SDK validates the container header, cipher/KDF identifiers, one-key count and embedded public identity; TrueNAS's local `ssh-keygen` remains responsible for cryptographic private/public validation. Synthetic tests are format/transport tests, not evidence that a synthetic private blob is a usable key.

The Flutter import uses a deliberate **Paste private key** action to preserve multiline bytes in a concealed read-only field; a separate Clear action discards it. Clipboard contents are never read automatically. Editor/review disposal, backgrounding and connection changes discard held private input, and late clipboard completions are rejected. The SDK's disposable input is also disposed on every execute exit, including a disconnected public-repository call. Private material never belongs in provider state, profiles, caches or logs. This controls reference lifetime, not guaranteed memory erasure: Dart strings, the operating system's clipboard history and the user's source application may retain copies; no automatic clipboard deletion or screenshot-proofing is claimed.

Public parsing accepts structurally bounded Ed25519, RSA with positive canonical mpints and 2048–8192-bit modulus structure, and ECDSA P-256. It checks wire algorithm tags and lengths, not remote ownership or complete mathematical key validity. SHA-256 fingerprints hash the SSH wire-format public-key blob using the standard `crypto` package, not the textual base64 representation. Public comments are omitted from the normalized displayed identity.

Connection host-key comments are removed **before** constructing the public inventory model, not merely hidden by the UI. Only validated algorithm/base64 pairs and their fingerprints remain. Comment-only changes therefore do not create a new cryptographic host identity or put arbitrary server comment content in provider state.

Manual host input permits bare hostnames/IPs, port 1–65535, a bounded plain SSH username, and timeout 1–120 seconds. Host trust accepts 1–8 distinct public key lines and at most 1024 characters in total, matching the bounded server string field; a large RSA key can therefore be unsuitable for this host-key field even if its keypair public format is supported. No `known_hosts` host-pattern prefixes, shell options or automatically accepted scan output are supported.

The same host/account/port/timeout checks apply to existing server records before they can enter the public inventory model. A stored URL with embedded user-info/password, shell-like account, invalid range or unsupported host-key shape makes the inventory unavailable with a fixed redacted error, rather than displaying the raw value. Correct such unsupported configuration in TrueNAS before using this bounded workspace.

The user must explicitly attest independent host-key verification and review every supplied SHA-256 fingerprint. A fingerprint only identifies the supplied blob; it does not prove the actual host's identity. An existing keypair ID is rechecked, but safe projection cannot prove that private material is present: public-only records can exist. A stored SSH configuration is consequently **not** proof of a usable or authenticated connection. Secret-only external replacement can preserve the public metadata and is not detectable here.

## Dependencies, review and conservative recovery

`used_by` covers keypairs referenced by SSH connections and SFTP cloud credentials. It recursively includes the connection's replication and rsync dependencies. The response has display titles and unbinding actions, not stable dependent IDs; the SDK never invents IDs or parses them from titles. Only absence of all dependencies permits rename/delete. A new connection adds exactly one observed usage of its referenced keypair; deletion of an unused connection removes that one usage. All other projected entries must remain unchanged during post-write verification.

Reviews are issued only from this exact session's inventory, expire after five minutes, and are single-use. Exact action/ID/name/endpoint confirmation is required. Refresh, wrong confirmation, forged/reused review, disconnect, changed public identity, changed dependency count or active-job state prevent a new submission. Generation is followed by another fresh read before storage so a new conflict cannot silently proceed to the second effect.

Every exception, permission-shaped error, timeout, lost connection, malformed receipt or mismatched post-write observation **after the first effectful RPC** produces an unknown outcome. That includes successful generation followed by failed storage. Input references are discarded, no private value is returned, and the shared SDK/Flutter mutation fence remains held. Local refresh cannot clear it. Recovery requires inspecting the original server and dependencies, then a fresh same-server connection and explicit acknowledgment; it does not claim rollback or automatically replay the request.

There is no atomic compare-and-swap across reference reads and a datastore mutation. An external administrator can still race after preflight. `cascade:false` supplies an additional server-side dependency guard but is not a transactional guarantee. Deleting a keychain record does not remove remote `authorized_keys`, stop SSH services, disable referencing tasks automatically or terminate existing remote sessions.

## Explicitly excluded network workflows

`remote_ssh_host_key_scan` runs `ssh-keyscan` against a remote endpoint. Its output is discovery, not trust. `remote_ssh_semiautomatic_setup` authenticates another TrueNAS instance and can enable/start its SSH service, append authorized keys, change the remote user's shell/sudo configuration and create local credentials. `setup_ssh_connection` can chain generation/setup operations. None of these endpoints, the private `ssh_pair`, or a remote authentication verification endpoint is called by this workspace. Their generic-admin routes remain unavailable.

Remaining parity work includes semiautomatic pairing with a separate remote-authority model, controlled discovery with out-of-band verification, existing connection/host-trust replacement, private-key export/rotation, public-only and additional key formats, larger inventories, directory-specific usernames, live acceptance testing and remote task execution. The connector-free preview refuses all writes and network actions. This implementation does not claim full WebUI parity or official TrueNAS affiliation.
