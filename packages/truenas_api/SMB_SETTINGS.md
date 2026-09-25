# Bounded global SMB settings

This native workspace reads global Samba configuration and edits five typed
fields: server NetBIOS name, workgroup, description, multichannel and transport
encryption. It is separate from individual SMB share management and is not full
SMB/WebUI parity. Development and verification used pinned public source and
synthetic SDK/UI fixtures only. No NAS login, credentials, appliance contact,
SMB client probe, server write, service restart or discovery request was used.

## Pinned contract and actual effects

The [TS-25.10.1 schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/smb.py)
defines `smb.update` as an ordinary authenticated SHARING_SMB configuration
update, not a job or file transfer. Its `ForUpdateMetaclass` accepts a partial
object. The [implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/smb.py)
merges that object with existing configuration and validates the complete merged
configuration. This adapter sends **only changed fields** among:

```text
smb.update [ {
  netbiosname?: STRING,
  workgroup?: STRING,
  description?: STRING,
  multichannel?: BOOLEAN,
  encryption?: DEFAULT | NEGOTIATE | DESIRED | REQUIRED
} ]
```

No unchanged field, ID, SID, alias, auxiliary option, SMB1/NTLMv1 flag, charset,
mask, bind address, Apple extension, account mapping, logging or local-master
field is submitted. Empty descriptions are intentional values, not omissions.
Names use a conservative 1–15 ASCII letter/digit/hyphen subset beginning with a
letter and exclude the pinned [reserved NetBIOS names](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/netbios.py).
Descriptions are limited to 120 characters without ASCII control characters. Alias/workgroup/name
collisions are rejected locally. Broader source-supported naming forms remain
protected rather than silently normalized.

Every update commits the database **before** generating Samba configuration and
calling the service-change helper. That helper always regenerates rc configuration
and [restarts SMB only when the service was running](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/service/service_mixin.py).
The app does not issue another service start/stop/restart. A stopped service still
has configuration regenerated; a running service can disconnect clients and
interrupt transfers. Regeneration resolves account/group information and validates
shares. Invalid audit-share groups can cause shares to be omitted from generated
configuration. This is not a harmless description-only write.

Changing the server NetBIOS name additionally sets the existing local SID,
synchronizes the local Samba password database, flushes identity caches and toggles
configured network announcements. Workgroup/name changes can require coordinated
client remapping or discovery changes. A [known existing domain SID](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/smb_/sid.py)
is required, because absent SID handling can initialize and store a new identity.
The adapter preserves the SID exactly; it does not initialize, rotate or claim to
attest runtime identity. The update response snapshot is captured before some
rename effects, so it is not proof that clients reconnected or passdb work succeeded.

Encryption must be unchanged or strictly stronger. DEFAULT currently has
NEGOTIATE behavior; swaps between those equivalent modes and all downgrades are
blocked. DESIRED encrypts when a client supports it; REQUIRED can reject incompatible
clients. DEFAULT/NEGOTIATE do not mean every session is encrypted. Multichannel is
a configured capability, not measured throughput or proof of active network paths.

## Protected profiles and safe reads

Mutation requires stable TrueNAS 25.10, exact authenticated non-job/non-file public
metadata, FULL_ADMIN before and after reads, the original endpoint/host/boot,
READY/standalone state, no conflicting jobs or pending reboot reasons, healthy
boot configuration and matching current/next boot environments. These reused
conservative boot/readiness guards do not establish workload safety, spare space,
service state, active client count or end-to-end access.

This increment blocks HA, nonempty auxiliary parameters, enabled SMB1 or NTLMv1,
missing/invalid existing SID, custom guest accounts, privileged admin-group mappings,
directory integration and configured FIPS/STIG profiles. Those settings are not
weakened, cleared, migrated or enabled by this workspace. Apple extensions are
preserved; an existing configuration with disabled Apple extensions and dependent
shares is blocked for separate repair.

`smb.config` removes the stored secrets field in its public extender, but
`smb_options` can still contain sensitive auxiliary content. The adapter exposes
only its presence, never its value. Its entire protected configuration is included
in a private per-session keyed SHA-256 preservation proof, including exact null,
empty, list ordering and unknown-shape rejection. All expected 21 schema keys must
be present; a changed or unexpected response schema fails closed.

Directory readiness uses `directoryservices.config`, **not**
`directoryservices.status` or a health method. The latter can initialize directory
health and contact AD/LDAP. The config [extender](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/directoryservices_/datastore.py)
is a local datastore projection but may return nested credentials and configuration.
The [public schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/directory_services.py)
has no ConfigService select parameter. Only a safe configured/unconfigured boolean
escapes the adapter; admission requires `enable:false` and null service type,
credential, configuration and Kerberos realm. A disabled but still configured
directory is not considered standalone. `system.security.config` similarly
projects only configured FIPS/STIG booleans; no active-FIPS subprocess or security
probe is called.

Complete DS/security responses are bounded and privately HMAC-fingerprinted, not
retained in public DTOs, review messages or logs. Hidden fields changing between
load, review, preflight or readback invalidate authorization or make a dispatched
result unknown. Bounds are 12 nesting levels, 4,096 nodes, 256 map entries, 1,024
list entries, 256-character keys, 131,072 characters per string and 262,144 total
string characters. The per-session key and temporary encoded byte buffers are
zeroed on disposal/use; Dart's immutable incoming strings cannot be promised
physical memory erasure. There is no persisted secret or unkeyed public hash.

Share reads avoid nested option/union serialization and raw auxiliary data:

```text
sharing.smb.query [ [], {
  limit: 257, select: [id, enabled], extra: {retrieve_locked_info: false}
} ]

sharing.smb.query [ [ [OR, [
  [options.afp, =, true], [options.timemachine, =, true],
  [purpose, =, TIMEMACHINE_SHARE], [purpose, =, FCP_SHARE]
]] ], {count: true, extra: {retrieve_locked_info: false}} ]
```

Only safe ID/enabled headers and a scalar dependency count are returned to this
workspace. Selecting `purpose` without complete nested `options` can fail the
public share union validator, so no such partial projection is used. The OR filter
matches the pinned backend Apple-extension validation. No SQL-forced filtering,
share paths/options, directory health call or direct SMB probe is used. More than
256 configured shares fails closed instead of treating a partial list as complete.
Counts include disabled rows and do not represent effective generated shares,
mounted clients, bandwidth, traffic, successful access or live security posture.

## Review, ownership and uncertain outcomes

`AuthenticatedSmbSettingsSession` exposes `smbSettingsCapabilities`,
`loadSmbSettings`, `reviewSmbSettings` and `executeSmbSettings`. Inventories and
reviews are session-issued immutable identities, not caller-created authority.
The exact confirmation is `UPDATE SMB <full host ID> <original NetBIOS name>`.
Review details show the endpoint, full host identity and only changed fields.

Reviews are single-use and expire after five minutes, with age checked again after
all preflight awaits. The required `isCurrent` callback is checked throughout reads
and immediately before dispatch; throwing callbacks fail closed. Complete private
configuration, DS/security proofs, share headers/dependency count and baseline
identity/readiness must still match. Reads and reviews use bounded configuration
and dependency queries and issue no explicit client probe or service-control call.
Standard ConfigService reads can initialize a missing datastore row on an
uninitialized appliance; they are not an absolute no-mutation guarantee for
malformed or uninitialized systems. The UI separately requires service/regeneration impact consent,
identity impact consent for name/workgroup changes and compatibility consent for
encryption/multichannel changes.

Normal editor/review route closure holds modal ownership until
`DialogRoute.completed`. Covering another route, leaving the page, backgrounding,
changing the session or replacing the inventory expires the draft/review and
clears actual local text buffers. Inline encryption choices create no popup route.
The UI carries no arbitrary raw JSON or secret configuration.

Before dispatch, invalid authorization is rejected without a write. Once
`smb.update` is invoked, **every** error, timeout, cancellation, malformed receipt,
protected-field drift or mismatched independent readback is unknown, not rollback.
Success requires the expected full response plus a separate fresh readback of
saved editable/protected configuration and dependencies. It proves saved settings
only, not restart success, runtime encryption, client connectivity, announcement
delivery, password synchronization or share availability. Reads are bounded and
non-atomic; other administrators and backend processing are not transactionally
locked by this app.

Pending operations and unknown outcomes share the cross-workspace mutation fence.
There is no automatic retry, polling, reconnect, rollback or repeat restart.
Recovery requires an explicitly reconnected fresh session at the original endpoint,
the same claimed full host identity and baseline readiness, followed by independent
operator inspection acknowledgement. This releases only the app lock, not the old
SDK session's terminal fence, and never replays the update. A still-pending old
future prevents acknowledgement. Host matching is not cryptographic attestation.

## Synthetic validation

The main SDK protocol suite and independent safety suite cover changed-field
payloads, all typed actions, exact metadata, malformed/oversized responses, private
dependency drift, protected profiles, SID/alias preservation, share projection,
review/session/route races, expiry and one-use leases, unknown readback/error fences,
generic bypass denial and SMB/NFS cross-workspace exclusion. Controller/widget
tests cover separate consents, modal transitions, buffer clearing, recovery fences,
empty/error states, light/dark charts and 320px/200% text with a keyboard inset.

```bash
fvm dart test test/session/session_smb_settings_test.dart test/session/session_smb_settings_safety_test.dart
fvm flutter test test/features/smb_settings
```

Run the first command from `packages/truenas_api`, and the second from
`apps/trueraid`. No production endpoint or credential is part of these fixtures.
