# TrueNAS API research for TrueRAID

## Executive conclusion

A new full-function client should treat **versioned JSON-RPC 2.0 over a persistent WebSocket** as the management control plane. TrueNAS 25.04 introduced it; the TrueNAS 26 documentation says the REST management API is removed and clients must migrate before upgrading.[1] File transfer and interactive terminals are separate transports rather than ordinary JSON-RPC calls: uploads/downloads use HTTP helper endpoints and shells use a dedicated binary-capable WebSocket.[3][16]

The key architecture decision is therefore not “WebSocket or REST,” but a transport bundle:

1. versioned JSON-RPC WebSocket for methods, events, auth and job control;
2. HTTP multipart/streaming for file jobs;
3. a separate terminal WebSocket for host/VM/app/container consoles;
4. version discovery and per-release compatibility adapters.

## 1. Management protocol and versioning

### Verified facts

- The documented request shape is standard JSON-RPC 2.0: `jsonrpc`, caller-chosen string/number `id`, method name, and positional `params` array. Responses carry either `result` or an error object. TrueNAS adds error codes `-32000` (too many concurrent calls) and `-32001` (method call error).[2]
- Server-pushed events are JSON-RPC notifications named `collection_update`; subscription termination is sent as `notify_unsubscribed`. Batch requests are explicitly unsupported.[2]
- Current middleware source exposes each API version at `GET /api/{version}` and aliases the newest model as `/api/current`; it also exposes `GET /api/versions` for the installed list.[14]
- The official API client uses `/api/current` for JSON-RPC and describes `/websocket` as the legacy protocol path. Its compatibility matrix says 24.10 is legacy-only, 25.04 introduced JSON-RPC, and 25.10 added new-style job support.[13]
- Appliance-local documentation is available at `/api/docs/`; hosted, version-specific documentation is at `https://api.truenas.com/`. Documentation covers API methods and events for supported versions.[1]
- `core.get_methods` returns runtime metadata mapping method names to signatures, documentation, and metadata; it can target WS, CLI, or REST interfaces.[8] Query-style methods share filter/options semantics including count, limit, offset, select and ordering.[12]

### Product implications (inference)

- **Negotiate, then pin.** Probe `/api/versions`, select an explicitly supported version, and reserve `/api/current` for exploratory/latest-mode connections. This avoids an appliance upgrade silently changing schemas behind an otherwise identical URL.
- Generate client models from versioned published/local docs, but retain `core.get_methods` as runtime capability discovery. Runtime metadata is useful for hiding unsupported controls; it is not, by itself, a stable cross-version contract.
- Supporting TrueNAS 24.10 requires a separate legacy protocol adapter. It should not contaminate the JSON-RPC core.
- On reconnect, assume all connection-scoped subscriptions are gone and authenticate/resubscribe before refreshing state. This follows from `core.subscribe` attaching a subscription to “the current connection.”[7]

## 2. REST status

### Verified facts

- TrueNAS 25.04 deprecated the REST management API. TrueNAS 26 removes it.[1]
- The current architecture still documents `/_upload` and `/_download/{job_id}?auth_token=...` HTTP endpoints for file-bearing jobs.[3]

### Product implication (inference)

“REST removed” means the general REST management surface is gone; it does **not** mean every HTTP endpoint is gone. TrueRAID should describe upload/download as auxiliary HTTP transports, not as a fallback REST client.

## 3. Authentication, API keys and sessions

### Verified facts

- `auth.login_ex` is the primary multi-mechanism login API. In v26 it supports `PASSWORD_PLAIN`, `API_KEY_PLAIN`, `TOKEN_PLAIN`, OTP continuation and API-key `SCRAM`. Its result is a state machine: `SUCCESS`, `OTP_REQUIRED`, `AUTH_ERR`, `EXPIRED`, `REDIRECT`, and related outcomes.[4]
- `_PLAIN` mechanisms transmit password-equivalent material and the docs warn against using them over insecure/untrusted transport.[4]
- v26 SCRAM is SHA-512/RFC 5802 challenge-response for API keys, supports optional RFC 5929 `tls-server-end-point` channel binding, and provides mutual verification/replay resistance.[4] The official client defaults to SCRAM on TrueNAS 26+, does not silently downgrade to plaintext, and says pre-26 servers require explicit plaintext opt-in.[13]
- The older `auth.login_with_api_key` method is deprecated and removed in API v27; clients are directed to `auth.login_ex` using `API_KEY_PLAIN` or `SCRAM`.[21]
- API keys are linked to users, can have an expiration timestamp, and are returned with actual key material when created.[10] TrueNAS warns that the key string is displayed only once, has password-equivalent API access as the associated user, is not gated by that user’s 2FA, and is automatically revoked if used in an insecure HTTP authentication attempt.[1]
- RBAC is enforced on every API call based on roles resolved from group-linked privileges. Fine-grained subsystem roles coexist with `FULL_ADMIN`, `READONLY_ADMIN`, `SHARING_ADMIN`, and `REPLICATION_ADMIN`; roles are additive rather than subtractive.[11]
- `READONLY_ADMIN` is the minimum predefined role for web UI access, but API clients can use custom privileges composed from individual roles. Secret schema fields are redacted for sessions lacking `FULL_ADMIN`.[11]
- `auth.sessions` reports active sessions, including whether each is current, its origin, credential type, credential-specific metadata and whether transport is secure. Credential types include password, 2FA, API key, token, Unix socket and TrueNAS-node sessions.[6] `auth.me` returns the currently authenticated user/session identity.[22]
- `auth.generate_token` creates delegated tokens with TTL (default 600 seconds), embedded attributes, same-origin matching (default true), and optional single-use behavior.[5] Login can request a reconnect token whose TTL follows the web UI session-lifetime preference (default 600 seconds).[4]

### Product implications (inference)

- Prefer **user-linked API keys over WSS**, with v26 SCRAM plus channel binding where the platform permits. Require an explicit warning/setting before plaintext API-key auth for 25.04/25.10.
- Store key material in OS secure storage, never logs/analytics, and expose expiry/revocation status. Key creation is a one-time secret-delivery UX.
- Password login must implement the full challenge state machine, not a boolean login call: OTP continuation and Enterprise HA `REDIRECT` materially affect connection flow.
- Keep a persistent authenticated socket. The official client warns that repeated connection/auth cycles incur auditing/security overhead and documents a rate limit of 20 authentication attempts and/or unauthenticated requests in 60 seconds, followed by a 10-minute cooldown (noted as subject to change).[13]
- Distinguish **API authorization**, `webui_access`, and the separate `web_shell` privilege. A user can be valid for API calls without qualifying for the same UI or shell experience.[11][20]

## 4. Event subscriptions and jobs

### Verified facts

- `core.subscribe(event)` returns a subscription identifier; notifications continue on that connection until `core.unsubscribe`. Unauthorized subscriptions return JSON-RPC `-32001`.[7]
- The published API Events index is the authoritative event catalog; the standard notification includes an operation (`added`, `changed`, etc.), collection, id, fields and extra data.[2]
- Long operations are jobs. To map an initiating JSON-RPC call to a job, subscribe to `core.get_jobs` **before calling**, then inspect both `added` and `changed` events for a `message_ids` array containing the original JSON-RPC request id.[3]
- Job events carry progress and terminal result/error state. `core.get_jobs` can query status, while `core.job_wait` can wait for completion.[3]

### Product implications (inference)

- Build one job coordinator that correlates request id → job id, persists progress in app state, handles cancellation (`core.job_abort` where permitted), and falls back to `core.get_jobs` after reconnect.
- Do not assume every method’s immediate JSON-RPC result is a job id. Published new-style semantics identify jobs through `core.get_jobs.message_ids`; version-specific clients differ here.[3][13]
- Backpressure and subscription lifecycle are first-class concerns: serialize or cap concurrent calls, because JSON-RPC batch requests are unsupported and TrueNAS can reject excess concurrent calls.[2]

## 5. Uploads and downloads

### Verified facts

- Upload-capable jobs accept `POST /_upload` with `multipart/form-data`. The first part must be `data`, a JSON object containing `method` and `params`; subsequent `file` parts carry content. The response contains `job_id`, which is monitored like any other job.[3]
- Current middleware source accepts a short-lived token (query string or `Token` header), HTTP Basic credentials, or a Bearer API key for the upload helper. It authorizes the requested method before starting the piped job and currently caps a request at five files.[15]
- The official Web UI obtains a single-use, same-origin five-minute token and uploads with XHR so it can report byte progress and support cancellation.[17][20]
- `core.download(method, args, filename, buffered?)` returns `[job_id, URL]`; the URL is time-limited and single-use.[9] For a non-buffered download, the consumer must start reading promptly because job output is pipe-backed; the jobs guide states 60 seconds and one download.[3]
- The official Web UI waits on the associated job and then retrieves the generated URL as a blob.[18]

### Product implications (inference)

- Use short-lived, origin-bound, single-use tokens for file endpoints rather than long-lived API keys in URLs or HTTP Basic credentials.
- Upload progress is HTTP byte progress; processing progress is the subsequent job’s progress. Present them as two phases.
- Stream downloads to disk and start non-buffered retrieval immediately. Avoid loading large exports/debug bundles into memory; use buffered mode only when its RAM-backed tradeoff is acceptable.[9]
- Treat the current five-file maximum as a discovered/version-specific limit, not a permanent public contract, because it is established by current source rather than the published jobs guide.[15]

## 6. Shell and terminal

### Verified facts

- Interactive shell is a dedicated WebSocket application, not JSON-RPC. Authentication begins with JSON containing a generated token and an `options` object; after connection, terminal input/output is byte-oriented.[16]
- Current middleware supports host login, VM serial console, application container shell and standalone container shell through this application. It requires the user’s `web_shell` privilege and additional shell-type roles where applicable.[16]
- The official Web UI currently connects to public path `/websocket/shell/`, sends `{token, options}`, switches to binary `arraybuffer` handling, and uses the returned connection id.[19] Terminal resizing is performed separately through `core.resize_shell`.[20]
- Current middleware source registers the underlying shell app at `/_shell`, while the Web UI source uses `/websocket/shell/`; this demonstrates that the public route can be rewritten by the appliance web server and should not be inferred solely from middleware internals.[14][19]

### Product implications (inference)

- Implement a separate terminal transport with mixed text-control frames and binary data, xterm-compatible encoding, resize RPC, disconnect/reconnect UX and explicit target options for host/VM/app/container.
- Discover/validate the shell URL against each supported appliance release rather than hard-coding the internal `/_shell` route. The browser-visible `/websocket/shell/` is the stronger default for current Web UI parity, but route behavior should be integration-tested.
- Shell sessions are ephemeral PTYs; reconnect should open a new session rather than promise process continuity.

## 7. Web-console parity gaps and special handling

The following are the likely parity traps, based on the verified transport and authorization behavior above:

1. **Legacy UI traffic is not the public API contract.** Current source still contains a legacy `/websocket` route and a separate `/api/current` JSON-RPC route; the current Web UI source also constructs its management connection with `/websocket`.[13][14][23] TrueRAID should target the documented versioned API, not blindly reproduce captured browser calls.
2. **HA authentication redirects.** `REDIRECT` must be handled before normal session initialization; active-controller changes also imply reconnect, reauthentication and resubscription.[4]
3. **Two-stage/step-up auth.** Password + OTP and token reconnect are stateful, while API keys bypass user 2FA. The product should make the security distinction visible.[1][4]
4. **Shell, VM serial and container consoles.** These require token minting, a separate WebSocket, binary terminal handling, target-specific options and resize RPC—not a generated JSON-RPC method wrapper.[16][19][20]
5. **Imports, exports, config backups, debug bundles and ISO/file jobs.** These cross JSON-RPC, HTTP streaming and job events, with single-use/timeout behavior.[3][9]
6. **RBAC-conditioned UI.** Controls must be capability/role-aware; read-only, sharing and replication admins have materially different surfaces, and secret fields may be redacted rather than absent.[11]
7. **STIG/security-profile behavior.** The v26 token docs say token generation is unsupported when replay-resistant GPOS STIG authentication is required.[5] Current middleware source is more nuanced for single-use versus multi-use tokens, so token-dependent upload/shell behavior should be feature-tested on every supported STIG release rather than assumed. This is a documented/source tension, not a settled guarantee.[5][15][16]
8. **Version drift.** Published API versions follow TrueNAS releases and method schemas/events can move. TrueRAID needs a tested support matrix, explicit version adapters and an “unsupported appliance version” state.[1][8]

## Recommended support boundary

### Verified basis

- 24.10: legacy WebSocket only.[13]
- 25.04+: versioned JSON-RPC is available.[1][13]
- 26: REST management API removed; API-key SCRAM is available in v26 docs/client.[1][4][13]

### Product recommendation (inference)

- Make **25.04+** the clean minimum for the new core.
- Treat 25.04/25.10 API-key auth as a compatibility tier requiring explicit plaintext-over-WSS support.
- Make 26+ the preferred tier for SCRAM and the long-term full-feature target.
- Add 24.10 only as an isolated legacy adapter if market demand justifies its cost.

## Sources

[1] https://www.truenas.com/docs/scale/26/api
[2] https://api.truenas.com/v26.0/jsonrpc.html
[3] https://api.truenas.com/v26.0/jobs.html
[4] https://api.truenas.com/v26.0/api_methods_auth.login_ex.html
[5] https://api.truenas.com/v26.0/api_methods_auth.generate_token.html
[6] https://api.truenas.com/v26.0/api_methods_auth.sessions.html
[7] https://api.truenas.com/v26.0/api_methods_core.subscribe.html
[8] https://api.truenas.com/v26.0/api_methods_core.get_methods.html
[9] https://api.truenas.com/v26.0/api_methods_core.download.html
[10] https://api.truenas.com/v26.0/api_methods_api_key.create.html
[11] https://api.truenas.com/v26.0/rbac.html
[12] https://api.truenas.com/v26.0/query_methods.html
[13] https://github.com/truenas/api_client/blob/5427b53766747e274650625f29c06c8ae7917966/README.md
[14] https://github.com/truenas/middleware/blob/d4f43b77317bc2e86a9d419632ce1b4f3b9ccd28/src/middlewared/middlewared/main.py
[15] https://github.com/truenas/middleware/blob/d4f43b77317bc2e86a9d419632ce1b4f3b9ccd28/src/middlewared/middlewared/apps/file_app.py
[16] https://github.com/truenas/middleware/blob/d4f43b77317bc2e86a9d419632ce1b4f3b9ccd28/src/middlewared/middlewared/apps/webshell_app.py
[17] https://github.com/truenas/webui/blob/5ebcbc79b0f5f9a3bae4fa6d32ac3eff802cefdb/src/app/services/upload.service.ts
[18] https://github.com/truenas/webui/blob/5ebcbc79b0f5f9a3bae4fa6d32ac3eff802cefdb/src/app/services/download.service.ts
[19] https://github.com/truenas/webui/blob/5ebcbc79b0f5f9a3bae4fa6d32ac3eff802cefdb/src/app/services/shell.service.ts
[20] https://github.com/truenas/webui/blob/5ebcbc79b0f5f9a3bae4fa6d32ac3eff802cefdb/src/app/modules/auth/auth.service.ts
[21] https://api.truenas.com/v26.0/api_methods_auth.login_with_api_key.html
[22] https://api.truenas.com/v26.0/api_methods_auth.me.html
[23] https://github.com/truenas/webui/blob/5ebcbc79b0f5f9a3bae4fa6d32ac3eff802cefdb/src/app/modules/websocket/websocket-handler.service.ts
