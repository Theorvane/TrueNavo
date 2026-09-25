# Global NFS service settings

This bounded native workspace implements `nfs.config` / `nfs.update` for stable
TrueNAS 25.10 using the pinned **TS-25.10.1** public contract. It is separate from
individual NFS exports and from service start/stop management. It is not full
NFS WebUI parity. All development verification uses synthetic transports and
fixtures: no NAS connection, credentials, service command, update or probe is
executed against a real machine.

## Supported configuration

| Setting | Native behavior |
| --- | --- |
| Server threads | Automatic (`servers: null`) or manual integer 1–256. |
| Protocols | Nonempty NFSV3 / NFSV4 selection; changes require zero enabled exports. |
| Bind addresses | Changed selections use only current static unicast IPv4 choices; changes require zero enabled exports. Empty selection means all interfaces when started. |
| Mountd logging | Explicit boolean change; additionally reloads syslogd. |
| Statd / lockd logging | Explicit boolean change. |

The automatic mode read response is **not null**: `managed_nfsd: true` accompanies
a computed `servers` value, currently CPU core count bounded to 1–32. The DTO
therefore separates `settings.serverThreads` (null for automatic) from
`reportedServers`. A log-only update does not accidentally pin the computed
count. Automatic-mode write/readback comparison checks this representation
semantically, while preserving every other supported configuration field.

All updates require NFS **STOPPED**, verified immediately in each bounded
configuration/readiness sample. This workspace sends no `service.control`,
start, stop, restart or enable-at-boot RPC. Manage the service independently and
reload this page. The page does not automatically stop a running server for a
settings change or start it afterward.

Protocol removal checks **all configured exports, including disabled exports**.
NFSV4 cannot be removed while any export uses KRB5/KRB5I/KRB5P or a protected
NFSV4 domain is configured. Unchanged protocol and binding lists are preserved,
not silently reordered. Existing IPv6 bindings can be displayed and preserved
for other edits but cannot be changed in this bounded editor. Any configured
binding missing from the current static choices blocks updates because the
server validates existing bindings even for an unrelated update.

## Protected and unsupported settings

Ports, `allow_nonroot`, `userd_manage_gids`, `v4_domain`, Kerberos/keytab settings,
RDMA, directory services, service boot enablement and individual exports are
read-only here and are never included in the changed-field patch. Port collision
management and IPv6 bind editing are deferred. The schema reserves **20049** for
NFS RDMA; an older plugin docstring says 20040, which is not the pinned schema
constraint.

Kerberos enabled, NFS keytab capability, RDMA enabled, HA, or a configured
directory-service profile blocks mutation. Directory admission requires
`enable: false`, null `service_type`, null credential/configuration, and no
Kerberos realm. Dormant configured AD/LDAP/IPA profiles are intentionally
protected rather than modified incidentally. `allow_nonroot` means accepting
non-root **source ports**, not root-user mapping; an existing value is preserved
and identified as a protected policy. A keytab capability does not establish
that every export forces Kerberos authentication.

Unknown/malformed public configuration, unsupported protocol/security flavors,
invalid service-state shapes, excess inventories or unprovable dependencies
fail closed. Admission uses full administrator status, stable endpoint/host,
boot identity and version, READY, non-HA, healthy non-scanning boot pool,
unchanged bootable next environment, and absence of visible active/waiting jobs.
These are bounded checks, not a guarantee that no concurrent work exists.

## Source effects and consent

`nfs.update` writes the configuration and uses `_update_service(..., 'restart')`.
The service helper generates `rc` configuration even when stopped. It only
requests a restart if the service is running. A changed mountd log setting
subsequently reloads syslogd. A later failure does **not** undo earlier writes.

STOPPED checks are not atomic with the update. If another administrator starts
NFS after the last check, a running restart can interrupt clients and regenerate
exports. Export generation may resolve hostnames and users/groups, manage alerts,
clean generated export files, and disable ZFS `sharenfs` properties. This is why
the workflow requires independently coordinated stopped-service/client recovery
consent, even though it does not itself issue a service command. Bind changes
add a distinct interface exposure/firewall consent; an empty bind list is not a
restrictive listen policy.

There is no dry run, client mount test, throughput test, service start, directory
health query, DNS probe or external reachability check. `directoryservices.config`
is a local configuration read; `directoryservices.status` is deliberately not
used because it can trigger a directory health check. Standard ConfigService
reads can initialize a missing datastore row on an uninitialized appliance;
configuration queries are not an absolute no-mutation guarantee for malformed
or uninitialized systems. The local configuration
response may contain protected credentials. Only a configured/unconfigured
boolean is exposed publicly; the complete dependency is immediately bound by a
per-session keyed HMAC. No directory secret, raw dependency map or private proof
is present in DTOs, widgets, logs or errors. The key and leases are discarded on
session close/replacement.

## Review, execution and uncertain outcomes

Only repository-issued immutable inventories and five-minute, one-use reviews
can execute. The exact target is `UPDATE NFS <full 64-hex host ID>`.
Each update carries a minimal changed-field patch for supported fields only;
private complete configuration and dependency proofs detect drift. Every awaited
preflight read and the final dispatch guard recheck session/route authorization.
Response and fresh readback must match the expected configuration and preserved
dependencies. Success means **configured values verified**, not effective
exports, working clients, firewall access, identity mapping or performance.

Once the update RPC has been invoked, exceptions, timeouts, lost authorization,
invalid receipts or mismatched readback produce `unknown`. That SDK session is
terminal for mutations; it does not poll, retry or replay. The app retains its
shared management-write fence across navigation and connection changes. Manual
fresh-session reconnection to the original address, an explicit same-host
readiness read and independent inspection acknowledgement can release only the
app fence after the old invocation settles. The original receiptless operation
remains unverified; a claimed host ID is not remote attestation.

The native editor and review invalidate on background, route coverage, session
or inventory changes. Actual input controllers are cleared on abandonment.
Normal owned-dialog cancellation/submission closes explicitly without treating
its reverse animation as unrelated route coverage. There are no popup selectors
that bypass or accidentally trigger route authorization. Consumed/expired
inventory and charts are hidden until an explicit refresh.

Dashboard visuals represent configured export enablement and configured thread
counts only. An enabled export may be inaccessible while NFS is stopped. The
thread bar is a count on a 0–256 API-limit scale, not utilization or health.
Empty export inventory has no inferred percentage.

## Pinned primary sources

- [NFS public schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/nfs.py)
- [NFS configuration/update and bind choices](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/nfs.py)
- [Service configuration change helper](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/service/service_mixin.py)
- [NFS export generation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/etc_files/exports.mako)
- [NFS security flavor selection](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/nfs_/sec.py)
- [Local directory configuration projection](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/directoryservices_/datastore.py)

Verification lives in `test/session/session_nfs_settings_test.dart`, the shared
synthetic fixture, independent `session_nfs_settings_safety_test.dart`, and the
native app's `test/features/nfs_settings/` controller/widget suites. Layout
coverage includes 320/430/1100 widths, light/dark, 200% text and open-keyboard
editor/review interactions. No runtime client measurements are invented.
