# Session management contract

`AuthenticatedSessionManagement` is a separate typed capability from the six-method, no-parameter inventory interface. There is no generic mutation RPC escape hatch.

| Operation | TrueNAS 25.04 | TrueNAS 25.10 / 26.0 |
| --- | --- | --- |
| Start / stop / restart service | `service.start` / `service.stop` / `service.restart`; boolean result | `service.control`; job ID followed by a bounded `core.get_jobs` read |
| Create child filesystem dataset | `pool.dataset.create` | Same |
| Delete non-root dataset | `pool.dataset.attachments` preflight, then `pool.dataset.delete` | Same |
| Create one snapshot | `zfs.snapshot.create` | `pool.snapshot.create` |

Only recognized release versions in these families are allowed. Unknown and prerelease versions are refused. Each endpoint must also be advertised by the authenticated server. The server remains the authority for account permissions; method availability does not prove write authorization.

## Safety boundaries

- No management or inventory calls before the complete authenticated handshake.
- Exact validated names only; root deletion and hidden/system, boot, and app-system dataset paths are blocked.
- Child filesystem creation does not create ancestors and inherits parent encryption.
- Snapshot creation is nonrecursive. Dataset deletion sends explicit `recursive: false` and `force: false`; children and snapshots are not recursively destroyed.
- Deletion refuses observed share/task attachments and refuses unreadable or malformed dependency checks. **The upstream API can delete attachment delegates even with `force: false`. Its dependency check and delete are not atomic. Do not concurrently attach new shares or tasks to a dataset being deleted.**
- One mutation submission at a time. Shared SDK locks also retain owned pending jobs and unresolved mutations across other gateways, including native SMB/NFS. No automatic mutation retries, including timeouts and transport loss.
- Timeouts, unrecognized responses and non-permission mutation RPC errors mean **unknown completion**, not failure or success: middleware may already have changed configuration. Inspect actual server state and establish a fresh session before another mutation without a recoverable owned job. Reconnection does not certify the old outcome.
- Jobs are bound to the exact authenticated session and issued result object. Polling remains available while its mutation fence is held and reads only the submitted ID with `limit: 1`; it never reissues the mutation. Unknown polls keep the fence until an exact terminal result or a fresh session. Terminal responses are cached.
- Errors displayed to clients are fixed, sanitized messages. Only explicit EPERM/EACCES values indicate permission failure; JSON-RPC `-32001` alone is a generic method-call error.

## Sources and verification

Contracts were checked against [25.10 service control](https://api.truenas.com/v25.10.0/api_methods_service.control.html), [26.0 service control](https://api.truenas.com/v26.0/api_methods_service.control.html), [dataset deletion](https://api.truenas.com/v25.10.0/api_methods_pool.dataset.delete.html), [26.0 snapshot creation](https://api.truenas.com/v26.0/api_methods_pool.snapshot.create.html), and the [TrueNAS JSON-RPC error contract](https://api.truenas.com/v25.10.0/jsonrpc.html).

Legacy behavior was checked in the official middleware `TS-25.04.2` sources: [service.py](https://github.com/truenas/middleware/blob/TS-25.04.2/src/middlewared/middlewared/plugins/service.py), [pool_/dataset.py](https://github.com/truenas/middleware/blob/TS-25.04.2/src/middlewared/middlewared/plugins/pool_/dataset.py), [zfs_/dataset.py](https://github.com/truenas/middleware/blob/TS-25.04.2/src/middlewared/middlewared/plugins/zfs_/dataset.py), and [zfs_/snapshot.py](https://github.com/truenas/middleware/blob/TS-25.04.2/src/middlewared/middlewared/plugins/zfs_/snapshot.py).

The fake-transport tests assert the actual serialized wire methods, parameters, results, capability gates, deletion preflight, session/ID binding, timeouts, stale/lost sessions, and no retries. They do not substitute for an integration test on a disposable NAS. No real NAS mutation is performed by the test suite.
