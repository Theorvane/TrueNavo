# Native administration gateway

`AuthenticatedAdminSession` is separate from both the six-method
`AuthenticatedSessionQueries` inventory boundary and the existing typed
`AuthenticatedSessionManagement` workflows. It does not expose arbitrary RPC.

## Enablement

An operation needs every one of these conditions:

1. The currently authenticated connection is still open and current.
2. Its exact version matches the verified stable **25.10** adapter family.
3. The method is explicitly listed in `adminOperationDefinitions` with no
   `blockedReason`.
4. That connection's authenticated `core.get_methods` response advertises the
   method and complete accepts/returns/job/auth/file metadata.
5. It is not private, unauthenticated, a pipe upload/download, or a specialized
   workflow deferred by policy.
6. Required input schemas are representable by the bounded native editor.
7. Every supplied argument validates against the session-owned schema.
8. A job method has advertised `core.get_jobs` inspection capability.

A method's presence is not a promise that a write will succeed: middleware
still checks current permissions, validation and dependencies on every request.
The gateway deliberately does not expand permissions or silently use a newer
adapter for an unverified release.

## Schemas and immutable state

TrueNAS 25.10 `core.get_methods` exposes `accepts` and `returns` as lists of
schemas. Parameters use `_name_` and `_required_`. Its compatibility conversion
wraps array `items` in a one-element list; this means repeated elements, not a
one-element tuple. The parser normalizes that form and bounded local `$ref`s.

The native subset supports scalar fields, fixed-property objects, repeated
arrays, enums/constants, nullable alternatives, `anyOf`/`oneOf`, bounds and
patterns. Unknown assertions, untyped input dictionaries, multiple item tuple
schemas, union-sibling assertions and recursive/remote references fail closed.
An unsupported optional parameter/property can be omitted, not edited as raw
JSON. The server may apply its advertised defaults to omitted values.

Inputs are limited to 32 positional arguments, 4096 value nodes, 65,536 combined
string/key UTF-16 code units, and nesting depth 12. Individual scalar strings are at
most 8192 characters. Single-line native inputs reject invisible control/bidi
characters; multiline scripts and key material need dedicated editors.

`AdminRequest` freezes arguments. Only the exact `AdminMethodSpec` object owned
by the current connection can be invoked. A fabricated catalogue, copied method
name, stale session or repeated request object cannot dispatch a mutation.

`redactedArguments` is a transient full-fidelity confirmation preview: it masks
schema/heuristic secrets but does not shorten non-secret target values. Every
returned `AdminResult` retains a request with **empty arguments**, so submitted
credentials do not become provider state or job-cache values. Secret defaults,
examples and parent defaults containing secret fields are removed from schema
metadata. Secret enum/constant fields require a dedicated editor.

Output sanitization follows secret flags across every union branch and also
redacts password, key, token, credential, hash and remote-error/argument fields.
Inventory output is bounded to 100 items/fields per collection, 512 characters
per string and depth eight. It is a bounded preview, not an export or complete
audit record.

## Submission and jobs

There is one in-flight submission across the generic gateway and legacy typed
management interface. The shared SDK mutation fence also persists after an owned
mutation job is submitted and after an uncertain mutation response, including
across the native SMB/NFS gateways. Mutations are never retried automatically.
Timeout, transport/session loss and non-permission mutation RPC errors produce
`AdminOutcomeUnknown`, because a server can save before later work fails. Only
exact integer EPERM/EACCES values retain the permission-denied classification.
Remote errors have fixed, sanitized user messages. Harmless read errors and read
jobs do not create a durable mutation fence.

A job result is bound to the actual submitted object, original connection,
positive job ID and exact method. One explicit `pollAdminJob` reads only that
ID with `limit: 1`, selects status/result and sets `raw_result: false`. It never
resends the original operation. `SUCCESS` may legally return an object or null;
it is not incorrectly interpreted using the old service-only boolean contract.
Terminal outcomes are cached for a bounded 64 submitted job objects. Read-job
cache pressure cannot evict an unresolved mutation handle. Unknown polls retain
the original ID and fence; explicit polling remains available and an exact
terminal result can release its pending-job fence. An uncertain mutation without
an owned job requires inspection and a fresh session. Reconnecting does not prove
the earlier operation succeeded, and never replays it.

## Verified primary contracts

- [TrueNAS 25.10 core.get_methods](https://api.truenas.com/v25.10.0/api_methods_core.get_methods.html)
- [Middleware TS-25.10.1 metadata generation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/service/core_service.py)
- [Middleware TS-25.10.1 JSON Schema compatibility conversion](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/base/jsonschema.py)
- [TrueNAS 25.10 job protocol](https://api.truenas.com/v25.10.0/jobs.html)

Tests use in-memory fake transports only; no NAS mutation or credential access
is part of this package's test suite. The registry's explicitly deferred native
workflows must not be described as implemented WebUI parity.
